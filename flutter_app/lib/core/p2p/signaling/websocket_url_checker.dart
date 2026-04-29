import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../../ui/screens/debug_overlay.dart';

/// Utility class to check and log WebSocket URLs
class WebSocketUrlChecker {
  /// Singleton instance
  static final WebSocketUrlChecker _instance = WebSocketUrlChecker._internal();
  factory WebSocketUrlChecker() => _instance;
  WebSocketUrlChecker._internal();

  /// Environment detection flags
  bool get _isSimulator =>
      !kIsWeb &&
      ((Platform.isIOS || Platform.isAndroid) &&
          !DebugOverlay.isPhysicalDevice);

  /// Get the appropriate WebSocket base URL based on runtime environment
  /// This is the centralized function for all WebSocket URL resolution
  String getWebSocketUrl({String? hostIp, String? sessionToken}) {
    // Determine the base URL based on environment
    String baseUrl;

    // COMPREHENSIVE DEBUGGING FOR DEVICE DETECTION
    print('🔍 BERU-DEVICE-DEBUG: Starting device detection');
    print('🔍 BERU-DEVICE-DEBUG: kIsWeb = $kIsWeb');
    print('🔍 BERU-DEVICE-DEBUG: Platform.isIOS = ${Platform.isIOS}');
    print('🔍 BERU-DEVICE-DEBUG: Platform.isAndroid = ${Platform.isAndroid}');
    print(
        '🔍 BERU-DEVICE-DEBUG: DebugOverlay.isPhysicalDevice = ${DebugOverlay.isPhysicalDevice}');
    print('🔍 BERU-DEVICE-DEBUG: _isSimulator calculated = $_isSimulator');
    print(
        '🔍 BERU-DEVICE-DEBUG: Platform.operatingSystemVersion = ${Platform.operatingSystemVersion}');

    if (_isSimulator) {
      // TEMPORARY FIX: Force IP address even for simulators
      baseUrl = 'ws://192.168.1.6:9090';
      print(
          '🔍 ENVIRONMENT: Running in simulator, FORCING IP ADDRESS: 192.168.1.6');
    } else {
      // Use configured host IP for real devices
      // FORCE IP address instead of falling back to localhost
      baseUrl = 'ws://192.168.1.6:9090';
      print(
          '🔍 ENVIRONMENT: Running on physical device, using IP: 192.168.1.6');
    }

    // Ensure the /ws path is included, but only if we're not appending a session token
    // that already includes the path
    if (!baseUrl.endsWith('/ws') &&
        (sessionToken == null || !sessionToken.startsWith('/ws'))) {
      baseUrl = '$baseUrl/ws';
    }

    // Append session token if provided, but ensure we don't duplicate the /ws path
    if (sessionToken != null && sessionToken.isNotEmpty) {
      // If the sessionToken already starts with /ws, don't duplicate it
      if (sessionToken.startsWith('/ws')) {
        // Replace the /ws in baseUrl with the sessionToken (which includes /ws)
        if (baseUrl.endsWith('/ws')) {
          baseUrl = baseUrl.substring(0, baseUrl.length - 3) + sessionToken;
        } else {
          baseUrl = baseUrl + sessionToken;
        }
      } else {
        // Normal case, just append the token
        baseUrl = '$baseUrl/$sessionToken';
      }
    }

    print('✅ WEBSOCKET URL RESOLVED: $baseUrl');
    print(
        '🔍 BERU-URL-DEBUG: Final URL protocol check: ${baseUrl.startsWith('ws://') ? 'CORRECT (ws://)' : 'WRONG PROTOCOL!'}');

    // CRITICAL: Ensure the URL always uses ws:// protocol
    if (baseUrl.startsWith('http://')) {
      baseUrl = baseUrl.replaceFirst('http://', 'ws://');
      print('🔧 BERU-URL-FIX: Corrected HTTP to WS protocol: $baseUrl');
    }

    return baseUrl;
  }

  /// Check and normalize WebSocket URL
  /// This maintains backward compatibility with existing code
  String normalizeUrl(String url) {
    print('🔍 WEBSOCKET URL CHECK: Original URL: $url');

    // If this is a relative URL or just a session token, build the full URL
    if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      return getWebSocketUrl(sessionToken: url);
    }

    String normalizedUrl = url;

    // Handle simulator environment - replace IP addresses with localhost
    if (_isSimulator && (url.contains('192.168.') || url.contains('10.0.'))) {
      normalizedUrl = url.replaceAll(
          RegExp(r'ws://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'), 'ws://localhost');
      print('🔄 SIMULATOR REDIRECT: $url -> $normalizedUrl');
    }

    // Check if the URL is using the old port
    if (normalizedUrl.contains(':8080')) {
      normalizedUrl = normalizedUrl.replaceAll(':8080', ':9090/ws');
      print('🔄 WEBSOCKET URL REDIRECT: $url -> $normalizedUrl');
    }
    // Check if the URL is missing the /ws path
    else if (!normalizedUrl.contains('/ws') &&
        normalizedUrl.contains(':9090')) {
      normalizedUrl = '$normalizedUrl/ws';
      print('🔄 WEBSOCKET URL REDIRECT: $url -> $normalizedUrl');
    }
    // Check if URL is using neither port 9090 nor path /ws
    else if (!normalizedUrl.contains(':9090') &&
        !normalizedUrl.contains('/ws')) {
      try {
        final uri = Uri.parse(normalizedUrl);
        final host = uri.host;
        normalizedUrl = 'ws://$host:9090/ws';
        print('🔄 WEBSOCKET URL REDIRECT: $url -> $normalizedUrl');
      } catch (e) {
        print('⚠️ WEBSOCKET URL ERROR: Could not parse URL: $url');
      }
    }

    // Fix double /ws//ws issue by replacing with single /ws
    if (normalizedUrl.contains('/ws//ws')) {
      normalizedUrl = normalizedUrl.replaceAll('/ws//ws', '/ws');
      print('🔄 WEBSOCKET PATH FIX: Removed duplicate /ws path');
    }

    // Log the final URL
    print('✅ WEBSOCKET URL FINAL: $normalizedUrl');
    return normalizedUrl;
  }
}
