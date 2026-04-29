// ./ui/widgets/qr_scanner_widget.dart

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/theme_provider.dart';
import 'package:provider/provider.dart';

/// Widget for scanning QR codes
class QRScannerWidget extends StatefulWidget {
  final Function(String) onQrScanned;
  final VoidCallback onCancelPressed;

  const QRScannerWidget({
    Key? key,
    required this.onQrScanned,
    required this.onCancelPressed,
  }) : super(key: key);

  @override
  State<QRScannerWidget> createState() => _QRScannerWidgetState();
}

class _QRScannerWidgetState extends State<QRScannerWidget> {
  final MobileScannerController _controller = MobileScannerController();
  bool _hasScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Scan QR Code',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: themeProvider.isDarkMode
                  ? AppColors.lightText
                  : AppColors.darkText,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scan the QR code shown on the other device to connect securely',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: themeProvider.isDarkMode
                  ? AppColors.lightText
                  : AppColors.darkText,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            height: 300,
            clipBehavior: Clip.hardEdge,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: themeProvider.isDarkMode
                      ? AppColors.secondary
                      : AppColors.primary,
                  width: 2),
            ),
            child: MobileScanner(
              controller: _controller,
              onDetect: (capture) {
                if (_hasScanned) return;

                final List<Barcode>? barcodes = capture.barcodes;
                if (barcodes != null &&
                    barcodes.isNotEmpty &&
                    barcodes.first.rawValue != null) {
                  final qrData = barcodes.first.rawValue!;

                  // Set flag to prevent multiple scans
                  setState(() {
                    _hasScanned = true;
                  });

                  // Call callback with scanned data
                  widget.onQrScanned(qrData);
                }
              },
            ),
          ),
          const SizedBox(height: 24),
          // Manual entry option for debugging on simulators
          if (!_hasScanned) ...[
            const Divider(),
            const SizedBox(height: 16),
            Text(
              'Debug Mode: Enter QR data manually',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: themeProvider.isDarkMode
                    ? AppColors.grayText
                    : Colors.grey[700],
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () {
                _showManualEntryDialog(context);
              },
              child: Text(
                'Enter QR Data',
                style: GoogleFonts.inter(),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: widget.onCancelPressed,
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

  /// Show a dialog for manual entry of QR data (for simulator testing)
  void _showManualEntryDialog(BuildContext context) {
    final TextEditingController _textController = TextEditingController();
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Enter QR Data',
            style: GoogleFonts.inter(
              color: themeProvider.isDarkMode
                  ? AppColors.lightText
                  : AppColors.darkText,
            )),
        content: TextField(
          controller: _textController,
          decoration: InputDecoration(
            hintText: 'Paste QR data here',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: GoogleFonts.inter(
                  color: themeProvider.isDarkMode
                      ? AppColors.grayText
                      : Colors.grey[700],
                )),
          ),
          ElevatedButton(
            onPressed: () {
              final data = _textController.text.trim();
              if (data.isNotEmpty) {
                Navigator.pop(context);

                // Set flag to prevent multiple scans
                setState(() {
                  _hasScanned = true;
                });

                // Call callback with manually entered data
                widget.onQrScanned(data);
              }
            },
            child: Text('Connect', style: GoogleFonts.inter()),
          ),
        ],
      ),
    );
  }
}
