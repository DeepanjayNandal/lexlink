// lib/features/session/session_recovery_service.dart

import 'dart:async';
import 'package:logger/logger.dart';
import '../../core/p2p/signaling_service.dart';
import '../../core/p2p/webrtc_connection_service.dart';
import '../../features/session/session_service.dart';
import '../../features/session/session_key_service.dart';
import '../../features/session/session_validator.dart';
import '../../features/contacts/contact_service.dart';
import '../../core/service/global_error_handler.dart';
import '../../core/utils/error_handler.dart';

/// Service for recovering interrupted sessions
class SessionRecoveryService {
  final Logger _logger = Logger();
  final SignalingService _signalingService;
  final WebRTCConnectionService _webRTCService;
  final SessionService _sessionService;
  final ContactService _contactService;
  final SessionKeyService _sessionKeyService;
  final SessionValidator _sessionValidator;

  // Default signaling server URL
  final String _defaultServerUrl;

  // Recovery state
  bool _isRecovering = false;
  int _recoveryAttempts = 0;
  static const int _maxRecoveryAttempts = 5;

  // Constructor
  SessionRecoveryService({
    required SignalingService signalingService,
    required WebRTCConnectionService webRTCService,
    required SessionService sessionService,
    required ContactService contactService,
    required SessionKeyService sessionKeyService,
    required String defaultServerUrl,
  })  : _signalingService = signalingService,
        _webRTCService = webRTCService,
        _sessionService = sessionService,
        _contactService = contactService,
        _sessionKeyService = sessionKeyService,
        _defaultServerUrl = defaultServerUrl,
        _sessionValidator = SessionValidator(
          sessionService: sessionService,
          contactService: contactService,
          sessionKeyService: sessionKeyService,
        );

  /// Recover a session with retry logic
  Future<bool> recoverSession(String sessionId, String contactId) async {
    if (_isRecovering) {
      _logger.d(
          'Already attempting to recover session, ignoring duplicate request');
      return false;
    }

    _isRecovering = true;
    ErrorHandler.logConnectionEvent('session_recovery_started', data: {
      'session_id': sessionId,
      'contact_id': contactId,
      'attempt': _recoveryAttempts + 1,
    });

    try {
      // 1. Validate session and contact
      final validationResult =
          await _sessionValidator.validateSession(sessionId, contactId);
      if (!validationResult.isValid) {
        _logger.w('Session validation failed: ${validationResult.summary}');
        _isRecovering = false;
        return false;
      }

      // 2. Ensure signaling connection
      if (!_signalingService.isConnected) {
        final peerId = await _getPeerIdForSession(sessionId);
        if (peerId == null) {
          _logger.w('No peer ID found for session $sessionId');
          _isRecovering = false;
          return false;
        }

        await _signalingService.connect(_defaultServerUrl, peerId);
      }

      // 3. Set target peer
      final targetPeerId =
          await _sessionService.getTargetPeerForSession(sessionId);
      if (targetPeerId != null) {
        _signalingService.setTargetPeer(targetPeerId);
        _logger.d('Set target peer to $targetPeerId');
      }

      // 4. Initialize WebRTC connection
      await _webRTCService.initializeForExistingSession(sessionId);

      _logger.d('Session recovery successful');
      _recoveryAttempts = 0;
      _isRecovering = false;
      return true;
    } catch (e, stackTrace) {
      _logger.e('Session recovery failed: $e');
      GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'session_recovery',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
          'attempt': _recoveryAttempts + 1,
        },
      );

      _recoveryAttempts++;

      // If we haven't exceeded max attempts, schedule another try
      if (_recoveryAttempts < _maxRecoveryAttempts) {
        _isRecovering = false;
        // Exponential backoff
        final delay = Duration(seconds: 1 << _recoveryAttempts);
        _logger.d(
            'Scheduling recovery attempt ${_recoveryAttempts + 1} in ${delay.inSeconds} seconds');

        Timer(delay, () {
          recoverSession(sessionId, contactId);
        });
      } else {
        _logger.w('Max recovery attempts reached ($_maxRecoveryAttempts)');
        _isRecovering = false;
      }

      return false;
    }
  }

  /// Get the peer ID for a session
  Future<String?> _getPeerIdForSession(String sessionId) async {
    try {
      final session = await _sessionService.getSessionById(sessionId);
      if (session == null) return null;

      // Try to get peer ID from session metadata
      final metadata = session.metadata;
      if (metadata != null && metadata.containsKey('peerId')) {
        return metadata['peerId'] as String;
      }

      // If not found, use the current peer ID from signaling service
      return _signalingService.peerId;
    } catch (e) {
      _logger.e('Error getting peer ID for session: $e');
      return null;
    }
  }

  /// Regenerate session keys if needed
  Future<bool> regenerateSessionKeys(String sessionId, String contactId) async {
    try {
      // Check if we already have valid keys
      final hasKeys = await _sessionKeyService.hasKeyForSession(sessionId);
      if (hasKeys) {
        _logger.d('Session already has valid keys');
        return true;
      }

      // Get the contact to check role
      final contact = await _contactService.getContact(contactId);
      if (contact == null) {
        _logger.w('Contact not found: $contactId');
        return false;
      }

      // Only lawyers can regenerate keys
      if (contact.role != 'lawyer') {
        _logger.w('Only lawyers can regenerate session keys');
        return false;
      }

      // Generate new keys
      await _sessionKeyService.generateKeyForSession(sessionId);
      _logger.d('Successfully regenerated keys for session $sessionId');
      return true;
    } catch (e, stackTrace) {
      _logger.e('Error regenerating session keys: $e');
      GlobalErrorHandler.captureError(
        e,
        stackTrace: stackTrace,
        context: 'regenerate_session_keys',
        data: {
          'session_id': sessionId,
          'contact_id': contactId,
        },
      );
      return false;
    }
  }
}
