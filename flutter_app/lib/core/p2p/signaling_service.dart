// lib/core/p2p/signaling_service.dart

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'webrtc_connection_service.dart';
import '../service/global_error_handler.dart';

/// Service for signaling between WebRTC peers
class SignalingService {
  final Logger _logger = Logger();
  late WebRTCLogger _sigLogger;

  // WebSocket connection
  WebSocketChannel? _channel;
  String? _peerId;
  String? _targetPeerId;
  String? _serverUrl;
  Timer? _reconnectTimer;

  // Heartbeat and backoff fields
  Timer? _heartbeatTimer;
  Duration _base = const Duration(seconds: 1);
  final Duration _maxBackoff = const Duration(seconds: 45);

  // Consolidated connection state
  bool _isConnecting = false;
  bool _isConnected = false;

  // Callback for MessageService to register
  Future<void> Function()? onConnectionOpen;

  // Stream controllers
  final _signalDataStreamController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Connection state controller
  final _connectionStateController = StreamController<bool>.broadcast();

  // Public stream for signal data
  Stream<Map<String, dynamic>> get onSignalData =>
      _signalDataStreamController.stream;

  // Public stream for connection state
  Stream<bool> get onConnectionStateChanged =>
      _connectionStateController.stream;

  // Connection state getter/setter
  bool get isConnected => _isConnected;
  set isConnected(bool value) {
    _isConnected = value;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(value);
    }
  }

  // Constructor
  SignalingService() {
    _sigLogger = WebRTCLogger();
  }

  /// Idempotent connect/ensureConnected
  Future<void> ensureConnected() async {
    if (isConnected || _isConnecting || _serverUrl == null || _peerId == null)
      return;
    await connect(_serverUrl!, _peerId!);
  }

  /// Connect to signaling server
  Future<void> connect(String serverUrl, String peerId) async {
    if (isConnected || _isConnecting) return;
    _isConnecting = true;

    _sigLogger = WebRTCLogger();
    _sigLogger.startPhase('signaling_connect');

    _peerId = peerId;
    _serverUrl = serverUrl;

    _sigLogger.info(
        'Connecting to signaling server: $serverUrl with peer ID: $peerId');
    _logger.d(
        'RECONNECT_DEBUG: Connecting to signaling server: $serverUrl with peer ID: $peerId');

    try {
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      _logger.d('RECONNECT_DEBUG: WebSocket channel created for $serverUrl');

      // Send registration message
      final message = {
        'type': 'register',
        'peerId': peerId,
      };
      _logger.d(
          'RECONNECT_DEBUG: Sending registration message with peerId: $peerId');
      sendToSignalingServer(message);

      // Listen for messages
      _logger.d('RECONNECT_DEBUG: Setting up WebSocket listeners');
      _channel!.stream.listen(
        (dynamic data) => _handleSignalingMessage(data),
        onError: (error) {
          _sigLogger.error('Signaling connection error', error);
          _logger.d('RECONNECT_DEBUG: WebSocket error: $error');
          _handleConnectionError();
        },
        onDone: () {
          _sigLogger.info('Signaling connection closed');
          _logger.d('RECONNECT_DEBUG: WebSocket connection closed');
          _onWebSocketClose();
        },
      );

      _sigLogger.info('Connected to signaling server with peer ID: $peerId');
      _logger.d(
          'RECONNECT_DEBUG: Successfully connected to signaling server with peer ID: $peerId');
      _onWebSocketOpen();
      _sigLogger.endPhase('signaling_connect');
    } catch (e, stackTrace) {
      _sigLogger.error('Failed to connect to signaling server', e, stackTrace);
      _logger.d('RECONNECT_DEBUG: Failed to connect to signaling server: $e');
      isConnected = false;
      _scheduleReconnect();
      _sigLogger.endPhase('signaling_connect');
      rethrow;
    } finally {
      _isConnecting = false;
    }
  }

  /// Open/close handlers
  void _onWebSocketOpen() async {
    isConnected = true;
    _base = const Duration(seconds: 1);

    GlobalErrorHandler.logInfo('CONNECTION_STATE: WebSocket connection opened',
        data: {
          'peer_id': _peerId,
          'server_url': _serverUrl,
        });

    _startHeartbeat();
    if (onConnectionOpen != null) {
      await onConnectionOpen!.call();
    }
  }

  void _onWebSocketClose() {
    isConnected = false;

    GlobalErrorHandler.logWarning(
        'CONNECTION_STATE: WebSocket connection closed',
        data: {
          'peer_id': _peerId,
          'server_url': _serverUrl,
        });

    _stopHeartbeat();
    _scheduleReconnect();
  }

  /// Backoff + heartbeat
  Future<Duration> _nextDelay() async {
    final low = _base.inMilliseconds;
    final high = 3 * low;
    final jitter = low + math.Random().nextInt(math.max(1, high - low + 1));
    _base = Duration(
        milliseconds: math.min(
            (_base.inMilliseconds * 3) ~/ 2, _maxBackoff.inMilliseconds));
    return Duration(milliseconds: math.min(jitter, _maxBackoff.inMilliseconds));
  }

  void _scheduleReconnect() {
    if (_isConnecting || isConnected) return;
    _nextDelay().then((d) {
      Future.delayed(d, () async {
        if (!isConnected) await connect(_serverUrl!, _peerId!);
      });
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (isConnected) _sendPing();
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _sendPing() {
    if (_channel != null) {
      try {
        _channel!.sink.add(jsonEncode({
          'type': 'ping',
          'timestamp': DateTime.now().millisecondsSinceEpoch
        }));
      } catch (e) {
        _logger.e('Error sending ping: $e');
        _handleDisconnection();
      }
    }
  }

  void _handleDisconnection() {
    isConnected = false;
    _stopHeartbeat();
    _scheduleReconnect();
  }

  /// Handle connection error and attempt reconnection
  void _handleConnectionError() {
    isConnected = false;
    _scheduleReconnect();
  }

  /// Handle incoming message from signaling server
  void _handleSignalingMessage(dynamic data) {
    try {
      final Map<String, dynamic> message = jsonDecode(data);
      final messageType = message['type'] ?? 'unknown';

      _sigLogger.signalLog('Received signaling message: $messageType',
          type: messageType);
      _logger.d('SIGNAL_SERVER_DEBUG: Received message type: $messageType');

      if (messageType == 'welcome') {
        _sigLogger.info('Received welcome from signaling server');
        _logger.d('SIGNAL_SERVER_DEBUG: Received welcome message');
      } else if (messageType == 'signal') {
        final from = message['from'] ?? 'unknown';
        final innerType = message['data']?['type'] ?? 'unknown';
        _sigLogger.signalLog('Received signal from $from of type $innerType',
            type: innerType);
        _logger.d(
            'SIGNAL_SERVER_DEBUG: Received signal from $from of type $innerType');
      }

      // Only process messages for this peer
      _signalDataStreamController.add(message);
      _logger.d('SIGNAL_SERVER_DEBUG: Forwarded message to WebRTC service');
    } catch (e, stackTrace) {
      _sigLogger.error('Error parsing signaling message', e, stackTrace);
    }
  }

  /// Set the target peer ID for sending messages
  void setTargetPeer(String peerId) {
    _targetPeerId = peerId;
    _sigLogger.signalLog('Target peer set to: $peerId');
  }

  /// Send signal data to the target peer
  void sendSignalData(Map<String, dynamic> data) {
    if (_targetPeerId == null) {
      _sigLogger.warn('Cannot send signal data: no target peer set');
      _logger.d(
          'SIGNAL_SERVER_DEBUG: Cannot send signal data: no target peer set');
      return;
    }

    final messageType = data['type'] ?? 'unknown';
    _sigLogger.signalLog(
        'Sending signal data of type $messageType to $_targetPeerId',
        type: messageType);
    _logger.d(
        'SIGNAL_SERVER_DEBUG: Sending signal data of type $messageType to $_targetPeerId');

    final message = {
      'type': 'signal',
      'to': _targetPeerId,
      'from': _peerId,
      'data': data,
    };

    sendToSignalingServer(message);
    _logger.d('SIGNAL_SERVER_DEBUG: Signal message sent to server');
  }

  /// Send a register_receiver message to the signaling server
  void sendRegisterReceiver(Map<String, dynamic> registerMessage) {
    _sigLogger.signalLog(
        'Sending register_receiver message to ${registerMessage['to']}');
    sendToSignalingServer(registerMessage);
  }

  /// Send a message to the signaling server
  void sendToSignalingServer(Map<String, dynamic> message) {
    if (_channel?.sink == null) {
      _sigLogger
          .error('Cannot send message: not connected to signaling server');
      return;
    }

    try {
      final messageType = message['type'] ?? 'unknown';
      _sigLogger.signalLog('Sending message to signaling server: $messageType',
          type: messageType);

      _channel!.sink.add(jsonEncode(message));
    } catch (e, stackTrace) {
      _sigLogger.error(
          'Error sending message to signaling server', e, stackTrace);
    }
  }

  /// Close the signaling connection
  void close() {
    _sigLogger.startPhase('signaling_close');

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      if (_channel != null) {
        _sigLogger.info('Closing signaling connection');
        _channel?.sink.close();
        _channel = null;
        isConnected = false;
      }
    } catch (e, stackTrace) {
      _sigLogger.error('Error closing signaling connection', e, stackTrace);
    }

    _sigLogger.endPhase('signaling_close');
  }

  /// Dispose resources
  void dispose() {
    _heartbeatTimer?.cancel();
    _channel?.sink.close();
    _connectionStateController.close();

    _sigLogger.info('Signaling service disposed');
  }

  /// Get the peer ID
  String? get peerId => _peerId;

  /// Get the target peer ID
  String? get targetPeerId => _targetPeerId;
}
