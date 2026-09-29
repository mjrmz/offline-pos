import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

enum CameraScanStatus { found, cancelled, denied, unavailable }

class CameraScanResult {
  final CameraScanStatus status;
  final String? barcode;
  const CameraScanResult(this.status, [this.barcode]);
}

abstract interface class CameraBarcodeScanner {
  Future<CameraScanResult> scan(BuildContext context);
}

class MobileCameraBarcodeScanner implements CameraBarcodeScanner {
  @override
  Future<CameraScanResult> scan(BuildContext context) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return const CameraScanResult(CameraScanStatus.unavailable);
    }
    try {
      return await Navigator.of(context).push<CameraScanResult>(
            MaterialPageRoute(builder: (_) => const _CameraScanPage()),
          ) ??
          const CameraScanResult(CameraScanStatus.cancelled);
    } catch (_) {
      return const CameraScanResult(CameraScanStatus.unavailable);
    }
  }
}

class _CameraScanPage extends StatefulWidget {
  const _CameraScanPage();
  @override
  State<_CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<_CameraScanPage> {
  final controller = MobileScannerController();
  bool finished = false;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Scan barcode')),
        body: MobileScanner(
          controller: controller,
          onDetect: (capture) {
            if (finished) return;
            for (final barcode in capture.barcodes) {
              final value = barcode.rawValue?.trim();
              if (value != null && value.isNotEmpty) {
                finished = true;
                Navigator.pop(
                    context, CameraScanResult(CameraScanStatus.found, value));
                return;
              }
            }
          },
          errorBuilder: (context, error) => Center(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error.errorCode == MobileScannerErrorCode.permissionDenied
                  ? 'Camera permission denied. Enable it in device settings or type the barcode.'
                  : 'Camera unavailable. Type the barcode instead.'),
              TextButton(
                  onPressed: () => Navigator.pop(
                      context,
                      CameraScanResult(error.errorCode ==
                              MobileScannerErrorCode.permissionDenied
                          ? CameraScanStatus.denied
                          : CameraScanStatus.unavailable)),
                  child: const Text('Use manual entry')),
            ],
          )),
        ),
      );
}
