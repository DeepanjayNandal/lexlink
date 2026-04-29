import 'package:flutter/widgets.dart';
import 'package:logger/logger.dart';
import '../../service/logging_service.dart';
import 'i_signaling_service.dart';

/// A lifecycle-aware manager for signaling services
///
/// This class manages the signaling service's lifecycle in response to
/// app lifecycle events (background/foreground transitions).
class SignalingLifecycleManager with WidgetsBindingObserver {
  final Logger _logger = Logger();
  late final OperationLogger _lifecycleLogger;
  final ISignalingService _signalingService;

  // Connection state before going to background
  bool _wasConnectedBeforeBackground = false;

  // Connection parameters for reconnection
  String? _serverUrl;
  String? _peerId;
  String? _targetPeerId;

  /// Constructor
  SignalingLifecycleManager(this._signalingService) {
    _lifecycleLogger =
        LoggingService.instance.getOperationLogger('signaling_lifecycle');
    _initialize();
  }

  void _initialize() {
    _lifecycleLogger.info('Initializing SignalingLifecycleManager');

    // Register for lifecycle events
    WidgetsBinding.instance.addObserver(this);

    // Store connection parameters when they're set
    _signalingService.onConnectionStateChanged.listen((isConnected) {
      if (isConnected) {
        _serverUrl = _signalingService.peerId != null ? _serverUrl : null;
        _peerId = _signalingService.peerId;
        _targetPeerId = _signalingService.targetPeerId;
        _lifecycleLogger
            .debug('Stored connection parameters for potential reconnection');
      }
    });

    _lifecycleLogger.info('SignalingLifecycleManager initialized');
  }

  /// Handle app lifecycle state changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleLogger.info('App lifecycle state changed to: $state');

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        _handleAppBackground();
        break;
      case AppLifecycleState.resumed:
        _handleAppForeground();
        break;
      default:
        // No action needed for other states
        break;
    }
  }

  /// Handle app going to background
  void _handleAppBackground() {
    _lifecycleLogger.info('App going to background');

    // Store current connection state
    _wasConnectedBeforeBackground = _signalingService.isConnected;

    if (_wasConnectedBeforeBackground) {
      _lifecycleLogger.info(
          'Signaling service was connected, storing parameters for reconnection');

      // Store connection parameters if not already stored
      _serverUrl ??= _signalingService.peerId != null ? _serverUrl : null;
      _peerId ??= _signalingService.peerId;
      _targetPeerId ??= _signalingService.targetPeerId;

      // Close connection to save resources
      _lifecycleLogger.info('Closing signaling connection to save resources');
      _signalingService.close();
    }
  }

  /// Handle app coming to foreground
  void _handleAppForeground() {
    _lifecycleLogger.info('App coming to foreground');

    // Reconnect if we were connected before going to background
    if (_wasConnectedBeforeBackground &&
        _serverUrl != null &&
        _peerId != null) {
      _lifecycleLogger.info('Reconnecting signaling service');

      // Reconnect
      _signalingService.connect(_serverUrl!, _peerId!).then((_) {
        // Restore target peer if it was set
        if (_targetPeerId != null) {
          _signalingService.setTargetPeer(_targetPeerId!);
          _lifecycleLogger.info('Restored target peer: $_targetPeerId');
        }

        _lifecycleLogger.info('Signaling service reconnected successfully');
      }).catchError((error) {
        _lifecycleLogger.error('Failed to reconnect signaling service',
            error: error);
      });
    }
  }

  /// Dispose resources
  void dispose() {
    _lifecycleLogger.info('Disposing SignalingLifecycleManager');

    // Unregister from lifecycle events
    WidgetsBinding.instance.removeObserver(this);

    _lifecycleLogger.info('SignalingLifecycleManager disposed');
  }
}
