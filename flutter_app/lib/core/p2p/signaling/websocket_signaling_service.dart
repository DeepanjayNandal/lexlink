import 'dart:async';
import 'dart:convert';
import 'dart:math' as Math;
import 'package:logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import '../../service/logging_service.dart';
import 'i_signaling_service.dart';
import 'signaling_config.dart';
import 'websocket_url_checker.dart';

/// Connection states for the signaling service
enum SignalingConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error
}

/// WebSocket implementation of the signaling service interface
///
/// Handles connection to a WebSocket-based signaling server with
/// heartbeat mechanism to maintain connection stability.
class WebSocketSignalingService implements ISignalingService {
  final Logger _logger = Logger();
  late final OperationLogger _sigLogger;
  final SignalingConfig _config;

  // WebSocket connection
  WebSocketChannel? _channel;
  String? _peerId;
  String? _targetPeerId;
  String? _serverUrl;
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  DateTime? _lastPongReceived;
  DateTime? _lastMessageTime; // Track any message received, not just pongs
  bool _connectionEstablished = false;
  bool _welcomeReceived = false; // Track if we've received a welcome message
  Timer? _initialPingTimer; // Timer for the first ping after connection
  Timer?
      _applicationKeepAliveTimer; // Timer for application-level keepalive messages
  DateTime? _lastSentMessageTime; // Track when we last sent any message
  DateTime? _welcomeReceivedTime;

  // Stream controllers
  final _signalDataStreamController =
      StreamController<Map<String, dynamic>>.broadcast();

  // Connection state controller
  final _connectionStateController = StreamController<bool>.broadcast();

  // Internal connection state for more detailed tracking
  SignalingConnectionState _connectionState =
      SignalingConnectionState.disconnected;

  // Public stream for signal data
  @override
  Stream<Map<String, dynamic>> get onSignalData =>
      _signalDataStreamController.stream;

  // Public stream for connection state
  @override
  Stream<bool> get onConnectionStateChanged =>
      _connectionStateController.stream;

  /// Constructor with optional configuration
  WebSocketSignalingService([SignalingConfig? config])
      : _config = config ?? SignalingConfig.development() {
    _sigLogger = LoggingService.instance.getOperationLogger('signaling');
  }

  /// Connect to signaling server
  @override
  Future<void> connect(String serverUrl, String peerId) async {
    _sigLogger.startPhase('signaling_connect');

    // Use the WebSocketUrlChecker to get the appropriate URL for the current environment
    final urlChecker = WebSocketUrlChecker();

    // If serverUrl is just a session token or relative path, build the full URL
    if (!serverUrl.startsWith('ws://') && !serverUrl.startsWith('wss://')) {
      serverUrl = urlChecker.getWebSocketUrl(
          hostIp: _config.hostIp, sessionToken: serverUrl);
      print('🔄 WEBSOCKET: Using dynamic URL resolution: $serverUrl');
    } else {
      // Otherwise normalize the existing URL
      serverUrl = urlChecker.normalizeUrl(serverUrl);
    }

    print(
        '🔄 WEBSOCKET: Connecting to signaling server: $serverUrl with peer ID: $peerId');

    _connectionState = SignalingConnectionState.connecting;
    _reconnectAttempts = 0;

    final completer = Completer<void>();

    // Set a timeout for the connection attempt
    final timeoutDuration = _config.connectionTimeout;
    final timeoutTimer = Timer(timeoutDuration, () {
      if (!completer.isCompleted) {
        print(
            '⏱️ WEBSOCKET: Connection attempt timed out after ${timeoutDuration.inSeconds}s');
        _sigLogger.error('Connection attempt timed out');
        completer.completeError(
            TimeoutException('Connection timed out', timeoutDuration));
      }
    });

    try {
      try {
        print('🔄 WEBSOCKET: Creating WebSocket channel to $serverUrl');
        _channel = WebSocketChannel.connect(Uri.parse(serverUrl));

        // Set up error handling for initial connection
        _channel!.sink.done.catchError((error) {
          print('❌ WEBSOCKET: Connection error during connect: $error');
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
          _sigLogger.error('Signaling connection error during connect',
              error: error);
          _handleConnectionError();
        });

        // Listen for messages
        _channel!.stream.listen(
          _handleSignalingMessage,
          onError: (error) {
            print('❌ WEBSOCKET: Stream error: $error');
            _sigLogger.error('Signaling connection error', error: error);
            _handleConnectionError();
          },
          onDone: () {
            print('⚠️ WEBSOCKET: Connection closed by server or network');
            _sigLogger.info('Signaling connection closed');
            _connectionStateController.add(false);
            _tryReconnect();
          },
        );

        // Listen for WebSocket close events
        _channel!.sink.done.then((_) {
          final closeCode = _channel?.closeCode;
          final closeReason = _channel?.closeReason;
          print(
              '❌ WEBSOCKET: Connection closed with code: ${closeCode ?? 'unknown'}, reason: ${closeReason ?? 'none provided'}');
          _sigLogger.error('WebSocket connection closed',
              error:
                  'Code: ${closeCode ?? 'unknown'}, Reason: ${closeReason ?? 'none provided'}');

          _connectionEstablished = false;
          _welcomeReceived = false;

          // Calculate time since last activity
          final timeSinceLastMessage = _lastMessageTime != null
              ? DateTime.now().difference(_lastMessageTime!)
              : null;

          print(
              '⏱️ WEBSOCKET: Connection closed after ${timeSinceLastMessage?.inSeconds ?? 'unknown'} seconds since last message');

          if (_isReconnecting) {
            _tryReconnect();
          }

          // Notify listeners of connection state change
          _connectionStateController.add(false);
        }, onError: (error) {
          print('❌ WEBSOCKET: Error in connection: $error');
          _sigLogger.error('WebSocket connection error', error: error);
        });

        // Complete the connection process
        _peerId = peerId;
        _serverUrl = serverUrl;
        print('✅ WEBSOCKET: Initial connection successful');

        // Send registration message
        final message = {
          'type': 'register',
          'peerId': peerId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'client': 'flutter',
          'version': '1.0.0',
        };
        _channel!.sink.add(jsonEncode(message));
        _sigLogger.info('Connected to signaling server with peer ID: $peerId');
        _connectionEstablished = true;
        _connectionStateController.add(true);

        // Start heartbeat after a short delay
        // This ensures the connection is fully established before sending pings
        _initialPingTimer = Timer(Duration(seconds: 5), () {
          _startHeartbeat();
          print('🔄 WEBSOCKET: Started heartbeat');
        });

        // Complete the connection
        if (!completer.isCompleted) {
          completer.complete();
        }

        // Cancel the timeout timer
        timeoutTimer.cancel();

        _sigLogger.endPhase('signaling_connect');
        print('✅ WEBSOCKET: Connection process completed successfully');
      } catch (e) {
        // Wait for the connection to complete or timeout
        timeoutTimer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
        print('❌ WEBSOCKET: Connection failed: $e');
        _sigLogger.error('Failed to connect to signaling server',
            error: e.toString());
        rethrow;
      }

      return completer.future;
    } catch (e) {
      String errorMessage = 'Connection to signaling server failed';
      if (e.toString().contains('Connection refused') ||
          e.toString().contains('Connection reset')) {
        errorMessage =
            'Cannot connect to signaling server at $serverUrl. Server may be down or unreachable.';
      } else if (e.toString().contains('SocketException')) {
        errorMessage =
            'Network error connecting to signaling server at $serverUrl';
      } else if (e is TimeoutException) {
        errorMessage = 'Connection to signaling server timed out';
      }

      _sigLogger.error(errorMessage, error: e.toString());
      _connectionEstablished = false;
      _welcomeReceived = false;
      _connectionStateController.add(false);
      _tryReconnect();
      _sigLogger.endPhase('signaling_connect');
      throw Exception(errorMessage);
    }
  }

  /// Start heartbeat timer to keep connection alive
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_config.heartbeatInterval, (_) {
      _sendPing();
      _checkConnectionTimeout(); // IMPROVEMENT: Renamed to reflect broader check
    });
    print(
        '🔄 WEBSOCKET: Heartbeat timer started with interval: ${_config.heartbeatInterval.inSeconds}s');
    _sigLogger.debug(
        'Heartbeat timer started with interval: ${_config.heartbeatInterval.inSeconds}s');
  }

  /// IMPROVEMENT: Start application-level keepalive messages
  void _startApplicationKeepAlive() {
    _applicationKeepAliveTimer?.cancel();

    // Use a slightly different interval than the ping to avoid collision
    // and provide additional coverage
    final keepAliveInterval =
        Duration(seconds: _config.heartbeatInterval.inSeconds + 5);

    _applicationKeepAliveTimer = Timer.periodic(keepAliveInterval, (_) {
      // Only send keepalive if we haven't sent any message recently
      if (_lastSentMessageTime != null) {
        final timeSinceLastMessage =
            DateTime.now().difference(_lastSentMessageTime!);

        // If we've sent a message in the last half of our interval, skip this keepalive
        if (timeSinceLastMessage < keepAliveInterval ~/ 2) {
          print(
              '🔄 WEBSOCKET: Recent message sent, skipping application keepalive');
          return;
        }
      }

      _sendApplicationKeepAlive();
    });

    print(
        '🔄 WEBSOCKET: Application keepalive started with interval: ${keepAliveInterval.inSeconds}s');
    _sigLogger.debug(
        'Application keepalive started with interval: ${keepAliveInterval.inSeconds}s');
  }

  /// Send application-level keepalive message
  void _sendApplicationKeepAlive() {
    if (_channel?.sink == null) {
      print(
          '⚠️ WEBSOCKET: Cannot send keepalive: WebSocket connection is null');
      return;
    }

    try {
      final keepAliveMessage = {
        'type': 'app_keepalive',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'id': Uuid().v4().substring(0, 8),
        'peerId': _peerId,
      };

      _channel!.sink.add(jsonEncode(keepAliveMessage));
      _lastSentMessageTime = DateTime.now();

      print('🔄 WEBSOCKET: Sent application-level keepalive message');
      if (_config.verboseLogging) {
        _sigLogger.debug('Sent application-level keepalive message');
      }
    } catch (e) {
      print('❌ WEBSOCKET: Error sending application keepalive: $e');
      _sigLogger.error('Error sending application keepalive', error: e);
      // Don't trigger connection error here - let the ping/pong system handle that
    }
  }

  /// Send ping message to keep connection alive
  void _sendPing() {
    if (_channel != null && _connectionEstablished) {
      try {
        final pingId = Uuid().v4().substring(0, 8);
        final pingMessage = {
          'type': 'ping',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'id': pingId,
        };

        // Log exact message format for debugging
        final pingJson = jsonEncode(pingMessage);
        print('🔄 WEBSOCKET: Sending ping with ID: $pingId');
        print('📤 PING FORMAT: $pingJson');
        _sigLogger.debug('Ping message format: $pingJson');

        _channel!.sink.add(pingJson);
        _lastSentMessageTime = DateTime.now();
      } catch (e, stackTrace) {
        print('❌ WEBSOCKET: Error sending ping: $e');
        _sigLogger.error('Error sending ping',
            error: e, stackTrace: stackTrace);
      }
    }
  }

  /// Check if connection has timed out
  void _checkConnectionTimeout() {
    final now = DateTime.now();

    // Only initialize timestamps if null, but set to a value that won't immediately trigger timeout
    if (_lastPongReceived == null) {
      _lastPongReceived = now;
      print('🔄 WEBSOCKET: Initializing _lastPongReceived');
    }

    if (_lastMessageTime == null) {
      _lastMessageTime = now;
      print('🔄 WEBSOCKET: Initializing _lastMessageTime');
    }

    // Calculate time since last pong and any message
    final timeSinceLastPong = now.difference(_lastPongReceived!);
    final timeSinceLastMessage = now.difference(_lastMessageTime!);

    // Log the current state for debugging
    print(
        '🔄 WEBSOCKET: Time since last pong: ${timeSinceLastPong.inSeconds}s, ' +
            'Time since last message: ${timeSinceLastMessage.inSeconds}s, ' +
            'Heartbeat interval: ${_config.heartbeatInterval.inSeconds}s');

    // Check for timeout - use a more generous timeout (3x the heartbeat interval)
    final timeoutThreshold = _config.heartbeatInterval * 3;

    // First check if we've received any message recently (more lenient)
    if (timeSinceLastMessage > timeoutThreshold) {
      print(
          '⚠️ WEBSOCKET: No messages received for ${timeSinceLastMessage.inSeconds} seconds - connection may be dead');

      // If we haven't received any message in 3x the heartbeat interval, consider it a timeout
      if (timeSinceLastMessage > timeoutThreshold * 2) {
        print(
            '❌ WEBSOCKET: Connection timeout - no messages received for ${timeSinceLastMessage.inSeconds} seconds');
        _handleConnectionError();
        return;
      }
    }

    // If we've received messages but no pongs, the server might be having issues with the ping handler
    if (timeSinceLastPong > timeoutThreshold &&
        timeSinceLastMessage < timeoutThreshold) {
      print(
          '⚠️ WEBSOCKET: Messages being received but no pongs - server might have ping handler issues');
    }
  }

  /// Handle connection error and attempt reconnection
  void _handleConnectionError() {
    print('❌ WEBSOCKET: Connection error detected, will attempt reconnection');
    _connectionStateController.add(false);
    _heartbeatTimer?.cancel();
    _initialPingTimer?.cancel(); // Cancel initial ping timer if active
    _applicationKeepAliveTimer?.cancel(); // Cancel keepalive timer
    _tryReconnect();
  }

  /// Try to reconnect to the signaling server
  void _tryReconnect() {
    if (_reconnectAttempts >= _config.maxReconnectAttempts) {
      print(
          '⚠️ WEBSOCKET: Max reconnect attempts reached (${_config.maxReconnectAttempts})');
      _sigLogger.error('Max reconnect attempts reached');
      _connectionState = SignalingConnectionState.error;
      return;
    }

    _isReconnecting = true;
    _connectionState = SignalingConnectionState.reconnecting;
    _reconnectAttempts++;

    // Cancel any existing reconnect timer
    _reconnectTimer?.cancel();

    // Calculate backoff delay (exponential with jitter)
    final baseDelay = 1000; // 1 second
    final maxDelay = 30000; // 30 seconds
    final exponentialDelay = baseDelay * Math.pow(2, _reconnectAttempts - 1);
    final jitter = Math.Random().nextInt(1000); // Add up to 1 second of jitter
    final delay = Math.min(exponentialDelay + jitter, maxDelay);

    print(
        '🔄 WEBSOCKET: Reconnect attempt $_reconnectAttempts in ${delay / 1000} seconds');
    _sigLogger.info(
        'Reconnect attempt $_reconnectAttempts in ${delay / 1000} seconds');

    _reconnectTimer = Timer(Duration(milliseconds: delay.toInt()), () async {
      print('🔄 WEBSOCKET: Attempting reconnect $_reconnectAttempts...');
      _sigLogger.info('Attempting reconnect $_reconnectAttempts');

      try {
        if (_serverUrl != null && _peerId != null) {
          await connect(_serverUrl!, _peerId!);
          print('✅ WEBSOCKET: Reconnected successfully');
          _sigLogger.info('Reconnected successfully');
          _isReconnecting = false;
          _connectionState = SignalingConnectionState.connected;
        } else {
          print(
              '❌ WEBSOCKET: Cannot reconnect - missing server URL or peer ID');
          _sigLogger.error('Cannot reconnect - missing server URL or peer ID');
          _connectionState = SignalingConnectionState.error;
        }
      } catch (e) {
        print('❌ WEBSOCKET: Reconnect attempt $_reconnectAttempts failed: $e');
        _sigLogger.error('Reconnect attempt $_reconnectAttempts failed',
            error: e.toString());
        _tryReconnect(); // Try again
      }
    });
  }

  /// Handle incoming message from signaling server
  void _handleSignalingMessage(dynamic data) {
    try {
      // CRITICAL FIX: Convert binary data to string before parsing
      String messageString;
      if (data is List<int>) {
        // Convert Uint8Array to string
        messageString = String.fromCharCodes(data);
        print(
            '🔧 BERU-DEBUG: Binary data converted to string (length: ${messageString.length})');
      } else if (data is String) {
        messageString = data;
        print(
            '🔧 BERU-DEBUG: String data received directly (length: ${messageString.length})');
      } else {
        messageString = data.toString();
        print(
            '🔧 BERU-DEBUG: Unknown data type converted to string: ${data.runtimeType}');
      }

      final Map<String, dynamic> message = jsonDecode(messageString);
      final messageType = message['type'] ?? 'unknown';

      print('✅ BERU-MSG-PARSED: Type="$messageType" | Success=true');

      // Handle ping/pong messages for heartbeat
      if (messageType == 'pong') {
        _lastPongReceived = DateTime.now();
        final echoTimestamp = message['echo'];
        final pingId = message['id'] ?? 'unknown';
        final latency = echoTimestamp != null
            ? DateTime.now().millisecondsSinceEpoch - echoTimestamp
            : null;
        // Remove excessive pong logging - only log connection issues
        return; // Don't forward heartbeat messages to listeners
      }

      // Handle application keepalive acknowledgements
      if (messageType == 'app_keepalive_ack') {
        // Remove excessive keepalive logging
        return; // Don't forward keepalive messages to listeners
      }

      // CRITICAL: Log all non-heartbeat messages
      if (messageType == 'welcome') {
        print(
            '🎉 BERU-WELCOME: Server welcome received | Connection established');
        _welcomeReceived = true;
        _welcomeReceivedTime = DateTime.now();
        _connectionEstablished = true;
        _connectionStateController.add(true);
      } else if (messageType == 'error') {
        print('❌ BERU-ERROR: Server error | Message="${message['message']}"');
        _sigLogger.error('Server error: ${message['message']}');
      } else if (messageType == 'signal') {
        final from = message['from'] ?? 'unknown';
        final innerType = message['data']?['type'] ?? 'unknown';
        print(
            '📡 BERU-SIGNAL: From="$from" | Type="$innerType" | Forwarding to listeners');
      } else if (messageType == 'client_name') {
        final clientName = message['clientTemporaryName'] ?? 'unknown';
        print(
            '👤 BERU-CLIENT-NAME: Received client name="$clientName" | Forwarding to QR service');
      } else if (messageType == 'register_receiver') {
        final peerId = message['peerId'] ?? 'unknown';
        print('📋 BERU-REGISTER: Receiver peer="$peerId" | Connection pairing');
      } else {
        print(
            '❓ BERU-UNKNOWN-MSG: Type="$messageType" | Forwarding to listeners');
      }

      // Forward message to listeners
      print(
          '➡️ BERU-FORWARD: Sending to ${_signalDataStreamController.hasListener ? 'active' : 'NO'} listeners');
      _signalDataStreamController.add(message);
    } catch (e, stackTrace) {
      print(
          '💥 BERU-PARSE-FAIL: Error="$e" | DataType="${data.runtimeType}" | DataLength="${data.toString().length}"');
      print('🔍 BERU-RAW-DATA: $data');
      _sigLogger.error('Error parsing signaling message',
          error: e, stackTrace: stackTrace);
    }
  }

  /// Set the target peer ID for sending messages
  @override
  void setTargetPeer(String peerId) {
    _targetPeerId = peerId;
    _sigLogger.signalLog('Target peer set to: $peerId');
  }

  /// Send signal data to the target peer
  @override
  void sendSignalData(Map<String, dynamic> data) {
    if (_targetPeerId == null) {
      _sigLogger.warn('Cannot send signal data: no target peer set');
      return;
    }

    final messageType = data['type'] ?? 'unknown';
    if (_config.verboseLogging) {
      _sigLogger.signalLog(
          'Sending signal data of type $messageType to $_targetPeerId',
          type: messageType);
    }

    final message = {
      'type': 'signal',
      'to': _targetPeerId,
      'from': _peerId,
      'data': data,
    };

    sendToSignalingServer(message);
  }

  /// Send a register_receiver message to the signaling server
  @override
  void sendRegisterReceiver(Map<String, dynamic> registerMessage) {
    if (_config.verboseLogging) {
      _sigLogger.signalLog(
          'Sending register_receiver message to ${registerMessage['to']}');
    }
    sendToSignalingServer(registerMessage);
  }

  /// Send a message to the signaling server
  @override
  void sendToSignalingServer(Map<String, dynamic> message) {
    if (_channel?.sink == null) {
      print(
          '❌ WEBSOCKET: Cannot send message: not connected to signaling server');
      _sigLogger
          .error('Cannot send message: not connected to signaling server');
      return;
    }

    try {
      final messageType = message['type'] ?? 'unknown';
      print('📤 WEBSOCKET: Sending message to server: $messageType');
      if (_config.verboseLogging) {
        _sigLogger.signalLog(
            'Sending message to signaling server: $messageType',
            type: messageType);
      }

      _channel!.sink.add(jsonEncode(message));
      _lastSentMessageTime = DateTime.now(); // Track when we sent a message
    } catch (e, stackTrace) {
      print('❌ WEBSOCKET: Error sending message to server: $e');
      _sigLogger.error('Error sending message to signaling server',
          error: e, stackTrace: stackTrace);

      // If we can't send messages, consider the connection broken
      if (_connectionEstablished) {
        _handleConnectionError();
      }
    }
  }

  /// Send a custom message with a specific type
  @override
  void sendCustomMessage(String type, Map<String, dynamic> payload) {
    final message = {
      'type': type,
      ...payload,
      'from': _peerId,
    };

    sendToSignalingServer(message);
  }

  /// Close the signaling connection
  @override
  void close() {
    _sigLogger.startPhase('signaling_close');
    print('🔄 WEBSOCKET: Closing signaling connection');

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _initialPingTimer?.cancel();
    _initialPingTimer = null;
    _applicationKeepAliveTimer?.cancel();
    _applicationKeepAliveTimer = null;
    _connectionEstablished = false;

    try {
      if (_channel != null) {
        _sigLogger.info('Closing signaling connection');
        print('🔄 WEBSOCKET: Closing WebSocket channel');
        _channel?.sink.close();
        _channel = null;
        _connectionStateController.add(false);
        print('✅ WEBSOCKET: Connection closed successfully');
      }
    } catch (e, stackTrace) {
      print('❌ WEBSOCKET: Error closing connection: $e');
      _sigLogger.error('Error closing signaling connection',
          error: e, stackTrace: stackTrace);
    }

    _sigLogger.endPhase('signaling_close');
  }

  /// Dispose resources
  @override
  void dispose() {
    _sigLogger.info('Disposing signaling service resources');

    close();

    if (!_signalDataStreamController.isClosed) {
      _signalDataStreamController.close();
    }

    if (!_connectionStateController.isClosed) {
      _connectionStateController.close();
    }

    _sigLogger.info('Signaling service disposed');
  }

  /// Get the peer ID
  @override
  String? get peerId => _peerId;

  /// Get the target peer ID
  @override
  String? get targetPeerId => _targetPeerId;

  /// Check if connected to signaling server
  @override
  bool get isConnected => _channel != null && _connectionEstablished;
}
