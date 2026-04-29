// lib/ui/theme/theme_provider.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';

class ThemeProvider extends ChangeNotifier {
  ThemeMode themeMode = ThemeMode.light;
  bool get isDarkMode => themeMode == ThemeMode.dark;

  // Auto-delete messages flag
  bool _autoDeleteEnabled = true;
  bool get autoDeleteEnabled => _autoDeleteEnabled;

  ThemeProvider() {
    _loadTheme();
    _loadAutoDeleteSetting();
  }

  void toggleTheme() {
    themeMode = isDarkMode ? ThemeMode.light : ThemeMode.dark;
    _saveTheme();
    notifyListeners();
  }

  void toggleAutoDelete() {
    _autoDeleteEnabled = !_autoDeleteEnabled;
    _saveAutoDeleteSetting();
    notifyListeners();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('isDarkMode') ?? false;
    themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  Future<void> _saveTheme() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool('isDarkMode', isDarkMode);
  }

  Future<void> _loadAutoDeleteSetting() async {
    final prefs = await SharedPreferences.getInstance();
    _autoDeleteEnabled = prefs.getBool('autoDeleteEnabled') ?? true;
    notifyListeners();
  }

  Future<void> _saveAutoDeleteSetting() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setBool('autoDeleteEnabled', _autoDeleteEnabled);
  }
}

class AppColors {
  // Colors from the CSS variables
  static const Color primary = Color(0xFFFC4746); // --primary
  static const Color secondary = Color(0xFF1EA7F3); // --secondary
  static const Color darkBg = Color(0xFF131720); // --dark-bg
  static const Color lightText = Color(0xFFFFFFFF); // --light-text
  static const Color grayText = Color(0xFFAFAFAF); // --gray-text

  // Light theme specifics
  static const Color lightBg = Color(0xFFFFFFFF); // .light background
  static const Color darkText = Color(0xFF000000); // .light color
}

class AppThemes {
  static final lightTheme = ThemeData(
    brightness: Brightness.light,
    primaryColor: AppColors.secondary,
    scaffoldBackgroundColor: AppColors.lightBg,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.secondary,
      elevation: 0,
      iconTheme: const IconThemeData(color: AppColors.lightText),
      titleTextStyle: GoogleFonts.inter(
        color: AppColors.lightText,
        fontWeight: FontWeight.bold,
        fontSize: 20,
      ),
    ),
    colorScheme: const ColorScheme.light().copyWith(
      primary: AppColors.secondary,
      secondary: AppColors.primary,
      onPrimary: AppColors.lightText,
      onSecondary: AppColors.lightText,
    ),
    textTheme: TextTheme(
      headlineLarge: GoogleFonts.inter(
        color: AppColors.darkText,
        fontWeight: FontWeight.bold,
        fontSize: 44,
        letterSpacing: 0.2,
      ),
      headlineMedium: GoogleFonts.inter(
        color: AppColors.darkText,
        fontWeight: FontWeight.bold,
        fontSize: 32,
        letterSpacing: 0.2,
      ),
      bodyLarge: GoogleFonts.inter(
        color: AppColors.darkText,
        fontWeight: FontWeight.w700,
        fontSize: 20,
        letterSpacing: 0.2,
      ),
      bodyMedium: GoogleFonts.inter(
        color: AppColors.darkText,
        fontSize: 16,
        letterSpacing: 0.2,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.secondary,
        foregroundColor: AppColors.lightText,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: GoogleFonts.inter(
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.darkText,
        side: BorderSide(color: AppColors.darkText),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: GoogleFonts.inter(
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFEFEFEF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFD0D0D0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFD0D0D0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.secondary),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      hintStyle: GoogleFonts.inter(
        color: AppColors.grayText,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  static final darkTheme = ThemeData(
    brightness: Brightness.dark,
    primaryColor: AppColors.secondary,
    scaffoldBackgroundColor: AppColors.darkBg,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.darkBg,
      elevation: 0,
      iconTheme: const IconThemeData(color: AppColors.lightText),
      titleTextStyle: GoogleFonts.inter(
        color: AppColors.lightText,
        fontWeight: FontWeight.bold,
        fontSize: 20,
      ),
    ),
    colorScheme: const ColorScheme.dark().copyWith(
      primary: AppColors.primary,
      secondary: AppColors.secondary,
      onPrimary: AppColors.lightText,
      onSecondary: AppColors.lightText,
      surface: AppColors.darkBg,
      background: AppColors.darkBg,
    ),
    textTheme: TextTheme(
      headlineLarge: GoogleFonts.inter(
        color: AppColors.lightText,
        fontWeight: FontWeight.bold,
        fontSize: 44,
        letterSpacing: 0.2,
      ),
      headlineMedium: GoogleFonts.inter(
        color: AppColors.lightText,
        fontWeight: FontWeight.bold,
        fontSize: 32,
        letterSpacing: 0.2,
      ),
      bodyLarge: GoogleFonts.inter(
        color: AppColors.lightText,
        fontWeight: FontWeight.w700,
        fontSize: 20,
        letterSpacing: 0.2,
      ),
      bodyMedium: GoogleFonts.inter(
        color: AppColors.lightText,
        fontSize: 16,
        letterSpacing: 0.2,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.secondary,
        foregroundColor: AppColors.lightText,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: GoogleFonts.inter(
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.lightText,
        side: const BorderSide(color: AppColors.lightText),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: GoogleFonts.inter(
          fontWeight: FontWeight.bold,
          fontSize: 18,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF232730),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: AppColors.grayText),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: AppColors.grayText),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppColors.secondary),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      hintStyle: GoogleFonts.inter(
        color: AppColors.grayText,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}
