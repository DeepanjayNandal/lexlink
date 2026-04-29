import 'dart:io';
import 'package:flutter/foundation.dart';

/// Debug overlay utilities for the app
class DebugOverlay {
  /// Singleton instance
  static final DebugOverlay _instance = DebugOverlay._internal();
  factory DebugOverlay() => _instance;
  DebugOverlay._internal();

  /// Determine if the app is running on a physical device
  /// This is used for environment-specific configurations
  static bool get isPhysicalDevice {
    if (kIsWeb) return false;

    // Use a heuristic approach to detect simulators/emulators
    if (Platform.isAndroid) {
      // On Android, check device model for emulator indicators
      String androidModel = Platform.operatingSystemVersion.toLowerCase();
      return !(androidModel.contains('sdk') ||
          androidModel.contains('emulator') ||
          androidModel.contains('android studio'));
    } else if (Platform.isIOS) {
      // On iOS, check for simulator indicators
      // This is a best-effort approach
      return !(Platform.operatingSystemVersion
          .toLowerCase()
          .contains('simulator'));
    }

    // Default to assuming it's a physical device
    return true;
  }

  /// Log device information for debugging
  static void logDeviceInfo() {
    print('🔧 DEBUG: Device Information');
    print(
        '🔧 Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    print('🔧 Is Physical Device: $isPhysicalDevice');
    print('🔧 Is Web: $kIsWeb');
  }
}
