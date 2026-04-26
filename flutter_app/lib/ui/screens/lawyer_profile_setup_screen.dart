import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/theme_provider.dart';
import 'landing_page.dart';
import '../../core/models/user_role.dart';

class LawyerProfileSetupScreen extends StatefulWidget {
  const LawyerProfileSetupScreen({Key? key}) : super(key: key);

  @override
  State<LawyerProfileSetupScreen> createState() =>
      _LawyerProfileSetupScreenState();
}

class _LawyerProfileSetupScreenState extends State<LawyerProfileSetupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadExistingName();
  }

  Future<void> _loadExistingName() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingName = prefs.getString('lawyer_name');
      if (existingName != null) {
        setState(() => _nameController.text = existingName);
      }
    } catch (e) {
      debugPrint('Error loading existing lawyer name: $e');
    }
  }

  Future<void> _saveLawyerProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lawyer_name', _nameController.text.trim());

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => LandingPage(userRole: UserRole.initiator),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving profile: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.isDarkMode;
    final accentColor = isDark ? Colors.blue.shade300 : Colors.blue.shade700;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.shield_outlined,
                    size: 48,
                    color: AppColors.secondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'LEXLINK',
                    style: GoogleFonts.inter(
                      fontWeight: FontWeight.bold,
                      fontSize: 28,
                      letterSpacing: 2.0,
                      color: isDark ? Colors.white : const Color(0xFF131720),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.gavel, size: 36, color: accentColor),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Set Up Your Profile',
                    style: GoogleFonts.inter(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your name is shared with clients when they scan your QR code.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppColors.grayText,
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextFormField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: 'Your Full Name',
                      hintText: 'e.g., Jane Smith, Esq.',
                      prefixIcon: Icon(Icons.person, color: accentColor),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: accentColor, width: 2),
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                    textCapitalization: TextCapitalization.words,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter your name';
                      }
                      if (value.trim().length < 2) {
                        return 'Name must be at least 2 characters';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => _saveLawyerProfile(),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _saveLawyerProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : Text(
                              'Continue',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'You can update this later in settings.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: AppColors.grayText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
