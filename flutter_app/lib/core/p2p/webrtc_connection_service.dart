// lib/core/p2p/webrtc_connection_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';
import '../security/encryption_service.dart';

/// WebRTC configuration constants
class WebRTCConfig {
  // Standard STUN servers for NAT traversal
  // Avoid using Dynamic
  static final List<Map<String, dynamic>> defaultIceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {'urls': 'stun:stun2.l.google.com:19302'}, // Added extra STUN server
    {'urls': 'stun:stun3.l.google.com:19302'}, // Added extra STUN server
    {'urls': 'stun:stun4.l.google.com:19302'}, // Added extra STUN server
    // Free TURN server for development/testing
    {
      'urls': 'turn:freeturn.net:3478',
      'username': 'free',
      'credential': 'free'
    },
    // Backup free TURN server
    {
      'urls': 'turn:turn.anyfirewall.com:443?transport=tcp',
      'username': 'webrtc',
      'credential': 'webrtc'
    }
  ];

  // Default media constraints (no audio/video for messaging)
  static final Map<String, dynamic> defaultMediaConstraints = {
    'audio': false,
    'video': false
  };

  // Data channel configuration
  static final RTCDataChannelInit dataChannelConfig = RTCDataChannelInit()
    ..ordered = true
    ..maxRetransmits = 3;
}

/// Enhanced logger for WebRTC connection diagnostics
class WebRTCLogger {
  final Logger _logger = Logger();
  final String _operationId;
  final Stopwatch _stopwatch = Stopwatch()..start();
  final Map<String, DateTime> _phaseTimestamps = {};

  WebRTCLogger({String? operationId})
      : _operationId = operationId ?? const Uuid().v4();

  void startPhase(String phase) {
    _phaseTimestamps[phase] = DateTime.now();
    info('🔄 PHASE START: $phase');
  }

  void endPhase(String phase) {
    if (_phaseTimestamps.containsKey(phase)) {
      final duration = DateTime.now().difference(_phaseTimestamps[phase]!);
      info('✅ PHASE END: $phase - Duration: ${duration.inMilliseconds}ms');
    } else {
      warn('❗ PHASE END: $phase - No start timestamp found');
    }
  }

  void info(String message) {
    _logger
        .i('[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId] $message');
  }

  void debug(String message) {
    _logger
        .d('[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId] $message');
  }

  void warn(String message) {
    _logger.w(
        '[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId] ⚠️ $message');
  }

  void error(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e(
        '[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId] 🔴 $message',
        error,
        stackTrace);
  }

  void iceLog(String message, {bool filtered = false}) {
    final icon = filtered ? '🛑' : '🧊';
    _logger.d(
        '[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId][ICE] $icon $message');
  }

  void connectionLog(String message, {bool isStateChange = false}) {
    final icon = isStateChange ? '🔄' : '🔌';
    _logger.i(
        '[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId][CONN] $icon $message');
  }

  void signalLog(String message, {String? type}) {
    final icon = type == 'offer'
        ? '📤'
        : type == 'answer'
            ? '📥'
            : '📡';
    _logger.i(
        '[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId][SIG] $icon $message');
  }

  void dataChannelLog(String message) {
    _logger.i(
        '[${_stopwatch.elapsedMilliseconds}ms][OP:$_operationId][DATA] 📨 $message');
  }
}

/// Service that manages WebRTC P2P connections
class WebRTCConnectionService {
  final Uuid _uuid = Uuid();
  final EncryptionService _encryptionService;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _hasRemoteDescription = false;

  // Enhanced logging
  late WebRTCLogger _webrtcLogger;

  // WebRTC components
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;

  // Connection state
  bool _isInitiator = false;
  bool _isConnected = false;
  bool _filterIceCandidates = true; // Keep privacy filtering enabled
  String? _connectionId;

  // Disposed flag
  bool _disposed = false;

  // Connection retry attempt counter
  int _connectionAttempts = 0;
  static const int _maxConnectionAttempts = 3;

  // Stream controllers for events
  final _messageStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStateStreamController = StreamController<bool>.broadcast();
  final _signalDataStreamController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _remoteDescriptionSetController = StreamController<void>.broadcast();

  // Public streams for listeners
  Stream<Map<String, dynamic>> get onMessage => _messageStreamController.stream;
  Stream<bool> get onConnectionStateChanged =>
      _connectionStateStreamController.stream;
  Stream<Map<String, dynamic>> get onSignalData =>
      _signalDataStreamController.stream;
  Stream<void> get onRemoteDescriptionSet =>
      _remoteDescriptionSetController.stream;

  // Constructor with dependency injection
  WebRTCConnectionService(this._encryptionService) {
    _webrtcLogger = WebRTCLogger();
  }

  /// Initialize as the connection initiator
  Future<void> initializeAsInitiator({required String sessionId}) async {
    _webrtcLogger = WebRTCLogger();
    _webrtcLogger.startPhase('initializeAsInitiator');
    _isInitiator = true;
    _connectionId = sessionId; // Use provided session ID instead of generating
    _connectionAttempts = 0;
    _webrtcLogger
        .info('Initializing as INITIATOR with session ID: $_connectionId');
    await _createPeerConnection();
    _webrtcLogger.endPhase('initializeAsInitiator');
  }

  /// Initialize as the connection receiver
  Future<void> initializeAsReceiver(String connectionId) async {
    _webrtcLogger = WebRTCLogger();
    _webrtcLogger.startPhase('initializeAsReceiver');
    _isInitiator = false;
    _connectionId = connectionId;
    _connectionAttempts = 0;
    _webrtcLogger
        .info('Initializing as RECEIVER with connection ID: $_connectionId');
    await _createPeerConnection();
    _webrtcLogger.endPhase('initializeAsReceiver');
  }

  /// Create the WebRTC peer connection
  Future<void> _createPeerConnection() async {
    _webrtcLogger.startPhase('createPeerConnection');
    _webrtcLogger.info(
        'Creating peer connection. Initiator: $_isInitiator, Attempt: ${_connectionAttempts + 1}');


    // Configure RTCPeerConnection with improved settings
    final configuration = {
      'iceServers': WebRTCConfig.defaultIceServers,
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy':
          'all', // Use all ICE policy for more connection options
      'bundlePolicy':
          'max-bundle', // Maximize bundling for better NAT traversal
      'rtcpMuxPolicy': 'require', // Require RTCP multiplexing
    };

    _webrtcLogger.debug('Using configuration: ${jsonEncode(configuration)}');

    try {
      // Create peer connection
      _peerConnection = await createPeerConnection(configuration);
      _webrtcLogger.info('Peer connection created successfully');

      // Set up listeners for peer connection events
      _peerConnection!.onIceCandidate = _handleIceCandidate;
      _peerConnection!.onConnectionState = _handleConnectionStateChange;
      _peerConnection!.onIceConnectionState = _handleIceConnectionStateChange;
      _webrtcLogger.debug('Event listeners attached to peer connection');

      // Create data channel if initiator, otherwise wait for it
      if (_isInitiator) {
        _webrtcLogger.info('Creating data channel as initiator');
        _dataChannel = await _peerConnection!
            .createDataChannel('messaging', WebRTCConfig.dataChannelConfig);
        _setupDataChannel();
      } else {
        _webrtcLogger.info('Waiting for data channel as receiver');
        _peerConnection!.onDataChannel = (RTCDataChannel channel) {
          _webrtcLogger.info('Data channel received from remote peer');
          _dataChannel = channel;
          _setupDataChannel();
        };
      }
      _webrtcLogger.endPhase('createPeerConnection');
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error creating peer connection', e, stackTrace);
      _webrtcLogger.endPhase('createPeerConnection');
      rethrow;
    }
  }

  /// Set up the data channel event handlers
  void _setupDataChannel() {
    _webrtcLogger.startPhase('setupDataChannel');
    _webrtcLogger.dataChannelLog('Setting up data channel event handlers');

    _dataChannel!.onMessage = (RTCDataChannelMessage message) {
      _handleDataChannelMessage(message);
    };

    _dataChannel!.onDataChannelState = (RTCDataChannelState state) {
      _webrtcLogger.dataChannelLog('Data channel state changed: $state');

      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _isConnected = true;
        _webrtcLogger.connectionLog(
            'Data channel OPEN - marking connection as established',
            isStateChange: true);
        if (!_disposed) {
          _connectionStateStreamController.add(true);
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
          state == RTCDataChannelState.RTCDataChannelClosing) {
        _isConnected = false;
        _webrtcLogger.connectionLog(
            'Data channel CLOSED - marking connection as disconnected',
            isStateChange: true);
        if (!_disposed) {
          _connectionStateStreamController.add(false);
        }
      }
    };

    _webrtcLogger.endPhase('setupDataChannel');
  }

  /// Handle incoming data channel message
  void _handleDataChannelMessage(RTCDataChannelMessage message) {
    try {
      final String data = message.text;
      _webrtcLogger.dataChannelLog('Received message, length: ${data.length}');
      final Map<String, dynamic> messageData = jsonDecode(data);
      if (!_disposed) {
        _messageStreamController.add(messageData);
      }
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error parsing message', e, stackTrace);
    }
  }

  /// Handle ICE candidate event
  void _handleIceCandidate(RTCIceCandidate candidate) {
    _webrtcLogger.iceLog('Got ICE candidate: ${candidate.candidate}');

    // Filter out local network ICE candidates for privacy if enabled
    if (_shouldFilterIceCandidate(candidate)) {
      _webrtcLogger.iceLog('Filtering out local network ICE candidate',
          filtered: true);
      return;
    }

    if (!_disposed) {
      try {
        _signalDataStreamController.add({
          'type': 'ice_candidate',
          'connectionId': _connectionId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }
        });
        _webrtcLogger.iceLog('Sent ICE candidate to signaling server');
      } catch (e, stackTrace) {
        _webrtcLogger.error(
            'Tried to add ICE candidate to closed stream', e, stackTrace);
      }
    }
  }

  /// Process received signal data (offer, answer, ICE candidate)
  Future<void> processSignalData(Map<String, dynamic> data) async {
    final String type = data['type'];
    _webrtcLogger.signalLog('Processing signal data type: $type');

    // Handle signal type 'signal' which contains nested data
    if (type == 'signal' && data.containsKey('data')) {
      // Extract the inner data which contains the actual WebRTC signal
      final innerData = data['data'];
      final innerType = innerData['type'];
      _webrtcLogger.signalLog(
          'Processing inner signal type: $innerType with _isInitiator=$_isInitiator',
          type: innerType);

      if (innerType == 'offer' && !_isInitiator) {
        _webrtcLogger.signalLog('Handling offer as receiver', type: 'offer');
        await _handleRemoteOffer(innerData['sdp']);
      } else if (innerType == 'answer' && _isInitiator) {
        _webrtcLogger.signalLog('Handling answer as initiator', type: 'answer');
        await _handleRemoteAnswer(innerData['sdp']);
      } else if (innerType == 'ice_candidate') {
        _webrtcLogger.signalLog('Handling inner ICE candidate',
            type: 'ice_candidate');
        await _handleRemoteIceCandidate(innerData['candidate']);
      }
    }
    // Handle direct signal types
    else if (type == 'offer' && !_isInitiator) {
      _webrtcLogger.signalLog('Handling direct offer as receiver',
          type: 'offer');
      await _handleRemoteOffer(data['sdp']);
    } else if (type == 'answer' && _isInitiator) {
      _webrtcLogger.signalLog('Handling direct answer as initiator',
          type: 'answer');
      await _handleRemoteAnswer(data['sdp']);
    } else if (type == 'ice_candidate') {
      _webrtcLogger.signalLog('Handling direct ICE candidate',
          type: 'ice_candidate');
      await _handleRemoteIceCandidate(data['candidate']);
    } else if (type == 'welcome') {
      _webrtcLogger.signalLog('Received welcome message from signaling server',
          type: 'welcome');
    } else {
      _webrtcLogger.warn('Ignoring unhandled signal type: $type');
    }
  }

  /// Create and send offer (initiator only)
  Future<void> createAndSendOffer() async {
    if (!_isInitiator) {
      _webrtcLogger.warn('Cannot create offer - not the initiator');
      return;
    }

    _webrtcLogger.startPhase('createAndSendOffer');
    _webrtcLogger.signalLog('Creating offer', type: 'offer');

    try {
      // Create offer with constraints for better connectivity
      final offerOptions = {
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      };

      // Create offer
      _webrtcLogger.debug('Calling createOffer with options: $offerOptions');
      final offer = await _peerConnection!.createOffer(offerOptions);
      _webrtcLogger.signalLog(
          'Offer SDP created - length: ${offer.sdp?.length}',
          type: 'offer');

      if (offer.sdp != null) {
        String sdpPreview = offer.sdp!.length > 100
            ? '${offer.sdp!.substring(0, 100)}...'
            : offer.sdp!;
        _webrtcLogger.debug('SDP preview: $sdpPreview');
      }

      _webrtcLogger.debug('Setting local description (offer)');
      await _peerConnection!.setLocalDescription(offer);
      _webrtcLogger.signalLog('Local description set successfully',
          type: 'offer');

      if (!_disposed) {
        try {
          _webrtcLogger.signalLog('Sending offer through signaling channel',
              type: 'offer');
          _signalDataStreamController.add({
            'type': 'offer',
            'connectionId': _connectionId,
            'sdp': offer.sdp,
          });
          _webrtcLogger.signalLog('Offer sent to signaling server',
              type: 'offer');
        } catch (e, stackTrace) {
          _webrtcLogger.error(
              'Tried to add offer to closed stream', e, stackTrace);
        }
      }

      _webrtcLogger.endPhase('createAndSendOffer');
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error creating offer', e, stackTrace);

      // Retry connection if under max attempts
      if (_connectionAttempts < _maxConnectionAttempts) {
        _connectionAttempts++;
        _webrtcLogger.warn('Retrying connection, attempt $_connectionAttempts');
        await _peerConnection?.close();
        await _createPeerConnection();
        await Future.delayed(Duration(seconds: 1));
        createAndSendOffer();
      }

      _webrtcLogger.endPhase('createAndSendOffer');
    }
  }

  /// Handle remote offer (receiver only)
  Future<void> _handleRemoteOffer(String sdp) async {
    _webrtcLogger.startPhase('handleRemoteOffer');
    _webrtcLogger.signalLog('Handling remote offer, SDP length: ${sdp.length}',
        type: 'offer');

    try {
      // Set remote description
      _webrtcLogger.debug('Setting remote description (offer)');
      final sessionDescription = RTCSessionDescription(sdp, 'offer');
      await _peerConnection!.setRemoteDescription(sessionDescription);
      _hasRemoteDescription = true;

      // Emit event that remote description was set
      if (!_disposed) {
        _remoteDescriptionSetController.add(null);
        _webrtcLogger.signalLog('Remote description set event emitted',
            type: 'offer');
      }

      _webrtcLogger.debug('Set remote description successfully');

      // Add any pending ICE candidates
      if (_pendingCandidates.isNotEmpty) {
        _webrtcLogger.iceLog(
            'Processing ${_pendingCandidates.length} pending ICE candidates');
        for (var candidate in _pendingCandidates) {
          await _peerConnection!.addCandidate(candidate);
          _webrtcLogger
              .iceLog('Added pending ICE candidate: ${candidate.candidate}');
        }
        _pendingCandidates.clear();
      }

      // Create answer with constraints for better connectivity
      final answerOptions = {
        'offerToReceiveAudio': false,
        'offerToReceiveVideo': false,
      };

      // Create answer
      _webrtcLogger.signalLog('Creating answer', type: 'answer');
      final answer = await _peerConnection!.createAnswer(answerOptions);

      if (answer.sdp != null) {
        String sdpPreview = answer.sdp!.length > 100
            ? '${answer.sdp!.substring(0, 100)}...'
            : answer.sdp!;
        _webrtcLogger.debug('Answer SDP preview: $sdpPreview');
      }

      _webrtcLogger.debug('Setting local description (answer)');
      await _peerConnection!.setLocalDescription(answer);
      _webrtcLogger.signalLog('Local description (answer) set successfully',
          type: 'answer');

      // Send answer through signaling
      _webrtcLogger.signalLog('Sending answer through signaling',
          type: 'answer');
      if (!_disposed) {
        try {
          _signalDataStreamController.add({
            'type': 'answer',
            'connectionId': _connectionId,
            'sdp': answer.sdp,
          });
          _webrtcLogger.signalLog('Answer sent successfully', type: 'answer');
        } catch (e, stackTrace) {
          _webrtcLogger.error(
              'Tried to add answer to closed stream', e, stackTrace);
        }
      }

      _webrtcLogger.endPhase('handleRemoteOffer');
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error in _handleRemoteOffer', e, stackTrace);

      // Retry if under max attempts
      if (_connectionAttempts < _maxConnectionAttempts) {
        _connectionAttempts++;
        _webrtcLogger.warn(
            'Retrying connection as receiver, attempt $_connectionAttempts');
        await _peerConnection?.close();
        await _createPeerConnection();
      }

      _webrtcLogger.endPhase('handleRemoteOffer');
    }
  }

  /// Handle remote answer (initiator only)
  Future<void> _handleRemoteAnswer(String sdp) async {
    _webrtcLogger.startPhase('handleRemoteAnswer');
    _webrtcLogger.signalLog('Handling remote answer, SDP length: ${sdp.length}',
        type: 'answer');

    try {
      // Set remote description
      _webrtcLogger.debug('Setting remote description (answer)');
      final sessionDescription = RTCSessionDescription(sdp, 'answer');
      await _peerConnection!.setRemoteDescription(sessionDescription);
      _hasRemoteDescription = true;

      // Emit event that remote description was set
      if (!_disposed) {
        _remoteDescriptionSetController.add(null);
        _webrtcLogger.signalLog('Remote description set event emitted',
            type: 'answer');
      }

      _webrtcLogger.signalLog('Remote answer processed successfully',
          type: 'answer');
      _webrtcLogger.endPhase('handleRemoteAnswer');
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error handling remote answer', e, stackTrace);
      _webrtcLogger.endPhase('handleRemoteAnswer');
    }
  }

  /// Handle remote ICE candidate
  Future<void> _handleRemoteIceCandidate(
      Map<String, dynamic> candidateData) async {
    _webrtcLogger.startPhase('handleRemoteIceCandidate');
    _webrtcLogger
        .iceLog('Handling remote ICE candidate: ${jsonEncode(candidateData)}');

    try {
      final candidate = RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      );

      if (_hasRemoteDescription) {
        // If we already have the remote description, add the candidate immediately
        _webrtcLogger.iceLog('Adding ICE candidate immediately');
        await _peerConnection!.addCandidate(candidate);
        _webrtcLogger.iceLog('Added ICE candidate successfully');
      } else {
        // Otherwise, store it to add later
        _pendingCandidates.add(candidate);
        _webrtcLogger.iceLog(
            'Stored ICE candidate for later (remote description not set yet)');
      }

      _webrtcLogger.endPhase('handleRemoteIceCandidate');
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error handling remote ICE candidate', e, stackTrace);
      _webrtcLogger.endPhase('handleRemoteIceCandidate');
    }
  }

  /// Send a message through the data channel
  Future<bool> sendMessage(Map<String, dynamic> message) async {
    if (!_isConnected || _dataChannel == null) {
      _webrtcLogger.warn('Cannot send message: not connected');
      return false;
    }

    try {
      final String messageJson = jsonEncode(message);
      _webrtcLogger
          .dataChannelLog('Sending message, length: ${messageJson.length}');
      _dataChannel!.send(RTCDataChannelMessage(messageJson));
      return true;
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error sending message', e, stackTrace);
      return false;
    }
  }

  /// Handle connection state change
  void _handleConnectionStateChange(RTCPeerConnectionState state) {
    _webrtcLogger.connectionLog('Connection state changed: $state',
        isStateChange: true);

    // Check if the stream controller is already closed
    if (_connectionStateStreamController.isClosed || _disposed) {
      _webrtcLogger.debug('Stream controller is closed, ignoring event');
      return;
    }

    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _isConnected = true;
      if (!_disposed) {
        _connectionStateStreamController.add(true);
      }
      _webrtcLogger.connectionLog('Connection established successfully',
          isStateChange: true);
    } else if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      _isConnected = false;
      if (!_disposed) {
        _connectionStateStreamController.add(false);
      }
      _webrtcLogger.connectionLog('Connection state: $state',
          isStateChange: true);

      // Attempt reconnection if failed and not over max attempts
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
          _connectionAttempts < _maxConnectionAttempts) {
        _connectionAttempts++;
        _webrtcLogger.warn(
            'Connection failed, attempting reconnect. Attempt: $_connectionAttempts');
        _tryReconnect();
      }
    }
  }

  // Helper method to attempt reconnection
  Future<void> _tryReconnect() async {
    _webrtcLogger.startPhase('tryReconnect');
    _webrtcLogger.connectionLog('Attempting reconnection', isStateChange: true);

    try {
      await _peerConnection?.close();
      await _createPeerConnection();

      // If initiator, create new offer
      if (_isInitiator) {
        _webrtcLogger.connectionLog(
            'Creating new offer as part of reconnection',
            isStateChange: false);
        await Future.delayed(Duration(seconds: 1));
        await createAndSendOffer();
      }

      _webrtcLogger.endPhase('tryReconnect');
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error during reconnection attempt', e, stackTrace);
      _webrtcLogger.endPhase('tryReconnect');
    }
  }

  void setFilterIceCandidates(bool filter) {
    _filterIceCandidates = filter;
    _webrtcLogger.iceLog('ICE candidate filtering set to: $filter');
  }

  /// Initialize WebRTC for an existing session with reconnection logic
  /// If preserveInitiatorRole is true, the current initiator role will be preserved
  Future<String> initializeForExistingSession(String sessionId,
      {bool? preserveInitiatorRole}) async {
    _webrtcLogger = WebRTCLogger();
    _webrtcLogger.startPhase('initializeForExistingSession');
    _webrtcLogger.info('Initializing WebRTC for existing session: $sessionId');

    final logger = Logger();
    logger.d(
        'RECONNECT_DEBUG: WebRTC initializing for existing session: $sessionId');
    logger.d(
        'RECONNECT_DEEP: WebRTC initializing with current state: isInitiator=$_isInitiator, isConnected=$_isConnected, connectionAttempts=$_connectionAttempts');

    // Store session ID
    _connectionId = sessionId;

    // Only reset initiator role if not preserving it
    if (preserveInitiatorRole != true) {
      // Set as non-initiator by default for existing sessions
      _isInitiator = false;
    } else {
    }
    _hasRemoteDescription = false;
    _connectionAttempts = 0;

    // Close any existing connection before creating a new one
    if (_peerConnection != null) {
      _webrtcLogger
          .info('Closing existing peer connection before creating new one');
      await close();
    }

    // Create fresh peer connection with standard configuration
    _webrtcLogger.info('Creating new peer connection for existing session');
    await _createPeerConnection();

    _webrtcLogger.info(
        'WebRTC initialized for existing session, waiting for signaling reconnection');
    _webrtcLogger.endPhase('initializeForExistingSession');

    // Return the session ID for confirmation
    return _connectionId!;
  }

  /// Handle ICE connection state change
  void _handleIceConnectionStateChange(RTCIceConnectionState state) {
    _webrtcLogger.iceLog('ICE connection state changed: $state');

    // Check if the stream controller is already closed
    if (_connectionStateStreamController.isClosed || _disposed) {
      _webrtcLogger.debug('Stream controller is closed, ignoring event');
      return;
    }

    // Add debugging and reconnection logic as needed
    if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      _webrtcLogger.warn('ICE connection failed, may need restart');

      // If we've failed at the ICE level, try reconnection
      if (_connectionAttempts < _maxConnectionAttempts) {
        _connectionAttempts++;
        _webrtcLogger.warn(
            'ICE connection failed, attempting restart. Attempt: $_connectionAttempts');
        _tryRestartIce();
      }
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
      _webrtcLogger.iceLog('ICE connection established successfully');
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
      _webrtcLogger.iceLog('ICE connection checking connectivity');
    }
  }

  // Helper method to restart ICE if connection fails
  Future<void> _tryRestartIce() async {
    _webrtcLogger.startPhase('tryRestartIce');
    _webrtcLogger.iceLog('Attempting ICE restart');

    try {
      if (_isInitiator && _peerConnection != null) {
        // Create offer with ICE restart flag
        final offerOptions = {
          'offerToReceiveAudio': false,
          'offerToReceiveVideo': false,
          'iceRestart': true
        };

        _webrtcLogger.iceLog('Creating offer with ICE restart flag');
        final offer = await _peerConnection!.createOffer(offerOptions);

        _webrtcLogger.iceLog('Setting local description for ICE restart');
        await _peerConnection!.setLocalDescription(offer);

        if (!_disposed) {
          _webrtcLogger
              .iceLog('Sending ICE restart offer through signaling channel');
          _signalDataStreamController.add({
            'type': 'offer',
            'connectionId': _connectionId,
            'sdp': offer.sdp,
            'iceRestart': true
          });
        }

        _webrtcLogger.iceLog('ICE restart offer sent');
      }

      _webrtcLogger.endPhase('tryRestartIce');
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error during ICE restart', e, stackTrace);
      _webrtcLogger.endPhase('tryRestartIce');
    }
  }

  /// Filter function for ICE candidates
  bool _shouldFilterIceCandidate(RTCIceCandidate candidate) {
    // If filtering is disabled, don't filter anything
    if (!_filterIceCandidates) {
      _webrtcLogger.iceLog('ICE filtering disabled, allowing all candidates');
      return false;
    }

    // Filter out local network candidates that could reveal private info
    final candidateStr = candidate.candidate?.toLowerCase() ?? '';

    // Log candidate type information for debugging
    if (candidateStr.contains('typ host')) {
      _webrtcLogger.iceLog('Host candidate (local): $candidateStr');
    } else if (candidateStr.contains('typ srflx')) {
      _webrtcLogger.iceLog('Server reflexive candidate (STUN): $candidateStr');
    } else if (candidateStr.contains('typ relay')) {
      _webrtcLogger.iceLog('Relay candidate (TURN): $candidateStr');
    }

    // Only filter the most sensitive local addresses
    // Allow IPv6 and some local addresses for better connectivity
    // but filter most internal IPs for privacy
    if (candidateStr.contains('127.0.0.')) {
      _webrtcLogger.iceLog('Filtering loopback address', filtered: true);
      return true;
    }

    // Allow IPv6 local addresses for better connectivity
    if (candidateStr.contains('::1')) {
      _webrtcLogger.iceLog('Allowing IPv6 loopback address');
      return false;
    }

    // Filter sensitive private network addresses
    // More permissive than before to allow better connectivity
    // while still protecting most private networks
    if (candidateStr.contains('192.168.') ||
        candidateStr.contains('10.') ||
        candidateStr.contains('172.16.')) {
      // Let STUN-derived candidates through (these are more secure)
      if (candidateStr.contains('typ srflx') ||
          candidateStr.contains('typ relay')) {
        _webrtcLogger
            .iceLog('Allowing STUN/TURN derived candidate for local network');
        return false;
      }

      // Filter direct local network exposure
      _webrtcLogger.iceLog('Filtering private network address', filtered: true);
      return true;
    }

    _webrtcLogger.iceLog('Allowing ICE candidate');
    return false;
  }

  /// Close the connection
  Future<void> close() async {
    _webrtcLogger.startPhase('close');
    _webrtcLogger.connectionLog('Closing WebRTC connection',
        isStateChange: true);

    try {
      if (_dataChannel != null) {
        _webrtcLogger.dataChannelLog('Closing data channel');
        _dataChannel?.close();
      }

      if (_peerConnection != null) {
        _webrtcLogger.connectionLog('Closing peer connection',
            isStateChange: true);
        await _peerConnection?.close();
      }

      _isConnected = false;

      // Only update if not closed
      if (!_connectionStateStreamController.isClosed && !_disposed) {
        _connectionStateStreamController.add(false);
      }

      _webrtcLogger.connectionLog('WebRTC connection closed successfully',
          isStateChange: true);
    } catch (e, stackTrace) {
      _webrtcLogger.error('Error closing WebRTC connection', e, stackTrace);
    }

    _webrtcLogger.endPhase('close');
  }

  /// Dispose resources
  void dispose() {
    _webrtcLogger.info('Disposing WebRTC connection service resources');
    _disposed = true;
    close();

    _webrtcLogger.debug('Closing stream controllers');
    if (!_messageStreamController.isClosed) {
      _messageStreamController.close();
    }
    if (!_connectionStateStreamController.isClosed) {
      _connectionStateStreamController.close();
    }
    if (!_signalDataStreamController.isClosed) {
      _signalDataStreamController.close();
    }
    if (!_remoteDescriptionSetController.isClosed) {
      _remoteDescriptionSetController.close();
    }

    _webrtcLogger.info('WebRTC connection service disposed');
  }

  /// Check if currently connected
  bool get isConnected => _isConnected;

  /// Set the connected status manually (used when restoring sessions)
  void setConnected(bool connected) {
    _isConnected = connected;
    if (!_connectionStateStreamController.isClosed && !_disposed) {
      _connectionStateStreamController.add(connected);
    }
    _webrtcLogger.connectionLog('Connection status manually set to: $connected',
        isStateChange: true);
  }

  /// Set the initiator status manually (used for debugging)
  void setInitiator(bool initiator) {
    _isInitiator = initiator;
  }

  /// Get connection ID
  String? get connectionId => _connectionId;

  /// Check if this peer is the initiator
  bool get isInitiator => _isInitiator;

  /// Wait for an offer from the initiator
  Future<void> waitForOffer() async {
    _webrtcLogger.signalLog('Waiting for offer from initiator', type: 'offer');
    // The actual waiting happens elsewhere through the onRemoteDescriptionSet stream
  }
}
