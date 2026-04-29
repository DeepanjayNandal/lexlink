import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logger/logger.dart';
import 'contact_model.dart';
import 'package:uuid/uuid.dart';

class ContactRepository {
  static const String _contactsKey = 'contacts';
  final _logger = Logger();

  // Add dummy contacts for testing
  Future<void> initializeDummyContacts() async {
    final contacts = await getAllContacts();

    // Only add dummy contacts if there are none
    if (contacts.isEmpty) {
      // Create dummy lawyers
      await saveContact(Contact(
        id: "lawyer-1",
        name: "Lawyer Smith",
        role: "lawyer",
        createdAt: DateTime.now(),
        isActive: true,
      ));

      await saveContact(Contact(
        id: "lawyer-2",
        name: "Lawyer Johnson",
        role: "lawyer",
        createdAt: DateTime.now(),
        isActive: true,
      ));

      // Create dummy clients
      await saveContact(Contact(
        id: "client-1",
        name: "Client Davis",
        role: "client",
        createdAt: DateTime.now(),
        isActive: true,
      ));

      await saveContact(Contact(
        id: "client-2",
        name: "Client Wilson",
        role: "client",
        createdAt: DateTime.now(),
        isActive: true,
      ));

      _logger.i('Dummy contacts created successfully');
    } else {
      _logger.d('Contacts already exist, skipping dummy creation');
    }
  }

  // Save a single contact
  Future<void> saveContact(Contact contact) async {
    _logger.d(
        'DEBUGGING SESSION: Saving contact: ${contact.id} with metadata: ${contact.metadata}');
    final prefs = await SharedPreferences.getInstance();
    final contactsJson = prefs.getStringList(_contactsKey) ?? [];

    // Check if contact already exists
    final existingIndex = contactsJson.indexWhere((json) {
      final existingContact = Contact.fromJson(jsonDecode(json));
      return existingContact.id == contact.id;
    });

    if (existingIndex >= 0) {
      // Update existing contact
      contactsJson[existingIndex] = jsonEncode(contact.toJson());
      _logger.d(
          'DEBUGGING SESSION: Updated existing contact at index $existingIndex');
    } else {
      // Add new contact
      contactsJson.add(jsonEncode(contact.toJson()));
      _logger.d('DEBUGGING SESSION: Added new contact');
    }

    await prefs.setStringList(_contactsKey, contactsJson);
    _logger.d('DEBUGGING SESSION: Contact saved successfully');
  }

  /// Retrieve all contacts
  Future<List<Contact>> getAllContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final contactsJson = prefs.getStringList(_contactsKey) ?? [];

    final contacts =
        contactsJson.map((json) => Contact.fromJson(jsonDecode(json))).toList();

    return contacts;
  }

  /// Get a contact by ID
  Future<Contact?> getContactById(String id) async {
    _logger.d('DEBUGGING SESSION: Getting contact by ID: $id');
    final contacts = await getAllContacts();
    _logger.d(
        'DEBUGGING SESSION: Found ${contacts.length} total contacts in storage');

    try {
      final contact = contacts.firstWhere(
        (contact) => contact.id == id,
      );
      _logger.d(
          'DEBUGGING SESSION: Retrieved contact ${id} with metadata: ${contact.metadata}');
      return contact;
    } catch (e) {
      _logger.d('DEBUGGING SESSION: Contact ${id} not found in storage');
      return null;
    }
  }

  // Delete contact
  Future<void> deleteContact(String id) async {
    _logger.d('Deleting contact: $id');
    final prefs = await SharedPreferences.getInstance();
    final contactsJson = prefs.getStringList(_contactsKey) ?? [];

    final updatedContacts = contactsJson.where((json) {
      final contact = Contact.fromJson(jsonDecode(json));
      return contact.id != id;
    }).toList();

    await prefs.setStringList(_contactsKey, updatedContacts);
    _logger.d('Contact deleted successfully');
  }

  // Clear all contacts
  Future<void> clearAllContacts() async {
    _logger.d('Clearing all contacts');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_contactsKey);
    _logger.d('All contacts cleared');
  }
}

class ContactNotFoundException implements Exception {
  final String message;
  ContactNotFoundException(this.message);

  @override
  String toString() => message;
}
