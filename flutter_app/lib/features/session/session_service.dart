// lib/features/session/session_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'session_model.dart';
import '../messaging/message_purge_service.dart';
import '../contacts/contact_service.dart';
import 'package:logger/logger.dart';
import 'session_key_service.dart';
import '../../core/models/user_role.dart';

class SessionService {
  static const String _sessionsKey = 'sessions';
  static const String _userRoleKey = 'user_role';
  final MessagePurgeService _messagePurgeService = MessagePurgeService();
  final ContactService _contactService;
  final _logger = Logger();

  UserRole? _currentUserRole;

  SessionService(this._contactService);

  // Creates a new session or returns the existing active session for a contact
  Future<Session> getOrCreateSession(String contactId) async {
    // Validate contact exists
    try {
      await _contactService.getContact(contactId);
    } catch (e) {
      _logger.e('Contact not found: $contactId');
      throw Exception('Contact not found: $contactId');
    }

    // Check if an active session already exists for this contact
    final existingSession = await getActiveSessionForContact(contactId);

    // If we found an active session, return it (persistent session)
    if (existingSession != null) {
      _logger.d(
          'Reusing existing session ${existingSession.id} for contact $contactId');
      return existingSession;
    }

    // No active session found, create a new one
    _logger.d('Creating new session for contact $contactId');

    final session = Session(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      contactId: contactId,
      startTime: DateTime.now(),
    );

    await _saveSession(session);
    return session;
  }

  // Explicitly delete a session and all its data
  Future<void> deleteSession(String sessionId) async {
    debugPrint('Deleting session $sessionId and all associated data');
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    final sessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    // Find the session to delete
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i].id == sessionId) {
        // Remove the session
        sessions.removeAt(i);
        await _saveSessions(sessions);

        // Purge all messages for this session immediately
        await _messagePurgeService.purgeSessionMessages(sessionId);

        // IMPORTANT: Delete encryption keys for this session
        try {
          await _deleteEncryptionKeysForSession(sessionId);
          _logger.d('Deleted encryption keys for session $sessionId');
        } catch (e) {
          _logger
              .e('Error deleting encryption keys for session $sessionId: $e');
        }

        return;
      }
    }
  }

  // Toggle the purge setting for a specific session
  Future<Session> toggleSessionPurge(String sessionId, bool enablePurge) async {
    debugPrint('Toggling purge setting to $enablePurge for session $sessionId');
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    final sessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    // Find the session to update
    Session? updatedSession;
    for (var i = 0; i < sessions.length; i++) {
      if (sessions[i].id == sessionId) {
        // Update the purge setting
        final session = sessions[i];

        // Create a new session with the updated purge setting
        final updatedSessionObj = Session(
          id: session.id,
          contactId: session.contactId,
          startTime: session.startTime,
          endTime: session.endTime,
          messageCount: session.messageCount,
          isActive: session.isActive,
          purgeEnabled: enablePurge, // Set the new purge value
        );

        sessions[i] = updatedSessionObj;
        updatedSession = updatedSessionObj;

        await _saveSessions(sessions);
        break;
      }
    }

    if (updatedSession == null) {
      throw Exception('Session not found: $sessionId');
    }

    return updatedSession;
  }

  // Get the current purge setting for a session
  Future<bool> getSessionPurgeSetting(String sessionId) async {
    final session = await getSessionById(sessionId);
    return session?.purgeEnabled ?? false;
  }

  // Get a session by its ID
  Future<Session?> getSessionById(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    for (var json in sessionsJson) {
      final session = Session.fromJson(jsonDecode(json));
      if (session.id == sessionId) {
        return session;
      }
    }

    return null;
  }

  Future<Session> createSessionWithId(Session session) async {
    await _saveSession(session);
    return session;
  }

  Future<void> reactivateSession(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    final sessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    // Find the session to reactivate
    for (var session in sessions) {
      if (session.id == sessionId) {
        session.isActive = true;
        session.endTime = null; // Clear the end time
        await _saveSessions(sessions);
        return;
      }
    }

    // Session not found
    throw Exception('Session not found: $sessionId');
  }

  // End a specific session - modified to be explicit rather than automatic
  Future<void> endSession(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    final sessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    // Find the session to end
    for (var session in sessions) {
      if (session.id == sessionId && session.isActive) {
        session.endTime = DateTime.now();
        session.isActive = false;
        await _saveSessions(sessions);

        // Only schedule purging if it's enabled for this session
        if (session.purgeEnabled) {
          debugPrint('Scheduling message purge for session $sessionId');
          await _messagePurgeService.schedulePurge(session);
        } else {
          debugPrint('Purge disabled for session $sessionId, not scheduling');
        }
        return;
      }
    }
  }

  Future<void> initializePurgeService() async {
    await _messagePurgeService.checkScheduledPurges();
    // Clean up orphaned sessions during initialization
    await cleanupOrphanedSessions();
  }

  /// Cleanup orphaned sessions (sessions without valid contacts)
  Future<void> cleanupOrphanedSessions() async {
    _logger.d('Looking for orphaned sessions to clean up');
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    if (sessionsJson.isEmpty) {
      _logger.d('No sessions found, skipping orphaned session cleanup');
      return;
    }

    final sessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    final orphanedSessionIds = <String>[];

    // Check each session to see if its contact exists
    for (var session in sessions) {
      try {
        final contact = await _contactService.getContact(session.contactId);
        if (contact == null) {
          _logger.w(
              'Found orphaned session: ${session.id} for non-existent contact: ${session.contactId}');
          orphanedSessionIds.add(session.id);
        }
      } catch (e) {
        _logger.e('Error checking contact for session ${session.id}: $e');
        // If there's an error, consider it orphaned to be safe
        orphanedSessionIds.add(session.id);
      }
    }

    if (orphanedSessionIds.isEmpty) {
      _logger.d('No orphaned sessions found');
      return;
    }

    // Remove orphaned sessions
    final cleanedSessions = sessions
        .where((session) => !orphanedSessionIds.contains(session.id))
        .toList();

    // Save the cleaned sessions
    final cleanedSessionsJson =
        cleanedSessions.map((session) => jsonEncode(session.toJson())).toList();

    await prefs.setStringList(_sessionsKey, cleanedSessionsJson);
    _logger.d('Removed ${orphanedSessionIds.length} orphaned sessions');
  }

  /// Get active session for a contact, with fallback for numeric contactIds
  Future<Session?> getActiveSessionForContact(String contactId) async {
    _logger.d(
        'DEBUGGING SESSION: Looking for active session for contact $contactId');

    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    _logger.d(
        'DEBUGGING SESSION: Found ${sessionsJson.length} total sessions in storage');

    // Log all sessions for debugging
    for (var json in sessionsJson) {
      final session = Session.fromJson(jsonDecode(json));
      _logger.d(
          'DEBUGGING SESSION: Session ${session.id} for contact ${session.contactId}, active: ${session.isActive}');
    }

    // Extract the numeric part of the contactId (e.g., "client-1" -> "1")
    final numericId = _extractNumericId(contactId);
    _logger.d(
        'DEBUGGING SESSION: Extracted numeric ID: $numericId from $contactId');

    for (var json in sessionsJson) {
      final jsonMap = jsonDecode(json);
      _logger.d('DEBUGGING SESSION: Raw JSON session data: $jsonMap');

      final session = Session.fromJson(jsonMap);

      // Try direct comparison first
      if (session.contactId == contactId && session.isActive) {
        _logger.d(
            'DEBUGGING SESSION: ✅ MATCH FOUND (exact) - active session ${session.id} for contact $contactId');
        return session;
      }

      // Try numeric comparison as fallback
      if (numericId != null &&
          session.contactId == numericId &&
          session.isActive) {
        _logger.d(
            'DEBUGGING SESSION: ✅ MATCH FOUND (numeric) - active session ${session.id} for contact $contactId');

        // Create updated session with correct contactId for future use
        final updatedSession = Session(
          id: session.id,
          contactId: contactId, // Use full contactId
          startTime: session.startTime,
          endTime: session.endTime,
          messageCount: session.messageCount,
          isActive: session.isActive,
          purgeEnabled: session.purgeEnabled,
        );

        // Save the updated session to fix the contactId
        await _saveSession(updatedSession);

        return updatedSession;
      }

      // Log no match reasons
      if (session.contactId != contactId) {
        _logger.d(
            'DEBUGGING SESSION: ❌ No match - different contactId (${session.contactId} vs $contactId)');
      }
      if (!session.isActive) {
        _logger.d('DEBUGGING SESSION: ❌ No match - session not active');
      }
    }

    _logger
        .d('DEBUGGING SESSION: No active session found for contact $contactId');
    return null;
  }

// Helper method to extract numeric ID from contact ID
  String? _extractNumericId(String contactId) {
    // Use regex to extract numeric part
    final match = RegExp(r'[a-zA-Z]+-(\d+)').firstMatch(contactId);
    if (match != null && match.groupCount >= 1) {
      return match.group(1); // Return just the number
    }
    return null;
  }

  // Get all sessions (active and inactive) for a contact
  Future<List<Session>> getSessionsForContact(String contactId) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    return sessionsJson
        .map((json) => Session.fromJson(jsonDecode(json)))
        .where((session) => session.contactId == contactId)
        .toList();
  }

  // Delete all sessions associated with a contact
  Future<void> deleteSessionsForContact(String contactId) async {
    _logger.d('Deleting all sessions for contact: $contactId');
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    final sessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    // Get sessions to delete and their IDs for key cleanup
    final sessionsToDelete =
        sessions.where((session) => session.contactId == contactId).toList();

    // Delete encryption keys for each session being deleted
    for (final session in sessionsToDelete) {
      try {
        await _deleteEncryptionKeysForSession(session.id);
        _logger.d('Deleted encryption keys for session ${session.id}');
      } catch (e) {
        _logger
            .e('Error deleting encryption keys for session ${session.id}: $e');
      }
    }

    // Filter out sessions for this contact
    final remainingSessions =
        sessions.where((session) => session.contactId != contactId).toList();

    // Save the remaining sessions
    final remainingSessionsJson = remainingSessions
        .map((session) => jsonEncode(session.toJson()))
        .toList();

    await prefs.setStringList(_sessionsKey, remainingSessionsJson);
    _logger.d('Removed sessions for contact: $contactId');
  }

  // Increment message count for a session
  Future<void> incrementMessageCount(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    final sessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    // Find the session and increment its message count
    for (var session in sessions) {
      if (session.id == sessionId) {
        session.messageCount++;
        await _saveSessions(sessions);
        return;
      }
    }
  }

  // Helper method to save a single session
  Future<void> _saveSession(Session session) async {
    _logger.d(
        'DEBUGGING SESSION: Saving session ${session.id} with contactId: ${session.contactId}');

    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList(_sessionsKey) ?? [];

    // Parse existing sessions
    final List<Session> existingSessions =
        sessionsJson.map((json) => Session.fromJson(jsonDecode(json))).toList();

    // Check if session with this ID already exists
    bool updated = false;
    for (int i = 0; i < existingSessions.length; i++) {
      if (existingSessions[i].id == session.id) {
        // Replace existing session
        existingSessions[i] = session;
        updated = true;
        _logger.d('DEBUGGING SESSION: Updated existing session ${session.id}');
        break;
      }
    }

    // If not found, add as new session
    if (!updated) {
      existingSessions.add(session);
      _logger.d('DEBUGGING SESSION: Added new session ${session.id}');
    }

    // Save all sessions back to storage
    final updatedSessionsJson =
        existingSessions.map((s) => jsonEncode(s.toJson())).toList();

    await prefs.setStringList(_sessionsKey, updatedSessionsJson);
    _logger.d(
        'DEBUGGING SESSION: Session saved successfully. Total sessions: ${existingSessions.length}');
  }

  // Helper method to save a list of sessions
  Future<void> _saveSessions(List<Session> sessions) async {
    final prefs = await SharedPreferences.getInstance();

    final sessionsJson =
        sessions.map((session) => jsonEncode(session.toJson())).toList();

    await prefs.setStringList(_sessionsKey, sessionsJson);
  }

  /// Create a session with a specific ID (for pre-registration in QR code flow)
  Future<Session> createSessionWithExistingId(
      String sessionId, String contactId,
      {bool purgeEnabled = true}) async {
    _logger.d(
        'DEBUGGING SESSION: Creating session with existing ID $sessionId for contact $contactId');
    _logger.d(
        'SESSION_EXTRA_CREATION: Creating session with ID $sessionId for contact $contactId');
    _logger.d('SESSION_EXTRA_CREATION: Stack trace: ${StackTrace.current}');

    // Check if this session already exists
    final existingSession = await getSessionById(sessionId);
    if (existingSession != null) {
      _logger.d(
          'DEBUGGING SESSION: Session with ID $sessionId already exists, returning it');
      _logger.d(
          'SESSION_EXTRA_CREATION: Session with ID $sessionId already exists, returning it');
      return existingSession;
    }

    // Create a new session with the provided ID
    final session = Session(
      id: sessionId,
      contactId: contactId,
      startTime: DateTime.now(),
      purgeEnabled: purgeEnabled,
    );

    // Save the session
    await _saveSession(session);
    _logger.d(
        'DEBUGGING SESSION: Created and saved session with ID $sessionId for contact $contactId');

    return session;
  }

  /// Mark a session as active
  /// Used when an actual connection has been established
  Future<void> markSessionActive(String sessionId) async {
    _logger.d('DEBUGGING SESSION: Marking session $sessionId as active');

    final session = await getSessionById(sessionId);
    if (session == null) {
      _logger.e(
          'DEBUGGING SESSION: Cannot mark non-existent session as active: $sessionId');
      return;
    }

    // Update the isActive flag
    session.isActive = true;

    // Ensure endTime is null for active sessions
    session.endTime = null;

    // Save the updated session
    await _saveSession(session);
    _logger.d(
        'DEBUGGING SESSION: Session $sessionId marked as active successfully');

    // Verify the change was saved
    final updatedSession = await getSessionById(sessionId);
    _logger.d(
        'DEBUGGING SESSION: Verification - Session $sessionId active status: ${updatedSession?.isActive}');
  }

  Future<void> _deleteEncryptionKeysForSession(String sessionId) async {
    try {
      // Delete session key from SessionKeyService - single source of truth
      final sessionKeyService = SessionKeyService();
      await sessionKeyService.deleteKeyForSession(sessionId);
      _logger.d('Deleted session key for session $sessionId');

      // Note: Contact metadata keys are managed separately by ContactKeyService
      // Session keys should only be deleted via SessionKeyService per Option A architecture
    } catch (e) {
      _logger.e('Error deleting session key for session $sessionId: $e');
      rethrow;
    }
  }

  /// Gets the current user role from memory or shared preferences
  Future<UserRole> getCurrentUserRole() async {
    if (_currentUserRole != null) {
      return _currentUserRole!;
    }

    final prefs = await SharedPreferences.getInstance();
    final roleStr = prefs.getString(_userRoleKey);

    if (roleStr == null) {
      // Default to responder if not set
      _currentUserRole = UserRole.responder;
      return UserRole.responder;
    }

    _currentUserRole =
        roleStr == 'initiator' ? UserRole.initiator : UserRole.responder;
    return _currentUserRole!;
  }

  /// Sets the current user role and persists it to shared preferences
  Future<void> setCurrentUserRole(UserRole role) async {
    _currentUserRole = role;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _userRoleKey, role == UserRole.initiator ? 'initiator' : 'responder');
    _logger.d(
        'User role set to: ${role == UserRole.initiator ? 'initiator' : 'responder'}');
  }

  /// Gets the target peer ID for a session from SharedPreferences
  /// This is used for Phase 2 messaging via the signaling server
  Future<String?> getTargetPeerForSession(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final targetPeer = prefs.getString('target_peer_$sessionId');

      if (targetPeer == null) {
        _logger.d('No target peer found for session $sessionId');
        return null;
      }

      _logger.d('Retrieved target peer for session $sessionId: $targetPeer');
      return targetPeer;
    } catch (e) {
      _logger.e('Error retrieving target peer for session $sessionId: $e');
      return null;
    }
  }
}
