import 'package:logger/logger.dart';
import 'contact_model.dart';
import 'contact_repository.dart';
import 'contact_key_service.dart';
import '../session/session_service.dart';

class ContactService {
  final ContactRepository _repository;
  final ContactKeyService _keyService;
  final _logger = Logger();
  SessionService? _sessionService;

  ContactService(this._repository, this._keyService);

  // Set session service (to avoid circular dependency)
  void setSessionService(SessionService sessionService) {
    _sessionService = sessionService;
  }

  // Create a new contact
  Future<Contact> createContact(String name, String role) async {
    _logger.d('Creating new contact: $name ($role)');

    // Validate inputs
    if (!isValidContactName(name)) {
      throw InvalidContactNameException('Invalid contact name: $name');
    }
    if (!isValidRole(role)) {
      throw InvalidRoleException('Invalid role: $role');
    }

    // Generate unique ID
    final id = '${role.toLowerCase()}-${DateTime.now().millisecondsSinceEpoch}';

    // Create contact
    final contact = Contact(
      id: id,
      name: name,
      role: role.toLowerCase(),
      createdAt: DateTime.now(),
    );

    // Save contact
    await _repository.saveContact(contact);
    _logger.d('Contact created successfully: $id');

    return contact;
  }

  // Get contact by ID
  Future<Contact?> getContact(String id) async {
    try {
      return await _repository.getContactById(id);
    } catch (e) {
      _logger.e('Error getting contact $id: $e');
      rethrow;
    }
  }

  // Get all contacts
  Future<List<Contact>> getAllContacts() async {
    _logger.d('Getting all contacts');
    return await _repository.getAllContacts();
  }

  // Get contacts by role
  Future<List<Contact>> getContactsByRole(String role) async {
    _logger.d('Getting contacts by role: $role');
    final contacts = await _repository.getAllContacts();
    return contacts
        .where((contact) => contact.role == role.toLowerCase())
        .toList();
  }

  // Update contact
  Future<void> updateContact(Contact contact) async {
    _logger.d('Updating contact: ${contact.id}');
    await _repository.saveContact(contact);
    _logger.d('Contact updated successfully');
  }

  // Delete contact
  Future<void> deleteContact(String id) async {
    _logger.d('Deleting contact: $id');

    try {
      // First, handle connection cleanup through ConnectionManagerService
      // This will be injected by the UI layer when needed

      // Delete contact's sessions before deleting the contact
      if (_sessionService != null) {
        _logger.d('Deleting sessions for contact: $id');
        await _sessionService!.deleteSessionsForContact(id);
      }

      await _repository.deleteContact(id);
      _logger.d('Contact deleted successfully');
    } catch (e, stackTrace) {
      _logger.e('Error deleting contact: $e');
      rethrow;
    }
  }

  // Set contact status
  Future<void> setContactStatus(String id, bool isActive) async {
    _logger.d('Setting contact status: $id -> $isActive');
    final contact = await getContact(id);
    if (contact == null) {
      throw ContactNotFoundException('Contact not found: $id');
    }

    final updatedContact = contact.copyWith(isActive: isActive);
    await _repository.saveContact(updatedContact);
    _logger.d('Contact status updated successfully');
  }

  // Search contacts
  Future<List<Contact>> searchContacts(String query) async {
    _logger.d('Searching contacts: $query');
    final contacts = await _repository.getAllContacts();
    final lowercaseQuery = query.toLowerCase();

    return contacts.where((contact) {
      return contact.name.toLowerCase().contains(lowercaseQuery) ||
          contact.id.toLowerCase().contains(lowercaseQuery);
    }).toList();
  }

  // Update contact with session information
  Future<void> updateContactWithSessionInfo(
      String contactId, String sessionId, bool hasSession) async {
    _logger.d(
        'DEBUGGING SESSION: Updating contact $contactId with session info: sessionId=$sessionId, hasSession=$hasSession');
    try {
      final contact = await getContact(contactId);
      if (contact == null) {
        throw ContactNotFoundException('Contact not found: $contactId');
      }

      // Create a new metadata map with session info
      final updatedMetadata = Map<String, dynamic>.from(contact.metadata);
      updatedMetadata['hasSession'] = hasSession.toString();
      updatedMetadata['sessionId'] = sessionId;

      // Update contact with new metadata
      final updatedContact = contact.copyWith(metadata: updatedMetadata);
      await _repository.saveContact(updatedContact);

      // Verify the update was saved
      final verifiedContact = await getContact(contactId);
      _logger.d(
          'DEBUGGING SESSION: Verification - Contact $contactId updated, hasSession: ${verifiedContact?.metadata['hasSession']}, sessionId: ${verifiedContact?.metadata['sessionId']}');
    } catch (e) {
      _logger.e('DEBUGGING SESSION: Error updating contact session info: $e');
      throw Exception('Failed to update contact session info: $e');
    }
  }

  // Clear session information from contact
  Future<void> clearContactSessionInfo(String contactId) async {
    _logger
        .d('DEBUGGING SESSION: Clearing session info for contact: $contactId');
    try {
      final contact = await getContact(contactId);
      if (contact == null) {
        throw ContactNotFoundException('Contact not found: $contactId');
      }

      // Log current metadata state
      _logger.d(
          'DEBUGGING SESSION: Current metadata before clearing: ${contact.metadata}');

      // Remove session info from metadata
      final updatedMetadata = Map<String, dynamic>.from(contact.metadata);
      updatedMetadata.remove('hasSession');
      updatedMetadata.remove('sessionId');

      // Update contact with new metadata
      final updatedContact = contact.copyWith(metadata: updatedMetadata);
      await _repository.saveContact(updatedContact);

      // Verify the update was saved
      final verifiedContact = await getContact(contactId);
      _logger.d(
          'DEBUGGING SESSION: Contact session info cleared. New metadata: ${verifiedContact?.metadata}');
    } catch (e) {
      _logger.e('DEBUGGING SESSION: Error clearing contact session info: $e');
      throw Exception('Failed to clear contact session info: $e');
    }
  }

  // Initialize dummy contacts for the app
  Future<void> initializeDummyContacts() async {
    _logger.d('Initializing dummy contacts');

    // Check if contacts already exist
    final existingContacts = await _repository.getAllContacts();
    if (existingContacts.isNotEmpty) {
      _logger.d('Contacts already exist - skipping dummy initialization');
      return;
    }

    // Create dummy lawyers
    final lawyer1 = Contact(
      id: 'lawyer-1747500000001',
      name: 'John Doe',
      role: 'lawyer',
      createdAt: DateTime.now(),
    );

    final lawyer2 = Contact(
      id: 'lawyer-1747500000002',
      name: 'Jane Smith',
      role: 'lawyer',
      createdAt: DateTime.now(),
    );

    // Create dummy clients
    final client1 = Contact(
      id: 'client-1747500000003',
      name: 'Client One',
      role: 'client',
      createdAt: DateTime.now(),
    );

    final client2 = Contact(
      id: 'client-1747500000004',
      name: 'Client Two',
      role: 'client',
      createdAt: DateTime.now(),
    );

    // Save the dummy contacts
    await _repository.saveContact(lawyer1);
    await _repository.saveContact(lawyer2);
    await _repository.saveContact(client1);
    await _repository.saveContact(client2);

    _logger.d('Successfully initialized 4 dummy contacts');
  }

  // Validation methods
  bool isValidContactName(String name) {
    return name.isNotEmpty && name.length <= 100;
  }

  bool isValidRole(String role) {
    final validRoles = ['lawyer', 'client'];
    return validRoles.contains(role.toLowerCase());
  }

  bool isValidContactId(String id) {
    return id.isNotEmpty &&
        (id.startsWith('lawyer-') || id.startsWith('client-'));
  }
}

// Custom exceptions
class InvalidContactNameException implements Exception {
  final String message;
  InvalidContactNameException(this.message);

  @override
  String toString() => message;
}

class InvalidRoleException implements Exception {
  final String message;
  InvalidRoleException(this.message);

  @override
  String toString() => message;
}
