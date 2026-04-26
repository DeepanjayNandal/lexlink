import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/theme_provider.dart';
import 'landing_page.dart';
import '../../core/models/user_role.dart';
import '../../core/service/global_error_handler.dart';

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 56,
                  color: AppColors.secondary,
                ),
                const SizedBox(height: 16),
                Text(
                  'LEXLINK',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.bold,
                    fontSize: 32,
                    letterSpacing: 2.0,
                    color: isDark ? Colors.white : const Color(0xFF131720),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'E2E Encrypted Legal Messaging',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.grayText,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 40),
                Text(
                  'Select your role',
                  style: GoogleFonts.inter(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF131720),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your role determines how you connect. You can change this later from settings.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: AppColors.grayText,
                  ),
                ),
                const SizedBox(height: 40),
                _buildRoleButton(
                  context: context,
                  icon: Icons.gavel,
                  title: 'Lawyer',
                  description: 'Generate QR codes and initiate secure sessions',
                  role: UserRole.initiator,
                  color: isDark ? Colors.blue.shade300 : Colors.blue.shade700,
                ),
                const SizedBox(height: 20),
                _buildRoleButton(
                  context: context,
                  icon: Icons.person_outline,
                  title: 'Client',
                  description: 'Scan a QR code to join a secure session',
                  role: UserRole.responder,
                  color: isDark ? Colors.green.shade300 : Colors.green.shade700,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoleButton({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String description,
    required UserRole role,
    required Color color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _selectRole(context, role),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            border: Border.all(color: color, width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 28, color: color),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: GoogleFonts.inter(fontSize: 13),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: color.withValues(alpha: 0.6)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _selectRole(BuildContext context, UserRole role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_role', role.asString);

    GlobalErrorHandler.logInfo('User role selected',
        data: {'role': role.asString});

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => LandingPage(userRole: role),
      ),
    );
  }
}
