// lib/ui/screens/chat_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/p2p/signaling_service.dart';
import '../../core/service/connection_manager_service.dart';
import '../../features/messaging/message_model.dart';
import '../../features/messaging/message_service.dart';
import '../../features/contacts/contact_service.dart';
import '../../features/contacts/contact_model.dart';
import '../../features/session/session_service.dart';
import 'package:logger/logger.dart';
import '../../features/messaging/message_purge_service.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/theme_provider.dart';
import 'package:intl/intl.dart';

class ChatScreen extends StatefulWidget {
  final String contactId;
  final String contactName;

  const ChatScreen({
    Key? key,
    required this.contactId,
    required this.contactName,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  // Message controller
  final TextEditingController _messageController = TextEditingController();
  List<Message> _messages = [];
  bool _isLoading = true;
  final _logger = Logger();
  StreamSubscription? _messageSubscription;
  StreamSubscription<bool>? _connectionSub;
  bool _isConnected = false;
  Contact? _contact;
  final ScrollController _scrollController = ScrollController();

  // Services
  late ConnectionManagerService _connectionManager;
  late MessageService _messageService;
  late MessagePurgeService _purgeService;
  bool _isPurgeEnabled = false;

  @override
  void initState() {
    super.initState();

    // Get services from provider
    _connectionManager =
        Provider.of<ConnectionManagerService>(context, listen: false);
    _messageService = Provider.of<MessageService>(context, listen: false);
    _purgeService = Provider.of<MessagePurgeService>(context, listen: false);

    // Load existing messages
    _loadContactAndMessages();
    _loadPurgeSetting();

    // Set up listeners for incoming messages
    if (_connectionManager.p2pMessageService != null) {
      _logger.d(
          'Setting up message stream subscription for contact ${widget.contactId}');
      _messageSubscription = _connectionManager
          .p2pMessageService!.onMessageReceived
          .listen(_handleIncomingMessage);
    } else {
      _logger.w(
          'P2P message service not available, no message subscription set up');
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final signaling = context.read<SignalingService>();
      // Connect to signaling service if not already connected
      if (!signaling.isConnected &&
          _connectionManager.currentSessionId != null) {
        // Use a default server URL and generate a peer ID if needed
        signaling.connect("wss://signaling.lexlink.app",
            "client_${DateTime.now().millisecondsSinceEpoch}");
      }
      _connectionSub = signaling.onConnectionStateChanged.listen((connected) {
        if (!mounted) return;
        setState(() => _isConnected = connected);
      });
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _connectionSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadContactAndMessages() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Load contact details
      final contactService =
          Provider.of<ContactService>(context, listen: false);
      _contact = await contactService.getContact(widget.contactId);

      // Load messages
      if (_connectionManager.currentSessionId != null) {
        final messages = await _messageService.getMessagesForContact(
          widget.contactId,
          _connectionManager.currentSessionId,
        );

        _logger.d(
            'Loaded ${messages.length} messages from storage for contact ${widget.contactId}');

        setState(() {
          _messages.clear();
          _messages.addAll(messages);
        });

        // Scroll to bottom after messages load
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
      } else {
        _logger.w('No current session ID available for loading messages');
      }
    } catch (e) {
      _logger.e('Error loading contact or messages: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading chat: $e')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _loadPurgeSetting() async {
    setState(() {
      _isPurgeEnabled = _purgeService.getPurgeSetting(widget.contactId);
    });
  }

  Future<void> _togglePurgeSetting(bool value) async {
    await _purgeService.setPurgeSetting(widget.contactId, value);
    setState(() {
      _isPurgeEnabled = value;
    });
  }

  // Handle incoming message from WebRTC
  void _handleIncomingMessage(Message message) async {
    try {
      // ✅ REMOVED: Don't save message here - P2P message service already saves it
      // The P2P message service handles saving incoming messages to storage
      // await _messageService.saveMessage(message, _connectionManager.currentSessionId!);

      // ✅ Prevent duplicate messages by checking if message ID already exists
      final existingMessageIndex =
          _messages.indexWhere((msg) => msg.id == message.id);
      if (existingMessageIndex != -1) {
        _logger.d(
            'Message ${message.id} already exists in UI, skipping duplicate');
        return;
      }

      // Only update UI if the widget is still mounted
      if (mounted) {
        setState(() {
          _messages.add(message);
        });
        // Scroll to bottom when new message arrives
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });
      } else {
        _logger.d('Widget no longer mounted, skipping UI update for message');
      }
    } catch (e) {
      debugPrint('Error processing incoming message: $e');
    }
  }

  // Send a message
  Future<void> _sendMessage(String text) async {
    final trimmedText = text.trim();
    if (trimmedText.isEmpty) return;

    final signalingService =
        Provider.of<SignalingService>(context, listen: false);

    // Create message object
    final message = Message(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      contactId: widget.contactId,
      text: trimmedText,
      isSent: true,
      timestamp: DateTime.now(),
    );

    // Add to local messages list
    setState(() {
      _messages.add(message);
    });

    // Clear input field
    _messageController.clear();

    // Save message and attempt to send
    if (_connectionManager.currentSessionId != null) {
      await _messageService.saveMessage(
          message, _connectionManager.currentSessionId!);
    }

    // Show offline notification if needed
    if (!signalingService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Queued — will send when online'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteContact() async {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Delete Contact',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
          ),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        content: Text(
          'Are you sure you want to delete this contact? This will also delete all messages.',
          style: GoogleFonts.inter(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w500,
                color: AppColors.secondary,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              foregroundColor: Colors.white,
              backgroundColor: Colors.red.shade700,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              'Delete',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final contactService =
            Provider.of<ContactService>(context, listen: false);
        final sessionService =
            Provider.of<SessionService>(context, listen: false);

        // Delete contact
        await contactService.deleteContact(widget.contactId);

        // Delete associated session if exists
        if (_connectionManager.currentSessionId != null) {
          await sessionService
              .deleteSession(_connectionManager.currentSessionId!);
        }

        // Close connection
        await _connectionManager.closeConnection();

        if (mounted) {
          Navigator.pop(context);
        }
      } catch (e) {
        _logger.e('Error deleting contact: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting contact: $e')),
        );
      }
    }
  }

  Future<void> _editContact() async {
    final TextEditingController nameController =
        TextEditingController(text: _contact?.name);
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Edit Contact',
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
          ),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        content: TextField(
          controller: nameController,
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'Enter contact name',
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
              'Save',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty && _contact != null) {
      try {
        final contactService =
            Provider.of<ContactService>(context, listen: false);

        // Create updated contact with new name
        final updatedContact = _contact!.copyWith(name: result);

        // Update the contact
        await contactService.updateContact(updatedContact);

        // Refresh contact
        _contact = await contactService.getContact(widget.contactId);
        setState(() {});
      } catch (e) {
        _logger.e('Error updating contact: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating contact: $e')),
        );
      }
    }
  }

  // Group messages by date
  Map<String, List<Message>> _getGroupedMessages() {
    final Map<String, List<Message>> grouped = {};

    for (final message in _messages) {
      final date = DateFormat('yyyy-MM-dd').format(message.timestamp);
      if (!grouped.containsKey(date)) {
        grouped[date] = [];
      }
      grouped[date]!.add(message);
    }

    return grouped;
  }

  // Format date header
  String _formatDateHeader(String dateString) {
    final date = DateTime.parse(dateString);
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));

    if (DateFormat('yyyy-MM-dd').format(now) == dateString) {
      return 'Today';
    } else if (DateFormat('yyyy-MM-dd').format(yesterday) == dateString) {
      return 'Yesterday';
    } else {
      return DateFormat('MMMM d, yyyy').format(date);
    }
  }

  Widget _buildStatusBanner() {
    if (!_isConnected) {
      return Container(
        color: Colors.amber.shade100,
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        child: const Text('Connecting...',
            style: TextStyle(fontSize: 12), textAlign: TextAlign.center),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final groupedMessages = _getGroupedMessages();
    final dateKeys = groupedMessages.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.secondary.withOpacity(0.9),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  widget.contactName.isNotEmpty
                      ? widget.contactName[0].toUpperCase()
                      : '?',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.contactName,
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _connectionManager.isConnected
                        ? 'Connected'
                        : 'Connecting...',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: _connectionManager.isConnected
                          ? AppColors.secondary
                          : themeProvider.isDarkMode
                              ? Colors.white.withOpacity(0.5)
                              : Colors.black.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor:
            themeProvider.isDarkMode ? AppColors.darkBg : AppColors.lightBg,
        actions: [
          PopupMenuButton<String>(
            icon: Icon(
              Icons.more_vert,
              color: themeProvider.isDarkMode ? Colors.white : Colors.black,
            ),
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  _editContact();
                  break;
                case 'delete':
                  _deleteContact();
                  break;
                case 'toggle_purge':
                  _togglePurgeSetting(!_isPurgeEnabled);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(
                      Icons.edit,
                      color: themeProvider.isDarkMode
                          ? Colors.white
                          : Colors.black,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text('Edit', style: GoogleFonts.inter()),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'toggle_purge',
                child: Row(
                  children: [
                    Icon(
                      _isPurgeEnabled ? Icons.visibility_off : Icons.visibility,
                      color: themeProvider.isDarkMode
                          ? Colors.white
                          : Colors.black,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isPurgeEnabled
                          ? 'Disable Auto-Delete'
                          : 'Enable Auto-Delete',
                      style: GoogleFonts.inter(),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    const Icon(
                      Icons.delete,
                      color: Colors.red,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Delete',
                      style: GoogleFonts.inter(
                        color: Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBanner(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.message_outlined,
                              size: 60,
                              color: themeProvider.isDarkMode
                                  ? Colors.white.withOpacity(0.3)
                                  : Colors.black.withOpacity(0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No messages yet',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: themeProvider.isDarkMode
                                    ? Colors.white.withOpacity(0.7)
                                    : Colors.black.withOpacity(0.7),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Send a message to start the conversation',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: themeProvider.isDarkMode
                                    ? Colors.white.withOpacity(0.5)
                                    : Colors.black.withOpacity(0.5),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        itemCount: dateKeys.length,
                        itemBuilder: (context, dateIndex) {
                          final date = dateKeys[dateIndex];
                          final messagesForDate = groupedMessages[date]!;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Date header
                              Center(
                                child: Container(
                                  margin:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: themeProvider.isDarkMode
                                        ? Colors.white.withOpacity(0.1)
                                        : Colors.black.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    _formatDateHeader(date),
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: themeProvider.isDarkMode
                                          ? Colors.white.withOpacity(0.7)
                                          : Colors.black.withOpacity(0.7),
                                    ),
                                  ),
                                ),
                              ),

                              // Messages for this date
                              ...messagesForDate.asMap().entries.map((entry) {
                                final index = entry.key;
                                final message = entry.value;
                                final isSent = message.isSent;
                                final isConsecutive = index > 0 &&
                                    messagesForDate[index - 1].isSent ==
                                        message.isSent;

                                return Padding(
                                  padding: EdgeInsets.only(
                                    bottom: 6,
                                    top: isConsecutive ? 0 : 8,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: isSent
                                        ? MainAxisAlignment.end
                                        : MainAxisAlignment.start,
                                    crossAxisAlignment: CrossAxisAlignment
                                        .end, // Align to bottom for timestamp
                                    children: [
                                      if (!isSent)
                                        Container(
                                          width: 26,
                                          height: 26,
                                          margin:
                                              const EdgeInsets.only(right: 8),
                                          decoration: BoxDecoration(
                                            color: isConsecutive
                                                ? Colors.transparent
                                                : themeProvider.isDarkMode
                                                    ? Colors.white
                                                        .withOpacity(0.1)
                                                    : Colors.grey
                                                        .withOpacity(0.2),
                                            shape: BoxShape.circle,
                                          ),
                                          child: isConsecutive
                                              ? null
                                              : Center(
                                                  child: Text(
                                                    widget.contactName
                                                            .isNotEmpty
                                                        ? widget.contactName[0]
                                                            .toUpperCase()
                                                        : '?',
                                                    style: GoogleFonts.inter(
                                                      color: themeProvider
                                                              .isDarkMode
                                                          ? Colors.white
                                                          : Colors.black,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                        ),

                                      // Message bubble
                                      Flexible(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isSent
                                                ? AppColors.secondary
                                                : themeProvider.isDarkMode
                                                    ? Colors.white
                                                        .withOpacity(0.1)
                                                    : Colors.grey
                                                        .withOpacity(0.1),
                                            borderRadius: BorderRadius.only(
                                              topLeft: Radius.circular(
                                                  isSent || isConsecutive
                                                      ? 18
                                                      : 4),
                                              topRight: Radius.circular(
                                                  !isSent || isConsecutive
                                                      ? 18
                                                      : 4),
                                              bottomLeft:
                                                  const Radius.circular(18),
                                              bottomRight:
                                                  const Radius.circular(18),
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                message.text,
                                                style: GoogleFonts.inter(
                                                  color: isSent
                                                      ? Colors.white
                                                      : themeProvider.isDarkMode
                                                          ? Colors.white
                                                          : Colors.black,
                                                  fontSize: 15,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                DateFormat('h:mm a')
                                                    .format(message.timestamp),
                                                style: GoogleFonts.inter(
                                                  color: isSent
                                                      ? Colors.white
                                                          .withOpacity(0.7)
                                                      : themeProvider.isDarkMode
                                                          ? Colors.white
                                                              .withOpacity(0.5)
                                                          : Colors.black
                                                              .withOpacity(0.5),
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),

                                      // Show profile picture for sent messages
                                      if (isSent)
                                        Container(
                                          width: 26,
                                          height: 26,
                                          margin:
                                              const EdgeInsets.only(left: 8),
                                          decoration: BoxDecoration(
                                            color: isConsecutive
                                                ? Colors.transparent
                                                : AppColors.primary
                                                    .withOpacity(0.9),
                                            shape: BoxShape.circle,
                                          ),
                                          child: isConsecutive
                                              ? null
                                              : const Center(
                                                  child: Icon(
                                                    Icons.person,
                                                    color: Colors.white,
                                                    size: 16,
                                                  ),
                                                ),
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ],
                          );
                        },
                      ),
          ),

          // Message input
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: themeProvider.isDarkMode
                  ? Colors.black.withOpacity(0.3)
                  : Colors.grey.withOpacity(0.1),
              border: Border(
                top: BorderSide(
                  color: themeProvider.isDarkMode
                      ? Colors.white.withOpacity(0.1)
                      : Colors.black.withOpacity(0.1),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: themeProvider.isDarkMode
                          ? Colors.white.withOpacity(0.1)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: themeProvider.isDarkMode
                            ? Colors.white.withOpacity(0.1)
                            : Colors.grey.withOpacity(0.3),
                        width: 0.5,
                      ),
                    ),
                    child: TextField(
                      controller: _messageController,
                      maxLines: 5,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Message',
                        hintStyle: GoogleFonts.inter(
                          color: themeProvider.isDarkMode
                              ? Colors.white.withOpacity(0.5)
                              : Colors.black.withOpacity(0.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: AppColors.secondary,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: () => _sendMessage(_messageController.text),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
