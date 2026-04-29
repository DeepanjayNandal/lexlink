import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../features/session/session_service.dart';
import '../../features/session/session_key_service.dart';
import '../../ui/screens/chat_screen.dart';
import '../../ui/screens/connection_screen.dart';
import '../models/user_role.dart';
import 'global_error_handler.dart';

class NavigationService {
  static final Set<String> _activeNavigations = {};

  static Future<bool> canNavigateToChat(
      BuildContext context, String contactId) async {
    GlobalErrorHandler.logDebug(
        'NAVIGATION: Checking chat navigation eligibility',
        data: {
          'contact_id': contactId,
        });

    final sessionService = context.read<SessionService>();
    final keyService = context.read<SessionKeyService>();
    final session = await sessionService.getActiveSessionForContact(contactId);

    GlobalErrorHandler.logDebug('NAVIGATION: Session lookup result', data: {
      'contact_id': contactId,
      'session_id': session?.id,
      'has_session': session != null,
    });

    if (session == null) {
      GlobalErrorHandler.logDebug(
          'NAVIGATION: No active session - cannot navigate to chat',
          data: {
            'contact_id': contactId,
          });
      return false;
    }

    final hasKeys = await keyService.hasKeyForSession(session.id);

    GlobalErrorHandler.logDebug('NAVIGATION: Key validation result', data: {
      'contact_id': contactId,
      'session_id': session.id,
      'has_keys': hasKeys,
    });

    return hasKeys;
  }

  static Future<void> navigateToChatScreen(
    BuildContext context,
    String contactId,
    String contactName,
    UserRole userRole,
  ) async {
    GlobalErrorHandler.logInfo('NAVIGATION: Chat screen navigation requested',
        data: {
          'contact_id': contactId,
          'contact_name': contactName,
          'user_role': userRole.asString,
        });

    if (_activeNavigations.contains(contactId)) {
      GlobalErrorHandler.logWarning(
          'NAVIGATION: Navigation already in progress',
          data: {
            'contact_id': contactId,
          });
      return;
    }

    _activeNavigations.add(contactId);
    try {
      final allowed = await canNavigateToChat(context, contactId);

      GlobalErrorHandler.logInfo('NAVIGATION: Navigation decision made', data: {
        'contact_id': contactId,
        'can_navigate_to_chat': allowed,
        'destination': allowed ? 'ChatScreen' : 'ConnectionScreen',
      });

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => allowed
              ? ChatScreen(contactId: contactId, contactName: contactName)
              : ConnectionScreen(
                  contactId: contactId,
                  contactName: contactName,
                  userRole: userRole),
        ),
      );

      GlobalErrorHandler.logInfo('NAVIGATION: Navigation completed', data: {
        'contact_id': contactId,
      });
    } finally {
      _activeNavigations.remove(contactId);
    }
  }
}
