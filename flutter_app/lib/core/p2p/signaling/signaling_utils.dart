import 'dart:convert';
import 'package:logger/logger.dart';

/// Utility class for signaling-related operations
class SignalingUtils {
  static final Logger _logger = Logger();

  /// Sanitize JSON data to prevent injection attacks
  ///
  /// This method removes potentially dangerous keys from JSON data
  /// before sending it to the signaling server.
  static Map<String, dynamic> sanitizeJson(Map<String, dynamic> json) {
    // Create a copy of the JSON to avoid modifying the original
    final sanitized = Map<String, dynamic>.from(json);

    // List of keys to remove (potentially dangerous)
    const dangerousKeys = ['__proto__', 'constructor', 'prototype'];

    // Remove dangerous keys
    for (final key in dangerousKeys) {
      sanitized.remove(key);
    }

    // Recursively sanitize nested objects
    sanitized.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        sanitized[key] = sanitizeJson(value);
      } else if (value is List) {
        sanitized[key] = _sanitizeList(value);
      }
    });

    return sanitized;
  }

  /// Sanitize a list of values
  static List _sanitizeList(List list) {
    return list.map((item) {
      if (item is Map<String, dynamic>) {
        return sanitizeJson(item);
      } else if (item is List) {
        return _sanitizeList(item);
      }
      return item;
    }).toList();
  }

  /// Validate a signaling message
  ///
  /// Returns true if the message is valid, false otherwise.
  static bool validateMessage(Map<String, dynamic> message) {
    // Check for required fields
    if (!message.containsKey('type')) {
      _logger.w('Invalid signaling message: missing "type" field');
      return false;
    }

    // Validate specific message types
    final type = message['type'];

    if (type == 'signal') {
      // Signal messages should have 'to', 'from', and 'data' fields
      if (!message.containsKey('to') ||
          !message.containsKey('from') ||
          !message.containsKey('data')) {
        _logger.w('Invalid signal message: missing required fields');
        return false;
      }

      // 'data' should be a Map
      if (message['data'] is! Map) {
        _logger.w('Invalid signal message: "data" is not a Map');
        return false;
      }
    } else if (type == 'register') {
      // Register messages should have a 'peerId' field
      if (!message.containsKey('peerId')) {
        _logger.w('Invalid register message: missing "peerId" field');
        return false;
      }
    }

    return true;
  }

  /// Try to parse JSON data safely
  ///
  /// Returns null if parsing fails
  static Map<String, dynamic>? tryParseJson(String jsonString) {
    try {
      final parsed = jsonDecode(jsonString);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
      _logger.w('Parsed JSON is not a Map<String, dynamic>');
      return null;
    } catch (e) {
      _logger.w('Failed to parse JSON: $e');
      return null;
    }
  }

  /// Retry an operation with exponential backoff
  ///
  /// [operation] - The operation to retry
  /// [maxAttempts] - Maximum number of attempts
  /// [initialDelay] - Initial delay in milliseconds
  static Future<T> retryWithBackoff<T>({
    required Future<T> Function() operation,
    required int maxAttempts,
    int initialDelay = 300,
  }) async {
    int attempts = 0;
    int delay = initialDelay;

    while (true) {
      attempts++;
      try {
        return await operation();
      } catch (e) {
        if (attempts >= maxAttempts) {
          _logger.e('Operation failed after $attempts attempts: $e');
          rethrow;
        }

        _logger.d('Attempt $attempts failed, retrying in ${delay}ms: $e');
        await Future.delayed(Duration(milliseconds: delay));

        // Exponential backoff with jitter
        delay = (delay * 1.5 +
                (delay * 0.1 * (DateTime.now().millisecondsSinceEpoch % 10)))
            .round();
      }
    }
  }
}
