import 'dart:convert';
import 'package:logger/logger.dart';
import 'package:cryptography/cryptography.dart';
import '../../core/security/encryption_service.dart';
import 'contact_model.dart';

/// Service for managing contact-specific encryption
/// This handles ONLY contact metadata encryption, not session keys
/// Session keys are managed by SessionKeyService
class ContactKeyService {
  final EncryptionService _encryptionService;
  final _logger = Logger();
  late final SecretKey _contactKey;

  ContactKeyService(this._encryptionService) {
    _initializeKey();
  }

  Future<void> _initializeKey() async {
    _contactKey = await _encryptionService.generateKey();
    _logger.d('Contact encryption key initialized');
  }

  // Encrypt contact data
  Future<String> encryptContactData(Contact contact) async {
    _logger.d('Encrypting contact data for: ${contact.id}');
    try {
      final jsonData = contact.toJson();
      final encrypted = await _encryptionService.encrypt(
        jsonEncode(jsonData),
        _contactKey,
      );
      _logger.d('Contact data encrypted successfully');
      return encrypted;
    } catch (e) {
      _logger.e('Failed to encrypt contact data: $e');
      rethrow;
    }
  }

  // Decrypt contact data
  Future<Contact> decryptContactData(String encryptedData) async {
    _logger.d('Decrypting contact data');
    try {
      final decrypted = await _encryptionService.decrypt(
        encryptedData,
        _contactKey,
      );
      final contact = Contact.fromJson(jsonDecode(decrypted));
      _logger.d('Contact data decrypted successfully');
      return contact;
    } catch (e) {
      _logger.e('Failed to decrypt contact data: $e');
      rethrow;
    }
  }

  // Encrypt contact metadata
  Future<String> encryptMetadata(Map<String, dynamic> metadata) async {
    _logger.d('Encrypting contact metadata');
    try {
      final encrypted = await _encryptionService.encrypt(
        jsonEncode(metadata),
        _contactKey,
      );
      _logger.d('Metadata encrypted successfully');
      return encrypted;
    } catch (e) {
      _logger.e('Failed to encrypt metadata: $e');
      rethrow;
    }
  }

  // Decrypt contact metadata
  Future<Map<String, dynamic>> decryptMetadata(String encryptedMetadata) async {
    _logger.d('Decrypting contact metadata');
    try {
      final decrypted = await _encryptionService.decrypt(
        encryptedMetadata,
        _contactKey,
      );
      final metadata = jsonDecode(decrypted) as Map<String, dynamic>;
      _logger.d('Metadata decrypted successfully');
      return metadata;
    } catch (e) {
      _logger.e('Failed to decrypt metadata: $e');
      rethrow;
    }
  }
}
