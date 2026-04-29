// lib/core/models/user_role.dart
enum UserRole { initiator, responder }

extension UserRoleX on UserRole {
  String get asString => this == UserRole.initiator ? 'initiator' : 'responder';

  String get displayName => this == UserRole.initiator ? 'Lawyer' : 'Client';

  static UserRole fromString(String v) =>
      v == 'initiator' ? UserRole.initiator : UserRole.responder;

  static UserRole fromDisplayString(String v) =>
      v.toLowerCase() == 'lawyer' ? UserRole.initiator : UserRole.responder;

  static UserRole fromLegacyString(String v) {
    // Handle old format: "UserRole.lawyer" -> initiator
    if (v == 'UserRole.lawyer' || v == 'lawyer') return UserRole.initiator;
    if (v == 'UserRole.client' || v == 'client') return UserRole.responder;
    return fromString(v);
  }
}
