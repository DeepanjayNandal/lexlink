// lib/features/messaging/message_model.dart
class Message {
  final String id;
  final String contactId;
  final String text;
  final bool isSent;
  final DateTime timestamp;
  final bool isEncrypted;

  Message({
    required this.id,
    required this.contactId,
    required this.text,
    required this.isSent,
    required this.timestamp,
    this.isEncrypted = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'contactId': contactId,
      'text': text,
      'isSent': isSent,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isEncrypted': isEncrypted,
    };
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'],
      contactId: json['contactId'],
      text: json['text'],
      isSent: json['isSent'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
      isEncrypted: json['isEncrypted'] ?? false,
    );
  }
}
