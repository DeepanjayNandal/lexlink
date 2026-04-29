import 'dart:async';
import 'dart:convert';
import '../repository/message_repository.dart';
import '../../../core/p2p/signaling_service.dart';
import '../../../core/security/encryption_service.dart';
import '../../../features/session/session_service.dart';
import '../../../features/session/session_key_service.dart';

class MessageService {
  final MessageRepository _repository;
  final SignalingService _signalingService;
  final EncryptionService _encryptionService;
  final SessionService _sessionService;
  final SessionKeyService _sessionKeyService;

  StreamSubscription<bool>? _connSub;
  bool _draining = false;

  MessageService(
    this._repository,
    this._signalingService,
    this._encryptionService,
    this._sessionService,
    this._sessionKeyService,
  ) {
    _signalingService.onConnectionOpen = _drainOutbox;
  }

  Future<void> startRetryWorker() async {
    await _drainOutbox();
    _connSub?.cancel();
    _connSub = _signalingService.onConnectionStateChanged.listen((isConnected) {
      if (isConnected) {
        _drainOutbox();
      }
    });
  }

  Future<void> _drainOutbox() async {
    if (_draining) return;
    _draining = true;
    try {
      final pending = await _repository.fetchDueOutboxMessages();
      for (final message in pending) {
        if (!_signalingService.isConnected) break;
        try {
          final payload =
              jsonDecode(message['blob'] as String) as Map<String, dynamic>;
          _signalingService.sendSignalData(payload);
          await _repository.markMessageSent(message['id'] as String);
        } catch (e) {
          await _repository.bumpRetry(message['id'] as String, e.toString());
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<bool> sendMessage(String contactId, String content) async {
    final sessionId = await _getSessionIdForContact(contactId);
    if (sessionId == null) return false;

    final sendKeyB64 = await _getSendKeyForSession(sessionId);
    if (sendKeyB64 == null) return false;

    final ctr = await _getNextCounter(sessionId);

    final messageId = _repository.generateMessageId();

    final encrypted = await _encryptionService.encrypt(
      content,
      await _encryptionService.importKey(sendKeyB64),
    );

    final peerId = await _getPeerIdForSession(sessionId);
    final payload = {
      'type': 'message',
      'to': peerId,
      'sessionId': sessionId,
      'id': messageId,
      'data': encrypted,
    };

    await _repository.insertOutboxMessage(
      id: messageId,
      sessionId: sessionId,
      blob: jsonEncode(payload),
      peerId: peerId,
    );

    if (_signalingService.isConnected) {
      try {
        _signalingService.sendSignalData(payload);
        await _repository.markMessageSent(messageId);
        return true;
      } catch (e) {
        // If sending fails, the message remains in outbox for retry
        return false;
      }
    }

    return false;
  }

  Future<String?> _getSessionIdForContact(String contactId) async {
    final session = await _sessionService.getActiveSessionForContact(contactId);
    return session?.id;
  }

  Future<String?> _getSendKeyForSession(String sessionId) async {
    final key = await _sessionKeyService.getSecretKeyForSession(sessionId);
    if (key != null) {
      return await _encryptionService.exportKey(key);
    }
    return null;
  }

  Future<String?> _getPeerIdForSession(String sessionId) async {
    // For now, return the sessionId as peerId since we don't have a separate peer mapping
    return sessionId;
  }

  Future<int> _getNextCounter(String sessionId) async {
    // For now, return a simple timestamp-based counter
    return DateTime.now().millisecondsSinceEpoch;
  }

  void dispose() {
    _connSub?.cancel();
    if (_signalingService.onConnectionOpen == _drainOutbox) {
      _signalingService.onConnectionOpen = null;
    }
  }
}
