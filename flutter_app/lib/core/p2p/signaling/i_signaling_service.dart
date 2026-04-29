// lib/core/p2p/signaling/i_signaling_service.dart

import 'dart:async';

/// Interface for signaling services that facilitate WebRTC connection establishment
/// and fallback messaging when direct P2P connections are not available.
///
/// This abstraction allows for swapping different signaling implementations
/// (WebSocket, Socket.io, HTTP polling, etc.) without changing client code.
abstract class ISignalingService {
  /// Connect to the signaling server
  ///
  /// [serverUrl] - The URL of the signaling server
  /// [peerId] - Unique identifier for this peer
  Future<void> connect(String serverUrl, String peerId);

  /// Close the signaling connection
  void close();

  /// Check if connected to signaling server
  bool get isConnected;

  /// Set the target peer ID for sending messages
  ///
  /// This is typically the peer we want to establish a connection with
  void setTargetPeer(String peerId);

  /// Get the ID of this peer
  String? get peerId;

  /// Get the ID of the target peer
  String? get targetPeerId;

  /// Send signal data to the target peer
  ///
  /// [data] - WebRTC signaling data (offer, answer, ICE candidate)
  void sendSignalData(Map<String, dynamic> data);

  /// Send a register_receiver message to the signaling server
  ///
  /// Used when a client wants to connect to a specific initiator
  void sendRegisterReceiver(Map<String, dynamic> registerMessage);

  /// Send a raw message to the signaling server
  ///
  /// [message] - Message to send to the server
  void sendToSignalingServer(Map<String, dynamic> message);

  /// Send a custom message with a specific type
  ///
  /// Allows for protocol extensions without changing the interface
  /// [type] - Message type
  /// [payload] - Message payload
  void sendCustomMessage(String type, Map<String, dynamic> payload);

  /// Stream of signal data received from the server
  Stream<Map<String, dynamic>> get onSignalData;

  /// Stream of connection state changes
  Stream<bool> get onConnectionStateChanged;

  /// Clean up resources
  void dispose();
}
