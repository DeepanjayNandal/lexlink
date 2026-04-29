// lib/features/session/session_model.dart
import 'package:flutter/foundation.dart';

class Session {
  final String id;
  final String contactId;
  final DateTime startTime;
  DateTime? endTime;
  int messageCount;
  bool isActive;

  // New field to track whether message purging is enabled for this session
  bool purgeEnabled;

  // Metadata for storing additional session information
  Map<String, dynamic>? metadata;

  Session({
    required this.id,
    required this.contactId,
    required this.startTime,
    this.endTime,
    this.messageCount = 0,
    this.isActive = true,

    // Default to purge disabled - messages persist by default
    this.purgeEnabled = false,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    debugPrint(
        'TESTINGSTEP4: Saving session with contactId "${this.contactId}" to JSON');
    return {
      'id': id,
      'contactId': contactId,
      'startTime': startTime.millisecondsSinceEpoch,
      'endTime': endTime?.millisecondsSinceEpoch,
      'messageCount': messageCount,
      'isActive': isActive,
      'purgeEnabled': purgeEnabled, // Include purge setting in serialization
      'metadata': metadata, // Include metadata in serialization
    };
  }

  factory Session.fromJson(Map<String, dynamic> json) {
    final contactId = json['contactId'];
    debugPrint(
        'TESTINGSTEP4: Loaded session with contactId "$contactId" from JSON');
    return Session(
      id: json['id'],
      contactId: json['contactId'],
      startTime: DateTime.fromMillisecondsSinceEpoch(json['startTime']),
      endTime: json['endTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['endTime'])
          : null,
      messageCount: json['messageCount'] ?? 0,
      isActive: json['isActive'] ?? true,
      purgeEnabled:
          json['purgeEnabled'] ?? false, // Load from storage with default
      metadata: json['metadata'] != null
          ? Map<String, dynamic>.from(json['metadata'])
          : null, // Load metadata from storage
    );
  }
}
