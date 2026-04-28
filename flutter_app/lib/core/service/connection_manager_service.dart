// lib/core/service/connection_manager_service.dart

import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../core/p2p/webrtc_connection_service.dart';
import '../../core/p2p/signaling_service.dart';
import '../../features/p2p/qr_connection_service.dart';
import '../../core/security/encryption_service.dart';
import '../../features/p2p/p2p_message_service.dart';
import '../../features/session/session_service.dart';
import '../../features/session/session_key_service.dart';
import '../../features/contacts/contact_service.dart';
import '../../features/contacts/contact_repository.dart';
import '../../features/contacts/contact_key_service.dart';
import 'global_error_handler.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Enum representing different sources of session IDs for tracing purposes
enum SessionIdSource {
  qrGeneration('qr_generation', 'Generated from QR code creation'),
  qrScanning('qr_scanning', 'Extracted from scanned QR code'),
  existingSession('existing_session', 'Retrieved from existing session'),
  autoReconnect('auto_reconnect', 'Used during automatic reconnection'),
  manualReconnect('manual_reconnect', 'Used during manual reconnection'),
  sessionRestore('session_restore', 'Restored from persistent storage'),
  targetPeerCallback(
      'target_peer_callback', 'Updated via target peer callback'),
  unknown('unknown', 'Source unknown or not tracked');

  const SessionIdSource(this.code, this.description);
  final String code;
  final String description;
}

/// Class to track session ID usage and flow throughout the system
class SessionIdTrace {
  final String sessionId;
  final String contactId;
  final SessionIdSource source;
  final DateTime timestamp;
  final String context;
  final Map<String, dynamic>? additionalData;

  SessionIdTrace({
    required this.sessionId,
    required this.contactId,
    required this.source,
    required this.timestamp,
    required this.context,
    this.additionalData,
  });

  Map<String, dynamic> toMap() {
    return {
      'session_id': sessionId,
      'contact_id': contactId,
      'source': source.code,
      'source_description': source.description,
      'timestamp': timestamp.toIso8601String(),
      'context': context,
      'additional_data': additionalData,
    };
  }

  @override
  String toString() {
    return 'SessionIdTrace(sessionId: $sessionId, contactId: $contactId, source: ${source.code}, timestamp: $timestamp, context: $context)';
  }
}

/// Enhanced connection manager with memory caching and robust error handling
class ConnectionManagerService extends ChangeNotifier {
  // Singleton pattern
  static final ConnectionManagerService _instance =
      ConnectionManagerService._internal();
  factory ConnectionManagerService() => _instance;
  ConnectionManagerService._internal();
  final _logger = Logger();

  // Service instances
  P2PMessageService? _p2pMessageService;
  WebRTCConnectionService? _webRTCService;
  SignalingService? _signalingService;
  QRConnectionService? _qrConnectionService;
  SessionService? _sessionService;
  ContactService? _contactService;

  // Connection state
  bool _isConnecting = false;
  bool _isInitialized = false;
  String? _currentSessionId;
  String? _currentContactId;
  String? _currentContactName;

  final List<SessionIdTrace> _sessionIdTraces = [];
  static const int _maxTraces = 100; // Keep last 100 traces
  SessionIdSource? _currentSessionSource;
  final Map<String, SessionIdSource> _sessionSourceMap =
      {}; // sessionId -> source

  // Memory cache for session data (avoid repeated SharedPreferences reads)
  final Map<String, String> _sessionContactCache = {}; // sessionId -> contactId
  String? _cachedCurrentSession;
  String? _cachedCurrentContact;
  DateTime? _cacheLastUpdated;
  static const Duration _cacheValidityDuration = Duration(minutes: 5);

  // Retry logic state
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;
  static const Duration _reconnectTimeout = Duration(seconds: 10);

  // Maps to track session-contact relationships
  final Map<String, String> _sessionToContactMapping = {};

  // Getters
  bool get isConnected {
    // Phase 1: Direct WebRTC connection
    if (_webRTCService?.isConnected == true) {
      return true;
    }

    // Phase 2: Signaling server connection for existing sessions
    if (_currentSessionId != null &&
        _signalingService?.isConnected == true &&
        _p2pMessageService != null) {
      return true;
    }

    return false;
  }

  String? get currentSessionId => _currentSessionId;
  String? get currentContactId => _currentContactId;
  String? get currentContactName => _currentContactName;
  WebRTCConnectionService? get webRTCService => _webRTCService;
  SignalingService? get signalingService => _signalingService;
  QRConnectionService? get qrConnectionService => _qrConnectionService;
  P2PMessageService? get p2pMessageService => _p2pMessageService;
  bool get isInitialized => _isInitialized;
  bool get isConnecting => _isConnecting;
  int get reconnectAttempts => _reconnectAttempts;

  List<SessionIdTrace> get sessionIdTraces =>
      List.unmodifiable(_sessionIdTraces);
  SessionIdSource? get currentSessionSource => _currentSessionSource;

  /// Add a session ID trace entry for debugging and audit purposes
  void _addSessionIdTrace({
    required String sessionId,
    required String contactId,
    required SessionIdSource source,
    required String context,
    Map<String, dynamic>? additionalData,
  }) {
    final trace = SessionIdTrace(
      sessionId: sessionId,
      contactId: contactId,
      source: source,
      timestamp: DateTime.now(),
      context: context,
      additionalData: additionalData,
    );

    // Add to traces list
    _sessionIdTraces.add(trace);

    // Keep only the last N traces to prevent memory bloat
    if (_sessionIdTraces.length > _maxTraces) {
      _sessionIdTraces.removeAt(0);
    }

    // Update source mapping
    _sessionSourceMap[sessionId] = source;
    if (sessionId == _currentSessionId) {
      _currentSessionSource = source;
    }

    // Log the trace
    GlobalErrorHandler.logInfo(
      '${source.code} - $context',
      data: {
        'session_id': sessionId,
        'contact_id': contactId,
        'source': source.code,
        'source_description': source.description,
        'context': context,
        'additional_data': additionalData,
        'timestamp': trace.timestamp.toIso8601String(),
      },
    );
  }

  /// Get all traces for a specific session ID
  List<SessionIdTrace> getTracesForSession(String sessionId) {
    return _sessionIdTraces
        .where((trace) => trace.sessionId == sessionId)
        .toList();
  }

  /// Get traces for a specific contact
  List<SessionIdTrace> getTracesForContact(String contactId) {
    return _sessionIdTraces
        .where((trace) => trace.contactId == contactId)
        .toList();
  }

  /// Get the source of a specific session ID
  SessionIdSource? getSessionSource(String sessionId) {
    return _sessionSourceMap[sessionId];
  }

  /// Validate session ID consistency across components
  Future<Map<String, dynamic>> validateSessionIdConsistency() async {
    final validation = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'current_session_id': _currentSessionId,
      'current_contact_id': _currentContactId,
      'current_session_source': _currentSessionSource?.code,
      'issues': <String>[],
      'components': <String, dynamic>{},
    };

    if (_currentSessionId != null && _currentContactId != null) {
      // Check WebRTC service
      final webrtcSessionId = _webRTCService?.connectionId;
      validation['components']['webrtc_session_id'] = webrtcSessionId;

      if (webrtcSessionId != null && webrtcSessionId != _currentSessionId) {
        validation['issues'].add(
            'WebRTC session ID mismatch: expected $_currentSessionId, got $webrtcSessionId');
      }

      // Check P2P message service session
      if (_p2pMessageService != null) {
        // We'll need to add a getter in P2P message service for this
        validation['components']['p2p_session_available'] = true;
      }

      // Check session-contact mapping consistency
      final mappedContactId = getContactIdForSession(_currentSessionId!);
      validation['components']['mapped_contact_id'] = mappedContactId;

      if (mappedContactId != _currentContactId) {
        validation['issues'].add(
            'Session-contact mapping mismatch: expected $_currentContactId, mapped to $mappedContactId');
      }

      // Check cache consistency
      final cachedContactId = _sessionContactCache[_currentSessionId];
      validation['components']['cached_contact_id'] = cachedContactId;

      if (cachedContactId != null && cachedContactId != _currentContactId) {
        validation['issues'].add(
            'Cache consistency issue: expected $_currentContactId, cached $cachedContactId');
      }
    }

    // Log validation results
    if (validation['issues'].isNotEmpty) {
      GlobalErrorHandler.logWarning(
        'SESSION-ID-VALIDATION: Consistency issues detected',
        data: validation,
      );
    } else {
      GlobalErrorHandler.logInfo(
        'SESSION-ID-VALIDATION: All components consistent',
        data: validation,
      );
    }

    return validation;
  }

  /// Export session traces for debugging
  Map<String, dynamic> exportSessionTraces() {
    return {
      'timestamp': DateTime.now().toIso8601String(),
      'total_traces': _sessionIdTraces.length,
      'current_session_id': _currentSessionId,
      'current_session_source': _currentSessionSource?.code,
      'session_source_map': _sessionSourceMap,
      'traces': _sessionIdTraces.map((trace) => trace.toMap()).toList(),
    };
  }

  /// Initialize network monitoring
  Future<void> _initializeNetworkMonitoring() async {
    try {
      // Import connectivity_plus package
      // This will need to be added to pubspec.yaml:
      // connectivity_plus: ^4.0.0

      // Check if the package is available
      bool hasConnectivityPackage = false;
      try {
        // This is a dummy check that will throw if the package isn't available
        const dynamic connectivityCheck = Connectivity;
        hasConnectivityPackage = true;
      } catch (e) {
        _logger.w('Connectivity package not available: $e');
        hasConnectivityPackage = false;
      }

      if (hasConnectivityPackage) {
        // Initialize connectivity monitoring
        final connectivity = Connectivity();
        final initialResult = await connectivity.checkConnectivity();


        // Listen for connectivity changes
        connectivity.onConnectivityChanged.listen((result) {

          if (result == ConnectivityResult.none) {
            // Network is gone, nothing to do but wait
          } else {
            // Network is back, check connections
            _checkConnectionsAfterNetworkChange(result);
          }
        });
      }
    } catch (e) {
      _logger.e('Error initializing network monitoring: $e');
    }
  }

  /// Check connections after network change
  Future<void> _checkConnectionsAfterNetworkChange(
      ConnectivityResult result) async {
    if (_currentSessionId == null || _currentContactId == null) return;

    try {
      // Check if signaling is connected
      if (_signalingService != null && !_signalingService!.isConnected) {
        await _signalingService!.ensureConnected();
      }

      // Check if WebRTC is connected
      if (_webRTCService != null && !_webRTCService!.isConnected) {
        await _attemptSessionRecovery(_currentSessionId!, _currentContactId!);
      }
    } catch (e) {
      _logger.e('Error checking connections after network change: $e');
    }
  }

  /// Attempt to recover an existing session
  Future<bool> _attemptSessionRecovery(
      String sessionId, String contactId) async {
    try {
      // First check if session is valid
      final session = await _sessionService?.getSessionById(sessionId);
      if (session == null) {
        _logger.w('Cannot recover session - session not found: $sessionId');
        return false;
      }

      // Check if contact is valid
      final contact = await _contactService?.getContact(contactId);
      if (contact == null) {
        _logger.w('Cannot recover session - contact not found: $contactId');
        return false;
      }

      // Ensure signaling connection
      if (_signalingService != null && !_signalingService!.isConnected) {
        await _signalingService!.ensureConnected();
      }

      // Try to reconnect WebRTC
      if (_webRTCService != null) {
        await _webRTCService!.initializeForExistingSession(sessionId);
      }

      // Update current session info
      _setCurrentSession(sessionId, contactId, SessionIdSource.autoReconnect);

      return true;
    } catch (e, stackTrace) {
      _logger.e('Error recovering session: $e');
      GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'session_recovery',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
        },
      );
      return false;
    }
  }

  /// Internal method to set current session with minimal parameters
  void _setCurrentSession(
      String sessionId, String contactId, SessionIdSource source) {
    try {
      // Add trace for debugging
      _addSessionIdTrace(
        sessionId: sessionId,
        contactId: contactId,
        source: source,
        context: source == SessionIdSource.qrScanning
            ? 'QR pairing session update'
            : 'Auto-recovery session update',
        additionalData: {
          'previous_session_id': _currentSessionId,
          'previous_contact_id': _currentContactId,
        },
      );

      // Update current session info
      _currentSessionId = sessionId;
      _currentContactId = contactId;
      _currentSessionSource = source;

      // Update session-contact mapping
      _sessionToContactMapping[sessionId] = contactId;

      // Update cache
      _cachedCurrentSession = sessionId;
      _cachedCurrentContact = contactId;
      _cacheLastUpdated = DateTime.now();
    } catch (e) {
      _logger.e('Error in _setCurrentSession: $e');
    }
  }

  /// Initialize the connection services if not already initialized
  Future<void> initializeServices() async {
    if (_isInitialized) return;

    try {
      GlobalErrorHandler.logInfo('Initializing ConnectionManagerService');

      // Phase 3: Create shared EncryptionService instances for dependency injection
      // Keep EncryptionService internal to key management services per Option A architecture
      final sharedEncryptionService = EncryptionService();

      // Inject shared instance into key management services
      final contactKeyService = ContactKeyService(sharedEncryptionService);
      final sessionKeyService = SessionKeyService(sharedEncryptionService);

      // WebRTC service gets its own instance for transport-level crypto (if needed)
      final webrtcEncryptionService = EncryptionService();
      _webRTCService = WebRTCConnectionService(webrtcEncryptionService);

      _signalingService = SignalingService();
      _contactService = ContactService(ContactRepository(), contactKeyService);
      _sessionService = SessionService(_contactService!);
      _qrConnectionService = QRConnectionService(
        _webRTCService!,
        _signalingService!,
        _sessionService!,
        _contactService!,
        contactKeyService,
        sessionKeyService,
      );

      // P2P message service uses SessionKeyService (no direct EncryptionService)
      _p2pMessageService = P2PMessageService(
          _webRTCService!, sessionKeyService, _signalingService!);

      // Set up target peer callback to update P2P service immediately
      _qrConnectionService!.onTargetPeerStored = (sessionId, targetPeerId) {
        _updateP2PServiceWithTargetPeer(sessionId, targetPeerId);
      };

      // Set up session established callback to set current session
      _qrConnectionService!.onSessionEstablished =
          (sessionId, contactId, contactName) async {
        await setCurrentSession(
          sessionId: sessionId,
          contactId: contactId,
          contactName: contactName,
          source: SessionIdSource.qrScanning,
          sourceContext: 'QR pairing session established',
        );
      };

      // Listen for connection state changes
      _qrConnectionService!.onConnectionStateChanged.listen((isConnected) {
        _handleConnectionStateChange(isConnected);
      });

      // Initialize network monitoring
      await _initializeNetworkMonitoring();

      // Load existing session-contact mappings and restore current session
      await _loadSessionContactMappings();
      await _restoreCurrentSession();

      _isInitialized = true;
      GlobalErrorHandler.logInfo(
          'ConnectionManagerService initialized successfully with shared encryption services');
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'ConnectionManagerService initialization',
      );
      _logger.e('Error initializing ConnectionManagerService: $e');
      // Clean up any partially initialized services
      await _cleanupServices();
      rethrow;
    }
  }

  /// Handle connection state changes with improved logic and network monitoring
  void _handleConnectionStateChange(bool qrServiceConnected) {
    final wasConnected = isConnected; // Use the getter instead of _isConnected
    _isConnecting = false;

    // Calculate current connection state using both Phase 1 and Phase 2
    final nowConnected = isConnected;

    // Log detailed connection state for debugging

    if (nowConnected && !wasConnected) {
      // Successfully connected (either Phase 1 or Phase 2)
      _reconnectAttempts = 0;
      GlobalErrorHandler.logInfo(
        'Connection established successfully',
        data: {
          'session_id': _currentSessionId,
          'contact_id': _currentContactId,
          'webrtc_connected': _webRTCService?.isConnected == true,
          'signaling_connected': _signalingService?.isConnected == true,
        },
      );

      // Update P2P service with target peer (now that it should be stored)
      _updateP2PServiceTargetPeerAsync();
    } else if (!nowConnected && wasConnected) {
      // Connection lost
      GlobalErrorHandler.logWarning(
        'Connection lost',
        data: {
          'session_id': _currentSessionId,
          'contact_id': _currentContactId,
          'reconnect_attempts': _reconnectAttempts,
          'webrtc_connected': _webRTCService?.isConnected == true,
          'signaling_connected': _signalingService?.isConnected == true,
        },
      );
    }

    notifyListeners();
  }

  /// Quick session check using memory cache
  Future<bool> hasActiveSession(String contactId) async {
    try {
      // Check cache first
      if (_isCacheValid() &&
          _cachedCurrentContact == contactId &&
          _cachedCurrentSession != null) {
        GlobalErrorHandler.logDebug(
            'Session check: Cache hit for contact $contactId');
        return true;
      }

      // Fallback to storage
      final session =
          await _sessionService?.getActiveSessionForContact(contactId);
      final hasSession = session != null;

      // Update cache
      if (hasSession) {
        _updateSessionCache(session!.id, contactId);
      }

      GlobalErrorHandler.logDebug(
        'Session check: ${hasSession ? "Found" : "No"} active session for contact $contactId',
        data: {'contact_id': contactId, 'has_session': hasSession},
      );

      return hasSession;
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Session check for contact $contactId',
      );
      return false;
    }
  }

  /// Auto-connect to existing session with retry logic
  Future<bool> autoConnectToSession(String contactId) async {
    if (_isConnecting) {
      GlobalErrorHandler.logDebug(
          'Already connecting, ignoring auto-connect request');
      return false;
    }

    try {
      _isConnecting = true;
      notifyListeners();

      GlobalErrorHandler.logInfo(
        'Starting auto-connect for contact $contactId',
        data: {'contact_id': contactId, 'attempt': _reconnectAttempts + 1},
      );

      // Get session info
      final session =
          await _sessionService?.getActiveSessionForContact(contactId);
      if (session == null) {
        GlobalErrorHandler.logWarning(
            'No active session found for contact $contactId');
        _isConnecting = false;
        notifyListeners();
        return false;
      }

      _addSessionIdTrace(
        sessionId: session.id,
        contactId: contactId,
        source: SessionIdSource.autoReconnect,
        context: 'Auto-connect to existing session initiated',
        additionalData: {
          'reconnect_attempt': _reconnectAttempts + 1,
          'max_reconnect_attempts': _maxReconnectAttempts,
          'session_found': true,
        },
      );

      // Check if WebRTC connection is already alive and working
      if (isConnected &&
          _currentSessionId == session.id &&
          _webRTCService?.isConnected == true) {
        _addSessionIdTrace(
          sessionId: session.id,
          contactId: contactId,
          source: SessionIdSource.autoReconnect,
          context: 'Reusing existing active connection',
          additionalData: {
            'webrtc_connected': true,
            'current_session_matches': true,
          },
        );

        GlobalErrorHandler.logInfo('Reusing existing active connection');
        _isConnecting = false;
        notifyListeners();
        return true;
      }

      // Attempt to reconnect using existing session
      final success = await _attemptReconnection(session.id, contactId);

      if (success) {
        await setCurrentSession(
          sessionId: session.id,
          contactId: contactId,
          contactName:
              (await _contactService?.getContact(contactId))?.name ?? 'Unknown',
          source: SessionIdSource.autoReconnect,
          sourceContext: 'Auto-connect successful - session restored',
          additionalData: {
            'reconnect_attempt': _reconnectAttempts + 1,
            'reconnection_successful': true,
          },
        );
        _reconnectAttempts = 0;
        GlobalErrorHandler.logInfo(
          'Auto-connect successful',
          data: {'contact_id': contactId, 'session_id': session.id},
        );
      } else {
        _reconnectAttempts++;

        _addSessionIdTrace(
          sessionId: session.id,
          contactId: contactId,
          source: SessionIdSource.autoReconnect,
          context: 'Auto-connect failed',
          additionalData: {
            'reconnect_attempt': _reconnectAttempts,
            'reconnection_successful': false,
            'will_retry': _reconnectAttempts < _maxReconnectAttempts,
          },
        );

        await GlobalErrorHandler.captureConnectionError(
          'Auto-connect failed',
          sessionId: session.id,
          contactId: contactId,
          connectionPhase: 'auto_connect',
        );
      }

      _isConnecting = false;
      notifyListeners();
      return success;
    } catch (e, stackTrace) {
      _isConnecting = false;
      notifyListeners();
      await GlobalErrorHandler.captureConnectionError(
        e,
        stackTrace: stackTrace,
        contactId: contactId,
        connectionPhase: 'auto_connect',
      );
      return false;
    }
  }

  /// Attempt reconnection with different strategies
  Future<bool> _attemptReconnection(String sessionId, String contactId) async {
    for (int attempt = 1; attempt <= _maxReconnectAttempts; attempt++) {
      try {
        GlobalErrorHandler.logDebug(
          'Reconnection attempt $attempt/$_maxReconnectAttempts',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
            'strategy': attempt <= 5 ? 'standard' : 'fallback',
          },
        );

        // Strategy 1-5: Standard reconnection (reset WebRTC completely)
        if (attempt <= 5) {
          final success = await _standardReconnection(sessionId, contactId);
          if (success) return true;
        }
        // Strategy 6-10: Try with fallback ICE servers
        else {
          final success = await _fallbackReconnection(sessionId, contactId);
          if (success) return true;
        }

        // Exponential backoff between attempts
        if (attempt < _maxReconnectAttempts) {
          final delay =
              Duration(milliseconds: 500 * (1 << (attempt - 1)).clamp(1, 8));
          await Future.delayed(delay);
        }
      } catch (e, stackTrace) {
        GlobalErrorHandler.logWarning(
          'Reconnection attempt $attempt failed: $e',
          data: {'session_id': sessionId, 'contact_id': contactId},
        );

        if (attempt == _maxReconnectAttempts) {
          await GlobalErrorHandler.captureConnectionError(
            e,
            stackTrace: stackTrace,
            sessionId: sessionId,
            contactId: contactId,
            connectionPhase: 'reconnection_final_attempt',
          );
        }
      }
    }

    return false;
  }

  /// Standard reconnection strategy
  Future<bool> _standardReconnection(String sessionId, String contactId) async {
    try {
      // Close existing connections cleanly
      await _webRTCService?.close();
      _signalingService?.close();

      // Wait a moment for cleanup
      await Future.delayed(const Duration(milliseconds: 500));

      // Attempt to reconnect using existing session
      if (_qrConnectionService != null) {
        return await _qrConnectionService!
            .connectUsingExistingSession(sessionId, contactId);
      }

      return false;
    } catch (e) {
      GlobalErrorHandler.logDebug('Standard reconnection failed: $e');
      return false;
    }
  }

  /// Fallback reconnection strategy with different configuration
  Future<bool> _fallbackReconnection(String sessionId, String contactId) async {
    try {
      // Close existing connections
      await _webRTCService?.close();
      _signalingService?.close();

      // Wait longer for cleanup
      await Future.delayed(const Duration(milliseconds: 1000));

      // Try to reinitialize services with different settings
      final encryptionService = EncryptionService();
      _webRTCService = WebRTCConnectionService(encryptionService);
      _signalingService = SignalingService();

      // Update QR connection service with new instances
      _qrConnectionService = QRConnectionService(
        _webRTCService!,
        _signalingService!,
        _sessionService!,
        _contactService!,
        ContactKeyService(encryptionService),
        SessionKeyService(encryptionService),
      );

      // Set up callbacks for the new QR service instance
      _qrConnectionService!.onTargetPeerStored = (sessionId, targetPeerId) {
        _updateP2PServiceWithTargetPeer(sessionId, targetPeerId);
      };

      _qrConnectionService!.onSessionEstablished =
          (sessionId, contactId, contactName) async {
        await setCurrentSession(
          sessionId: sessionId,
          contactId: contactId,
          contactName: contactName,
          source: SessionIdSource.qrScanning,
          sourceContext: 'QR pairing session established (fallback)',
        );
      };

      // Try connecting with the fresh services
      if (_qrConnectionService != null) {
        return await _qrConnectionService!
            .connectUsingExistingSession(sessionId, contactId);
      }

      return false;
    } catch (e) {
      GlobalErrorHandler.logDebug('Fallback reconnection failed: $e');
      return false;
    }
  }

  /// Check if cache is still valid
  bool _isCacheValid() {
    if (_cacheLastUpdated == null) return false;
    return DateTime.now().difference(_cacheLastUpdated!) <
        _cacheValidityDuration;
  }

  /// Update session cache
  void _updateSessionCache(String sessionId, String contactId) {
    _cachedCurrentSession = sessionId;
    _cachedCurrentContact = contactId;
    _cacheLastUpdated = DateTime.now();
    _sessionContactCache[sessionId] = contactId;
  }

  /// Clear session cache
  void _clearSessionCache() {
    _cachedCurrentSession = null;
    _cachedCurrentContact = null;
    _cacheLastUpdated = null;
  }

  /// Clean up services in case of initialization failure
  Future<void> _cleanupServices() async {
    try {
      if (_qrConnectionService != null) {
        _qrConnectionService!.dispose();
        _qrConnectionService = null;
      }
      if (_p2pMessageService != null) {
        _p2pMessageService!.dispose();
        _p2pMessageService = null;
      }
      _webRTCService = null;
      _signalingService = null;
      _sessionService = null;
      _contactService = null;
      _isInitialized = false;
      _clearSessionCache();
    } catch (e) {
      GlobalErrorHandler.logWarning('Error during service cleanup: $e');
    }
  }

  /// Load saved session-contact mappings from storage
  Future<void> _loadSessionContactMappings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mappingJson = prefs.getString('session_contact_mapping');

      if (mappingJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(mappingJson);
        decoded.forEach((key, value) {
          _sessionToContactMapping[key] = value.toString();
          _sessionContactCache[key] = value.toString(); // Also update cache
        });
        GlobalErrorHandler.logDebug(
            'Loaded ${_sessionToContactMapping.length} session-contact mappings');
      }
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Loading session-contact mappings',
      );
      // Don't rethrow - we can continue without mappings
    }
  }

  /// Restore the current session from persistent storage
  Future<void> _restoreCurrentSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionId = prefs.getString('current_session_id');
      final contactId = prefs.getString('current_contact_id');
      final contactName = prefs.getString('current_contact_name');

      if (sessionId != null && contactId != null && contactName != null) {
        _addSessionIdTrace(
          sessionId: sessionId,
          contactId: contactId,
          source: SessionIdSource.sessionRestore,
          context: 'Session restored from persistent storage',
          additionalData: {
            'contact_name': contactName,
            'restored_from_storage': true,
          },
        );

        GlobalErrorHandler.logInfo(
          'Restoring session from persistent storage',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
            'contact_name': contactName,
            'source': SessionIdSource.sessionRestore.code,
          },
        );

        // Set the current session info
        _currentSessionId = sessionId;
        _currentContactId = contactId;
        _currentContactName = contactName;
        _currentSessionSource = SessionIdSource.sessionRestore;

        // Update cache
        _updateSessionCache(sessionId, contactId);

        // Pass session and contact info to P2P message service
        if (_p2pMessageService != null) {
          // Get target peer for Phase 2 messaging
          String? targetPeerId;
          if (_qrConnectionService != null) {
            targetPeerId =
                await _qrConnectionService!.getTargetPeerForSession(sessionId);
          }

          _p2pMessageService!
              .setSessionInfo(sessionId, contactId, targetPeerId: targetPeerId);

          _addSessionIdTrace(
            sessionId: sessionId,
            contactId: contactId,
            source: SessionIdSource.sessionRestore,
            context: 'P2P service updated during session restoration',
            additionalData: {
              'target_peer': targetPeerId,
              'p2p_service_available': true,
            },
          );

          GlobalErrorHandler.logDebug(
            'Updated P2P service during restoration',
            data: {
              'session_id': sessionId,
              'contact_id': contactId,
              'target_peer': targetPeerId,
              'source': SessionIdSource.sessionRestore.code,
            },
          );
        }

        // Try to restore the connection using existing session
        if (_qrConnectionService != null) {
          try {
            _addSessionIdTrace(
              sessionId: sessionId,
              contactId: contactId,
              source: SessionIdSource.sessionRestore,
              context: 'Attempting to restore connection',
              additionalData: {
                'qr_service_available': true,
              },
            );

            final success = await _qrConnectionService!
                .connectUsingExistingSession(sessionId, contactId);

            if (success) {
              _addSessionIdTrace(
                sessionId: sessionId,
                contactId: contactId,
                source: SessionIdSource.sessionRestore,
                context: 'Session restoration successful',
                additionalData: {
                  'connection_restored': true,
                },
              );

              GlobalErrorHandler.logInfo(
                'Successfully restored connection for session',
                data: {
                  'session_id': sessionId,
                  'source': SessionIdSource.sessionRestore.code,
                },
              );
            } else {
              _addSessionIdTrace(
                sessionId: sessionId,
                contactId: contactId,
                source: SessionIdSource.sessionRestore,
                context:
                    'Session restoration failed - connection not established',
                additionalData: {
                  'connection_restored': false,
                  'session_kept_for_retry': true,
                },
              );

              GlobalErrorHandler.logWarning(
                'Failed to restore connection - session kept for manual retry',
                data: {
                  'session_id': sessionId,
                  'source': SessionIdSource.sessionRestore.code,
                },
              );
            }
          } catch (e, stackTrace) {
            _addSessionIdTrace(
              sessionId: sessionId,
              contactId: contactId,
              source: SessionIdSource.sessionRestore,
              context: 'Session restoration error occurred',
              additionalData: {
                'error': e.toString(),
                'connection_restored': false,
              },
            );

            await GlobalErrorHandler.captureConnectionError(
              e,
              stackTrace: stackTrace,
              sessionId: sessionId,
              contactId: contactId,
              connectionPhase: 'session_restore',
            );
          }
        }
      } else {
        GlobalErrorHandler.logDebug(
          'No session to restore from persistent storage',
          data: {
            'session_id_available': sessionId != null,
            'contact_id_available': contactId != null,
            'contact_name_available': contactName != null,
          },
        );
      }
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Restoring current session',
      );
      // Clear the current session on error
      await _clearCurrentSession();
    }
  }

  /// Clear the current session information
  Future<void> clearCurrentSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Remember contactId before clearing
      final contactId = _currentContactId;

      await prefs.remove('current_session_id');
      await prefs.remove('current_contact_id');
      await prefs.remove('current_contact_name');

      _currentSessionId = null;
      _currentContactId = null;
      _currentContactName = null;
      _clearSessionCache();

      // Clear the session info from contact metadata
      if (contactId != null && _contactService != null) {
        try {
          await _contactService!.clearContactSessionInfo(contactId);
          GlobalErrorHandler.logDebug(
              'Cleared session info from contact $contactId metadata');
        } catch (e, stackTrace) {
          await GlobalErrorHandler.captureError(
            e,
            stackTrace: stackTrace,
            context: 'Clearing session info from contact metadata',
          );
        }
      }
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Clearing current session',
      );
    }
  }

  // Keep _clearCurrentSession as a private method for backward compatibility
  Future<void> _clearCurrentSession() async {
    return await clearCurrentSession();
  }

  /// Set the current session information
  Future<void> setCurrentSession({
    required String sessionId,
    required String contactId,
    required String contactName,
    SessionIdSource source = SessionIdSource.unknown,
    String? sourceContext,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      _addSessionIdTrace(
        sessionId: sessionId,
        contactId: contactId,
        source: source,
        context: sourceContext ?? 'setCurrentSession called',
        additionalData: {
          'contact_name': contactName,
          'previous_session_id': _currentSessionId,
          'previous_contact_id': _currentContactId,
          ...?additionalData,
        },
      );

      GlobalErrorHandler.logInfo(
        'Setting current session with source tracking',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
          'contact_name': contactName,
          'source': source.code,
          'source_description': source.description,
          'source_context': sourceContext,
          'previous_session_id': _currentSessionId,
        },
      );

      _currentSessionId = sessionId;
      _currentContactId = contactId;
      _currentContactName = contactName;
      _currentSessionSource = source;

      // Store the mapping between sessionId and contactId
      _sessionToContactMapping[sessionId] = contactId;

      // Update cache
      _updateSessionCache(sessionId, contactId);

      // Ensure the session is stored persistently
      await _saveCurrentSessionInfo(sessionId, contactId, contactName);

      // Pass session and contact info to P2P message service
      if (_p2pMessageService != null) {
        // Get target peer for Phase 2 messaging
        String? targetPeerId;
        if (_qrConnectionService != null) {
          targetPeerId =
              await _qrConnectionService!.getTargetPeerForSession(sessionId);
        }

        _p2pMessageService!
            .setSessionInfo(sessionId, contactId, targetPeerId: targetPeerId);

        // Trace P2P service update
        _addSessionIdTrace(
          sessionId: sessionId,
          contactId: contactId,
          source: source,
          context: 'P2P message service updated with session info',
          additionalData: {
            'target_peer': targetPeerId,
            'p2p_service_available': true,
          },
        );

        GlobalErrorHandler.logDebug(
          'Updated P2P message service',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
            'target_peer': targetPeerId,
            'source': source.code,
          },
        );
      }

      // Update contact metadata to mark that it has a session
      if (_contactService != null) {
        await _contactService!
            .updateContactWithSessionInfo(contactId, sessionId, true);

        // Trace contact service update
        _addSessionIdTrace(
          sessionId: sessionId,
          contactId: contactId,
          source: source,
          context: 'Contact service updated with session info',
          additionalData: {
            'contact_service_available': true,
          },
        );

        GlobalErrorHandler.logDebug(
          'Updated contact metadata',
          data: {
            'session_id': sessionId,
            'contact_id': contactId,
            'source': source.code,
          },
        );
      } else {
        GlobalErrorHandler.logWarning(
            'ContactService not available, could not update contact metadata');
      }

      // Validate consistency after setting session
      await validateSessionIdConsistency();

      notifyListeners();
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Setting current session',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
          'contact_name': contactName,
          'source': source.code,
          'source_context': sourceContext,
        },
      );
    }
  }

  /// Get contact ID for a specific session ID
  String? getContactIdForSession(String sessionId) {
    // Check cache first
    final cachedContactId = _sessionContactCache[sessionId];
    if (cachedContactId != null) {
      return cachedContactId;
    }

    // Fallback to in-memory mapping
    return _sessionToContactMapping[sessionId];
  }

  /// Save current session information to persistent storage
  Future<void> _saveCurrentSessionInfo(
      String sessionId, String contactId, String contactName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_session_id', sessionId);
      await prefs.setString('current_contact_id', contactId);
      await prefs.setString('current_contact_name', contactName);

      // Save the session-to-contact mapping
      Map<String, String> sessionMapping = Map.from(_sessionToContactMapping);

      // Get existing mappings if any
      final mappingJson = prefs.getString('session_contact_mapping');
      if (mappingJson != null) {
        final Map<String, dynamic> decoded = jsonDecode(mappingJson);
        decoded.forEach((key, value) {
          sessionMapping[key] = value.toString();
        });
      }

      // Add or update current mapping
      sessionMapping[sessionId] = contactId;

      // Save the updated mapping
      await prefs.setString(
          'session_contact_mapping', jsonEncode(sessionMapping));

      GlobalErrorHandler.logDebug(
          'Saved session $sessionId to persistent storage with contact $contactId');
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Saving session info',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
          'contact_name': contactName,
        },
      );
      // Don't rethrow - we can continue without saving
    }
  }

  /// Close the current connection and clean up resources
  Future<void> closeConnection() async {
    try {
      GlobalErrorHandler.logInfo('Closing connection');

      // Save contact ID before clearing
      final contactId = _currentContactId;
      final sessionId = _currentSessionId;

      // Clean up WebRTC resources
      if (_webRTCService != null) {
        _webRTCService!.dispose();
      }

      // Clean up signaling resources
      if (_signalingService != null) {
        _signalingService!.close();
      }

      // Clean up session state
      if (sessionId != null && _sessionService != null) {
        await _sessionService!.endSession(sessionId);
      }

      await _clearCurrentSession();

      // Additional step: Update contact metadata to reflect closed connection
      if (contactId != null && _contactService != null) {
        try {
          await _contactService!.clearContactSessionInfo(contactId);
          GlobalErrorHandler.logDebug(
              'Updated contact $contactId metadata to reflect closed connection');
        } catch (e, stackTrace) {
          await GlobalErrorHandler.captureError(
            e,
            stackTrace: stackTrace,
            context: 'Updating contact metadata on connection close',
          );
        }
      }

      _reconnectAttempts = 0;
      notifyListeners();

      GlobalErrorHandler.logInfo('Connection closed and resources cleaned up');
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Closing connection',
      );
      // Make sure we still clear local state even if cleanup fails
      await _clearCurrentSession();
      _reconnectAttempts = 0;
      notifyListeners();
    }
  }

  /// Handle contact deletion - close connections and clean up all data
  Future<void> handleContactDeletion(String contactId) async {
    try {
      GlobalErrorHandler.logInfo(
        'Handling contact deletion for $contactId',
        data: {'contact_id': contactId},
      );

      // If this is the current contact, close the connection
      if (_currentContactId == contactId) {
        await closeConnection();
      }

      // Clean up all sessions for this contact
      if (_sessionService != null) {
        await _sessionService!.deleteSessionsForContact(contactId);
      }

      // Remove from cache
      _sessionContactCache.removeWhere(
          (sessionId, cachedContactId) => cachedContactId == contactId);

      // Remove from mapping
      _sessionToContactMapping.removeWhere(
          (sessionId, mappedContactId) => mappedContactId == contactId);

      // IMPORTANT: Clean up target peer mappings for Phase 2 messaging
      await _cleanupTargetPeerMappings(contactId);

      // Update persistent storage
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'session_contact_mapping', jsonEncode(_sessionToContactMapping));

      GlobalErrorHandler.logInfo(
          'Successfully handled contact deletion for $contactId');
    } catch (e, stackTrace) {
      await GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'Handling contact deletion',
        data: {'contact_id': contactId},
      );
    }
  }

  /// Reset reconnection attempts (for manual retry)
  void resetReconnectionAttempts() {
    _reconnectAttempts = 0;
    notifyListeners();
  }

  /// Clean up target peer mappings for a deleted contact
  Future<void> _cleanupTargetPeerMappings(String contactId) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Get all sessions that were associated with this contact
      final sessionsToClean = <String>[];
      _sessionContactCache.forEach((sessionId, cachedContactId) {
        if (cachedContactId == contactId) {
          sessionsToClean.add(sessionId);
        }
      });

      // Remove target peer mappings for those sessions
      for (final sessionId in sessionsToClean) {
        await prefs.remove('target_peer_$sessionId');
        GlobalErrorHandler.logDebug(
            'Removed target peer mapping for session $sessionId');
      }

      GlobalErrorHandler.logInfo(
          'Cleaned up ${sessionsToClean.length} target peer mappings for contact $contactId');
    } catch (e) {
      GlobalErrorHandler.logWarning(
          'Error cleaning up target peer mappings for contact $contactId: $e');
    }
  }

  /// Manual retry connection (called by retry button)
  Future<bool> manualRetryConnection() async {
    if (_currentContactId == null) return false;

    resetReconnectionAttempts();
    return await autoConnectToSession(_currentContactId!);
  }

  /// Dispose all resources when app is shutting down
  @override
  void dispose() {
    GlobalErrorHandler.logInfo('Disposing ConnectionManagerService');

    // Only dispose during app shutdown
    if (_qrConnectionService != null) {
      _qrConnectionService!.dispose();
      _qrConnectionService = null;
    }

    if (_p2pMessageService != null) {
      _p2pMessageService!.dispose();
      _p2pMessageService = null;
    }

    _webRTCService = null;
    _signalingService = null;
    _sessionService = null;
    _contactService = null;
    _isInitialized = false;
    _clearSessionCache();

    super.dispose();
  }

  /// Update P2P service with target peer after connection is established
  void _updateP2PServiceTargetPeerAsync() {
    // Run async operation without blocking
    Future(() async {
      try {
        if (_p2pMessageService != null &&
            _currentSessionId != null &&
            _currentContactId != null &&
            _qrConnectionService != null) {
          final targetPeerId = await _qrConnectionService!
              .getTargetPeerForSession(_currentSessionId!);

          if (targetPeerId != null) {
            _p2pMessageService!.setSessionInfo(
                _currentSessionId!, _currentContactId!,
                targetPeerId: targetPeerId);
            GlobalErrorHandler.logInfo(
              'Updated P2P service with target peer after connection',
              data: {
                'session_id': _currentSessionId,
                'contact_id': _currentContactId,
                'target_peer': targetPeerId,
              },
            );
          }
        }
      } catch (e) {
        GlobalErrorHandler.logWarning(
            'Failed to update P2P service target peer: $e');
      }
    });
  }

  /// Update P2P service with target peer after target peer is stored
  void _updateP2PServiceWithTargetPeer(String sessionId, String targetPeerId) {
    try {
      if (_p2pMessageService != null && _currentContactId != null) {
        _addSessionIdTrace(
          sessionId: sessionId,
          contactId: _currentContactId!,
          source: SessionIdSource.targetPeerCallback,
          context:
              'Target peer callback - updating session ID to match key storage',
          additionalData: {
            'target_peer': targetPeerId,
            'previous_session_id': _currentSessionId,
            'session_id_updated': sessionId != _currentSessionId,
          },
        );

        // Update current session to the correct one where keys are stored
        _currentSessionId = sessionId;
        _currentSessionSource = SessionIdSource.targetPeerCallback;

        _p2pMessageService!.setSessionInfo(sessionId, _currentContactId!,
            targetPeerId: targetPeerId);

        GlobalErrorHandler.logInfo(
          'Updated P2P service via target peer callback',
          data: {
            'session_id': sessionId,
            'contact_id': _currentContactId,
            'target_peer': targetPeerId,
            'source': SessionIdSource.targetPeerCallback.code,
            'callback_triggered': true,
          },
        );
      } else {
        GlobalErrorHandler.logWarning(
          'Cannot update P2P service via target peer callback',
          data: {
            'session_id': sessionId,
            'target_peer': targetPeerId,
            'p2p_service_available': _p2pMessageService != null,
            'current_contact_available': _currentContactId != null,
          },
        );
      }
    } catch (e) {
      GlobalErrorHandler.logWarning(
          'Failed to update P2P service with target peer: $e');
    }
  }
}
