import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../ui/screens/debug_overlay.dart';

/// Configuration class for signaling services
///
/// This class centralizes all configuration options for signaling services,
/// making it easy to switch between different environments or configurations.
class SignalingConfig {
  /// The URL of the signaling server
  final String serverUrl;

  /// Interval for sending heartbeat messages to keep the connection alive
  final Duration heartbeatInterval;

  /// Timeout for connection attempts
  final Duration connectionTimeout;

  /// Maximum number of reconnection attempts
  final int maxReconnectAttempts;

  /// Whether to log detailed signaling messages (excluding PII)
  final bool verboseLogging;

  /// Whether to use secure WebSocket (wss://) for production
  final bool useSecureWebSocket;

  /// Backup server URLs to try if primary fails
  final List<String> fallbackServerUrls;

  /// Default server URL
  final String defaultServerUrl;

  /// Host IP address for direct connections (used for real devices)
  final String hostIp;

  /// Constructor with named parameters and default values
  const SignalingConfig({
    required this.serverUrl,
    this.heartbeatInterval = const Duration(seconds: 15),
    this.connectionTimeout = const Duration(seconds: 10),
    this.maxReconnectAttempts = 3,
    this.verboseLogging = kDebugMode,
    this.useSecureWebSocket = false,
    this.fallbackServerUrls = const [],
    required this.defaultServerUrl,
    required this.hostIp,
  });

  /// Factory method for development environment
  factory SignalingConfig.development() {
    // Check if running in simulator
    bool isSimulator = !kIsWeb &&
        ((Platform.isIOS || Platform.isAndroid) &&
            !DebugOverlay.isPhysicalDevice);

    // Log environment detection
    print('🔧 CONFIG: Creating development config');
    print(
        '🔧 CONFIG: Running in ${isSimulator ? 'simulator' : 'physical device'}');

    return SignalingConfig(
      // Use localhost for simulators, IP for real devices
      serverUrl:
          isSimulator ? 'ws://localhost:9090/ws' : 'ws://192.168.1.6:9090/ws',
      heartbeatInterval: const Duration(seconds: 5),
      connectionTimeout: const Duration(seconds: 10),
      maxReconnectAttempts: 5,
      verboseLogging: true,
      useSecureWebSocket: false,
      fallbackServerUrls: ['ws://localhost:9090/ws', 'ws://127.0.0.1:9090/ws'],
      defaultServerUrl:
          isSimulator ? 'ws://localhost:9090/ws' : 'ws://192.168.1.6:9090/ws',
      hostIp: '192.168.1.6', // Default development IP
    );
  }

  /// Factory method for local testing with a specific IP
  factory SignalingConfig.localNetwork() {
    // Check if running in simulator
    bool isSimulator = !kIsWeb &&
        ((Platform.isIOS || Platform.isAndroid) &&
            !DebugOverlay.isPhysicalDevice);

    // Log environment detection
    print('🔧 CONFIG: Creating local network config');
    print(
        '🔧 CONFIG: Running in ${isSimulator ? 'simulator' : 'physical device'}');

    return SignalingConfig(
      // Use localhost for simulators, IP for real devices
      serverUrl:
          isSimulator ? 'ws://localhost:9090/ws' : 'ws://192.168.1.6:9090/ws',
      heartbeatInterval: const Duration(
          seconds: 3), // More frequent heartbeats to prevent disconnection
      connectionTimeout: const Duration(seconds: 10),
      maxReconnectAttempts: 5,
      verboseLogging: true,
      useSecureWebSocket: false,
      fallbackServerUrls: ['ws://localhost:9090/ws', 'ws://127.0.0.1:9090/ws'],
      defaultServerUrl:
          isSimulator ? 'ws://localhost:9090/ws' : 'ws://192.168.1.6:9090/ws',
      hostIp: '192.168.1.6', // Default local network IP
    );
  }

  /// Factory method for production environment
  factory SignalingConfig.production() {
    return const SignalingConfig(
      serverUrl: 'wss://signaling.lexlink.app/ws',
      heartbeatInterval: Duration(seconds: 15),
      connectionTimeout: Duration(seconds: 15),
      maxReconnectAttempts: 3,
      verboseLogging: false,
      useSecureWebSocket: true,
      fallbackServerUrls: ['wss://backup-signaling.lexlink.app/ws'],
      defaultServerUrl: 'wss://signaling.lexlink.app/ws',
      hostIp: 'signaling.lexlink.app',
    );
  }

  /// Create a copy of this config with some fields replaced
  SignalingConfig copyWith({
    String? serverUrl,
    Duration? heartbeatInterval,
    Duration? connectionTimeout,
    int? maxReconnectAttempts,
    bool? verboseLogging,
    bool? useSecureWebSocket,
    List<String>? fallbackServerUrls,
    String? defaultServerUrl,
    String? hostIp,
  }) {
    return SignalingConfig(
      serverUrl: serverUrl ?? this.serverUrl,
      heartbeatInterval: heartbeatInterval ?? this.heartbeatInterval,
      connectionTimeout: connectionTimeout ?? this.connectionTimeout,
      maxReconnectAttempts: maxReconnectAttempts ?? this.maxReconnectAttempts,
      verboseLogging: verboseLogging ?? this.verboseLogging,
      useSecureWebSocket: useSecureWebSocket ?? this.useSecureWebSocket,
      fallbackServerUrls: fallbackServerUrls ?? this.fallbackServerUrls,
      defaultServerUrl: defaultServerUrl ?? this.defaultServerUrl,
      hostIp: hostIp ?? this.hostIp,
    );
  }
}
