---
description: Repository Information Overview
alwaysApply: true
---

# LexLink

## Summary
LexLink is a secure peer-to-peer messaging application built with Flutter. It enables end-to-end encrypted communication between lawyers and clients using WebRTC DataChannels and a WebSocket signaling server. The signaling server is never in the message path.

## Structure
- **lib/core/**: Core services including P2P communication, security, and utilities
- **lib/features/**: Feature modules including messaging, contacts, and sessions
- **lib/ui/**: User interface components and screens
- **test/**: Test files

## Language & Runtime
**Language**: Dart
**Version**: SDK >=3.0.0 <4.0.0
**Framework**: Flutter
**Package Manager**: pub (Dart/Flutter)

## Dependencies
**Main Dependencies**:
- flutter_webrtc: ^0.13.1+hotfix.1 (WebRTC implementation)
- web_socket_channel: ^2.4.0 (WebSocket communication)
- cryptography: ^2.5.0 (ChaCha20-Poly1305 AEAD encryption)
- crypto: ^3.0.3 (HKDF key derivation)
- sqflite: ^2.2.0 (Local SQLite database)
- shared_preferences: ^2.2.0 (Local storage)
- connectivity_plus: ^4.0.2 (Network monitoring)
- uuid: ^3.0.7 (Unique ID generation)
- logger: ^1.3.0 (Logging)

**Development Dependencies**:
- flutter_test
- flutter_lints: ^2.0.0
- sentry_dart_plugin: ^2.4.1

## Communication Architecture

1. **WebRTC Direct Connection (Phase 1)**:
   - Peer-to-peer DataChannel for real-time messaging
   - STUN/TURN servers for NAT traversal
   - ICE candidate exchange via signaling server

2. **Signaling Server Relay (Phase 2)**:
   - WebSocket fallback when WebRTC is unavailable
   - Handles SDP offer/answer and ICE relay only
   - Heartbeat mechanism with ping/pong

3. **Message Persistence**:
   - SQLite for local message storage
   - Encrypted message content
   - Outbox queue with retry on reconnect

## Security

- ChaCha20-Poly1305 AEAD encryption for all messages
- HKDF with SHA-256 for per-session key derivation (separate send/receive keys)
- QR code out-of-band pairing — signaling server never receives keys
- Privacy-focused ICE candidate filtering

## Connection Management

- Automatic reconnection with exponential backoff
- Network transition handling
- Session recovery mechanism
- Connection state monitoring

## Key Components

### P2P Communication

- **SignalingService**: Manages WebSocket connection to signaling server
- **WebRTCConnectionService**: Handles WebRTC peer connections and data channels
- **QRConnectionService**: Establishes initial sessions via QR code exchange

### Messaging

- **P2PMessageService**: Sends/receives messages over WebRTC or signaling
- **MessageService**: Message storage and retrieval
- **MessageRepository**: SQLite operations for messages

### Session Management

- **SessionService**: Session lifecycle management
- **SessionKeyService**: Encryption key management per session
- **SessionRecoveryService**: Recovers interrupted sessions

### Error Handling

- **GlobalErrorHandler**: Centralized error reporting via Sentry
- **ConnectionManagerService**: Connection state management and retry logic
