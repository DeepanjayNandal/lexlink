// lib/features/p2p/qr_connection_service.dart
// Update the necessary methods

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/p2p/webrtc_connection_service.dart';
import '../../core/p2p/signaling_service.dart';
import '../../features/session/session_service.dart';
import '../../features/session/session_model.dart';
import '../../features/session/session_key_service.dart';
import '../../features/session/session_validator.dart';
import '../../features/contacts/contact_service.dart';
import '../../features/contacts/contact_key_service.dart';
import '../../core/service/global_error_handler.dart';

/// Class representing connection information for QR code
/// Contains information needed to establish a secure P2P connection
class ConnectionInfo {
  final String peerId;
  final String sessionId;
  final String signalServerUrl;
  final String verificationCode;
  final String? encryptionKey; // Add encryption key to QR code

  ConnectionInfo({
    required this.peerId,
    required this.sessionId,
    required this.signalServerUrl,
    required this.verificationCode,
    this.encryptionKey, // Optional for backward compatibility
  });

  /// Convert connection info to QR code data string
  /// Encodes the connection details as a base64 string for QR code generation
  String toQrString() {
    final Map<String, dynamic> data = {
      'peerId': peerId,
      'sessionId': sessionId,
      'server': signalServerUrl,
      'verification': verificationCode,
      'version': '2', // Increment version for key sharing support
    };

    // Include encryption key if available
    if (encryptionKey != null) {
      data['encryptionKey'] = encryptionKey;
    }

    return base64Encode(utf8.encode(jsonEncode(data)));
  }

  /// Create ConnectionInfo from QR code data string
  /// Decodes the base64 string back to connection details
  factory ConnectionInfo.fromQrString(String qrString) {
    try {
      // Clean the input string
      String cleanedQrString = qrString.trim();

      // Add proper base64 padding if needed
      while (cleanedQrString.length % 4 != 0) {
        cleanedQrString += '=';
      }

      // Log the input for debugging
      GlobalErrorHandler.logDebug(
        'Parsing QR string',
        data: {
          'original_length': qrString.length,
          'cleaned_length': cleanedQrString.length,
          'first_50_chars':
              qrString.length > 50 ? qrString.substring(0, 50) : qrString,
          'last_50_chars': qrString.length > 50
              ? qrString.substring(qrString.length - 50)
              : qrString,
        },
      );

      final String jsonString = utf8.decode(base64Decode(cleanedQrString));
      final Map<String, dynamic> data = jsonDecode(jsonString);

      // Validate required fields
      if (!data.containsKey('peerId') ||
          !data.containsKey('sessionId') ||
          !data.containsKey('server') ||
          !data.containsKey('verification')) {
        throw FormatException('Missing required QR code fields');
      }

      return ConnectionInfo(
        peerId: data['peerId'],
        sessionId: data['sessionId'],
        signalServerUrl: data['server'],
        verificationCode: data['verification'],
        encryptionKey:
            data['encryptionKey'], // Extract encryption key if present
      );
    } catch (e) {
      GlobalErrorHandler.logWarning(
        'QR code parsing failed',
        data: {
          'error': e.toString(),
          'qr_length': qrString.length,
          'qr_preview': qrString.length > 100
              ? qrString.substring(0, 100) + '...'
              : qrString,
        },
      );
      throw FormatException('Invalid QR code format: $e');
    }
  }
}

/// Class to hold session information
class SessionInfo {
  final String sessionId;
  final String contactId;

  SessionInfo({
    required this.sessionId,
    required this.contactId,
  });
}

/// Enhanced QR-based connection service with robust error handling
class QRConnectionService {
  final Logger _logger = Logger();
  final Uuid _uuid = Uuid();
  final WebRTCConnectionService _webRTCService;
  final SignalingService _signalingService;
  final SessionService _sessionService;
  final ContactService _contactService;
  final ContactKeyService _contactKeyService;
  final SessionKeyService _sessionKeyService;
  late final SessionValidator _sessionValidator;

  // Enhanced logging
  late WebRTCLogger _qrLogger;

  // Current operation ID for tracking connection flows
  String? _currentConnectionId;

  // Add getter for ContactKeyService
  ContactKeyService get contactKeyService => _contactKeyService;

  // Connection state management
  bool _connectionStepsCompleted = false;
  bool _isConnecting = false;

  // Retry logic
  int _connectionAttempts = 0;
  static const int _maxConnectionAttempts = 10;
  static const Duration _connectionTimeout = Duration(seconds: 10);

  // Stream controllers for connection state
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();

  // Callback for target peer storage
  Function(String sessionId, String targetPeerId)? onTargetPeerStored;

  // Callback for setting current session after pairing
  Function(String sessionId, String contactId, String contactName)?
      onSessionEstablished;

  /// Constructor sets up signal data listeners
  QRConnectionService(
    this._webRTCService,
    this._signalingService,
    this._sessionService,
    this._contactService,
    this._contactKeyService,
    this._sessionKeyService,
  ) {
    // Initialize session validator with dependency injection
    _sessionValidator = SessionValidator(
      sessionService: _sessionService,
      contactService: _contactService,
      sessionKeyService: _sessionKeyService,
    );

    _qrLogger = WebRTCLogger();
    GlobalErrorHandler.logInfo(
        'QRConnectionService initialized with session validator');

    // Listen for signal data from WebRTC service
    _webRTCService.onSignalData.listen((data) {
      try {
        GlobalErrorHandler.logDebug(
          'Received signal data from WebRTC service',
          data: {'signal_type': data['type']},
        );
        _handleWebRTCSignalData(data);
      } catch (e, stackTrace) {
        GlobalErrorHandler.captureConnectionError(
          e,
          stackTrace: stackTrace,
          connectionPhase: 'webrtc_signal_handling',
        );
      }
    });

    // Listen for signal data from signaling service
    _signalingService.onSignalData.listen((data) {
      try {
        GlobalErrorHandler.logDebug(
          'Received signal data from signaling service',
          data: {'signal_type': data['type']},
        );
        _handleSignalingData(data);
      } catch (e, stackTrace) {
        GlobalErrorHandler.captureConnectionError(
          e,
          stackTrace: stackTrace,
          connectionPhase: 'signaling_data_handling',
        );
      }
    });

    // Listen for WebRTC connection state changes and forward them
    _webRTCService.onConnectionStateChanged.listen((isConnected) {
      try {
        GlobalErrorHandler.logDebug(
          'WebRTC connection state changed',
          data: {'is_connected': isConnected},
        );
        _connectionStateController.add(isConnected);
      } catch (e, stackTrace) {
        GlobalErrorHandler.captureConnectionError(
          e,
          stackTrace: stackTrace,
          connectionPhase: 'webrtc_state_forwarding',
        );
      }
    });
  }

  /// Check if a session exists for a contact with enhanced error handling
  Future<SessionInfo?> checkExistingSession(String contactId) async {
    _qrLogger.startPhase('checkExistingSession');

    try {
      GlobalErrorHandler.logInfo(
        'Checking for existing session',
        data: {'contact_id': contactId},
      );

      // Validate contact exists
      final contact = await _contactService.getContact(contactId);
      if (contact == null) {
        GlobalErrorHandler.logWarning('Contact not found',
            data: {'contact_id': contactId});
        _qrLogger.endPhase('checkExistingSession');
        return null;
      }

      // Get active session for contact
      final session =
          await _sessionService.getActiveSessionForContact(contactId);

      if (session != null) {
        GlobalErrorHandler.logInfo(
          'Found existing session',
          data: {
            'session_id': session.id,
            'contact_id': contactId,
          },
        );
        _qrLogger.endPhase('checkExistingSession');
        return SessionInfo(
          sessionId: session.id,
          contactId: contactId,
        );
      } else {
        GlobalErrorHandler.logDebug('No active session found',
            data: {'contact_id': contactId});
      }
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        contactId: contactId,
        connectionPhase: 'check_existing_session',
      );
    }

    _qrLogger.endPhase('checkExistingSession');
    return null;
  }

  /// Enhanced connection using existing session with retry logic
  Future<bool> connectUsingExistingSession(
      String sessionId, String contactId) async {
    if (_isConnecting) {
      GlobalErrorHandler.logDebug('Already connecting, ignoring request');
      return false;
    }

    _isConnecting = true;
    _qrLogger = WebRTCLogger(); // New logger for each connection attempt
    _currentConnectionId = sessionId;
    _qrLogger.startPhase('connectUsingExistingSession');

    _logger.d(
        'SESSION_EXTRA_CREATION: QRConnectionService.connectUsingExistingSession called with sessionId=$sessionId, contactId=$contactId');
    _logger.d('SESSION_EXTRA_CREATION: Stack trace: ${StackTrace.current}');
    _logger.d(
        'RECONNECT_DEBUG: Starting reconnection attempt for session $sessionId, contact $contactId');
    _logger.d(
        'RECONNECT_DEEP: Starting reconnection process. Current connection state: isConnecting=$_isConnecting');

    try {
      GlobalErrorHandler.logInfo(
        'Attempting to connect using existing session',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
          'attempt': _connectionAttempts + 1,
        },
      );

      // STEP 3: Comprehensive session validation for existing sessions
      final validationResult =
          await _sessionValidator.validateSession(sessionId, contactId);

      _logger.d(
          'RECONNECT_DEEP: Session validation result: isValid=${validationResult.isValid}, summary=${validationResult.summary}, isMessagingReady=${validationResult.isMessagingReady}');

      if (!validationResult.isValid) {
        _logger.d(
            'RECONNECT_DEEP: Session validation failed: ${validationResult.summary}');
        throw Exception(
            'Session validation failed: ${validationResult.summary}');
      }

      GlobalErrorHandler.logInfo(
        'Existing session validation passed',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
          'validation_summary': validationResult.summary,
          'is_messaging_ready': validationResult.isMessagingReady,
        },
      );

      // Get the contact to access session keys and verify it exists
      final contact = await _contactService.getContact(contactId);
      if (contact == null) {
        _logger.d('RECONNECT_DEEP: Contact not found: $contactId');
        throw ContactNotFoundException('Contact not found: $contactId');
      }

      _logger.d(
          'RECONNECT_DEEP: Contact found: ${contact.name}, role: ${contact.role}, metadata: ${contact.metadata}');

      GlobalErrorHandler.logDebug('Contact validated',
          data: {'contact_name': contact.name});

      // Get session info from the session service
      final session = await _sessionService.getSessionById(sessionId);
      if (session == null) {
        _logger.d('RECONNECT_DEEP: Session not found: $sessionId');
        throw SessionNotFoundException('Session not found: $sessionId');
      }

      _logger.d(
          'RECONNECT_DEEP: Session found: id=${session.id}, contactId=${session.contactId}, isActive=${session.isActive}, startTime=${session.startTime}');

      GlobalErrorHandler.logDebug('Session validated',
          data: {'session_id': sessionId});

      // Check if we already have a valid key for this session
      bool hasValidKey = false;
      try {
        hasValidKey = await _sessionKeyService.hasKeyForSession(sessionId);
        GlobalErrorHandler.logDebug(
          'KEY-VALIDATION: Checked for existing key',
          data: {
            'session_id': sessionId,
            'has_valid_key': hasValidKey,
          },
        );
      } catch (e) {
        GlobalErrorHandler.logWarning(
            'KEY-VALIDATION: Error checking for existing key: $e');
      }

      if (!hasValidKey) {
        _logger.d('RECONNECT_DEEP: No valid key found for session $sessionId');
        // For lawyer role, attempt to regenerate keys and metadata
        if (contact.role == 'lawyer') {
          _logger.d(
              'RECONNECT_DEEP: Contact is lawyer, attempting to regenerate keys');
          GlobalErrorHandler.logInfo(
              'Regenerating session keys for lawyer role');
          await _regenerateSessionKeys(sessionId, contactId);
        } else {
          _logger.d(
              'RECONNECT_DEEP: Contact is not lawyer, cannot regenerate keys');
          throw EncryptionKeyNotFoundException(
              'No encryption key found for session: $sessionId');
        }
      }

      // Initialize the connection using existing session info
      _logger.d(
          'RECONNECT_DEEP: Attempting connection with retry for session $sessionId');
      final success = await _attemptConnectionWithRetry(sessionId, contactId);

      if (success) {
        _connectionStepsCompleted = true;
        _connectionAttempts = 0;
        _logger
            .d('RECONNECT_DEEP: Successfully connected using existing session');
        GlobalErrorHandler.logInfo(
          'Successfully connected using existing session',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
          },
        );

        // Add a small delay to ensure the connection is fully established
        // This helps prevent navigation issues and decryption problems
        await Future.delayed(Duration(milliseconds: 500));
        _logger.d(
            'NAV_DEEP: Added 500ms delay after successful reconnection to ensure stability');

        _connectionStateController.add(true);
      } else {
        _connectionAttempts++;
        _logger.d(
            'RECONNECT_DEEP: Failed to connect using existing session after $_connectionAttempts attempts');
        await GlobalErrorHandler.captureConnectionError(
          'Failed to connect using existing session',
          sessionId: sessionId,
          contactId: contactId,
          connectionPhase: 'existing_session_connection',
        );
        _logger.d(
            'RECONNECT_DEBUG: Reconnection failed after $_connectionAttempts attempts');
        _connectionStateController.add(false);
      }

      _qrLogger.endPhase('connectUsingExistingSession');
      _logger
          .d('RECONNECT_DEBUG: Reconnection completed with result: $success');
      return success;
    } catch (e, stackTrace) {
      _logger.d('RECONNECT_DEEP: Exception during reconnection: $e');
      _logger.d('RECONNECT_DEEP: Stack trace: $stackTrace');
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        sessionId: sessionId,
        contactId: contactId,
        connectionPhase: 'connect_existing_session',
      );
      _logger.d('RECONNECT_DEBUG: Reconnection failed with error: $e');
      _qrLogger.endPhase('connectUsingExistingSession');
      _connectionStateController.add(false);
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  /// Attempt connection with retry logic and timeout
  Future<bool> _attemptConnectionWithRetry(
      String sessionId, String contactId) async {
    _logger.d(
        'RECONNECT_DEBUG: Starting connection attempt with retry for session $sessionId');
    _logger.d(
        'RECONNECT_FLOW: Attempting to connect to signaling server and establish WebRTC connection');
    _logger.d(
        'RECONNECT_DEEP: Connection attempt starting with sessionId=$sessionId, contactId=$contactId, isInitiator=${_webRTCService.isInitiator}');
    for (int attempt = 1; attempt <= _maxConnectionAttempts; attempt++) {
      try {
        GlobalErrorHandler.logDebug(
          'Connection attempt $attempt/$_maxConnectionAttempts',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
          },
        );
        _logger.d(
            'RECONNECT_DEBUG: Connection attempt $attempt/$_maxConnectionAttempts');

        // Create a timeout completer
        final Completer<bool> completer = Completer<bool>();
        Timer? timeoutTimer;

        // Set up timeout
        timeoutTimer = Timer(_connectionTimeout, () {
          if (!completer.isCompleted) {
            _logger.d(
                'RECONNECT_DEEP: Connection attempt $attempt timed out after ${_connectionTimeout.inSeconds} seconds. WebRTC state: ${_webRTCService.isConnected ? "connected" : "not connected"}');
            GlobalErrorHandler.logWarning(
              'Connection attempt timed out',
              data: {
                'attempt': attempt,
                'timeout_seconds': _connectionTimeout.inSeconds
              },
            );
            _logger.d(
                'RECONNECT_DEBUG: Connection attempt $attempt timed out after ${_connectionTimeout.inSeconds} seconds');
            completer.complete(false);
          }
        });

        // Listen for connection success
        late StreamSubscription subscription;
        subscription =
            _webRTCService.onConnectionStateChanged.listen((connected) async {
          _logger.d(
              'RECONNECT_DEEP: WebRTC connection state changed: connected=$connected');
          if (connected && !completer.isCompleted) {
            _logger.d(
                'RECONNECT_DEEP: WebRTC connection established, cancelling timeout');
            timeoutTimer!.cancel();
            subscription.cancel();

            try {
              // IMPORTANT: Add the missing key exchange for existing sessions!
              _logger.d(
                  'RECONNECT_DEEP: Starting key exchange for existing session');
              GlobalErrorHandler.logInfo(
                  'KEY-EXCHANGE: WebRTC connected - starting key exchange for existing session');
              await _handleConnectionEstablished(sessionId, contactId);
              _logger.d('RECONNECT_DEEP: Key exchange completed successfully');
              completer.complete(true);
            } catch (e, stackTrace) {
              _logger.d('RECONNECT_DEEP: Key exchange failed: $e');
              await GlobalErrorHandler.captureConnectionError(
                e,
                stackTrace: stackTrace,
                sessionId: sessionId,
                contactId: contactId,
                connectionPhase: 'existing_session_key_exchange',
              );
              completer.complete(false);
            }
          }
        });

        // Start the actual connection attempt
        final connectionStarted =
            await _initializeExistingConnection(sessionId, contactId);
        _logger.d(
            'RECONNECT_DEBUG: Connection initialization result: $connectionStarted');
        if (!connectionStarted) {
          timeoutTimer.cancel();
          subscription.cancel();
          if (!completer.isCompleted) {
            _logger.d(
                'RECONNECT_DEBUG: Connection initialization failed, completing with false');
            completer.complete(false);
          }
          continue;
        }

        // Wait for result
        final result = await completer.future;

        if (result) {
          GlobalErrorHandler.logInfo(
            'Connection successful on attempt $attempt',
            data: {'session_id': sessionId, 'contact_id': contactId},
          );
          return true;
        }

        // Cleanup failed attempt
        timeoutTimer.cancel();
        subscription.cancel();

        if (attempt < _maxConnectionAttempts) {
          final delayMs = attempt * 1000; // Exponential backoff
          GlobalErrorHandler.logDebug(
            'Retrying in ${delayMs}ms',
            data: {'attempt': attempt, 'next_attempt': attempt + 1},
          );
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      } catch (e, stackTrace) {
        await GlobalErrorHandler.captureConnectionError(
          e,
          stackTrace: stackTrace,
          sessionId: sessionId,
          contactId: contactId,
          connectionPhase: 'connection_attempt_$attempt',
        );
      }
    }

    GlobalErrorHandler.logWarning(
      'All connection attempts failed',
      data: {
        'session_id': sessionId,
        'contact_id': contactId,
        'max_attempts': _maxConnectionAttempts,
      },
    );
    return false;
  }

  /// Regenerate session keys for lawyer role
  Future<void> _regenerateSessionKeys(
      String sessionId, String contactId) async {
    _qrLogger.startPhase('regenerateSessionKeys');

    try {
      // Note: For existing sessions, keys should already exist from QR exchange
      // Only regenerate if absolutely necessary (e.g., security breach)
      GlobalErrorHandler.logInfo('Checking existing encryption key',
          data: {'session_id': sessionId});

      // Generate a new signaling server connection
      final String signalingServerUrl = 'ws://192.168.0.214:8080';
      final String peerId = _uuid.v4();

      GlobalErrorHandler.logInfo(
        'Connecting to signaling server',
        data: {
          'server_url': signalingServerUrl,
          'peer_id': peerId,
        },
      );

      await _signalingService.connect(signalingServerUrl, peerId);

      // Initialize WebRTC service as initiator with the existing session ID
      await _webRTCService.initializeAsInitiator(sessionId: sessionId);

      // Update contact metadata with session info
      await _contactService.updateContactWithSessionInfo(
          contactId, sessionId, true);

      GlobalErrorHandler.logInfo(
          'Successfully regenerated session keys and metadata');
      _qrLogger.endPhase('regenerateSessionKeys');
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        sessionId: sessionId,
        contactId: contactId,
        connectionPhase: 'regenerate_session_keys',
      );
      _qrLogger.endPhase('regenerateSessionKeys');
      rethrow;
    }
  }

  /// Private method to initialize an existing connection
  Future<bool> _initializeExistingConnection(
      String sessionId, String contactId) async {
    _qrLogger.startPhase('initializeExistingConnection');
    _logger.d(
        'RECONNECT_DEBUG: Initializing existing connection for session $sessionId, contact $contactId');

    try {
      // Check if WebRTC service is already initialized for this session
      final isAlreadyInitialized = _webRTCService.connectionId == sessionId;
      _logger.d(
          'RECONNECT_DEEP: WebRTC service initialization check: isAlreadyInitialized=$isAlreadyInitialized, currentConnectionId=${_webRTCService.connectionId}');

      GlobalErrorHandler.logDebug(
        'Initializing existing connection',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
        },
      );

      // Get the contact to determine role
      final contact = await _contactService.getContact(contactId);
      if (contact == null) {
        _logger.d('RECONNECT_DEBUG: Contact not found: $contactId');
        throw ContactNotFoundException('Contact not found: $contactId');
      }
      _logger.d(
          'RECONNECT_DEBUG: Found contact: ${contact.name} with role: ${contact.role}');

      // Initialize WebRTC with the existing session ID
      _logger.d(
          'RECONNECT_DEBUG: Initializing WebRTC for existing session $sessionId');

      // Preserve the WebRTC initiator role during reconnection
      _logger.d(
          'RECONNECT_DEEP: Calling initializeForExistingSession with preserveInitiatorRole=true');
      final sessionIdResult = await _webRTCService
          .initializeForExistingSession(sessionId, preserveInitiatorRole: true);
      _logger.d(
          'RECONNECT_DEEP: initializeForExistingSession returned sessionId=$sessionIdResult');
      _logger.d(
          'RECONNECT_DEBUG: WebRTC initialized successfully for existing session');
      GlobalErrorHandler.logDebug('WebRTC initialized for existing session');

      // Check if we need to create an offer based on the WebRTC service's initiator status
      if (_webRTCService.isInitiator) {
        _logger.d(
            'RECONNECT_DEEP: WebRTC service is initiator - triggering offer creation');
        await _webRTCService.createAndSendOffer();
      } else {
        _logger.d(
            'RECONNECT_DEEP: WebRTC service is receiver - waiting for offer');
      }

      // For UI feedback
      _connectionStepsCompleted = true;

      GlobalErrorHandler.logInfo(
          'Existing connection initialized successfully');
      _logger
          .d('RECONNECT_DEBUG: Existing connection initialized successfully');
      _qrLogger.endPhase('initializeExistingConnection');
      return true;
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        sessionId: sessionId,
        contactId: contactId,
        connectionPhase: 'initialize_existing_connection',
      );
      _logger
          .d('RECONNECT_DEBUG: Failed to initialize existing connection: $e');
      _logger.d('RECONNECT_DEBUG: Stack trace: $stackTrace');
      _qrLogger.endPhase('initializeExistingConnection');
      return false;
    }
  }

  /// Associate a session with a contact ID with proper error handling
  Future<void> associateSessionWithContact(
      String sessionId, String contactId) async {
    try {
      GlobalErrorHandler.logDebug(
        'Associating session with contact',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
        },
      );

      // Validate contact exists
      final contact = await _contactService.getContact(contactId);
      if (contact == null) {
        throw ContactNotFoundException('Contact not found: $contactId');
      }

      final existingSession = await _sessionService.getSessionById(sessionId);

      if (existingSession == null) {
        // No session exists yet, create one with proper contactId
        final session = Session(
          id: sessionId,
          contactId: contactId,
          startTime: DateTime.now(),
          isActive: true,
        );

        await _sessionService.createSessionWithId(session);
        GlobalErrorHandler.logDebug(
          'Created new session with proper contactId',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
          },
        );
      } else if (existingSession.contactId != contactId) {
        // Session exists but has wrong contactId, update it
        final updatedSession = Session(
          id: existingSession.id,
          contactId: contactId,
          startTime: existingSession.startTime,
          endTime: existingSession.endTime,
          messageCount: existingSession.messageCount,
          isActive: existingSession.isActive,
          purgeEnabled: existingSession.purgeEnabled,
        );

        await _sessionService.createSessionWithId(updatedSession);
        GlobalErrorHandler.logDebug(
          'Updated session with correct contactId',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
          },
        );
      }
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        sessionId: sessionId,
        contactId: contactId,
        connectionPhase: 'associate_session_contact',
      );
      rethrow;
    }
  }

  /// Generate connection info for QR code with enhanced error handling
  Future<ConnectionInfo> generateConnectionInfo(String signalServerUrl) async {
    try {
      final String peerId = _uuid.v4();
      // Generate canonical session ID FIRST - this is the source of truth
      final String sessionId = _uuid.v4();

      // Validate the generated session ID format
      if (!_sessionValidator.isValidFormat(sessionId)) {
        throw Exception('Generated session ID has invalid format: $sessionId');
      }

      // Ensure session ID is unique (shouldn't happen with UUID v4, but good to verify)
      final isUnique = await _sessionValidator.isUnique(sessionId);
      if (!isUnique) {
        GlobalErrorHandler.logWarning(
          'Generated session ID collision - regenerating',
          data: {'session_id': sessionId},
        );
        // In the extremely rare case of a collision, regenerate
        return await generateConnectionInfo(signalServerUrl);
      }

      // Generate encryption key for this session (lawyer side creates the key)
      final String encryptionKey =
          await _sessionKeyService.generateKeyForSession(sessionId);
      GlobalErrorHandler.logInfo(
        'Generated encryption key for QR code sharing',
        data: {'session_id': sessionId},
      );

      // Pass the canonical session ID to WebRTC instead of letting it generate one
      await _webRTCService.initializeAsInitiator(sessionId: sessionId);

      // Generate a verification code for security
      final String verificationCode = _generateVerificationCode();

      // Connect to signaling server
      await _signalingService.connect(signalServerUrl, peerId);

      final connectionInfo = ConnectionInfo(
        peerId: peerId,
        sessionId: sessionId,
        signalServerUrl: signalServerUrl,
        verificationCode: verificationCode,
        encryptionKey: encryptionKey, // Include the key in QR code
      );

      // Log and save the QR string for testing
      final qrString = connectionInfo.toQrString();
      GlobalErrorHandler.logInfo(
        '[copyqrstring] QR string generated with encryption key',
        data: {
          'qr_string': qrString,
          'peer_id': peerId,
          'session_id': sessionId,
          'has_encryption_key': encryptionKey.isNotEmpty,
        },
      );
      _logger.i('[copyqrstring] QR string: $qrString');

      await _saveQrStringToFile(qrString);

      GlobalErrorHandler.logInfo(
        'Connection info generated successfully with shared encryption key',
        data: {
          'peer_id': peerId,
          'session_id': sessionId,
          'verification_code': verificationCode,
        },
      );

      return connectionInfo;
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        connectionPhase: 'generate_connection_info',
      );
      rethrow;
    }
  }

  /// Save QR string to file for testing purposes
  Future<void> _saveQrStringToFile(String qrString) async {
    // Only run this in debug mode
    if (!kDebugMode) return;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final path = '${directory.path}/generated_qr.txt';
      final file = File(path);

      await file.writeAsString(qrString);
      GlobalErrorHandler.logDebug('Saved QR string to file',
          data: {'path': path});
    } catch (e) {
      GlobalErrorHandler.logWarning('Error saving QR string to file: $e');
    }
  }

  /// Enhanced QR connection with retry logic
  Future<bool> connectUsingQrInfo(String qrString, String contactId) async {
    if (_isConnecting) {
      GlobalErrorHandler.logDebug(
          'Already connecting, ignoring QR connect request');
      return false;
    }

    _isConnecting = true;

    try {
      GlobalErrorHandler.logInfo(
        'Starting QR connection process',
        data: {'contact_id': contactId},
      );

      final ConnectionInfo info = ConnectionInfo.fromQrString(qrString);

      // STEP 3: Validate session ID from QR code
      if (!_sessionValidator.isValidFormat(info.sessionId)) {
        throw Exception(
            'Invalid session ID format in QR code: ${info.sessionId}');
      }

      // Initialize WebRTC as receiver with the validated session ID
      await _webRTCService.initializeAsReceiver(info.sessionId);

      // Generate a unique ID for the receiver
      final receiverPeerId = _uuid.v4();

      // Connect to signaling server with receiver's own unique ID
      await _signalingService.connect(info.signalServerUrl, receiverPeerId);

      // Set the target (initiator) peer ID
      _signalingService.setTargetPeer(info.peerId);

      // Register the receiver with the initiator
      Map<String, dynamic> registerMessage = {
        'type': 'register_receiver',
        'peerId': receiverPeerId,
        'to': info.peerId
      };
      _signalingService.sendRegisterReceiver(registerMessage);

      // Track the session association with the contact
      await associateSessionWithContact(info.sessionId, contactId);

      // CRITICAL: Store the shared encryption key from QR code (if available)
      if (info.encryptionKey != null && info.encryptionKey!.isNotEmpty) {
        await _sessionKeyService.storeKeyStringForSession(
            info.sessionId, info.encryptionKey!);
        GlobalErrorHandler.logInfo(
          'SHARED-KEY: Stored encryption key from QR code',
          data: {'session_id': info.sessionId},
        );
      } else {
        GlobalErrorHandler.logWarning(
          'QR code missing encryption key - will generate during connection',
          data: {'session_id': info.sessionId},
        );
      }

      // STEP 5: End-to-end validation after key storage
      GlobalErrorHandler.logInfo(
        'STEP 5: Performing end-to-end session validation after key storage',
        data: {
          'session_id': info.sessionId,
          'contact_id': contactId,
        },
      );

      final preConnectionValidation =
          await _sessionValidator.validateCompleteSessionFlow(
        info.sessionId,
        contactId,
        shouldHaveKeys:
            info.encryptionKey != null, // Should have keys if QR included them
        shouldHaveTargetPeer: false, // Target peer not stored yet
        shouldHaveActiveSession: false, // New connection
      );

      if (!preConnectionValidation.isValid) {
        GlobalErrorHandler.logWarning(
          'STEP 5: Pre-connection validation failed',
          data: {
            'errors': preConnectionValidation.errors,
            'warnings': preConnectionValidation.warnings,
          },
        );
        // Continue anyway for new connections
      } else {
        GlobalErrorHandler.logInfo(
          'STEP 5: Pre-connection validation passed',
          data: {
            'steps': preConnectionValidation.validationSteps,
          },
        );
      }

      // Wait for offer from initiator
      await _webRTCService.waitForOffer();

      // Wait for connection to be established with timeout
      bool connected = await _waitForConnectionWithTimeout();

      if (connected) {
        // Process the newly established connection
        await _handleConnectionEstablished(info.sessionId, contactId);
        GlobalErrorHandler.logInfo(
          'QR connection established successfully',
          data: {
            'session_id': info.sessionId,
            'contact_id': contactId,
          },
        );
        _connectionStateController.add(true);
      } else {
        await GlobalErrorHandler.captureConnectionError(
          'QR connection failed',
          sessionId: info.sessionId,
          contactId: contactId,
          connectionPhase: 'qr_connection',
        );
        _connectionStateController.add(false);
      }

      return connected;
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        contactId: contactId,
        connectionPhase: 'connect_using_qr',
      );
      _connectionStateController.add(false);
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  /// Generate a verification code
  String _generateVerificationCode() {
    final String randomData = _uuid.v4();
    final List<int> bytes = utf8.encode(randomData);
    final Digest digest = sha256.convert(bytes);

    // Take first 6 characters of the hash
    return digest.toString().substring(0, 6).toUpperCase();
  }

  /// Handle WebRTC signal data and send through signaling
  void _handleWebRTCSignalData(Map<String, dynamic> data) {
    try {
      _signalingService.sendSignalData(data);
    } catch (e, stackTrace) {
      GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        connectionPhase: 'handle_webrtc_signal',
      );
    }
  }

  /// Handle signaling data and process or forward it
  void _handleSignalingData(Map<String, dynamic> data) {
    try {
      if (data['type'] == 'register_receiver' && _webRTCService.isInitiator) {
        // The receiver is registering, extract their peer ID
        final receiverPeerId = data['peerId'];
        GlobalErrorHandler.logDebug(
          'Receiver registered, setting as target peer',
          data: {'receiver_peer_id': receiverPeerId},
        );

        // Set the target peer ID in the signaling service
        _signalingService.setTargetPeer(receiverPeerId);

        // Add a delay to ensure the receiver is ready to process the offer
        Future.delayed(const Duration(milliseconds: 1500), () {
          GlobalErrorHandler.logDebug(
            'Creating and sending offer to receiver',
            data: {'receiver_peer_id': receiverPeerId},
          );
          // Now that we have the target peer, create and send the offer
          _webRTCService.createAndSendOffer();
        });
      } else {
        // Process other signal types normally
        _webRTCService.processSignalData(data);
      }
    } catch (e, stackTrace) {
      GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        connectionPhase: 'handle_signaling_data',
      );
    }
  }

  /// Get connection state stream
  Stream<bool> get onConnectionStateChanged =>
      _connectionStateController.stream;

  /// Check if connected
  bool get isConnected => _webRTCService.isConnected;

  /// Check if currently connecting
  bool get isConnecting => _isConnecting;

  /// Get current connection attempts
  int get connectionAttempts => _connectionAttempts;

  /// Reset connection attempts (for manual retry)
  void resetConnectionAttempts() {
    _connectionAttempts = 0;
  }

  /// Close the connection
  Future<void> close() async {
    try {
      GlobalErrorHandler.logInfo('Closing QR connection service');
      await _webRTCService.close();
      _signalingService.close();
      _isConnecting = false;
      _connectionStepsCompleted = false;
      _connectionStateController.add(false);
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Closing QR connection service',
      );
    }
  }

  /// Dispose resources
  void dispose() {
    GlobalErrorHandler.logInfo('Disposing QR connection service');
    try {
      _webRTCService.dispose();
      _signalingService.dispose();
      _connectionStateController.close();
    } catch (e) {
      GlobalErrorHandler.logWarning(
          'Error disposing QR connection service: $e');
    }
  }

  /// Process a newly established connection
  Future<void> _handleConnectionEstablished(
      String sessionId, String contactId) async {
    try {
      GlobalErrorHandler.logInfo(
        'Processing newly established connection',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
        },
      );

      // Check if we already have a valid key for this session
      bool hasValidKey = false;
      try {
        hasValidKey = await _sessionKeyService.hasKeyForSession(sessionId);
        GlobalErrorHandler.logDebug(
          'KEY-VALIDATION: Checked for existing key',
          data: {
            'session_id': sessionId,
            'has_valid_key': hasValidKey,
          },
        );
      } catch (e) {
        GlobalErrorHandler.logWarning(
            'KEY-VALIDATION: Error checking for existing key: $e');
      }

      // With QR code key sharing, we should always have a key by this point
      if (!hasValidKey) {
        GlobalErrorHandler.logWarning(
          'KEY-EXCHANGE: No shared key found - this may indicate QR code parsing failed',
          data: {'session_id': sessionId},
        );
        // Note: We no longer generate keys here as they should come from QR code sharing
        // If no key exists, this indicates a problem with the QR code key sharing process
      } else {
        GlobalErrorHandler.logInfo(
          'KEY-EXCHANGE: Using shared encryption key from QR code',
          data: {'session_id': sessionId},
        );
      }

      // Mark the connection as successful
      GlobalErrorHandler.logInfo(
        'Connection established with shared encryption',
        data: {'session_id': sessionId, 'contact_id': contactId},
      );

      // STEP 5: Post-connection validation - verify everything is consistent
      GlobalErrorHandler.logInfo(
        'STEP 5: Performing end-to-end session validation after connection',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
        },
      );

      final postConnectionValidation =
          await _sessionValidator.validateCompleteSessionFlow(
        sessionId,
        contactId,
        shouldHaveKeys: true, // Keys should be generated now
        shouldHaveTargetPeer: true, // Target peer should be stored
        shouldHaveActiveSession: true, // Connection should be active
      );

      if (!postConnectionValidation.isValid) {
        GlobalErrorHandler.logWarning(
          'STEP 5: Post-connection validation found issues',
          data: {
            'errors': postConnectionValidation.errors,
            'warnings': postConnectionValidation.warnings,
            'steps': postConnectionValidation.validationSteps,
          },
        );
      } else {
        GlobalErrorHandler.logInfo(
          'STEP 5: Post-connection validation passed - session ID flow is consistent',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
            'validation_steps': postConnectionValidation.validationSteps,
          },
        );
      }

      // Quick consistency check
      final isConsistent =
          await _sessionValidator.quickConsistencyCheck(sessionId, contactId);
      if (!isConsistent) {
        GlobalErrorHandler.logWarning(
          'STEP 5: Quick consistency check failed - session IDs may be mismatched',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
          },
        );
      } else {
        GlobalErrorHandler.logInfo(
          'STEP 5: Quick consistency check passed - all components use same session ID',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
          },
        );
      }

      // PHASE 1: Disconnect WebRTC after key exchange (only for NEW key exchange)
      if (!hasValidKey) {
        GlobalErrorHandler.logInfo(
            'KEY-EXCHANGE: New key generated - initiating Phase 1 disconnect');
        await _disconnectAfterKeyExchange(sessionId, contactId);
      } else {
        GlobalErrorHandler.logInfo(
            'KEY-EXCHANGE: Using existing key - staying connected for direct messaging');

        // Store target peer for Phase 2 messaging (also needed for existing sessions)
        final targetPeerId = _signalingService.targetPeerId;
        if (targetPeerId != null) {
          await _storeTargetPeerForSession(sessionId, targetPeerId);
          GlobalErrorHandler.logDebug(
            'Stored target peer for existing session Phase 2 messaging',
            data: {'session_id': sessionId, 'target_peer': targetPeerId},
          );
        }

        // For existing keys, mark session as active but keep WebRTC connected
        await _sessionService.markSessionActive(sessionId);

        // Set current session in connection manager after marking active
        await _setCurrentSessionAfterPairing(sessionId, contactId);
      }

      GlobalErrorHandler.logInfo(
          'Connection establishment processing completed');
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        sessionId: sessionId,
        contactId: contactId,
        connectionPhase: 'handle_connection_established',
      );
    } finally {
      // Ensure WebRTC connection is fully closed after key exchange
      await _webRTCService.close();
      _logger.d('WebRTC connection fully closed after key exchange');
    }
  }

  /// Wait for WebRTC connection to be established with timeout
  Future<bool> _waitForConnectionWithTimeout() async {
    GlobalErrorHandler.logDebug('Waiting for WebRTC connection with timeout');

    // Create a completer to handle the async wait
    final completer = Completer<bool>();

    // Listen for connection state changes
    late StreamSubscription subscription;
    subscription = _webRTCService.onConnectionStateChanged.listen((connected) {
      if (connected && !completer.isCompleted) {
        GlobalErrorHandler.logInfo('Connection established');
        subscription.cancel();
        completer.complete(true);
      }
    });

    // Set a timeout - increased to 60 seconds for better reliability
    Timer(const Duration(seconds: 60), () {
      if (!completer.isCompleted) {
        GlobalErrorHandler.logWarning('Connection timeout after 60 seconds');
        subscription.cancel();
        completer.complete(false);
      }
    });

    // Wait for either connection or timeout
    final result = await completer.future;
    return result;
  }

  /// Disconnect WebRTC after successful key exchange (Phase 1)
  Future<void> _disconnectAfterKeyExchange(
      String sessionId, String contactId) async {
    try {
      GlobalErrorHandler.logInfo(
          'KEY-EXCHANGE: Key exchange complete - disconnecting WebRTC for session: $sessionId');

      // Store the current target peer for Phase 2 messaging
      final targetPeerId = _signalingService.targetPeerId;
      if (targetPeerId != null) {
        await _storeTargetPeerForSession(sessionId, targetPeerId);
        GlobalErrorHandler.logDebug(
          'Stored target peer for Phase 2 messaging',
          data: {'session_id': sessionId, 'target_peer': targetPeerId},
        );
      }

      // Close WebRTC connection (key exchange job done!)
      await _webRTCService.close();

      // Mark session as active but not WebRTC connected
      await _sessionService.markSessionActive(sessionId);

      // Set current session in connection manager after marking active
      await _setCurrentSessionAfterPairing(sessionId, contactId);

      // IMPORTANT: Keep signaling connection alive for Phase 2 messaging
      // DON'T close _signalingService here!

      GlobalErrorHandler.logInfo(
          'PHASE1: WebRTC disconnected - session now ready for Phase 2 server-based messaging');

      // Don't emit true here since WebRTC is disconnected
      // UI will handle this differently for "paired" state
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        sessionId: sessionId,
        connectionPhase: 'disconnect_after_key_exchange',
      );
    }
  }

  /// Store target peer ID for Phase 2 messaging
  Future<void> _storeTargetPeerForSession(
      String sessionId, String targetPeerId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storageKey = 'target_peer_$sessionId';
      await prefs.setString(storageKey, targetPeerId);

      // Verify storage worked
      final stored = prefs.getString(storageKey);
      GlobalErrorHandler.logDebug(
        'TARGET-PEER-STORAGE: Stored target peer for session',
        data: {
          'session_id': sessionId,
          'target_peer': targetPeerId,
          'storage_key': storageKey,
          'verification': stored,
        },
      );

      // Notify callback
      if (onTargetPeerStored != null) {
        onTargetPeerStored!(sessionId, targetPeerId);
      }
    } catch (e) {
      GlobalErrorHandler.logWarning('Failed to store target peer: $e');
    }
  }

  /// Get target peer ID for Phase 2 messaging
  Future<String?> getTargetPeerForSession(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final targetPeer = prefs.getString('target_peer_$sessionId');
      GlobalErrorHandler.logDebug(
        'TARGET-PEER-RETRIEVAL: Getting target peer for session',
        data: {
          'session_id': sessionId,
          'storage_key': 'target_peer_$sessionId',
          'target_peer': targetPeer,
        },
      );
      return targetPeer;
    } catch (e) {
      GlobalErrorHandler.logWarning('Failed to get target peer: $e');
      return null;
    }
  }

  /// Set current session in connection manager after pairing
  Future<void> _setCurrentSessionAfterPairing(
      String sessionId, String contactId) async {
    try {
      // Get contact name for the callback
      final contact = await _contactService.getContact(contactId);
      final contactName = contact?.name ?? contactId;

      // Call the callback if it's set
      if (onSessionEstablished != null) {
        GlobalErrorHandler.logDebug(
          'SESSION_LIFECYCLE: Calling onSessionEstablished callback',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
            'contact_name': contactName,
          },
        );
        onSessionEstablished!(sessionId, contactId, contactName);
      } else {
        GlobalErrorHandler.logWarning(
          'SESSION_LIFECYCLE: onSessionEstablished callback not set',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
          },
        );
      }
    } catch (e) {
      GlobalErrorHandler.logError(
        'SESSION_LIFECYCLE: Error setting current session after pairing: $e',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
          'error': e.toString(),
        },
      );
      // Don't rethrow - this shouldn't block the pairing process
    }
  }

  /// Public method to handle connection establishment (can be called multiple times safely)
  Future<void> handleConnectionEstablished(
      String sessionId, String contactId) async {
    await _handleConnectionEstablished(sessionId, contactId);
  }
}

// Custom exceptions for better error handling
class ContactNotFoundException implements Exception {
  final String message;
  ContactNotFoundException(this.message);
  @override
  String toString() => 'ContactNotFoundException: $message';
}

class SessionNotFoundException implements Exception {
  final String message;
  SessionNotFoundException(this.message);
  @override
  String toString() => 'SessionNotFoundException: $message';
}

class EncryptionKeyNotFoundException implements Exception {
  final String message;
  EncryptionKeyNotFoundException(this.message);
  @override
  String toString() => 'EncryptionKeyNotFoundException: $message';
}
