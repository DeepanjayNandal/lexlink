import 'i_signaling_service.dart';
import 'websocket_signaling_service.dart';
import 'signaling_config.dart';

/// Enum representing different signaling service types
enum SignalingServiceType {
  /// Standard WebSocket-based signaling service
  webSocket,

  /// Socket.IO-based signaling service (not implemented yet)
  socketIo,

  /// Cloud-based signaling service (not implemented yet)
  cloud,
}

/// Factory class for creating signaling service instances
///
/// This factory allows the application to easily switch between different
/// signaling service implementations without changing client code.
class SignalingServiceFactory {
  /// Create a signaling service of the specified type
  ///
  /// [type] - The type of signaling service to create
  /// [config] - Optional configuration for the service
  static ISignalingService createSignalingService(
    SignalingServiceType type, [
    SignalingConfig? config,
  ]) {
    switch (type) {
      case SignalingServiceType.webSocket:
        return WebSocketSignalingService(config);

      case SignalingServiceType.socketIo:
        // Socket.IO implementation would go here
        // For now, fall back to WebSocket implementation
        return WebSocketSignalingService(config);

      case SignalingServiceType.cloud:
        // Cloud implementation would go here
        // For now, fall back to WebSocket implementation
        return WebSocketSignalingService(config);
    }
  }

  /// Create a signaling service based on environment
  ///
  /// This method selects the appropriate signaling service type based on
  /// the current environment (development, testing, production).
  static ISignalingService createForEnvironment(String environment,
      [SignalingConfig? config]) {
    switch (environment.toLowerCase()) {
      case 'development':
      case 'dev':
        // Use WebSocket for development
        return createSignalingService(
          SignalingServiceType.webSocket,
          config ?? SignalingConfig.development(),
        );

      case 'testing':
      case 'test':
        // Use WebSocket for testing
        return createSignalingService(
          SignalingServiceType.webSocket,
          config ?? SignalingConfig.localNetwork(),
        );

      case 'production':
      case 'prod':
        // Use WebSocket for production (for now)
        // In the future, this could be changed to a different implementation
        return createSignalingService(
          SignalingServiceType.webSocket,
          config ?? SignalingConfig.production(),
        );

      default:
        // Default to WebSocket
        return createSignalingService(
          SignalingServiceType.webSocket,
          config ?? SignalingConfig.development(),
        );
    }
  }
}
