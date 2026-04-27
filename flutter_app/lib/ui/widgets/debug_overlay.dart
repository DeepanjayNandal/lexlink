import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/service/logging_service.dart';
import 'package:flutter/services.dart';
import '../theme/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';

/// A debug panel that can be shown in debug mode to view logs and control debugging
class DebugOverlay extends StatefulWidget {
  final Widget child;
  final bool isEnabled;

  const DebugOverlay({
    Key? key,
    required this.child,
    this.isEnabled = false,
  }) : super(key: key);

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  bool _isVisible = false;
  bool _showConnectionLogs = true;
  bool _showSignalingLogs = true;
  bool _showIceLogs = false;
  bool _showDebugLogs = false;
  final List<LogEntry> _logEntries = [];
  late StreamSubscription<LogEntry> _logSubscription;
  int _logLevel = 2; // Default to INFO
  bool _logToFile = false;
  bool _autoScroll = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadPreferences();

    // Listen for log entries
    _logSubscription = LoggingService.instance.onLogEntry.listen((entry) {
      setState(() {
        _logEntries.add(entry);
        // Limit to last 500 logs
        if (_logEntries.length > 500) {
          _logEntries.removeAt(0);
        }
      });

      // Auto-scroll to bottom if already at bottom
      if (_scrollController.hasClients &&
          _scrollController.offset >=
              _scrollController.position.maxScrollExtent - 50) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    // Add existing logs if available
    try {
      final existingLogs = LoggingService.instance.getRecentLogs();
      if (existingLogs.isNotEmpty) {
        setState(() {
          _logEntries.addAll(existingLogs);
          if (_logEntries.length > 500) {
            _logEntries.removeRange(0, _logEntries.length - 500);
          }
        });
      }
    } catch (_) {
      // Ignore if the method isn't available
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _isVisible = prefs.getBool('debug_overlay_visible') ?? false;
        _showConnectionLogs = prefs.getBool('show_connection_logs') ?? true;
        _showSignalingLogs = prefs.getBool('show_signaling_logs') ?? true;
        _showIceLogs = prefs.getBool('show_ice_logs') ?? false;
        _showDebugLogs = prefs.getBool('show_debug_logs') ?? false;
        _logLevel = prefs.getInt('log_level') ?? WebRTCLogLevel.info;
        _logToFile = prefs.getBool('log_to_file') ?? false;
      });
    } catch (e) {
      debugPrint('Error loading debug preferences: $e');
    }
  }

  Future<void> _savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('debug_overlay_visible', _isVisible);
      await prefs.setBool('show_connection_logs', _showConnectionLogs);
      await prefs.setBool('show_signaling_logs', _showSignalingLogs);
      await prefs.setBool('show_ice_logs', _showIceLogs);
      await prefs.setBool('show_debug_logs', _showDebugLogs);
    } catch (e) {
      debugPrint('Error saving debug preferences: $e');
    }
  }

  void _addLogEntry(LogEntry entry) {
    if (!mounted) return;

    // Apply filters
    if (!_showDebugLogs && entry.level == 'DEBUG') {
      return;
    }

    // Apply category filters
    final category = entry.category?.toLowerCase() ?? '';
    if (!_showConnectionLogs && category.contains('conn')) {
      return;
    }
    if (!_showSignalingLogs && category.contains('signal')) {
      return;
    }
    if (!_showIceLogs && category.contains('ice')) {
      return;
    }

    setState(() {
      _logEntries.add(entry);
      // Limit to last 500 logs
      if (_logEntries.length > 500) {
        _logEntries.removeAt(0);
      }
    });

    // Auto-scroll to the bottom
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _shareLogs() async {
    try {
      final logFilePath = await LoggingService.instance.exportLogs();
      if (logFilePath != null) {
        // When share_plus is available, you would use:
        // await Share.shareXFiles([XFile(logFilePath)], text: 'LexLink Debug Logs');

        // Instead, we'll use a clipboard fallback
        final file = File(logFilePath);
        if (await file.exists()) {
          final content = await file.readAsString();
          await Clipboard.setData(ClipboardData(text: content));
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Log file copied to clipboard')));
        }
      } else {
        // If no log file, share as text
        final allLogs = _logEntries.map((entry) {
          return '${entry.timestamp.toIso8601String()} [${entry.level}] ${entry.message}';
        }).join('\n');

        // When share_plus is available, you would use:
        // await Share.share(allLogs, subject: 'LexLink Debug Logs');

        // Instead, we'll use clipboard
        await Clipboard.setData(ClipboardData(text: allLogs));
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Logs copied to clipboard')));
      }
    } catch (e) {
      debugPrint('Error sharing logs: $e');
    }
  }

  void _copyAllLogs() {
    final allLogs = _logEntries.map((entry) {
      return '${entry.timestamp.toIso8601String()} [${entry.level}] ${entry.message}';
    }).join('\n');

    Clipboard.setData(ClipboardData(text: allLogs));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs copied to clipboard')));
  }

  void _clearLogs() {
    setState(() {
      _logEntries.clear();
    });
  }

  void _setLogLevel(int level) async {
    await LoggingService.instance.setLogLevel(level);
    setState(() {
      _logLevel = level;
    });
  }

  void _toggleLogToFile(bool value) async {
    await LoggingService.instance.enableFileLogging(value);
    setState(() {
      _logToFile = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isEnabled) {
      return widget.child;
    }

    final themeProvider = Provider.of<ThemeProvider>(context);

    return Stack(
      children: [
        widget.child,

        // Debug toggle button (always visible)
        Positioned(
          bottom: 100,
          right: 10,
          child: FloatingActionButton.small(
            heroTag: 'debugFab',
            backgroundColor: _isVisible
                ? Colors.red.withOpacity(0.7)
                : Colors.grey.withOpacity(0.5),
            child:
                Icon(_isVisible ? Icons.bug_report : Icons.bug_report_outlined),
            onPressed: () {
              setState(() {
                _isVisible = !_isVisible;
                _savePreferences();
              });
            },
          ),
        ),

        // Debug overlay (visible when toggled)
        if (_isVisible)
          Positioned.fill(
            child: Material(
              color: Colors.transparent,
              child: Container(
                color: themeProvider.isDarkMode
                    ? Colors.black.withOpacity(0.85)
                    : Colors.white.withOpacity(0.85),
                child: Column(
                  children: [
                    // Header with controls
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 40, 16, 8),
                      decoration: BoxDecoration(
                        color: themeProvider.isDarkMode
                            ? Colors.grey.shade900
                            : Colors.grey.shade200,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Debug Console',
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.copy),
                                    tooltip: 'Copy Logs',
                                    onPressed: _copyAllLogs,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.share),
                                    tooltip: 'Share Logs',
                                    onPressed: _shareLogs,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.clear_all),
                                    tooltip: 'Clear Logs',
                                    onPressed: _clearLogs,
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close),
                                    tooltip: 'Close Debug Console',
                                    onPressed: () {
                                      setState(() {
                                        _isVisible = false;
                                        _savePreferences();
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('Connection'),
                                selected: _showConnectionLogs,
                                onSelected: (selected) {
                                  setState(() {
                                    _showConnectionLogs = selected;
                                    _savePreferences();
                                  });
                                },
                              ),
                              FilterChip(
                                label: const Text('Signaling'),
                                selected: _showSignalingLogs,
                                onSelected: (selected) {
                                  setState(() {
                                    _showSignalingLogs = selected;
                                    _savePreferences();
                                  });
                                },
                              ),
                              FilterChip(
                                label: const Text('ICE'),
                                selected: _showIceLogs,
                                onSelected: (selected) {
                                  setState(() {
                                    _showIceLogs = selected;
                                    _savePreferences();
                                  });
                                },
                              ),
                              FilterChip(
                                label: const Text('Debug'),
                                selected: _showDebugLogs,
                                onSelected: (selected) {
                                  setState(() {
                                    _showDebugLogs = selected;
                                    _savePreferences();
                                  });
                                },
                              ),
                              FilterChip(
                                label: const Text('Auto-scroll'),
                                selected: _autoScroll,
                                onSelected: (selected) {
                                  setState(() {
                                    _autoScroll = selected;
                                  });
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Text('Log Level: ', style: GoogleFonts.inter()),
                              DropdownButton<int>(
                                value: _logLevel,
                                items: [
                                  DropdownMenuItem(
                                      value: WebRTCLogLevel.verbose,
                                      child: Text('Verbose',
                                          style: GoogleFonts.inter())),
                                  DropdownMenuItem(
                                      value: WebRTCLogLevel.debug,
                                      child: Text('Debug',
                                          style: GoogleFonts.inter())),
                                  DropdownMenuItem(
                                      value: WebRTCLogLevel.info,
                                      child: Text('Info',
                                          style: GoogleFonts.inter())),
                                  DropdownMenuItem(
                                      value: WebRTCLogLevel.warning,
                                      child: Text('Warning',
                                          style: GoogleFonts.inter())),
                                  DropdownMenuItem(
                                      value: WebRTCLogLevel.error,
                                      child: Text('Error',
                                          style: GoogleFonts.inter())),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    _setLogLevel(value);
                                  }
                                },
                              ),
                              const SizedBox(width: 16),
                              Row(
                                children: [
                                  Text('Log to file: ',
                                      style: GoogleFonts.inter()),
                                  Switch(
                                    value: _logToFile,
                                    onChanged: _toggleLogToFile,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Logs area
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Dedicated section for QR code logs
                          Builder(
                            builder: (context) {
                              List<LogEntry> qrLogs = [];
                              try {
                                qrLogs =
                                    LoggingService.instance.getQrCodeLogs();
                              } catch (_) {
                                // Fall back to filtering local logs
                                qrLogs = _logEntries
                                    .where((entry) =>
                                        entry.message
                                            .contains('[copyqrstring]') ||
                                        entry.message.contains('QR string'))
                                    .toList();
                              }

                              if (qrLogs.isEmpty) {
                                return const SizedBox
                                    .shrink(); // Don't show section if no QR logs
                              }

                              return Container(
                                decoration: BoxDecoration(
                                  color: Colors.amber.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.qr_code, size: 16),
                                        const SizedBox(width: 4),
                                        Text('QR CODES',
                                            style: GoogleFonts.inter(
                                              fontWeight: FontWeight.bold,
                                            )),
                                        Spacer(),
                                        IconButton(
                                          padding: EdgeInsets.zero,
                                          constraints: BoxConstraints(),
                                          iconSize: 16,
                                          icon: Icon(Icons.copy),
                                          onPressed: () {
                                            final qrStrings = qrLogs
                                                .map((entry) => entry.message
                                                    .replaceAll(
                                                        '[copyqrstring] ', '')
                                                    .replaceAll(
                                                        'djay QR string to paste in receiver: ',
                                                        'QR string: '))
                                                .toList();

                                            Clipboard.setData(ClipboardData(
                                                text: qrStrings.join('\n')));
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(const SnackBar(
                                                    content: Text(
                                                        'QR codes copied to clipboard')));
                                          },
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    // Display QR code logs
                                    ...qrLogs.map((entry) => Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 2),
                                          child: Text(
                                            entry.message
                                                .replaceAll(
                                                    '[copyqrstring] ', '')
                                                .replaceAll(
                                                    'djay QR string to paste in receiver: ',
                                                    'QR string: '),
                                            style: GoogleFonts.robotoMono(
                                                fontSize: 12),
                                          ),
                                        )),
                                  ],
                                ),
                              );
                            },
                          ),

                          // All logs section header
                          Row(
                            children: [
                              Text('LOGS',
                                  style: GoogleFonts.inter(
                                    fontWeight: FontWeight.bold,
                                  )),
                              Spacer(),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: BoxConstraints(),
                                iconSize: 16,
                                icon: Icon(Icons.clear_all),
                                onPressed: _clearLogs,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // All logs
                          Expanded(
                            child: ListView.builder(
                              controller: _scrollController,
                              itemCount: _logEntries.length,
                              itemBuilder: (context, index) {
                                final entry = _logEntries[index];
                                return LogEntryWidget(entry: entry);
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _logSubscription.cancel();
    _scrollController.dispose();
    super.dispose();
  }
}

/// Widget to display a log entry with appropriate styling
class LogEntryWidget extends StatelessWidget {
  final LogEntry entry;

  const LogEntryWidget({
    Key? key,
    required this.entry,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    // Get colors based on log level
    Color textColor;
    Color bgColor;
    switch (entry.level) {
      case 'ERROR':
        textColor = Colors.red.shade300;
        bgColor = themeProvider.isDarkMode
            ? Colors.red.shade900.withOpacity(0.3)
            : Colors.red.shade50;
        break;
      case 'WARNING':
        textColor = Colors.orange.shade300;
        bgColor = themeProvider.isDarkMode
            ? Colors.orange.shade900.withOpacity(0.3)
            : Colors.orange.shade50;
        break;
      case 'INFO':
        textColor = themeProvider.isDarkMode
            ? Colors.blue.shade300
            : Colors.blue.shade700;
        bgColor = themeProvider.isDarkMode
            ? Colors.blue.shade900.withOpacity(0.2)
            : Colors.blue.shade50;
        break;
      case 'DEBUG':
        textColor = themeProvider.isDarkMode
            ? Colors.grey.shade400
            : Colors.grey.shade700;
        bgColor = themeProvider.isDarkMode
            ? Colors.grey.shade900.withOpacity(0.2)
            : Colors.grey.shade100;
        break;
      default:
        textColor = themeProvider.isDarkMode
            ? Colors.grey.shade300
            : Colors.grey.shade800;
        bgColor = Colors.transparent;
    }

    final time = entry.timestamp.toIso8601String().substring(11, 23);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          bottom: BorderSide(
            color: themeProvider.isDarkMode
                ? Colors.grey.shade900
                : Colors.grey.shade200,
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                time,
                style: GoogleFonts.robotoMono(
                  fontSize: 10,
                  color: themeProvider.isDarkMode
                      ? Colors.grey.shade500
                      : Colors.grey.shade700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: textColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  entry.level,
                  style: GoogleFonts.robotoMono(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ),
              if (entry.category != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.purple.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    entry.category!,
                    style: GoogleFonts.robotoMono(
                      fontSize: 10,
                      color: themeProvider.isDarkMode
                          ? Colors.purple.shade300
                          : Colors.purple.shade700,
                    ),
                  ),
                ),
              ],
              if (entry.operationId != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.teal.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'OP:${entry.operationId!.substring(0, min(entry.operationId!.length, 6))}',
                    style: GoogleFonts.robotoMono(
                      fontSize: 10,
                      color: themeProvider.isDarkMode
                          ? Colors.teal.shade300
                          : Colors.teal.shade700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            entry.message,
            style: GoogleFonts.robotoMono(
              fontSize: 12,
              color: textColor,
            ),
          ),
          if (entry.error != null) ...[
            const SizedBox(height: 2),
            Text(
              'Error: ${entry.error}',
              style: GoogleFonts.robotoMono(
                fontSize: 12,
                color: Colors.red,
              ),
            ),
          ],
        ],
      ),
    );
  }

  int min(int a, int b) => a < b ? a : b;
}
