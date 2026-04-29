// lib/features/messaging/message_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'message_model.dart';
import '../../features/session/session_key_service.dart';
import '../session/session_service.dart';
import '../contacts/contact_service.dart';
import '../contacts/contact_repository.dart';
import '../contacts/contact_key_service.dart';
import '../../core/security/encryption_service.dart'; // Still needed for ContactKeyService
import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart';

class MessageService {
  static const String _messagesKey = 'messages';
  final SessionKeyService _sessionKeyService = SessionKeyService();
  final ContactRepository _contactRepository = ContactRepository();
  late final ContactKeyService _contactKeyService;
  late final ContactService _contactService;
  late final SessionService _sessionService;
  final _logger = Logger();

  MessageService() {
    // Note: EncryptionService is now fully encapsulated within SessionKeyService
    // per Option A architecture - MessageService no longer needs direct access
    _contactKeyService = ContactKeyService(EncryptionService());
    _contactService = ContactService(_contactRepository, _contactKeyService);
    _sessionService = SessionService(_contactService);
  }

  // Save a message to local storage with encryption
  Future<void> saveMessage(Message message, String sessionId) async {
    try {
      // Use SessionKeyService for encryption - no key generation here
      // Keys must be established during connection/session setup
      String encryptedText;

      try {
        encryptedText =
            await _sessionKeyService.encryptForSession(sessionId, message.text);
      } catch (e) {
        // Graceful handling of missing keys per audit recommendations
        if (kDebugMode) {
          // Fail fast in development
          throw Exception(
              'Missing encryption key for session: $sessionId. Error: $e');
        } else {
          // Graceful fallback in production
          _logger.e('Cannot encrypt message for session $sessionId: $e');
          encryptedText = '[ENCRYPTION_FAILED]'; // Marker for UI handling
        }
      }

      // Create a new message with encrypted text
      final encryptedMessage = Message(
        id: message.id,
        contactId: message.contactId,
        text: encryptedText,
        isSent: message.isSent,
        timestamp: message.timestamp,
        isEncrypted: true,
      );

      final prefs = await SharedPreferences.getInstance();
      final messagesJson = prefs.getStringList(_messagesKey) ?? [];

      messagesJson.add(jsonEncode(encryptedMessage.toJson()));
      await prefs.setStringList(_messagesKey, messagesJson);

      // Update message count in the session
      await _sessionService.incrementMessageCount(sessionId);
    } catch (e) {
      _logger.e('Error saving message: $e');
      rethrow;
    }
  }

  // Get messages for a specific contact, decrypting if possible
  Future<List<Message>> getMessagesForContact(
      String contactId, String? currentSessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messagesJson = prefs.getStringList(_messagesKey) ?? [];

      final messages = messagesJson
          .map((json) => Message.fromJson(jsonDecode(json)))
          .where((message) => message.contactId == contactId)
          .toList();

      // If we have a current session ID, try to decrypt messages using SessionKeyService
      if (currentSessionId != null) {
        // Try to decrypt each message
        for (int i = 0; i < messages.length; i++) {
          final message = messages[i];
          if (message.isEncrypted) {
            try {
              final decryptedText = await _sessionKeyService.decryptForSession(
                  currentSessionId, message.text);

              // Replace with decrypted version
              messages[i] = Message(
                id: message.id,
                contactId: message.contactId,
                text: decryptedText,
                isSent: message.isSent,
                timestamp: message.timestamp,
                isEncrypted: false,
              );
            } catch (e) {
              _logger.w('Failed to decrypt message ${message.id}: $e');

              // Graceful fallback for undecryptable messages
              String fallbackText;
              if (message.text == '[ENCRYPTION_FAILED]') {
                fallbackText = 'Message encryption failed';
              } else {
                fallbackText = 'Message cannot be decrypted';
              }

              messages[i] = Message(
                id: message.id,
                contactId: message.contactId,
                text: fallbackText,
                isSent: message.isSent,
                timestamp: message.timestamp,
                isEncrypted: true,
              );
            }
          }
        }
      } else {
        _logger.w('No session ID provided for decryption');
      }

      return messages;
    } catch (e) {
      _logger.e('Error getting messages for contact $contactId: $e');
      rethrow;
    }
  }

  // Delete all messages for a contact
  Future<void> deleteMessagesForContact(String contactId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messagesJson = prefs.getStringList(_messagesKey) ?? [];

      final filteredMessages = messagesJson
          .map((json) => jsonDecode(json))
          .where((jsonMap) => jsonMap['contactId'] != contactId)
          .map((jsonMap) => jsonEncode(jsonMap))
          .toList();

      await prefs.setStringList(_messagesKey, filteredMessages);
      _logger.d('Deleted all messages for contact $contactId');
    } catch (e) {
      _logger.e('Error deleting messages for contact $contactId: $e');
      rethrow;
    }
  }

  // Clear all messages
  Future<void> clearAllMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_messagesKey);
      _logger.d('Cleared all messages');
    } catch (e) {
      _logger.e('Error clearing all messages: $e');
      rethrow;
    }
  }

  /// Delete messages for a contact before a specific timestamp
  Future<void> deleteMessagesBefore(String contactId, DateTime before) async {
    try {
      final messages = await getMessagesForContact(contactId, null);
      final messagesToDelete =
          messages.where((m) => m.timestamp.isBefore(before));

      for (final message in messagesToDelete) {
        await deleteMessage(message.id);
      }

      _logger.d(
          'Deleted ${messagesToDelete.length} messages before ${before.toIso8601String()}');
    } catch (e) {
      _logger
          .e('Error deleting messages before ${before.toIso8601String()}: $e');
      rethrow;
    }
  }

  /// Delete a specific message by ID
  Future<void> deleteMessage(String messageId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messagesJson = prefs.getString(_messagesKey);

      if (messagesJson != null) {
        final List<dynamic> messages = jsonDecode(messagesJson);
        messages.removeWhere((m) => m['id'] == messageId);
        await prefs.setString(_messagesKey, jsonEncode(messages));
        _logger.d('Deleted message with ID: $messageId');
      }
    } catch (e) {
      _logger.e('Error deleting message $messageId: $e');
      rethrow;
    }
  }
}
