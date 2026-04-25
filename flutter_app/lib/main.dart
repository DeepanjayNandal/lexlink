import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/session/session_service.dart';
import 'features/session/session_key_service.dart';
import 'features/contacts/contact_service.dart';
import 'features/contacts/contact_repository.dart';
import 'features/contacts/contact_key_service.dart';
import 'core/security/encryption_service.dart';
import 'features/messaging/message_service.dart';
import 'features/messaging/message_purge_service.dart';
import 'ui/screens/landing_page.dart';
import 'ui/screens/role_selection_screen.dart';
import 'ui/theme/theme_provider.dart';
import 'package:provider/provider.dart';
import 'core/service/connection_manager_service.dart';
import 'core/service/global_error_handler.dart';
import 'core/models/user_role.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await SentryFlutter.init(
    (options) {
      options.dsn =
          'https://91442fb0027cb01edb7f98e459894f83@o4509403344142336.ingest.us.sentry.io/4509403361181696';
      options.sendDefaultPii = false;
      options.tracesSampleRate = 1.0;
      options.profilesSampleRate = 1.0;
      options.environment = kDebugMode ? 'development' : 'production';
      options.debug = kDebugMode;
    },
  );

  try {
    await GlobalErrorHandler.instance.initialize();

    final encryptionService = EncryptionService();
    final contactKeyService = ContactKeyService(encryptionService);
    final sessionKeyService = SessionKeyService(encryptionService);
    final contactRepository = ContactRepository();
    final contactService = ContactService(contactRepository, contactKeyService);
    final sessionService = SessionService(contactService);

    final messageService = MessageService();
    final purgeService = MessagePurgeService();

    contactService.setSessionService(sessionService);
    purgeService.setMessageService(messageService);

    await purgeService.initialize();

    if (kDebugMode) {
      await contactRepository.initializeDummyContacts();
    }

    final connectionManager = ConnectionManagerService();
    await connectionManager.initializeServices();

    await sessionService.initializePurgeService();

    final prefs = await SharedPreferences.getInstance();
    final userRoleStr = prefs.getString('user_role');

    final initialScreen = userRoleStr != null
        ? LandingPage(userRole: UserRoleX.fromLegacyString(userRoleStr))
        : const RoleSelectionScreen();

    runApp(
      SentryWidget(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => connectionManager),
            Provider<ContactService>.value(value: contactService),
            Provider<SessionService>.value(value: sessionService),
            Provider<SessionKeyService>.value(value: sessionKeyService),
            Provider<MessageService>.value(value: messageService),
            Provider<MessagePurgeService>.value(value: purgeService),
          ],
          child: MyApp(initialScreen: initialScreen),
        ),
      ),
    );
  } catch (error, stackTrace) {
    GlobalErrorHandler.captureError(error,
        stackTrace: stackTrace, context: 'App initialization');

    runApp(
      SentryWidget(
        child: MaterialApp(
          title: 'LexLink',
          home: Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.error_outline, size: 64, color: Colors.red),
                  SizedBox(height: 16),
                  Text('Initialization failed — please restart the app'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  final Widget initialScreen;

  const MyApp({Key? key, required this.initialScreen}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      title: 'LexLink',
      debugShowCheckedModeBanner: false,
      themeMode: themeProvider.themeMode,
      theme: AppThemes.lightTheme,
      darkTheme: AppThemes.darkTheme,
      home: initialScreen,
    );
  }
}
