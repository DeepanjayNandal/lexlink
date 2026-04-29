import 'dart:convert';

class Contact {
  final String id;
  final String name;
  final String role;
  final DateTime createdAt;
  final bool isActive;
  final Map<String, dynamic> metadata;

  Contact({
    required this.id,
    required this.name,
    required this.role,
    required this.createdAt,
    this.isActive = true,
    this.metadata = const {},
  });

  // Convert Contact to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'role': role,
      'createdAt': createdAt.toIso8601String(),
      'isActive': isActive,
      'metadata': metadata,
    };
  }

  // Create Contact from JSON
  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      id: json['id'],
      name: json['name'],
      role: json['role'],
      createdAt: DateTime.parse(json['createdAt']),
      isActive: json['isActive'] ?? true,
      metadata: json['metadata'] ?? {},
    );
  }

  // Create a copy of Contact with updated fields
  Contact copyWith({
    String? id,
    String? name,
    String? role,
    DateTime? createdAt,
    bool? isActive,
    Map<String, dynamic>? metadata,
  }) {
    return Contact(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      createdAt: createdAt ?? this.createdAt,
      isActive: isActive ?? this.isActive,
      metadata: metadata ?? this.metadata,
    );
  }
}
