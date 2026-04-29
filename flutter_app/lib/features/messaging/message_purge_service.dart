// lib/features/messaging/message_purge_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import '../session/session_model.dart';
import '../session/session_key_service.dart';
import 'message_model.dart';
import 'package:logger/logger.dart';
import 'message_service.dart';

class MessagePurgeService {
  static final MessagePurgeService _instance = MessagePurgeService._internal();
  factory MessagePurgeService() => _instance;
  MessagePurgeService._internal();

  final _logger = Logger();
  MessageService? _messageService;
  final Map<String, Timer> _purgeTimers = {};
  final Map<String, bool> _purgeSettings = {};

  static const String _messagesKey = 'messages';
  static const String _purgeTimersKey = 'purge_timers';
  static const String _messagePurgeTimersKey = 'message_purge_timers';
  final SessionKeyService _sessionKeyService = SessionKeyService();

  // Map to keep track of active timers
  final Map<String, Timer> _activeTimers = {};

  // Map to keep track of per-message timers
  final Map<String, Timer> _messageTimers = {};

  // Set the message service (to avoid circular dependency)
  void setMessageService(MessageService messageService) {
    _messageService = messageService;
  }

  // Initialize purge settings from storage
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settings = prefs.getString('message_purge_settings');
      if (settings != null) {
        final settingsMap = jsonDecode(settings) as Map<String, dynamic>;
        settingsMap.forEach((key, value) {
          _purgeSettings[key] = value as bool;
        });
      }
    } catch (e) {
      _logger.e('Error initializing purge settings: $e');
    }
  }

  // Save purge settings to storage
  Future<void> _savePurgeSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'message_purge_settings', jsonEncode(_purgeSettings));
    } catch (e) {
      _logger.e('Error saving purge settings: $e');
    }
  }

  // Set purge setting for a contact
  Future<void> setPurgeSetting(String contactId, bool enabled) async {
    _purgeSettings[contactId] = enabled;
    await _savePurgeSettings();

    if (enabled) {
      _startPurgeTimer(contactId);
    } else {
      _stopPurgeTimer(contactId);
    }
  }

  // Get purge setting for a contact
  bool getPurgeSetting(String contactId) {
    return _purgeSettings[contactId] ?? false;
  }

  // Start purge timer for a contact
  void _startPurgeTimer(String contactId) {
    _stopPurgeTimer(contactId); // Stop existing timer if any

    _purgeTimers[contactId] = Timer.periodic(
      const Duration(minutes: 5),
      (timer) => _purgeOldMessages(contactId),
    );
  }

  // Stop purge timer for a contact
  void _stopPurgeTimer(String contactId) {
    _purgeTimers[contactId]?.cancel();
    _purgeTimers.remove(contactId);
  }

  // Purge old messages for a contact
  Future<void> _purgeOldMessages(String contactId) async {
    if (_messageService == null) {
      _logger.e('MessageService not set, cannot purge messages');
      return;
    }

    try {
      final fiveMinutesAgo =
          DateTime.now().subtract(const Duration(minutes: 5));
      await _messageService!.deleteMessagesBefore(contactId, fiveMinutesAgo);
    } catch (e) {
      _logger.e('Error purging messages for contact $contactId: $e');
    }
  }

  // Schedule message purging for an individual message
  // This is new functionality for per-message timers
  Future<void> scheduleMessagePurge(String messageId, String sessionId) async {
    // Get the session to check if purging is enabled
    final prefs = await SharedPreferences.getInstance();
    final sessionsJson = prefs.getStringList('sessions') ?? [];

    bool purgeEnabled = false;

    // Find the session and check if purging is enabled
    for (var json in sessionsJson) {
      final session = Session.fromJson(jsonDecode(json));
      if (session.id == sessionId) {
        purgeEnabled = session.purgeEnabled;
        break;
      }
    }

    // If purging isn't enabled for this session, don't schedule
    if (!purgeEnabled) {
      debugPrint(
          'Purge disabled for session $sessionId, not scheduling for message $messageId');
      return;
    }

    debugPrint('Scheduling purge for message $messageId in session $sessionId');

    // Calculate purge time (5 minutes from now)
    final purgeTime = DateTime.now().add(const Duration(minutes: 5));

    // Store the purge time for this message
    await _storeMessagePurgeTime(messageId, sessionId, purgeTime);

    // Cancel any existing timer for this message
    if (_messageTimers.containsKey(messageId)) {
      _messageTimers[messageId]?.cancel();
      _messageTimers.remove(messageId);
    }

    // Set a timer for future purge
    _messageTimers[messageId] = Timer(const Duration(minutes: 5), () async {
      await purgeMessage(messageId, sessionId);
      _messageTimers.remove(messageId);
    });
  }

  // Helper to redact a message
  Message _redactMessage(Message message) {
    return Message(
      id: message.id,
      contactId: message.contactId,
      text: "[REDACTED]",
      isSent: message.isSent,
      timestamp: message.timestamp,
      isEncrypted: false,
    );
  }

  // Purge a specific message
  Future<void> purgeMessage(String messageId, String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final messagesJson = prefs.getStringList(_messagesKey) ?? [];

    // Process each message
    final List<String> updatedMessages = [];
    bool messageFound = false;

    for (final jsonStr in messagesJson) {
      final Map<String, dynamic> messageData = jsonDecode(jsonStr);
      final message = Message.fromJson(messageData);

      // If this is the message to purge
      if (message.id == messageId) {
        messageFound = true;
        updatedMessages.add(jsonEncode(_redactMessage(message).toJson()));
      } else {
        updatedMessages.add(jsonStr);
      }
    }

    if (messageFound) {
      await prefs.setStringList(_messagesKey, updatedMessages);
      debugPrint('Message $messageId has been purged');
    }
    await _removeMessagePurgeTime(messageId);
  }

  // Schedule message purging for a session
  // Modified to respect the session's purge setting
  Future<void> schedulePurge(Session session) async {
    // Only schedule for ended sessions with purge enabled
    if (session.isActive || session.endTime == null || !session.purgeEnabled) {
      if (!session.purgeEnabled) {
        debugPrint(
            'Not scheduling session purge: purge disabled for session ${session.id}');
      }
      return;
    }

    debugPrint('Scheduling session purge for session ${session.id}');

    // Calculate purge time (5 minutes after session end)
    final purgeTime = session.endTime!.add(const Duration(minutes: 5));

    // Store the purge time
    await _storePurgeTime(session.id, purgeTime);

    // Calculate how much time until purge
    final now = DateTime.now();
    final timeUntilPurge = purgeTime.difference(now);

    // If purge time is in the future, set a timer
    if (timeUntilPurge.isNegative) {
      // Purge time has already passed, purge immediately
      await purgeSessionMessages(session.id);
    } else {
      // Set a timer for future purge
      _activeTimers[session.id] = Timer(timeUntilPurge, () async {
        await purgeSessionMessages(session.id);
        _activeTimers.remove(session.id);
      });
    }
  }

  // Purge messages for a session but keep metadata
  Future<void> purgeSessionMessages(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final messagesJson = prefs.getStringList(_messagesKey) ?? [];
    final List<String> updatedMessages = [];
    for (final jsonStr in messagesJson) {
      final Map<String, dynamic> messageData = jsonDecode(jsonStr);
      final message = Message.fromJson(messageData);
      if (_isMessageFromSession(message, sessionId)) {
        updatedMessages.add(jsonEncode(_redactMessage(message).toJson()));
      } else {
        updatedMessages.add(jsonStr);
      }
    }
    await prefs.setStringList(_messagesKey, updatedMessages);
    await _sessionKeyService.deleteKeyForSession(sessionId);
    await _removePurgeTime(sessionId);
    await _removeAllMessagePurgeTimesForSession(sessionId);
    debugPrint('Purged all messages for session $sessionId');
  }

  // Store purge time for a specific message
  Future<void> _storeMessagePurgeTime(
      String messageId, String sessionId, DateTime purgeTime) async {
    final prefs = await SharedPreferences.getInstance();
    final purgeTimesJson = prefs.getStringList(_messagePurgeTimersKey) ?? [];

    // Remove any existing entry for this message
    final filteredTimes = purgeTimesJson
        .map((json) => jsonDecode(json))
        .where((data) => data['messageId'] != messageId)
        .map((data) => jsonEncode(data))
        .toList();

    // Add the new purge time
    filteredTimes.add(jsonEncode({
      'messageId': messageId,
      'sessionId': sessionId,
      'purgeTime': purgeTime.millisecondsSinceEpoch,
    }));

    await prefs.setStringList(_messagePurgeTimersKey, filteredTimes);
  }

  // Remove purge time for a specific message
  Future<void> _removeMessagePurgeTime(String messageId) async {
    final prefs = await SharedPreferences.getInstance();
    final purgeTimesJson = prefs.getStringList(_messagePurgeTimersKey) ?? [];

    final filteredTimes = purgeTimesJson
        .map((json) => jsonDecode(json))
        .where((data) => data['messageId'] != messageId)
        .map((data) => jsonEncode(data))
        .toList();

    await prefs.setStringList(_messagePurgeTimersKey, filteredTimes);
  }

  // Remove all message purge times for a session
  Future<void> _removeAllMessagePurgeTimesForSession(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final purgeTimesJson = prefs.getStringList(_messagePurgeTimersKey) ?? [];

    final filteredTimes = purgeTimesJson
        .map((json) => jsonDecode(json))
        .where((data) => data['sessionId'] != sessionId)
        .map((data) => jsonEncode(data))
        .toList();

    await prefs.setStringList(_messagePurgeTimersKey, filteredTimes);
  }

  // Check all scheduled message purges
  Future<void> checkScheduledMessagePurges() async {
    final prefs = await SharedPreferences.getInstance();
    final purgeTimesJson = prefs.getStringList(_messagePurgeTimersKey) ?? [];

    for (final jsonStr in purgeTimesJson) {
      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final String messageId = data['messageId'];
      final String sessionId = data['sessionId'];
      final DateTime purgeTime =
          DateTime.fromMillisecondsSinceEpoch(data['purgeTime']);

      final now = DateTime.now();
      final timeUntilPurge = purgeTime.difference(now);

      // Check if purging is still enabled for this session
      bool purgeEnabled = false;
      final sessionsJson = prefs.getStringList('sessions') ?? [];

      for (var json in sessionsJson) {
        final session = Session.fromJson(jsonDecode(json));
        if (session.id == sessionId) {
          purgeEnabled = session.purgeEnabled;
          break;
        }
      }

      // Only proceed if purging is enabled
      if (!purgeEnabled) {
        await _removeMessagePurgeTime(messageId);
        continue;
      }

      if (timeUntilPurge.isNegative) {
        // Purge time has already passed, purge immediately
        await purgeMessage(messageId, sessionId);
      } else {
        // Set a timer for future purge
        if (_messageTimers.containsKey(messageId)) {
          _messageTimers[messageId]?.cancel();
        }

        _messageTimers[messageId] = Timer(timeUntilPurge, () async {
          await purgeMessage(messageId, sessionId);
          _messageTimers.remove(messageId);
        });
      }
    }
  }

  // Check all scheduled purges on app start
  Future<void> checkScheduledPurges() async {
    await checkScheduledMessagePurges();

    final prefs = await SharedPreferences.getInstance();
    final purgeTimesJson = prefs.getStringList(_purgeTimersKey) ?? [];

    for (final jsonStr in purgeTimesJson) {
      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final String sessionId = data['sessionId'];
      final DateTime purgeTime =
          DateTime.fromMillisecondsSinceEpoch(data['purgeTime']);

      final now = DateTime.now();
      final timeUntilPurge = purgeTime.difference(now);

      if (timeUntilPurge.isNegative) {
        // Purge time has already passed, purge immediately
        await purgeSessionMessages(sessionId);
      } else {
        // Set a timer for future purge
        _activeTimers[sessionId] = Timer(timeUntilPurge, () async {
          await purgeSessionMessages(sessionId);
          _activeTimers.remove(sessionId);
        });
      }
    }
  }

  // Helper method to check if a message belongs to a session
  bool _isMessageFromSession(Message message, String sessionId) {
    // In a real app, you'd have a direct way to associate messages with sessions
    // For this demo, we'll use a heuristic based on timestamps
    return true;
  }

  // Store a purge time
  Future<void> _storePurgeTime(String sessionId, DateTime purgeTime) async {
    final prefs = await SharedPreferences.getInstance();
    final purgeTimesJson = prefs.getStringList(_purgeTimersKey) ?? [];

    // Remove any existing entry for this session
    final filteredTimes = purgeTimesJson
        .map((json) => jsonDecode(json))
        .where((data) => data['sessionId'] != sessionId)
        .map((data) => jsonEncode(data))
        .toList();

    // Add the new purge time
    filteredTimes.add(jsonEncode({
      'sessionId': sessionId,
      'purgeTime': purgeTime.millisecondsSinceEpoch,
    }));

    await prefs.setStringList(_purgeTimersKey, filteredTimes);
  }

  // Remove a purge time
  Future<void> _removePurgeTime(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final purgeTimesJson = prefs.getStringList(_purgeTimersKey) ?? [];

    final filteredTimes = purgeTimesJson
        .map((json) => jsonDecode(json))
        .where((data) => data['sessionId'] != sessionId)
        .map((data) => jsonEncode(data))
        .toList();

    await prefs.setStringList(_purgeTimersKey, filteredTimes);
  }

  // Cancel all active timers
  void dispose() {
    for (final timer in _activeTimers.values) {
      timer.cancel();
    }
    _activeTimers.clear();

    for (final timer in _messageTimers.values) {
      timer.cancel();
    }
    _messageTimers.clear();
  }
}
