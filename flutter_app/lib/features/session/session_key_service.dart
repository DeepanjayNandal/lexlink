// lib/features/session/session_key_service.dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';
import 'package:cryptography/cryptography.dart';
import '../../core/security/encryption_service.dart';

/// Service that manages session-specific encryption keys
/// This is the single source of truth for all session key operations
class SessionKeyService {
  final EncryptionService _encryptionService;
  final Logger _logger = Logger();
  static const String _keysPrefix = 'session_key_';

  /// Constructor with dependency injection for EncryptionService
  /// If no encryptionService is provided, creates its own instance for backward compatibility
  SessionKeyService([EncryptionService? encryptionService])
      : _encryptionService = encryptionService ?? EncryptionService();

  /// Generate and store a new key for a session
  /// Returns the key as a hex string for immediate use
  Future<String> generateKeyForSession(String sessionId) async {
    try {
      _logger.d('Generating new session key for: $sessionId');

      // Generate new key
      final key = await _encryptionService.generateKey();
      final keyStr = await _encryptionService.exportKey(key);

      // Store with session key prefix
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_keysPrefix$sessionId', keyStr);

      _logger
          .d('Successfully generated and stored session key for: $sessionId');
      return keyStr;
    } catch (e) {
      _logger.e('Error generating session key for $sessionId: $e');
      rethrow;
    }
  }

  /// Store an existing key for a session (for keys received during connection)
  Future<void> storeKeyForSession(String sessionId, SecretKey key) async {
    try {
      _logger.d('Storing session key for: $sessionId');

      final keyStr = await _encryptionService.exportKey(key);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_keysPrefix$sessionId', keyStr);

      _logger.d('Successfully stored session key for: $sessionId');
    } catch (e) {
      _logger.e('Error storing session key for $sessionId: $e');
      rethrow;
    }
  }

  /// Store a key from hex string (for keys received during connection)
  Future<void> storeKeyStringForSession(String sessionId, String keyHex) async {
    try {
      _logger.d('Storing session key string for: $sessionId');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_keysPrefix$sessionId', keyHex);

      _logger.d('Successfully stored session key string for: $sessionId');
    } catch (e) {
      _logger.e('Error storing session key string for $sessionId: $e');
      rethrow;
    }
  }

  /// Get the key for a session as hex string
  Future<String?> getKeyForSession(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keyStr = prefs.getString('$_keysPrefix$sessionId');

      if (keyStr != null) {
        _logger.d('Retrieved session key for: $sessionId');
      } else {
        _logger.w('No session key found for: $sessionId');
      }

      return keyStr;
    } catch (e) {
      _logger.e('Error retrieving session key for $sessionId: $e');
      return null;
    }
  }

  /// Get the key for a session as SecretKey object
  Future<SecretKey?> getSecretKeyForSession(String sessionId) async {
    try {
      final keyStr = await getKeyForSession(sessionId);
      if (keyStr == null) return null;

      final key = await _encryptionService.importKey(keyStr);
      _logger.d('Retrieved SecretKey object for session: $sessionId');
      return key;
    } catch (e) {
      _logger.e('Error retrieving SecretKey for $sessionId: $e');
      return null;
    }
  }

  /// Check if a key exists for a session
  Future<bool> hasKeyForSession(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final exists = prefs.containsKey('$_keysPrefix$sessionId');
      _logger.d('Session key exists for $sessionId: $exists');
      return exists;
    } catch (e) {
      _logger.e('Error checking session key existence for $sessionId: $e');
      return false;
    }
  }

  /// Delete the key for a session
  Future<void> deleteKeyForSession(String sessionId) async {
    try {
      _logger.d('Deleting session key for: $sessionId');

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_keysPrefix$sessionId');

      _logger.d('Successfully deleted session key for: $sessionId');
    } catch (e) {
      _logger.e('Error deleting session key for $sessionId: $e');
      rethrow;
    }
  }

  /// Delete all session keys (for app reset/cleanup)
  Future<void> deleteAllSessionKeys() async {
    try {
      _logger.d('Deleting all session keys');

      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final sessionKeys = keys.where((key) => key.startsWith(_keysPrefix));

      for (final key in sessionKeys) {
        await prefs.remove(key);
      }

      _logger.d('Successfully deleted ${sessionKeys.length} session keys');
    } catch (e) {
      _logger.e('Error deleting all session keys: $e');
      rethrow;
    }
  }

  /// Get all session IDs that have keys
  Future<List<String>> getAllSessionsWithKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final sessionKeys = keys.where((key) => key.startsWith(_keysPrefix));

      final sessionIds =
          sessionKeys.map((key) => key.substring(_keysPrefix.length)).toList();

      _logger.d('Found ${sessionIds.length} sessions with keys');
      return sessionIds;
    } catch (e) {
      _logger.e('Error getting sessions with keys: $e');
      return [];
    }
  }

  /// Encrypt a message using the session key
  Future<String> encryptMessage(String sessionId, String message) async {
    try {
      final key = await getSecretKeyForSession(sessionId);
      if (key == null) {
        throw Exception('No session key found for session: $sessionId');
      }

      final encrypted = await _encryptionService.encrypt(message, key);
      _logger.d('Successfully encrypted message for session: $sessionId');
      return encrypted;
    } catch (e) {
      _logger.e('Error encrypting message for session $sessionId: $e');
      rethrow;
    }
  }

  /// Decrypt a message using the session key
  Future<String> decryptMessage(
      String sessionId, String encryptedMessage) async {
    try {
      final key = await getSecretKeyForSession(sessionId);
      if (key == null) {
        throw Exception('No session key found for session: $sessionId');
      }

      final decrypted = await _encryptionService.decrypt(encryptedMessage, key);
      _logger.d('Successfully decrypted message for session: $sessionId');
      return decrypted;
    } catch (e) {
      _logger.e('Error decrypting message for session $sessionId: $e');
      rethrow;
    }
  }

  /// Encrypt data for a specific session (preferred API)
  /// This encapsulates crypto logic and ensures correct key usage
  Future<String> encryptForSession(String sessionId, String plaintext) async {
    return await encryptMessage(sessionId, plaintext);
  }

  /// Decrypt data for a specific session (preferred API)
  /// This encapsulates crypto logic and ensures correct key usage
  Future<String> decryptForSession(String sessionId, String ciphertext) async {
    return await decryptMessage(sessionId, ciphertext);
  }
}
