import 'package:flutter/material.dart';
import '../theme/theme_provider.dart';
import 'package:provider/provider.dart';
import 'contacts_screen.dart';
import 'role_selection_screen.dart';
import 'dart:math' as math;
import 'package:google_fonts/google_fonts.dart';
import '../../core/service/connection_manager_service.dart';
import '../../features/contacts/contact_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/models/user_role.dart';

class LandingPage extends StatelessWidget {
  final UserRole userRole;

  const LandingPage({
    Key? key,
    required this.userRole,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            if (isDark) ...[
              Positioned(
                top: size.height * 0.1,
                left: size.width * 0.05,
                child: ShapeWidget(
                  size: 15,
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: 'circle',
                ),
              ),
              Positioned(
                top: size.height * 0.2,
                right: size.width * 0.1,
                child: ShapeWidget(
                  size: 20,
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: 'triangle',
                ),
              ),
              Positioned(
                bottom: size.height * 0.3,
                left: size.width * 0.15,
                child: ShapeWidget(
                  size: 25,
                  color: Colors.white.withValues(alpha: 0.15),
                  shape: 'square',
                ),
              ),
            ],
            SingleChildScrollView(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.shield_outlined,
                                size: 20,
                                color: AppColors.secondary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'LEXLINK',
                                style: GoogleFonts.inter(
                                  fontWeight: FontWeight.bold,
                                  fontSize: size.width < 350 ? 18 : 20,
                                  letterSpacing: 1.5,
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF131720),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: userRole == UserRole.initiator
                                      ? Colors.blue.withValues(alpha: 0.15)
                                      : Colors.green.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  userRole.displayName.toUpperCase(),
                                  style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: userRole == UserRole.initiator
                                        ? Colors.blue
                                        : Colors.green,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                isDark ? Icons.light_mode : Icons.dark_mode,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF131720),
                              ),
                              onPressed: themeProvider.toggleTheme,
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.menu,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF131720),
                              ),
                              padding: const EdgeInsets.all(8),
                              constraints: const BoxConstraints(),
                              onPressed: () => _showMenu(context),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 60),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      children: [
                        Text(
                          'Secure.\nPrivate.\nPrivileged.',
                          style: GoogleFonts.inter(
                            fontSize: 44,
                            fontWeight: FontWeight.bold,
                            height: 1.15,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF131720),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'End-to-end encrypted messaging built for attorney-client privilege. No server ever sees your messages.',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w400,
                            height: 1.6,
                            color: AppColors.grayText,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 40),
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    ContactsScreen(userRole: userRole),
                              ),
                            );
                          },
                          icon: const Icon(Icons.lock_outline, size: 18),
                          label: Text(
                            'Connect Securely',
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 60),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : Colors.black.withValues(alpha: 0.08),
                        ),
                      ),
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          _featureTile(
                            icon: Icons.lock_outline,
                            title: 'Zero-knowledge messaging',
                            subtitle:
                                'Messages are encrypted before leaving your device.',
                            isDark: isDark,
                          ),
                          const SizedBox(height: 16),
                          _featureTile(
                            icon: Icons.qr_code_scanner,
                            title: 'QR pairing',
                            subtitle:
                                'Establish sessions out-of-band. No account required.',
                            isDark: isDark,
                          ),
                          const SizedBox(height: 16),
                          _featureTile(
                            icon: Icons.wifi_tethering,
                            title: 'Peer-to-peer transport',
                            subtitle:
                                'WebRTC DataChannel — the signaling server is never in the message path.',
                            isDark: isDark,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 60),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _featureTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppColors.secondary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 20, color: AppColors.secondary),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: isDark ? Colors.white : const Color(0xFF131720),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: AppColors.grayText,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showMenu(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isDark = themeProvider.isDarkMode;
    final textColor = isDark ? Colors.white : const Color(0xFF131720);

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.darkBg : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.message_outlined, color: textColor),
                title: Text('Connect',
                    style: GoogleFonts.inter(color: textColor)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          ContactsScreen(userRole: userRole),
                    ),
                  );
                },
              ),
              ListTile(
                leading: Icon(Icons.swap_horiz, color: textColor),
                title: Text('Switch Role',
                    style: GoogleFonts.inter(color: textColor)),
                onTap: () async {
                  Navigator.pop(context);
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const RoleSelectionScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class ShapeWidget extends StatelessWidget {
  final double size;
  final Color color;
  final String shape;

  const ShapeWidget({
    Key? key,
    required this.size,
    required this.color,
    required this.shape,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: shape == 'circle'
          ? CirclePainter(color)
          : shape == 'triangle'
              ? TrianglePainter(color)
              : SquarePainter(color),
    );
  }
}

class CirclePainter extends CustomPainter {
  final Color color;
  CirclePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      size.width / 2,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class TrianglePainter extends CustomPainter {
  final Color color;
  TrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class SquarePainter extends CustomPainter {
  final Color color;
  SquarePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class SettingsTab extends StatelessWidget {
  const SettingsTab({Key? key}) : super(key: key);

  Future<void> _resetApp(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset App Data'),
        content: const Text(
            'This will delete all sessions, contacts, and encryption keys. This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();

        final contactService =
            Provider.of<ContactService>(context, listen: false);
        final connectionManager =
            Provider.of<ConnectionManagerService>(context, listen: false);

        connectionManager.closeConnection();
        await contactService.initializeDummyContacts();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('App data reset. Restart for full effect.'),
            duration: Duration(seconds: 4),
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error resetting: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            title: const Text('Dark Mode'),
            value: themeProvider.isDarkMode,
            onChanged: (_) => themeProvider.toggleTheme(),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Auto-Delete Messages'),
            subtitle: const Text('Messages deleted after 5 minutes'),
            value: themeProvider.autoDeleteEnabled,
            onChanged: (_) => themeProvider.toggleAutoDelete(),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: ElevatedButton.icon(
              onPressed: () => _resetApp(context),
              icon: const Icon(Icons.restore),
              label: const Text('Reset App Data'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
              ),
            ),
          ),
          const Text(
            'Warning: deletes all contacts, messages, and session data.',
            style: TextStyle(color: Colors.red, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
