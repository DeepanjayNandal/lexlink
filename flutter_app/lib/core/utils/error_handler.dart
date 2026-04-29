// lib/core/utils/error_handler.dart

import 'dart:async';
import 'package:logger/logger.dart';
import '../service/global_error_handler.dart';

/// Utility class for standardized error handling with retry logic
/// This class integrates with GlobalErrorHandler for centralized error reporting
class ErrorHandler {
  static final Logger _logger = Logger();

  /// Execute an operation with retry logic
  ///
  /// [operation] - The async operation to execute
  /// [operationName] - Name of the operation for logging
  /// [maxRetries] - Maximum number of retry attempts
  /// [initialDelay] - Initial delay before first retry
  /// [context] - Additional context for error reporting
  /// [shouldRetry] - Optional function to determine if a specific error should trigger retry
  static Future<T> executeWithRetry<T>({
    required Future<T> Function() operation,
    required String operationName,
    int maxRetries = 3,
    Duration initialDelay = const Duration(milliseconds: 500),
    Map<String, dynamic>? context,
    bool Function(dynamic error)? shouldRetry,
  }) async {
    int attempts = 0;
    Duration delay = initialDelay;

    while (true) {
      try {
        attempts++;
        if (attempts > 1) {
          _logger.d('Executing $operationName (attempt $attempts/$maxRetries)');
        }
        return await operation();
      } catch (e, stackTrace) {
        // Check if we should retry this specific error
        final bool canRetry = shouldRetry != null ? shouldRetry(e) : true;

        if (!canRetry || attempts >= maxRetries) {
          _logger.e('$operationName failed after $attempts attempts: $e');
          GlobalErrorHandler.captureError(
            e,
            stackTrace: stackTrace,
            context: operationName,
            data: {
              'attempts': attempts,
              'max_retries': maxRetries,
              if (context != null) ...context,
            },
          );
          rethrow;
        }

        _logger.w(
            '$operationName attempt $attempts failed, retrying in ${delay.inMilliseconds}ms: $e');

        // Log retry attempt
        GlobalErrorHandler.logWarning(
          '$operationName retry attempt',
          data: {
            'attempt': attempts,
            'max_retries': maxRetries,
            'delay_ms': delay.inMilliseconds,
            'error': e.toString(),
            if (context != null) ...context,
          },
        );

        await Future.delayed(delay);
        delay = delay * 2; // Exponential backoff
      }
    }
  }

  /// Execute an operation with timeout
  ///
  /// [operation] - The async operation to execute
  /// [operationName] - Name of the operation for logging
  /// [timeout] - Maximum time to wait for operation
  /// [onTimeout] - Optional callback to execute on timeout
  /// [context] - Additional context for error reporting
  static Future<T> executeWithTimeout<T>({
    required Future<T> Function() operation,
    required String operationName,
    required Duration timeout,
    Future<T> Function()? onTimeout,
    Map<String, dynamic>? context,
  }) async {
    try {
      return await operation().timeout(
        timeout,
        onTimeout: onTimeout != null
            ? () async {
                _logger
                    .w('$operationName timed out after ${timeout.inSeconds}s');

                // Log timeout
                GlobalErrorHandler.logWarning(
                  '$operationName timed out',
                  data: {
                    'timeout_seconds': timeout.inSeconds,
                    'has_fallback': true,
                    if (context != null) ...context,
                  },
                );

                return await onTimeout();
              }
            : () {
                _logger.e(
                    '$operationName timed out after ${timeout.inSeconds}s with no fallback');

                // Log timeout with no fallback
                GlobalErrorHandler.logError(
                  '$operationName timed out with no fallback',
                  data: {
                    'timeout_seconds': timeout.inSeconds,
                    if (context != null) ...context,
                  },
                );

                throw TimeoutException(
                    'Operation $operationName timed out', timeout);
              },
      );
    } catch (e, stackTrace) {
      if (e is! TimeoutException) {
        _logger.e('$operationName failed: $e');
        GlobalErrorHandler.captureError(
          e,
          stackTrace: stackTrace,
          context: operationName,
          data: context != null ? Map<String, dynamic>.from(context) : null,
        );
      }
      rethrow;
    }
  }

  /// Log a connection event with standardized format
  ///
  /// [event] - The connection event name
  /// [data] - Additional data to log
  /// [level] - Log level (info, warning, error)
  static void logConnectionEvent(
    String event, {
    Map<String, dynamic>? data,
    String level = 'info',
  }) {
    final logData = {
      'event': event,
      'timestamp': DateTime.now().toIso8601String(),
      ...?data,
    };

    switch (level) {
      case 'warning':
        _logger.w('CONNECTION_EVENT: $event', logData);
        GlobalErrorHandler.logWarning('CONNECTION_EVENT: $event',
            data: logData);
        break;
      case 'error':
        _logger.e('CONNECTION_EVENT: $event', logData);
        GlobalErrorHandler.logError('CONNECTION_EVENT: $event', data: logData);
        break;
      case 'info':
      default:
        _logger.d('CONNECTION_EVENT: $event', logData);
        GlobalErrorHandler.logInfo('CONNECTION_EVENT: $event', data: logData);
        break;
    }
  }

  /// Handle a specific error type with custom logic
  ///
  /// [error] - The error to handle
  /// [handler] - Custom handler for the specific error type
  /// [defaultHandler] - Default handler for other error types
  /// [context] - Additional context for error reporting
  static Future<T> handleSpecificError<T, E extends Exception>({
    required dynamic error,
    required Future<T> Function(E error) handler,
    Future<T> Function(dynamic error)? defaultHandler,
    String? context,
    Map<String, dynamic>? contextData,
  }) async {
    try {
      if (error is E) {
        return await handler(error);
      } else if (defaultHandler != null) {
        return await defaultHandler(error);
      } else {
        throw error;
      }
    } catch (e, stackTrace) {
      // Only log if this is a new error, not the original one being rethrown
      if (e != error) {
        _logger.e('Error in error handler: $e');
        GlobalErrorHandler.captureError(
          e,
          stackTrace: stackTrace,
          context: context ?? 'error_handler',
          data: {
            'original_error': error.toString(),
            'error_type': error.runtimeType.toString(),
            ...?contextData,
          },
        );
      }
      rethrow;
    }
  }

  /// Clean up resources and perform error recovery
  ///
  /// [resources] - List of resources to clean up (e.g., streams, subscriptions)
  /// [cleanupFn] - Function to call for each resource
  static Future<void> cleanupResources<T>({
    required List<T?> resources,
    required Future<void> Function(T resource) cleanupFn,
    String? operationName,
  }) async {
    for (final resource in resources) {
      if (resource != null) {
        try {
          await cleanupFn(resource);
        } catch (e, stackTrace) {
          _logger.w('Error cleaning up resource: $e');
          GlobalErrorHandler.captureError(
            e,
            stackTrace: stackTrace,
            context: operationName ?? 'resource_cleanup',
            data: {
              'resource_type': resource.runtimeType.toString(),
            },
          );
          // Continue cleanup despite errors
        }
      }
    }
  }
}
