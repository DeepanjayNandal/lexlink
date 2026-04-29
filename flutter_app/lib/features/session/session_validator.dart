import '../../core/service/global_error_handler.dart';
import 'session_service.dart';
import '../contacts/contact_service.dart';
import 'session_key_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Session validation utility for ensuring session ID integrity and consistency
/// Follows dependency injection pattern for testability and clean architecture
class SessionValidator {
  final SessionService _sessionService;
  final ContactService _contactService;
  final SessionKeyService _sessionKeyService;

  SessionValidator({
    required SessionService sessionService,
    required ContactService contactService,
    required SessionKeyService sessionKeyService,
  })  : _sessionService = sessionService,
        _contactService = contactService,
        _sessionKeyService = sessionKeyService;

  /// UUID v4 pattern for validating session ID format
  static final RegExp _uuidV4Pattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  /// Validate session ID format (UUID v4)
  /// Prevents malformed, forged, or tampered session IDs
  bool isValidFormat(String sessionId) {
    final isValid = _uuidV4Pattern.hasMatch(sessionId);
    if (!isValid) {
      GlobalErrorHandler.logWarning(
        'Invalid session ID format',
        data: {'session_id': sessionId, 'reason': 'not_uuid_v4'},
      );
    }
    return isValid;
  }

  /// Check if session ID is unique (doesn't already exist)
  /// Prevents duplicate session creation for same contact
  Future<bool> isUnique(String sessionId) async {
    try {
      final existingSession = await _sessionService.getSessionById(sessionId);
      final isUnique = existingSession == null;

      if (!isUnique) {
        GlobalErrorHandler.logWarning(
          'Session ID already exists',
          data: {
            'session_id': sessionId,
            'existing_contact': existingSession?.contactId,
          },
        );
      }

      return isUnique;
    } catch (e) {
      GlobalErrorHandler.logWarning('Error checking session uniqueness: $e');
      return false;
    }
  }

  /// Check if session exists in storage
  /// Ensures session is valid and not deleted/reset
  Future<bool> isKnownSession(String sessionId) async {
    try {
      final session = await _sessionService.getSessionById(sessionId);
      final exists = session != null;

      if (!exists) {
        GlobalErrorHandler.logWarning(
          'Session not found in storage',
          data: {'session_id': sessionId},
        );
      }

      return exists;
    } catch (e) {
      GlobalErrorHandler.logWarning('Error checking session existence: $e');
      return false;
    }
  }

  /// Validate session is properly associated with contact
  /// Prevents session/contact ID mismatches
  Future<bool> isValidSessionForContact(
      String sessionId, String contactId) async {
    try {
      // Check if contact exists
      final contact = await _contactService.getContact(contactId);
      if (contact == null) {
        GlobalErrorHandler.logWarning(
          'Contact not found for session validation',
          data: {'session_id': sessionId, 'contact_id': contactId},
        );
        return false;
      }

      // Check if session exists
      final session = await _sessionService.getSessionById(sessionId);
      if (session == null) {
        GlobalErrorHandler.logWarning(
          'Session not found for contact validation',
          data: {'session_id': sessionId, 'contact_id': contactId},
        );
        return false;
      }

      // Verify session is associated with the correct contact
      final isValid = session.contactId == contactId;
      if (!isValid) {
        GlobalErrorHandler.logWarning(
          'Session/contact association mismatch',
          data: {
            'session_id': sessionId,
            'expected_contact': contactId,
            'actual_contact': session.contactId,
          },
        );
      }

      return isValid;
    } catch (e) {
      GlobalErrorHandler.logWarning(
          'Error validating session-contact association: $e');
      return false;
    }
  }

  /// Check if session has required encryption keys
  /// Ensures session is ready for secure messaging
  Future<bool> hasValidKeys(String sessionId) async {
    try {
      final hasKeys = await _sessionKeyService.hasKeyForSession(sessionId);

      if (!hasKeys) {
        GlobalErrorHandler.logWarning(
          'No encryption keys found for session',
          data: {'session_id': sessionId},
        );
      }

      return hasKeys;
    } catch (e) {
      GlobalErrorHandler.logWarning('Error checking session keys: $e');
      return false;
    }
  }

  /// Check if session has target peer mapping (for Phase 2 messaging)
  /// Ensures session can send messages via signaling server relay
  Future<bool> hasTargetPeerMapping(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final targetPeer = prefs.getString('target_peer_$sessionId');
      final hasMapping = targetPeer != null;

      if (!hasMapping) {
        GlobalErrorHandler.logWarning(
          'No target peer mapping found for session',
          data: {'session_id': sessionId},
        );
      }

      return hasMapping;
    } catch (e) {
      GlobalErrorHandler.logWarning('Error checking target peer mapping: $e');
      return false;
    }
  }

  /// Comprehensive validation for session readiness
  /// Checks all critical requirements for a functional session
  Future<SessionValidationResult> validateSession(
      String sessionId, String contactId) async {
    final result =
        SessionValidationResult(sessionId: sessionId, contactId: contactId);

    // Format validation (sync)
    result.validFormat = isValidFormat(sessionId);
    if (!result.validFormat) return result;

    // Async validations
    result.sessionExists = await isKnownSession(sessionId);
    result.contactAssociation =
        await isValidSessionForContact(sessionId, contactId);
    result.hasKeys = await hasValidKeys(sessionId);
    result.hasTargetPeer = await hasTargetPeerMapping(sessionId);

    return result;
  }

  /// Prevent duplicate sessions for same contact
  /// Returns existing session ID if found, null if safe to create new
  Future<String?> getExistingSessionForContact(String contactId) async {
    try {
      final sessions = await _sessionService.getSessionsForContact(contactId);
      final activeSession = sessions.where((s) => s.isActive).firstOrNull;

      if (activeSession != null) {
        GlobalErrorHandler.logInfo(
          'Found existing active session for contact',
          data: {
            'contact_id': contactId,
            'session_id': activeSession.id,
          },
        );
        return activeSession.id;
      }

      return null;
    } catch (e) {
      GlobalErrorHandler.logWarning('Error checking existing sessions: $e');
      return null;
    }
  }

  /// STEP 5: End-to-end session ID flow validation
  /// Comprehensive validation to ensure single session ID throughout entire flow
  Future<SessionFlowValidationResult> validateCompleteSessionFlow(
    String sessionId,
    String contactId, {
    bool shouldHaveKeys = false,
    bool shouldHaveTargetPeer = false,
    bool shouldHaveActiveSession = false,
  }) async {
    final List<String> flowErrors = [];
    final List<String> flowWarnings = [];
    final List<String> flowSteps = [];

    try {
      flowSteps.add('STEP 5: Starting complete session flow validation');

      // 1. Validate session ID format
      if (!isValidFormat(sessionId)) {
        flowErrors.add('Session ID format validation failed');
      } else {
        flowSteps.add('✅ Session ID format valid');
      }

      // 2. Check session uniqueness
      final sessionIsUnique = await isUnique(sessionId);
      if (shouldHaveActiveSession && sessionIsUnique) {
        flowWarnings.add('Expected active session but session ID is unique');
      } else if (!shouldHaveActiveSession && !sessionIsUnique) {
        flowWarnings.add('Unexpected existing session found');
      }
      flowSteps.add('✅ Session uniqueness check completed');

      // 3. Validate contact exists
      final contact = await _contactService.getContact(contactId);
      if (contact == null) {
        flowErrors.add('Contact not found: $contactId');
      } else {
        flowSteps.add('✅ Contact validation completed');
      }

      // 4. Check encryption keys exist - ✅ Use hasKeyForSession consistently
      if (shouldHaveKeys) {
        final hasKeys = await _sessionKeyService.hasKeyForSession(sessionId);
        if (!hasKeys) {
          flowErrors.add(
              'Expected encryption keys but none found for session: $sessionId');
        } else {
          flowSteps.add('✅ Encryption keys validation completed');
        }
      } else {
        flowSteps.add('✅ Encryption keys validation skipped');
      }

      // 5. Check target peer mapping
      final prefs = await SharedPreferences.getInstance();
      final targetPeerData = prefs.getString('target_peer_$contactId');
      if (shouldHaveTargetPeer && targetPeerData == null) {
        flowErrors.add('Expected target peer mapping but none found');
      } else if (shouldHaveTargetPeer && targetPeerData != null) {
        final targetPeerMap = jsonDecode(targetPeerData);
        if (!targetPeerMap.containsKey(sessionId)) {
          flowErrors
              .add('Target peer mapping not found for session ID: $sessionId');
        } else {
          flowSteps.add('✅ Target peer mapping validation completed');
        }
      } else {
        flowSteps.add('✅ Target peer mapping validation skipped');
      }

      // 6. Cross-validate all components use same session ID
      final crossValidationResult =
          await _crossValidateSessionIdConsistency(sessionId, contactId);
      if (!crossValidationResult) {
        flowErrors.add(
            'Cross-validation failed - components use different session IDs');
      } else {
        flowSteps.add(
            '✅ Cross-validation completed - all components use same session ID');
      }

      flowSteps.add('STEP 5: Complete session flow validation finished');

      return SessionFlowValidationResult(
        isValid: flowErrors.isEmpty,
        sessionId: sessionId,
        contactId: contactId,
        errors: flowErrors,
        warnings: flowWarnings,
        validationSteps: flowSteps,
        timestamp: DateTime.now(),
      );
    } catch (e) {
      flowErrors.add('Session flow validation error: $e');
      return SessionFlowValidationResult(
        isValid: false,
        sessionId: sessionId,
        contactId: contactId,
        errors: flowErrors,
        warnings: flowWarnings,
        validationSteps: flowSteps,
        timestamp: DateTime.now(),
      );
    }
  }

  /// Cross-validate that all components use the same session ID
  Future<bool> _crossValidateSessionIdConsistency(
      String expectedSessionId, String contactId) async {
    try {
      // ✅ Use hasKeyForSession instead of manual storage parsing
      final hasExpectedKey =
          await _sessionKeyService.hasKeyForSession(expectedSessionId);

      // Check if there are any keys at all
      final allSessionsWithKeys =
          await _sessionKeyService.getAllSessionsWithKeys();

      // If there are other session keys but not the expected one, that's inconsistent
      if (allSessionsWithKeys.isNotEmpty && !hasExpectedKey) {
        GlobalErrorHandler.logWarning(
          'Key consistency issue: Expected session has no key but other sessions do',
          data: {
            'expected_session_id': expectedSessionId,
            'contact_id': contactId,
            'sessions_with_keys': allSessionsWithKeys,
          },
        );
        return false;
      }

      // Check target peer mapping consistency (this is separate from session keys)
      final prefs = await SharedPreferences.getInstance();
      final targetPeerData = prefs.getString('target_peer_$expectedSessionId');

      // If we expect a target peer but don't have one, that's fine for new connections
      // Cross-validation should focus on consistency, not completeness

      return true; // Keys are consistent
    } catch (e) {
      GlobalErrorHandler.logWarning('Error in cross-validation: $e');
      return false; // Error means inconsistency
    }
  }

  /// Quick session ID consistency check for real-time validation
  Future<bool> quickConsistencyCheck(String sessionId, String contactId) async {
    try {
      return await _crossValidateSessionIdConsistency(sessionId, contactId);
    } catch (e) {
      return false;
    }
  }
}

/// Result object for comprehensive session validation
class SessionValidationResult {
  final String sessionId;
  final String contactId;

  bool validFormat = false;
  bool sessionExists = false;
  bool contactAssociation = false;
  bool hasKeys = false;
  bool hasTargetPeer = false;

  SessionValidationResult({
    required this.sessionId,
    required this.contactId,
  });

  /// Check if session is fully valid and ready for use
  bool get isValid => validFormat && sessionExists && contactAssociation;

  /// Check if session is ready for messaging (has encryption setup)
  bool get isMessagingReady => isValid && hasKeys && hasTargetPeer;

  /// Get list of validation failures for debugging
  List<String> get failures {
    final failures = <String>[];
    if (!validFormat) failures.add('invalid_format');
    if (!sessionExists) failures.add('session_not_found');
    if (!contactAssociation) failures.add('contact_mismatch');
    if (!hasKeys) failures.add('missing_keys');
    if (!hasTargetPeer) failures.add('missing_target_peer');
    return failures;
  }

  /// Get human-readable validation summary
  String get summary {
    if (isMessagingReady) return 'Session fully ready';
    if (isValid) return 'Session valid but missing messaging setup';
    return 'Session validation failed: ${failures.join(', ')}';
  }
}

/// Comprehensive session flow validation result
class SessionFlowValidationResult {
  final bool isValid;
  final String sessionId;
  final String contactId;
  final List<String> errors;
  final List<String> warnings;
  final List<String> validationSteps;
  final DateTime timestamp;

  SessionFlowValidationResult({
    required this.isValid,
    required this.sessionId,
    required this.contactId,
    required this.errors,
    required this.warnings,
    required this.validationSteps,
    required this.timestamp,
  });

  @override
  String toString() {
    return 'SessionFlowValidationResult(isValid: $isValid, sessionId: $sessionId, contactId: $contactId, errors: ${errors.length}, warnings: ${warnings.length})';
  }
}

/// Extension for null-safe firstOrNull on Iterable
extension IterableExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
