import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/printer_settings.dart';
import 'package:modern_offline_pos/hardware/cash_drawer/cash_drawer.dart';
import 'package:modern_offline_pos/hardware/printer/device_transports.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_printer.dart';

class FakeDeviceClient implements DevicePrinterClient {
  String? lastDevice;
  List<int>? lastBytes;
  bool fail = false;
  @override
  Future<List<PrinterDevice>> discover(PrinterConnection connection) async =>
      [const PrinterDevice('id', 'Printer')];
  @override
  Future<void> writeUsb(String name, List<int> bytes) async {
    lastDevice = name;
    lastBytes = bytes;
    if (fail) throw const HardwareException('USB failure');
  }

  @override
  Future<void> writeBluetooth(
      String address, String name, List<int> bytes) async {
    lastDevice = address;
    lastBytes = bytes;
    if (fail) throw const HardwareException('Bluetooth failure');
  }
}

void main() {
  test('LAN sends raw receipt bytes to TCP printer', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<List<int>>();
    final subscription = server.listen((socket) {
      final bytes = <int>[];
      socket.listen(bytes.addAll, onDone: () => received.complete(bytes));
    });
    try {
      final settings =
          PrinterSettings(enabled: true, host: '127.0.0.1', port: server.port);
      await LanEscPosTransport().send([27, 64, 65, 10], settings);
      expect(await received.future.timeout(const Duration(seconds: 3)),
          [27, 64, 65, 10]);
    } finally {
      await subscription.cancel();
      await server.close();
    }
  });

  test(
      'same receipt encoder routes through USB or Bluetooth; drawer follows selection',
      () async {
    final client = FakeDeviceClient();
    final transport = ConfiguredPrinterTransport(
        LanEscPosTransport(),
        UsbEscPosTransport(client, supported: () => true),
        BluetoothEscPosTransport(client, supported: () => true));
    final printer = EscPosReceiptPrinter(transport);
    final drawer = EscPosCashDrawer(transport);
    final receipt = ReceiptDocument('sale', DateTime(2026), 'Cashier', 'Shop',
        [const ReceiptLine('Item', 2, 500, 1000)], 1000, 'cash', 1000);
    final usb = PrinterSettings(
        enabled: true,
        transport: PrinterConnection.usb,
        deviceId: 'USB Printer',
        deviceName: 'USB Printer');
    await printer.print(receipt, usb);
    final usbBytes = List<int>.of(client.lastBytes!);
    expect(client.lastDevice, 'USB Printer');
    expect(usbBytes, EscPosEncoder().encode(receipt, 80));
    final bt = PrinterSettings(
        enabled: true,
        transport: PrinterConnection.bluetooth,
        deviceId: 'AA:BB',
        deviceName: 'BT Printer');
    await printer.print(receipt, bt);
    expect(client.lastDevice, 'AA:BB');
    expect(client.lastBytes, usbBytes);
    await drawer.open(bt);
    expect(client.lastBytes, [27, 112, 0, 25, 250]);
    client.fail = true;
    await expectLater(
        printer.print(receipt, usb), throwsA(isA<HardwareException>()));
    await expectLater(
        printer.print(receipt, bt), throwsA(isA<HardwareException>()));
    await expectLater(drawer.open(bt), throwsA(isA<HardwareException>()));
  });
}
