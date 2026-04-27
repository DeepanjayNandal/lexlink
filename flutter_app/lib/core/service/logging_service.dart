// lib/core/service/logging_service.dart

import 'dart:async';
import 'package:logger/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Enhanced logger for debugging connection issues
class WebRTCLogLevel {
  static const int verbose = 0;
  static const int debug = 1;
  static const int info = 2;
  static const int warning = 3;
  static const int error = 4;
  static const int nothing = 5;
}

/// Global logging service for the entire app
class LoggingService {
  static final LoggingService _instance = LoggingService._internal();
  static LoggingService get instance => _instance;

  Logger _logger = Logger();
  int _logLevel = WebRTCLogLevel.info;
  bool _logToFile = false;
  String _logFilePath = '';
  final Map<String, OperationLogger> _operationLoggers = {};
  final StreamController<LogEntry> _logStreamController =
      StreamController<LogEntry>.broadcast();

  // In-memory log retention
  static const int _maxMemoryLogEntries = 1000; // Keep only the latest entries
  final List<LogEntry> _memoryLogs = [];

  Stream<LogEntry> get onLogEntry => _logStreamController.stream;

  LoggingService._internal() {
    _initLogger();
  }

  Future<void> _initLogger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _logLevel = WebRTCLogLevel.debug; // Force debug level for development
      _logToFile = prefs.getBool('log_to_file') ??
          true; // Enable file logging by default

      if (_logToFile) {
        await _setupLogFile();
        // Clean up old log files
        _cleanupOldLogFiles();
      }

      _logger = Logger(
        printer: PrettyPrinter(
            methodCount: 2,
            errorMethodCount: 8,
            lineLength: 120,
            colors: !kIsWeb, // Disable colors for web
            printEmojis: true,
            printTime: true),
        level: _mapLogLevel(_logLevel),
      );

      debugPrint(
          'LoggingService initialized with level: $_logLevel, logToFile: $_logToFile');
    } catch (e) {
      debugPrint('Error initializing LoggingService: $e');
      // Default fallback logger
      _logger = Logger();
    }
  }

  Level _mapLogLevel(int level) {
    switch (level) {
      case WebRTCLogLevel.verbose:
        return Level.verbose;
      case WebRTCLogLevel.debug:
        return Level.debug;
      case WebRTCLogLevel.info:
        return Level.info;
      case WebRTCLogLevel.warning:
        return Level.warning;
      case WebRTCLogLevel.error:
        return Level.error;
      case WebRTCLogLevel.nothing:
        return Level.nothing;
      default:
        return Level.info;
    }
  }

  Future<void> setLogLevel(int level) async {
    _logLevel = level;
    await _saveSettings();
    await _initLogger();
  }

  Future<void> enableFileLogging(bool enable) async {
    _logToFile = enable;
    await _saveSettings();

    if (_logToFile) {
      await _setupLogFile();
      _cleanupOldLogFiles();
    }
  }

  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('log_level', _logLevel);
      await prefs.setBool('log_to_file', _logToFile);
    } catch (e) {
      debugPrint('Error saving logging settings: $e');
    }
  }

  Future<void> _setupLogFile() async {
    try {
      if (kIsWeb) return; // Skip file logging on web

      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _logFilePath = '${dir.path}/lexlink_logs_$timestamp.log';

      // Create the file
      File(_logFilePath).createSync();
      debugPrint('Log file created at: $_logFilePath');
    } catch (e) {
      debugPrint('Error setting up log file: $e');
      _logToFile = false;
    }
  }

  // Remove old log files, keeping only the 5 most recent ones
  Future<void> _cleanupOldLogFiles() async {
    if (kIsWeb) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = dir
          .listSync()
          .where(
              (file) => file is File && file.path.contains('lexlink_logs_'))
          .toList();

      // Sort files by creation time, newest first
      files.sort((a, b) => File(b.path)
          .lastModifiedSync()
          .compareTo(File(a.path).lastModifiedSync()));

      // Delete all but the 5 most recent log files
      if (files.length > 5) {
        for (int i = 5; i < files.length; i++) {
          try {
            File(files[i].path).deleteSync();
            debugPrint('Deleted old log file: ${files[i].path}');
          } catch (e) {
            debugPrint('Failed to delete old log file: ${files[i].path}');
          }
        }
      }
    } catch (e) {
      debugPrint('Error cleaning up old log files: $e');
    }
  }

  void _writeToLogFile(LogEntry entry) {
    if (!_logToFile || _logFilePath.isEmpty || kIsWeb) return;

    try {
      final file = File(_logFilePath);
      final logLine =
          '${entry.timestamp.toIso8601String()} [${entry.level}] ${entry.message}\n';
      file.writeAsStringSync(logLine, mode: FileMode.append);
    } catch (e) {
      debugPrint('Error writing to log file: $e');
    }
  }

  /// Get an operation logger for tracking a specific flow
  OperationLogger getOperationLogger(String category, {String? operationId}) {
    final opId = operationId ?? const Uuid().v4();
    final logger = OperationLogger(this, category, opId);
    _operationLoggers[opId] = logger;
    return logger;
  }

  /// Basic logging methods
  void verbose(String message, {String? category, String? operationId}) {
    _log(WebRTCLogLevel.verbose, message, category, operationId);
  }

  void debug(String message, {String? category, String? operationId}) {
    _log(WebRTCLogLevel.debug, message, category, operationId);
  }

  void info(String message, {String? category, String? operationId}) {
    _log(WebRTCLogLevel.info, message, category, operationId);
  }

  void warn(String message,
      {String? category, String? operationId, dynamic error}) {
    _log(WebRTCLogLevel.warning, message, category, operationId, error);
  }

  void error(String message,
      {String? category,
      String? operationId,
      dynamic error,
      StackTrace? stackTrace}) {
    _log(WebRTCLogLevel.error, message, category, operationId, error,
        stackTrace);
  }

  void _log(int level, String message, String? category, String? operationId,
      [dynamic error, StackTrace? stackTrace]) {
    if (level < _logLevel) return;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: _levelToString(level),
      message: message,
      category: category,
      operationId: operationId,
      error: error,
      stackTrace: stackTrace,
    );

    // Store in memory logs with limit
    _memoryLogs.add(entry);
    if (_memoryLogs.length > _maxMemoryLogEntries) {
      _memoryLogs.removeAt(0); // Remove oldest log
    }

    // Log using the native logger
    switch (level) {
      case WebRTCLogLevel.verbose:
        _logger.v(message, error, stackTrace);
        break;
      case WebRTCLogLevel.debug:
        _logger.d(message, error, stackTrace);
        break;
      case WebRTCLogLevel.info:
        _logger.i(message, error, stackTrace);
        break;
      case WebRTCLogLevel.warning:
        _logger.w(message, error, stackTrace);
        break;
      case WebRTCLogLevel.error:
        _logger.e(message, error, stackTrace);
        break;
    }

    // Send to stream for listeners
    _logStreamController.add(entry);

    // Write to file if enabled
    if (_logToFile) {
      _writeToLogFile(entry);
    }
  }

  String _levelToString(int level) {
    switch (level) {
      case WebRTCLogLevel.verbose:
        return 'VERBOSE';
      case WebRTCLogLevel.debug:
        return 'DEBUG';
      case WebRTCLogLevel.info:
        return 'INFO';
      case WebRTCLogLevel.warning:
        return 'WARNING';
      case WebRTCLogLevel.error:
        return 'ERROR';
      default:
        return 'UNKNOWN';
    }
  }

  // Get recent in-memory logs
  List<LogEntry> getRecentLogs() {
    return List<LogEntry>.from(_memoryLogs);
  }

  // Get QR code logs specifically
  List<LogEntry> getQrCodeLogs() {
    return _memoryLogs
        .where((log) =>
            log.message.contains('QR string') ||
            log.message.contains('copyqrstring'))
        .toList();
  }

  /// Export logs to a file that can be shared
  Future<String?> exportLogs() async {
    if (kIsWeb) return null;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final exportPath = '${dir.path}/lexlink_logs_export_$timestamp.log';

      // If logging to file is enabled, just copy that file
      if (_logToFile && _logFilePath.isNotEmpty) {
        final srcFile = File(_logFilePath);
        if (await srcFile.exists()) {
          await srcFile.copy(exportPath);
          return exportPath;
        }
      }

      // Otherwise create a new file with current session logs
      final exportFile = File(exportPath);
      await exportFile.create();

      // Write the in-memory logs to the file
      final buffer = StringBuffer();
      for (final entry in _memoryLogs) {
        buffer.writeln(
            '${entry.timestamp.toIso8601String()} [${entry.level}] ${entry.message}');
      }
      await exportFile.writeAsString(buffer.toString());

      return exportPath;
    } catch (e) {
      debug('Error exporting logs: $e');
      return null;
    }
  }

  void dispose() {
    if (!_logStreamController.isClosed) {
      _logStreamController.close();
    }
  }
}

/// Logger for tracking a specific operation flow
class OperationLogger {
  final LoggingService _loggingService;
  final String _category;
  final String _operationId;
  final Stopwatch _stopwatch = Stopwatch()..start();
  final Map<String, DateTime> _phaseTimestamps = {};

  OperationLogger(this._loggingService, this._category, this._operationId);

  String get operationId => _operationId;

  /// Begin tracking a phase of the operation
  void startPhase(String phase) {
    _phaseTimestamps[phase] = DateTime.now();
    info('🔄 PHASE START: $phase');
  }

  /// End tracking a phase and report duration
  void endPhase(String phase) {
    if (_phaseTimestamps.containsKey(phase)) {
      final duration = DateTime.now().difference(_phaseTimestamps[phase]!);
      info('✅ PHASE END: $phase - Duration: ${duration.inMilliseconds}ms');
    } else {
      warn('❗ PHASE END: $phase - No start timestamp found');
    }
  }

  /// Log connection details using icons
  void connectionLog(String message, {bool isStateChange = false}) {
    final icon = isStateChange ? '🔄' : '🔌';
    info('$icon $message');
  }

  /// Log signaling details using icons
  void signalLog(String message, {String? type}) {
    final icon = type == 'offer'
        ? '📤'
        : type == 'answer'
            ? '📥'
            : '📡';
    info('$icon $message');
  }

  /// Log ICE candidate details
  void iceLog(String message, {bool filtered = false}) {
    final icon = filtered ? '🛑' : '🧊';
    debug('$icon $message');
  }

  /// Log messaging details
  void messageLog(String message) {
    info('📨 $message');
  }

  // Basic logging methods that include the operation ID
  void verbose(String message) {
    _loggingService.verbose(message,
        category: _category, operationId: _operationId);
  }

  void debug(String message) {
    _loggingService.debug(message,
        category: _category, operationId: _operationId);
  }

  void info(String message) {
    _loggingService.info(message,
        category: _category, operationId: _operationId);
  }

  void warn(String message, {dynamic error}) {
    _loggingService.warn(message,
        category: _category, operationId: _operationId, error: error);
  }

  void error(String message, {dynamic error, StackTrace? stackTrace}) {
    _loggingService.error(message,
        category: _category,
        operationId: _operationId,
        error: error,
        stackTrace: stackTrace);
  }
}

/// Structure for log entries
class LogEntry {
  final DateTime timestamp;
  final String level;
  final String message;
  final String? category;
  final String? operationId;
  final dynamic error;
  final StackTrace? stackTrace;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.category,
    this.operationId,
    this.error,
    this.stackTrace,
  });
}
