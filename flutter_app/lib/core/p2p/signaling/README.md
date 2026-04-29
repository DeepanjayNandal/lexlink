# Signaling Service Abstraction

This module provides an abstraction layer for signaling services used in WebRTC connection establishment and message relay.

## Overview

The signaling service abstraction allows the application to easily switch between different signaling service implementations (WebSocket, Socket.IO, HTTP polling, etc.) without changing client code. This is particularly useful when migrating from one signaling server to another.

## Key Components

### Interfaces

- **ISignalingService**: The core interface that all signaling service implementations must implement. It defines methods for connecting, sending messages, and handling events.

### Implementations

- **WebSocketSignalingService**: A WebSocket-based implementation of the signaling service interface with heartbeat support.

### Configuration

- **SignalingConfig**: A class that centralizes all configuration options for signaling services, making it easy to switch between different environments or configurations.

### Factory

- **SignalingServiceFactory**: A factory class for creating signaling service instances. It allows the application to easily switch between different signaling service implementations.

### Utilities

- **SignalingUtils**: A utility class for signaling-related operations, such as sanitizing JSON data and validating messages.

### Lifecycle Management

- **SignalingLifecycleManager**: A lifecycle-aware manager for signaling services that handles background/foreground transitions.

## Usage

### Basic Usage

```dart
// Create a signaling service using the factory
final signalingService = SignalingServiceFactory.createForEnvironment('development');

// Connect to the signaling server
await signalingService.connect('ws://localhost:8080', 'peer-123');

// Set the target peer
signalingService.setTargetPeer('peer-456');

// Send a signal
signalingService.sendSignalData({
  'type': 'offer',
  'sdp': 'session description...',
});

// Listen for signals
signalingService.onSignalData.listen((data) {
  // Handle incoming signal
});

// Close the connection when done
signalingService.close();
```

### With Lifecycle Management

```dart
// Create a signaling service
final signalingService = SignalingServiceFactory.createForEnvironment('development');

// Create a lifecycle manager
final lifecycleManager = SignalingLifecycleManager(signalingService);

// Connect to the signaling server
await signalingService.connect('ws://localhost:8080', 'peer-123');

// The lifecycle manager will automatically handle background/foreground transitions

// Dispose the lifecycle manager when done
lifecycleManager.dispose();
```

## Extending

To add a new signaling service implementation:

1. Create a new class that implements `ISignalingService`
2. Add the new implementation to `SignalingServiceFactory`
3. Update the configuration as needed

For example:

```dart
class SocketIoSignalingService implements ISignalingService {
  // Implement the interface methods
}
```

Then update the factory:

```dart
static ISignalingService createSignalingService(
  SignalingServiceType type, [
  SignalingConfig? config,
]) {
  switch (type) {
    case SignalingServiceType.webSocket:
      return WebSocketSignalingService(config);

    case SignalingServiceType.socketIo:
      return SocketIoSignalingService(config);

    // ...
  }
}
```

## Heartbeat Mechanism

The signaling service implementations include a heartbeat mechanism to keep the connection alive. This is particularly important for mobile devices, which may disconnect from the network or go to sleep.

The heartbeat interval and connection timeout can be configured using the `SignalingConfig` class.