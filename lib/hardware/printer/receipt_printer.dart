import 'dart:io';
import 'dart:async';
import '../../core/models/printer_settings.dart';
import 'receipt.dart';

abstract interface class ReceiptPrinter {
  Future<void> print(ReceiptDocument document, PrinterSettings settings);
  Future<void> test(PrinterSettings settings);
}

abstract interface class PrinterTransport {
  Future<void> send(List<int> bytes, PrinterSettings settings);
}

class LanEscPosTransport implements PrinterTransport {
  @override
  Future<void> send(List<int> bytes, PrinterSettings settings) async {
    if (!settings.configured) {
      throw const HardwareException('No printer configured.');
    }
    try {
      final socket = await Socket.connect(settings.host, settings.port,
          timeout: const Duration(seconds: 4));
      try {
        socket.add(bytes);
        await socket.flush().timeout(const Duration(seconds: 5));
      } finally {
        await socket.close();
      }
    } on SocketException {
      throw const HardwareException(
          'Printer connection unavailable. Check its address and connection.');
    } on TimeoutException {
      throw const HardwareException(
          'Printer did not respond. Check its connection.');
    } catch (_) {
      throw const HardwareException(
          'Printer write failed. Check the printer and try reprint.');
    }
  }
}

class HardwareException implements Exception {
  final String message;
  const HardwareException(this.message);
  @override
  String toString() => message;
}

class EscPosReceiptPrinter implements ReceiptPrinter {
  final PrinterTransport transport;
  final EscPosEncoder encoder;
  EscPosReceiptPrinter(this.transport, [EscPosEncoder? encoder])
      : encoder = encoder ?? EscPosEncoder();
  @override
  Future<void> print(ReceiptDocument document, PrinterSettings settings) =>
      transport.send(encoder.encode(document, settings.widthMm), settings);
  @override
  Future<void> test(PrinterSettings settings) => transport.send([
        27,
        64,
        ...'MASD POS\nPrinter test successful\n\n\n'.codeUnits,
        29,
        86,
        0
      ], settings);
}
