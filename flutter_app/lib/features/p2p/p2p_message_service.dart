// lib/features/p2p/p2p_message_service.dart

import 'dart:async';
import 'dart:convert';
import 'package:logger/logger.dart';
import '../../core/p2p/webrtc_connection_service.dart';
import '../../core/p2p/signaling_service.dart';
import '../../features/messaging/message_model.dart';
import '../../features/messaging/message_service.dart';
import '../../features/session/session_key_service.dart';

/// Service for handling P2P messages using WebRTC or signaling server relay
class P2PMessageService {
  final Logger _logger = Logger();
  final WebRTCConnectionService _webRTCService;
  final SignalingService? _signalingService;
  final MessageService _messageService = MessageService();
  final SessionKeyService _sessionKeyService;

  // Session and contact information
  String? _currentSessionId;
  String? _currentContactId;
  String? _targetPeerId; // For Phase 2 messaging

  // Message acknowledgment tracking
  final Map<String, Completer<bool>> _pendingAcks = {};
  final Set<String> _processedMessageIds = {};

  // Stream controller for messages
  final _messageStreamController = StreamController<Message>.broadcast();

  // Public stream for messages
  Stream<Message> get onMessageReceived => _messageStreamController.stream;

  // Constructor - now requires SessionKeyService instead of ContactKeyService
  P2PMessageService(this._webRTCService, this._sessionKeyService,
      [this._signalingService]) {
    // Listen for messages from WebRTC (Phase 1 - if still connected)
    _webRTCService.onMessage.listen(_handleIncomingWebRTCMessage);

    // Listen for messages from signaling service (Phase 2 - server relay)
    if (_signalingService != null) {
      _signalingService!.onSignalData.listen(_handleIncomingSignalingMessage);
    }
  }

  /// Set current session and contact information
  void setSessionInfo(String sessionId, String contactId,
      {String? targetPeerId}) {
    _currentSessionId = sessionId;
    _currentContactId = contactId;
    _targetPeerId = targetPeerId;
    _logger.d(
        'P2P message service set to session: $sessionId, contact: $contactId, target: $targetPeerId');
  }

  /// Send a message via the best available channel (WebRTC or signaling server)
  Future<bool> sendMessage(Message message, String sessionId) async {
    try {
      _logger.d(
          'P2P sendMessage called - WebRTC connected: ${_webRTCService.isConnected}, Signaling connected: ${_signalingService?.isConnected}, Target peer: $_targetPeerId');

      // Phase 1: Try WebRTC first (if connected)
      if (_webRTCService.isConnected) {
        _logger.d('Sending message via WebRTC (Phase 1)');
        return await _sendViaWebRTC(message, sessionId);
      }

      // Phase 2: Use signaling server relay (if WebRTC disconnected)
      else if (_signalingService != null &&
          _signalingService!.isConnected &&
          _targetPeerId != null) {
        _logger.d('Sending message via signaling server relay (Phase 2)');
        return await _sendViaSignalingRelay(message, sessionId);
      }

      // No available channels
      else {
        _logger.w(
            'No available messaging channels - WebRTC: ${_webRTCService.isConnected}, Signaling: ${_signalingService?.isConnected}, Target: $_targetPeerId');
        return false;
      }
    } catch (e) {
      _logger.e('Error sending message: $e');
      return false;
    }
  }

  /// Send message via WebRTC (Phase 1) with acknowledgment
  Future<bool> _sendViaWebRTC(Message message, String sessionId) async {
    try {
      // Convert Message to WebRTC message format
      final webRTCMessage = {
        'type': 'message',
        'text': message.text,
        'timestamp': message.timestamp.millisecondsSinceEpoch,
        'id': message.id,
        'requiresAck': true, // Add flag to indicate acknowledgment is expected
      };

      // Create a completer for this message's acknowledgment
      final completer = Completer<bool>();
      _pendingAcks[message.id] = completer;

      // Set up a timeout for acknowledgment
      final timeout = Timer(const Duration(seconds: 30), () {
        if (!completer.isCompleted) {
          _logger.w('Message acknowledgment timed out after 30 seconds: ${message.id}');
          completer.complete(false);
          _pendingAcks.remove(message.id);
        }
      });

      // Send via WebRTC
      final sendSuccess = await _webRTCService.sendMessage(webRTCMessage);

      if (!sendSuccess) {
        // If sending failed immediately, clean up and return
        timeout.cancel();
        _pendingAcks.remove(message.id);
        return false;
      }

      // Save to local storage immediately (we'll mark as delivered when ack received)
      await _messageService.saveMessage(message, sessionId);
      _logger.d('Message sent via WebRTC, waiting for acknowledgment: ${message.id}');

      // Wait for acknowledgment or timeout
      final ackReceived = await completer.future;
      timeout.cancel();

      if (ackReceived) {
        _logger.d('Message acknowledged by recipient: ${message.id}');
      } else {
        _logger.w('Message not acknowledged by recipient: ${message.id}');
      }

      return ackReceived;
    } catch (e) {
      _logger.e('Error sending message via WebRTC: $e');
      return false;
    }
  }

  /// Send message via signaling server relay (Phase 2) with acknowledgment
  Future<bool> _sendViaSignalingRelay(Message message, String sessionId) async {
    try {
      // Encrypt the message using SessionKeyService
      final encryptedText =
          await _sessionKeyService.encryptMessage(sessionId, message.text);

      // Create encrypted message data
      final messageData = {
        'id': message.id,
        'text': encryptedText, // Encrypted text
        'timestamp': message.timestamp.millisecondsSinceEpoch,
        'contactId': message.contactId,
        'requiresAck': true, // Add flag to indicate acknowledgment is expected
      };

      // Create a completer for this message's acknowledgment
      final completer = Completer<bool>();
      _pendingAcks[message.id] = completer;

      // Set up a timeout for acknowledgment
      final timeout = Timer(const Duration(seconds: 45), () {
        if (!completer.isCompleted) {
          _logger.w('Signaling message acknowledgment timed out after 45 seconds: ${message.id}');
          completer.complete(false);
          _pendingAcks.remove(message.id);
        }
      });

      // Send through signaling server
      final signalingMessage = {
        'type': 'message',
        'to': _targetPeerId,
        'data': messageData,
        'timestamp': message.timestamp.millisecondsSinceEpoch,
      };

      _signalingService!.sendToSignalingServer(signalingMessage);
      _logger.d('Message sent via signaling relay, waiting for acknowledgment: ${message.id}');

      // Save to local storage (with encrypted text)
      final encryptedMessage = Message(
        id: message.id,
        contactId: message.contactId,
        text: encryptedText,
        isSent: message.isSent,
        timestamp: message.timestamp,
        isEncrypted: true,
      );

      await _messageService.saveMessage(encryptedMessage, sessionId);

      // Wait for acknowledgment or timeout
      final ackReceived = await completer.future;
      timeout.cancel();

      if (ackReceived) {
        _logger.d('Signaling message acknowledged by recipient: ${message.id}');
      } else {
        _logger.w('Signaling message not acknowledged by recipient: ${message.id}');
      }

      return ackReceived;
    } catch (e) {
      _logger.e('Error sending message via signaling relay: $e');
      return false;
    }
  }

  /// Handle incoming WebRTC messages (Phase 1)
  void _handleIncomingWebRTCMessage(Map<String, dynamic> data) async {
    try {
      final String messageType = data['type'] ?? 'unknown';

      // Handle message acknowledgments
      if (messageType == 'message_ack') {
        final String messageId = data['id'] ?? '';
        _logger.d('Received message acknowledgment for ID: $messageId');

        final completer = _pendingAcks.remove(messageId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(true);
          _logger.d('✅ Completed acknowledgment for message: $messageId');
        }
        return;
      }

      // Check if this is a message type we should process
      if (messageType != 'message') return;

      // Extract message data
      final String text = data['text'] ?? '';
      final int timestamp = data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch;
      final String id = data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
      final bool requiresAck = data['requiresAck'] ?? false;

      // Check for duplicate messages
      if (_processedMessageIds.contains(id)) {
        _logger.d('Ignoring duplicate message with ID: $id');

        // Still send acknowledgment for duplicates if required
        if (requiresAck) {
          _sendMessageAck(id);
        }
        return;
      }

      // Mark as processed
      _processedMessageIds.add(id);

      // Use the current contact ID instead of hardcoded "peer"
      final contactId = _currentContactId ?? 'unknown';

      _logger.d('Processing incoming WebRTC message: id=$id, text="$text", contact=$contactId');

      // Create Message object with proper contactId
      final message = Message(
        id: id,
        contactId: contactId,
        text: text,
        isSent: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
      );

      // Emit the message to listeners first
      if (!_messageStreamController.isClosed) {
        _messageStreamController.add(message);
        _logger.d('✅ Emitted message ${id} to stream listeners');
      }

      // Save message to storage
      if (_currentSessionId != null) {
        await _messageService.saveMessage(message, _currentSessionId!);
        _logger.d('✅ Saved message ${id} to storage for session $_currentSessionId');
      } else {
        _logger.w('❌ No current session ID - message ${id} not saved to storage');
      }

      // Send acknowledgment if required
      if (requiresAck) {
        _sendMessageAck(id);
      }
    } catch (e) {
      _logger.e('Error processing WebRTC message: $e');
    }
  }

  /// Send acknowledgment for a received message
  void _sendMessageAck(String messageId) {
    try {
      final ackMessage = {
        'type': 'message_ack',
        'id': messageId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      _logger.d('Sending acknowledgment for message: $messageId');

      // Send via WebRTC if connected
      if (_webRTCService.isConnected) {
        _webRTCService.sendMessage(ackMessage);
      }
      // Otherwise try signaling server if available
      else if (_signalingService != null &&
               _signalingService!.isConnected &&
               _targetPeerId != null) {
        _signalingService!.sendToSignalingServer({
          'type': 'message_ack',
          'to': _targetPeerId,
          'data': ackMessage,
        });
      } else {
        _logger.w('Cannot send message acknowledgment - no available channel');
      }
    } catch (e) {
      _logger.e('Error sending message acknowledgment: $e');
    }
  }

  /// Handle incoming signaling messages (Phase 2)
  void _handleIncomingSignalingMessage(Map<String, dynamic> data) async {
    try {
      final String messageType = data['type'] ?? 'unknown';

      // Handle message acknowledgments
      if (messageType == 'message_ack') {
        final messageData = data['data'];
        if (messageData != null) {
          final String messageId = messageData['id'] ?? '';
          _logger.d('Received signaling message acknowledgment for ID: $messageId');

          final completer = _pendingAcks.remove(messageId);
          if (completer != null && !completer.isCompleted) {
            completer.complete(true);
            _logger.d('✅ Completed acknowledgment for signaling message: $messageId');
          }
        }
        return;
      }

      // Only process message type from signaling server
      if (messageType != 'message') return;

      _logger.d('Processing incoming signaling server message');

      // Extract message data
      final messageData = data['data'];
      if (messageData == null) return;

      final String encryptedText = messageData['text'] ?? '';
      final int timestamp = messageData['timestamp'] ?? DateTime.now().millisecondsSinceEpoch;
      final String id = messageData['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
      final String contactId = messageData['contactId'] ?? _currentContactId ?? 'unknown';
      final bool requiresAck = messageData['requiresAck'] ?? false;

      // Check for duplicate messages
      if (_processedMessageIds.contains(id)) {
        _logger.d('Ignoring duplicate signaling message with ID: $id');

        // Still send acknowledgment for duplicates if required
        if (requiresAck) {
          _sendSignalingMessageAck(id, data['from']);
        }
        return;
      }

      // Mark as processed
      _processedMessageIds.add(id);

      _logger.d('Processing signaling message: id=$id, contact=$contactId');

      // Decrypt the message using SessionKeyService
      String decryptedText = encryptedText;
      bool isDecrypted = false;

      if (_currentSessionId != null) {
        try {
          decryptedText = await _sessionKeyService.decryptMessage(
              _currentSessionId!, encryptedText);
          isDecrypted = true;
          _logger.d('✅ Successfully decrypted message ${id}: "$decryptedText"');
        } catch (e) {
          _logger.w('❌ Failed to decrypt message ${id}: $e');
          decryptedText = 'Message could not be decrypted';
        }
      }

      // Create Message object for UI
      final message = Message(
        id: id,
        contactId: contactId,
        text: decryptedText,
        isSent: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
        isEncrypted: !isDecrypted,
      );

      // Emit the message to listeners first
      if (!_messageStreamController.isClosed) {
        _messageStreamController.add(message);
        _logger.d('✅ Emitted message ${id} to stream listeners');
      }

      // Save message to storage (store encrypted version for security)
      if (_currentSessionId != null) {
        final storageMessage = Message(
          id: id,
          contactId: contactId,
          text: encryptedText, // Store encrypted
          isSent: false,
          timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
          isEncrypted: true,
        );
        await _messageService.saveMessage(storageMessage, _currentSessionId!);
        _logger.d(
            '✅ Saved encrypted message ${id} to storage for session $_currentSessionId');
      } else {
        _logger
            .w('❌ No current session ID - message ${id} not saved to storage');
      }

      // Send acknowledgment if required
      if (requiresAck) {
        _sendSignalingMessageAck(id, data['from']);
      }
    } catch (e) {
      _logger.e('Error processing signaling server message: $e');
    }
  }

  /// Send acknowledgment for a received signaling message
  void _sendSignalingMessageAck(String messageId, String? targetPeerId) {
    try {
      if (_signalingService == null || !_signalingService!.isConnected) {
        _logger.w('Cannot send signaling acknowledgment - no signaling connection');
        return;
      }

      final String targetPeer = targetPeerId ?? _targetPeerId ?? '';
      if (targetPeer.isEmpty) {
        _logger.w('Cannot send signaling acknowledgment - no target peer ID');
        return;
      }

      final ackMessage = {
        'type': 'message_ack',
        'id': messageId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      _logger.d('Sending signaling acknowledgment for message: $messageId to $targetPeer');

      _signalingService!.sendToSignalingServer({
        'type': 'message_ack',
        'to': targetPeer,
        'data': ackMessage,
      });
    } catch (e) {
      _logger.e('Error sending signaling message acknowledgment: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    // Complete any pending acknowledgments
    for (final entry in _pendingAcks.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(false);
      }
    }
    _pendingAcks.clear();
    _processedMessageIds.clear();

    // Close stream controller
    if (!_messageStreamController.isClosed) {
      _messageStreamController.close();
    }

    _logger.d('P2PMessageService disposed');
  }
}
