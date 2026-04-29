import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/service/logging_service.dart';
import '../../core/p2p/signaling/websocket_url_checker.dart';

/// Service for diagnosing connection issues with the signaling server
class ConnectionDiagnosticService {
  final LoggingService _logger = LoggingService.instance;
  final Duration _timeout = Duration(seconds: 10);

  /// Singleton instance
  static final ConnectionDiagnosticService _instance =
      ConnectionDiagnosticService._internal();
  factory ConnectionDiagnosticService() => _instance;
  ConnectionDiagnosticService._internal();

  /// Check if the signaling server is reachable via HTTP
  Future<bool> isServerReachable(String serverUrl) async {
    try {
      // Convert WebSocket URL to HTTP URL for health check
      final httpUrl = serverUrl
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://');
      final response = await http.get(Uri.parse(httpUrl)).timeout(_timeout);
      print('🔍 DIAGNOSTIC: HTTP check - Status code: ${response.statusCode}');
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      print('🔍 DIAGNOSTIC: HTTP check failed - ${e.toString()}');
      return false;
    }
  }

  /// Test WebSocket connection to the signaling server
  Future<Map<String, dynamic>> testWebSocketConnection(String serverUrl) async {
    print('🔍 DIAGNOSTIC: Testing WebSocket connection to $serverUrl');
    final result = <String, dynamic>{
      'success': false,
      'connectSuccess': false,
      'registerSuccess': false,
      'welcomeReceived': false,
      'pongReceived': false,
      'error': null,
      'details': <String, dynamic>{},
    };

    WebSocketChannel? channel;
    final completer = Completer<Map<String, dynamic>>();
    Timer? timeoutTimer;

    // Use URL checker to normalize the WebSocket URL
    final urlChecker = WebSocketUrlChecker();
    serverUrl = urlChecker.normalizeUrl(serverUrl);
    result['serverUrl'] = serverUrl;

    try {
      // Set timeout
      timeoutTimer = Timer(_timeout, () {
        if (!completer.isCompleted) {
          print(
              '🔍 DIAGNOSTIC: WebSocket test timed out after ${_timeout.inSeconds} seconds');
          result['error'] = 'Connection test timed out';
          completer.complete(result);
        }
      });

      // Generate a unique test ID
      final testId = 'test-${Uuid().v4().substring(0, 8)}';

      // Connect to WebSocket
      print('🔬 DIAGNOSTIC: Testing connection to $serverUrl');
      channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      result['connectSuccess'] = true;
      print('🔍 DIAGNOSTIC: WebSocket connection established');

      // Listen for messages
      channel.stream.listen(
        (dynamic data) {
          try {
            print('🔍 DIAGNOSTIC: Received: $data');
            final message = jsonDecode(data);

            if (message['type'] == 'welcome') {
              print('🔍 DIAGNOSTIC: Welcome message received');
              result['welcomeReceived'] = true;
              result['details']['welcome'] = message;
            } else if (message['type'] == 'pong') {
              print('🔍 DIAGNOSTIC: Pong message received');
              result['pongReceived'] = true;

              // Complete the test if we've received both welcome and pong
              if (result['welcomeReceived'] == true && !completer.isCompleted) {
                result['success'] = true;
                completer.complete(result);
              }
            } else if (message['type'] == 'error') {
              print(
                  '🔍 DIAGNOSTIC: Error message received: ${message['message']}');
              result['error'] = message['message'];
              result['details']['error'] = message;
            }
          } catch (e) {
            print('🔍 DIAGNOSTIC: Error parsing message: $e');
            result['details']['parseError'] = e.toString();
          }
        },
        onError: (error) {
          print('🔍 DIAGNOSTIC: WebSocket error: $error');
          result['error'] = 'WebSocket error: $error';
          if (!completer.isCompleted) completer.complete(result);
        },
        onDone: () {
          print('🔍 DIAGNOSTIC: WebSocket connection closed');
          if (!completer.isCompleted) {
            result['error'] = 'Connection closed unexpectedly';
            completer.complete(result);
          }
        },
      );

      // Send registration message
      final registerMessage = {
        'type': 'register',
        'peerId': testId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'diagnostic': true,
      };

      print('🔍 DIAGNOSTIC: Sending registration message');
      channel.sink.add(jsonEncode(registerMessage));
      result['registerSuccess'] = true;

      // Send ping message after a short delay
      Timer(Duration(seconds: 1), () {
        if (channel != null && !completer.isCompleted) {
          final pingMessage = {
            'type': 'ping',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'id': testId,
          };
          print('🔍 DIAGNOSTIC: Sending ping message');
          channel.sink.add(jsonEncode(pingMessage));
        }
      });

      // Wait for result
      return result;
    } catch (e) {
      print('🔍 DIAGNOSTIC: Exception during WebSocket test: $e');
      result['error'] = e.toString();
      return result;
    } finally {
      channel?.sink.close();
    }
  }

  /// Check network connectivity
  Future<bool> checkInternetConnectivity() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    }
  }

  /// Run a comprehensive connection diagnostic
  Future<Map<String, dynamic>> runDiagnostic(String serverUrl) async {
    final results = <String, dynamic>{
      'timestamp': DateTime.now().toIso8601String(),
      'serverUrl': serverUrl,
    };

    // Check internet connectivity
    print('🔍 DIAGNOSTIC: Checking internet connectivity');
    final hasInternet = await checkInternetConnectivity();
    results['internetConnectivity'] = hasInternet;

    if (!hasInternet) {
      results['status'] = 'failed';
      results['primaryIssue'] = 'No internet connectivity';
      return results;
    }

    // Check if server is reachable via HTTP
    print('🔍 DIAGNOSTIC: Checking if server is reachable');
    final isReachable = await isServerReachable(serverUrl);
    results['serverReachable'] = isReachable;

    if (!isReachable) {
      results['status'] = 'failed';
      results['primaryIssue'] = 'Signaling server not reachable';
      return results;
    }

    // Test WebSocket connection
    print('🔍 DIAGNOSTIC: Testing WebSocket connection');
    final wsTest = await testWebSocketConnection(serverUrl);
    results['webSocketTest'] = wsTest;

    // Determine overall status
    if (wsTest['success'] == true) {
      results['status'] = 'success';
      results['primaryIssue'] = null;
    } else {
      results['status'] = 'failed';

      if (!wsTest['connectSuccess']) {
        results['primaryIssue'] = 'Could not establish WebSocket connection';
      } else if (!wsTest['registerSuccess']) {
        results['primaryIssue'] = 'Could not send registration message';
      } else if (!wsTest['welcomeReceived']) {
        results['primaryIssue'] = 'No welcome message received from server';
      } else if (!wsTest['pongReceived']) {
        results['primaryIssue'] = 'No pong response received from server';
      } else {
        results['primaryIssue'] = wsTest['error'] ?? 'Unknown WebSocket issue';
      }
    }

    return results;
  }
}
