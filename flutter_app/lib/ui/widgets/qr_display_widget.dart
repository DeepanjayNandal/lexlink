// lib/ui/widgets/qr_display_widget.dart

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../features/p2p/qr_connection_service.dart';

/// Widget for displaying a QR code for connection
class QRDisplayWidget extends StatelessWidget {
  final ConnectionInfo connectionInfo;
  final VoidCallback onCancelPressed;

  const QRDisplayWidget({
    Key? key,
    required this.connectionInfo,
    required this.onCancelPressed,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Convert connection info to QR string
    final qrData = connectionInfo.toQrString();

    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Scan this QR code',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Have the other device scan this QR code to establish a secure connection',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          QrImageView(
            data: qrData,
            version: QrVersions.auto,
            size: 200,
            backgroundColor: Colors.white,
          ),
          const SizedBox(height: 16),
          // Verification code display
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Verification: ${connectionInfo.verificationCode}',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: onCancelPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.inter(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
