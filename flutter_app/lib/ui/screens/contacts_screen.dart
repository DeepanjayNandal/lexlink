// lib/ui/screens/contacts_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'connection_screen.dart';
import 'chat_screen.dart';
import 'role_selection_screen.dart';
import 'package:provider/provider.dart';
import '../../core/service/connection_manager_service.dart';
import '../../features/session/session_service.dart';
import '../../features/contacts/contact_service.dart';
import '../../features/contacts/contact_model.dart';
import 'package:logger/logger.dart';
import '../theme/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/session/session_key_service.dart';
import '../../core/service/navigation_service.dart';
import '../../core/models/user_role.dart';

/// Screen for displaying contacts and initiating secure communications
class ContactsScreen extends StatefulWidget {
  final UserRole userRole;

  const ContactsScreen({
    Key? key,
    required this.userRole,
  }) : super(key: key);

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final _logger = Logger();
  bool _isLoading = true;
  List<Contact> _contacts = [];
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  /// Load contacts and check for existing sessions
  /// Shows different contacts based on user role
  Future<void> _loadContacts() async {
    _logger.d('DEBUGGING SESSION: Loading contacts');
    setState(() {
      _isLoading = true;
    });

    try {
      final contactService =
          Provider.of<ContactService>(context, listen: false);
      final role = widget.userRole == UserRole.initiator ? 'client' : 'lawyer';
      _contacts = await contactService.getContactsByRole(role);
      _logger.d(
          'DEBUGGING SESSION: Loaded ${_contacts.length} contacts from repository');

      // Log all contacts and their metadata
      for (final contact in _contacts) {
        _logger.d(
            'DEBUGGING SESSION: Contact ${contact.id} loaded with metadata: ${contact.metadata}');
      }

      // Check for active sessions - only mark hasSession=true if session is ACTIVE
      final sessionService =
          Provider.of<SessionService>(context, listen: false);

      for (int i = 0; i < _contacts.length; i++) {
        final contact = _contacts[i];

        // DEBUGGING: Log contact metadata before checking session
        _logger.d(
            'DEBUGGING SESSION: Contact ${contact.id} metadata before check: ${contact.metadata}');

        // First check if metadata already indicates a session
        if (contact.metadata.containsKey('hasSession') &&
            contact.metadata['hasSession'] == 'true' &&
            contact.metadata.containsKey('sessionId')) {
          final sessionId = contact.metadata['sessionId'];
          _logger.d(
              'DEBUGGING SESSION: Contact ${contact.id} has sessionId ${sessionId} in metadata');

          // Verify this session exists and belongs to this contact
          final session = await sessionService.getSessionById(sessionId);

          if (session != null && session.contactId == contact.id) {
            _logger.d(
                'DEBUGGING SESSION: Session ${sessionId} exists and belongs to contact ${contact.id}');

            // Keep the existing session info
            continue;
          } else {
            _logger.w(
                'DEBUGGING SESSION: Session ${sessionId} does not exist or does not belong to contact ${contact.id}');
          }
        }

        // If we get here, either there's no session in metadata or it's invalid
        // Try to find an active session for this contact
        final session =
            await sessionService.getActiveSessionForContact(contact.id);

        if (session != null && session.isActive) {
          _logger.d(
              'DEBUGGING SESSION: Found active session ${session.id} for contact ${contact.id}');

          _contacts[i] = contact.copyWith(metadata: {
            ...contact.metadata,
            'hasSession': 'true',
            'sessionId': session.id,
          });

          // Also update in storage to ensure persistence
          await contactService.updateContactWithSessionInfo(
              contact.id, session.id, true);

          _logger.d(
              'DEBUGGING SESSION: Updated contact in storage with session info');
        } else {
          _logger.d(
              'DEBUGGING SESSION: No active session found for contact ${contact.id}');

          // Only clear session info if it's not already set correctly
          if (contact.metadata.containsKey('hasSession') &&
              contact.metadata['hasSession'] == 'true') {
            _logger.d(
                'DEBUGGING SESSION: Clearing incorrect session info for contact ${contact.id}');

            _contacts[i] = contact.copyWith(metadata: {
              ...contact.metadata,
              'hasSession': 'false',
            });

            // Also update in storage
            await contactService.clearContactSessionInfo(contact.id);
          }
        }
      }
    } catch (e) {
      _logger.e('DEBUGGING SESSION: Error loading contacts: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading contacts: $e')),
      );
    }

    setState(() {
      _isLoading = false;
    });
  }

  /// Clear all app data (for testing/debugging)
  Future<void> _clearAllData() async {
    try {
      _logger.d('Clearing all app data');

      // Show confirmation dialog
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clear All Data'),
          content: const Text(
              'This will delete ALL contacts, messages, sessions, and settings. Are you sure?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child:
                  const Text('DELETE ALL', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );

      if (confirmed != true) return;

      // Clear all SharedPreferences data
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      _logger.d('All app data cleared');

      // Immediately refresh UI
      setState(() {
        _contacts = [];
        _searchQuery = '';
      });

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All data cleared successfully'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      _logger.e('Error clearing app data: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error clearing data: $e')),
      );
    }
  }

  Future<void> _addNewContact() async {
    final TextEditingController nameController = TextEditingController();
    final contactService = Provider.of<ContactService>(context, listen: false);
    final role = widget.userRole == UserRole.initiator ? 'client' : 'lawyer';
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Add New ${role.capitalize()}',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'Enter ${role} name',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: themeProvider.isDarkMode
                    ? Colors.white.withOpacity(0.3)
                    : Colors.black.withOpacity(0.1),
              ),
            ),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w500,
                color: AppColors.secondary,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            style: ElevatedButton.styleFrom(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              'Add',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        await contactService.createContact(result, role);
        await _loadContacts();
      } catch (e) {
        _logger.e('Error creating contact: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating contact: $e')),
        );
      }
    }
  }

  List<Contact> get _filteredContacts {
    if (_searchQuery.isEmpty) return _contacts;
    return _contacts
        .where((contact) =>
            contact.name.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.userRole == UserRole.initiator ? 'Clients' : 'Lawyers',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor:
            themeProvider.isDarkMode ? AppColors.darkBg : AppColors.lightBg,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 22),
            onPressed: _loadContacts,
            tooltip: 'Refresh contacts',
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever, size: 22, color: Colors.red),
            onPressed: _clearAllData,
            tooltip: 'Clear all data',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar with minimalist design
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Container(
              decoration: BoxDecoration(
                color: themeProvider.isDarkMode
                    ? const Color(0xFF232730)
                    : const Color(0xFFF3F3F5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: TextField(
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 16,
                    color: themeProvider.isDarkMode
                        ? Colors.white.withOpacity(0.5)
                        : Colors.black.withOpacity(0.5),
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    color: themeProvider.isDarkMode
                        ? Colors.white.withOpacity(0.5)
                        : Colors.black.withOpacity(0.5),
                    size: 22,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                },
              ),
            ),
          ),

          // Divider
          Divider(
            height: 1,
            thickness: 0.5,
            color: themeProvider.isDarkMode
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.05),
          ),

          // Contacts list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredContacts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 60,
                              color: themeProvider.isDarkMode
                                  ? Colors.white.withOpacity(0.3)
                                  : Colors.black.withOpacity(0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No contacts found',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: themeProvider.isDarkMode
                                    ? Colors.white.withOpacity(0.7)
                                    : Colors.black.withOpacity(0.7),
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: _filteredContacts.length,
                        separatorBuilder: (context, index) => Divider(
                          height: 1,
                          thickness: 0.5,
                          indent: 72,
                          color: themeProvider.isDarkMode
                              ? Colors.white.withOpacity(0.1)
                              : Colors.black.withOpacity(0.05),
                        ),
                        itemBuilder: (context, index) {
                          final contact = _filteredContacts[index];
                          final bool hasSession =
                              contact.metadata['hasSession'] == 'true';

                          return ListTile(
                            leading: Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: hasSession
                                    ? AppColors.secondary.withOpacity(0.9)
                                    : themeProvider.isDarkMode
                                        ? Colors.white.withOpacity(0.1)
                                        : Colors.black.withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: Text(
                                  contact.name.isNotEmpty
                                      ? contact.name[0].toUpperCase()
                                      : '?',
                                  style: GoogleFonts.inter(
                                    color: hasSession
                                        ? Colors.white
                                        : themeProvider.isDarkMode
                                            ? Colors.white.withOpacity(0.8)
                                            : Colors.black.withOpacity(0.8),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                            ),
                            title: Text(
                              contact.name,
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                              ),
                            ),
                            subtitle: Text(
                              hasSession
                                  ? 'Secure session established'
                                  : 'Tap to establish secure connection',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: hasSession
                                    ? AppColors.secondary
                                    : themeProvider.isDarkMode
                                        ? Colors.white.withOpacity(0.5)
                                        : Colors.black.withOpacity(0.5),
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Delete button
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                    color: themeProvider.isDarkMode
                                        ? Colors.white.withOpacity(0.5)
                                        : Colors.black.withOpacity(0.5),
                                  ),
                                  onPressed: () =>
                                      _confirmDeleteContact(contact),
                                  tooltip: 'Delete contact',
                                ),
                                // Arrow or wifi icon
                                Icon(
                                  hasSession
                                      ? Icons.arrow_forward_ios
                                      : Icons.wifi_tethering,
                                  size: hasSession ? 16 : 20,
                                  color: hasSession
                                      ? AppColors.secondary
                                      : themeProvider.isDarkMode
                                          ? Colors.white.withOpacity(0.5)
                                          : Colors.black.withOpacity(0.5),
                                ),
                              ],
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            onTap: () => _connectToContact(contact),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addNewContact,
        backgroundColor: AppColors.secondary,
        elevation: 2,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  // Flag to prevent multiple navigation attempts while connecting
  bool _isNavigating = false;

  /// Connect to a contact, either using existing session or creating a new one
  /// If a session exists, goes directly to chat screen
  /// If no session exists, goes to connection screen
  Future<void> _connectToContact(Contact contact) async {
    NavigationService.navigateToChatScreen(
      context,
      contact.id,
      contact.name,
      widget.userRole,
    );
  }

  // Method to delete a contact and refresh the UI
  Future<void> _deleteContact(String contactId) async {
    try {
      setState(() {
        _isLoading = true;
      });

      final contactService =
          Provider.of<ContactService>(context, listen: false);
      await contactService.deleteContact(contactId);

      // Remove the contact from the local list to update UI immediately
      setState(() {
        _contacts.removeWhere((contact) => contact.id == contactId);
        _isLoading = false;
      });

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Contact deleted successfully'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      _logger.e('Error deleting contact: $e');
      setState(() {
        _isLoading = false;
      });

      // Show error message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error deleting contact: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Method to ask for confirmation before deleting a contact
  void _confirmDeleteContact(Contact contact) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Delete Contact',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'Are you sure you want to delete ${contact.name}?',
            style: GoogleFonts.inter(),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: GoogleFonts.inter(
                  color: AppColors.secondary,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _deleteContact(contact.id);
              },
              child: Text(
                'Delete',
                style: GoogleFonts.inter(
                  color: Colors.red,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}
