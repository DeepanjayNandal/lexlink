import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:logger/logger.dart';

/// Global error handler service for comprehensive error tracking
class GlobalErrorHandler {
  static final GlobalErrorHandler _instance = GlobalErrorHandler._internal();
  static GlobalErrorHandler get instance => _instance;
  GlobalErrorHandler._internal();

  final Logger _logger = Logger();
  bool _isInitialized = false;

  /// Initialize the global error handler
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Set up Flutter error handling
    FlutterError.onError = _handleFlutterError;

    // Set up platform error handling
    PlatformDispatcher.instance.onError = _handlePlatformError;

    // Set up zone error handling for async errors
    runZonedGuarded<void>(() {}, _handleZoneError);

    _isInitialized = true;
    _logger.i('GlobalErrorHandler initialized successfully');
  }

  /// Handle Flutter framework errors
  void _handleFlutterError(FlutterErrorDetails details) {
    _logger.e('Flutter Error: ${details.exception}', details.exception,
        details.stack);

    // Send to Sentry with additional context
    Sentry.captureException(
      details.exception,
      stackTrace: details.stack,
      withScope: (scope) {
        scope.setTag('error_type', 'flutter_error');
        scope.setExtra('library', details.library);
        scope.setExtra('context', details.context?.toString());
        scope.setExtra('silent', details.silent);
      },
    );

    // Show error in debug mode
    if (kDebugMode) {
      FlutterError.presentError(details);
    }
  }

  /// Handle platform-specific errors
  bool _handlePlatformError(Object error, StackTrace stack) {
    _logger.e('Platform Error: $error', error, stack);

    Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: (scope) {
        scope.setTag('error_type', 'platform_error');
      },
    );

    return true; // Indicates error was handled
  }

  /// Handle async zone errors
  void _handleZoneError(Object error, StackTrace stack) {
    _logger.e('Zone Error: $error', error, stack);

    Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: (scope) {
        scope.setTag('error_type', 'zone_error');
      },
    );
  }

  /// Manually capture an error with context
  static Future<void> captureError(
    dynamic error, {
    StackTrace? stackTrace,
    String? context,
    Map<String, dynamic>? data,
    String? userAction,
  }) async {
    instance._logger.e('Manual Error Capture: $error', error, stackTrace);

    await Sentry.captureException(
      error,
      stackTrace: stackTrace,
      withScope: (scope) {
        scope.setTag('error_type', 'manual_capture');
        if (context != null) scope.setExtra('context_description', context);
        if (userAction != null) scope.setTag('user_action', userAction);
        if (data != null) {
          data.forEach((key, value) {
            scope.setExtra(key, value);
          });
        }
      },
    );
  }

  /// Capture connection-specific errors
  static Future<void> captureConnectionError(
    dynamic error, {
    StackTrace? stackTrace,
    String? sessionId,
    String? contactId,
    String? connectionPhase,
    String? peerRole,
  }) async {
    instance._logger.e('Connection Error: $error', error, stackTrace);

    await Sentry.captureException(
      error,
      stackTrace: stackTrace,
      withScope: (scope) {
        scope.setTag('error_type', 'connection_error');
        scope.setTag('connection_phase', connectionPhase ?? 'unknown');
        scope.setTag('peer_role', peerRole ?? 'unknown');

        scope.setExtra('session_id', sessionId);
        scope.setExtra('contact_id', contactId);
        scope.setExtra('phase', connectionPhase);
        scope.setExtra('role', peerRole);
      },
    );
  }

  /// Show user-friendly error message
  static void showUserError(BuildContext context, String message) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  /// Show connection status to user
  static void showConnectionStatus(BuildContext context, String message,
      {bool isError = false}) {
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: isError ? Colors.red.shade600 : Colors.blue.shade600,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }

  /// Log info with optional Sentry breadcrumb
  static void logInfo(String message, {Map<String, dynamic>? data}) {
    instance._logger.i(message);

    Sentry.addBreadcrumb(Breadcrumb(
      message: message,
      level: SentryLevel.info,
      data: data,
    ));
  }

  /// Log debug information
  static void logDebug(String message, {Map<String, dynamic>? data}) {
    instance._logger.d(message);

    if (kDebugMode) {
      Sentry.addBreadcrumb(Breadcrumb(
        message: message,
        level: SentryLevel.debug,
        data: data,
      ));
    }
  }

  /// Log warning
  static void logWarning(String message, {Map<String, dynamic>? data}) {
    instance._logger.w(message);

    Sentry.addBreadcrumb(Breadcrumb(
      message: message,
      level: SentryLevel.warning,
      data: data,
    ));
  }

  /// Log error
  static void logError(String message, {Map<String, dynamic>? data}) {
    instance._logger.e(message);

    Sentry.addBreadcrumb(Breadcrumb(
      message: message,
      level: SentryLevel.error,
      data: data,
    ));
  }
}
