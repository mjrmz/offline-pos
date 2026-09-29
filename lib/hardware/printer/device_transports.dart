import 'dart:io';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart' as plugin;
import '../../core/models/printer_settings.dart';
import 'receipt_printer.dart';

class PrinterDevice {
  final String id;
  final String name;
  const PrinterDevice(this.id, this.name);
}

abstract interface class DevicePrinterClient {
  Future<List<PrinterDevice>> discover(PrinterConnection connection);
  Future<void> writeUsb(String name, List<int> bytes);
  Future<void> writeBluetooth(String address, String name, List<int> bytes);
}

class PluginPrinterClient implements DevicePrinterClient {
  final plugin.ThermalPrinterFlutter pluginInstance;
  final MethodChannel channel;
  PluginPrinterClient(
      {plugin.ThermalPrinterFlutter? pluginInstance, MethodChannel? channel})
      : pluginInstance = pluginInstance ?? plugin.ThermalPrinterFlutter(),
        channel = channel ?? const MethodChannel('thermal_printer_flutter');

  @override
  Future<List<PrinterDevice>> discover(PrinterConnection connection) async {
    try {
      if (connection == PrinterConnection.usb && !Platform.isWindows) {
        throw const HardwareException(
            'USB printer is unsupported on this platform.');
      }
      if (connection == PrinterConnection.bluetooth && !Platform.isAndroid) {
        throw const HardwareException(
            'Bluetooth printer is unsupported on this platform.');
      }
      if (connection == PrinterConnection.bluetooth && Platform.isAndroid) {
        if (!await pluginInstance.checkBluetoothPermissions()) {
          throw const HardwareException(
              'Bluetooth permission denied. Allow it in device settings.');
        }
        if (!await pluginInstance.isBluetoothEnabled()) {
          throw const HardwareException(
              'Turn on Bluetooth before searching for printers.');
        }
      }
      final devices = await pluginInstance.getPrinters(
          printerType: connection == PrinterConnection.usb
              ? plugin.PrinterType.usb
              : plugin.PrinterType.bluetooth);
      return [
        for (final d in devices)
          if (d.name.isNotEmpty &&
              (connection == PrinterConnection.usb || d.bleAddress.isNotEmpty))
            PrinterDevice(
                connection == PrinterConnection.usb ? d.name : d.bleAddress,
                d.name)
      ];
    } on HardwareException {
      rethrow;
    } catch (_) {
      throw const HardwareException(
          'Could not discover printers. Check connection and permissions.');
    }
  }

  @override
  Future<void> writeUsb(String name, List<int> bytes) async {
    try {
      // The plugin's USB facade logs a false native write result. Inspect it here.
      final written = await channel.invokeMethod<bool>('writebytes', {
        'bytes': Uint8List.fromList(bytes),
        'printerName': name,
      });
      if (written != true) {
        throw const HardwareException(
            'USB printer write failed. Check printer and driver.');
      }
    } on HardwareException {
      rethrow;
    } catch (_) {
      throw const HardwareException(
          'USB printer unavailable. Check printer and driver.');
    }
  }

  @override
  Future<void> writeBluetooth(
      String address, String name, List<int> bytes) async {
    final target = plugin.Printer(
        type: plugin.PrinterType.bluetooth, name: name, bleAddress: address);
    try {
      if (!await pluginInstance.checkBluetoothPermissions()) {
        throw const HardwareException(
            'Bluetooth permission denied. Allow it in device settings.');
      }
      if (!await pluginInstance.isBluetoothEnabled()) {
        throw const HardwareException(
            'Turn on Bluetooth and reconnect the printer.');
      }
      if (!await pluginInstance.connect(printer: target)) {
        throw const HardwareException(
            'Bluetooth printer connection failed. Re-pair and try again.');
      }
      await pluginInstance.printBytes(bytes: bytes, printer: target);
    } on HardwareException {
      rethrow;
    } catch (_) {
      throw const HardwareException(
          'Bluetooth printer write failed. Reconnect and try again.');
    } finally {
      await pluginInstance.disconnect(printer: target);
    }
  }
}

class UsbEscPosTransport implements PrinterTransport {
  final DevicePrinterClient client;
  final bool Function() supported;
  UsbEscPosTransport(this.client, {bool Function()? supported})
      : supported = supported ?? (() => Platform.isWindows);
  @override
  Future<void> send(List<int> bytes, PrinterSettings settings) async {
    if (!supported()) {
      throw const HardwareException(
          'USB printer is unsupported on this platform.');
    }
    if (settings.deviceId.isEmpty) {
      throw const HardwareException('Select a USB printer in settings.');
    }
    await client.writeUsb(settings.deviceId, bytes);
  }
}

class BluetoothEscPosTransport implements PrinterTransport {
  final DevicePrinterClient client;
  final bool Function() supported;
  BluetoothEscPosTransport(this.client, {bool Function()? supported})
      : supported = supported ?? (() => Platform.isAndroid);
  @override
  Future<void> send(List<int> bytes, PrinterSettings settings) async {
    if (!supported()) {
      throw const HardwareException(
          'Bluetooth printer is unsupported on this platform.');
    }
    if (settings.deviceId.isEmpty) {
      throw const HardwareException('Select a Bluetooth printer in settings.');
    }
    await client.writeBluetooth(settings.deviceId, settings.deviceName, bytes);
  }
}

class ConfiguredPrinterTransport implements PrinterTransport {
  final PrinterTransport lan;
  final PrinterTransport usb;
  final PrinterTransport bluetooth;
  ConfiguredPrinterTransport(this.lan, this.usb, this.bluetooth);
  @override
  Future<void> send(List<int> bytes, PrinterSettings settings) =>
      switch (settings.transport) {
        PrinterConnection.lan => lan.send(bytes, settings),
        PrinterConnection.usb => usb.send(bytes, settings),
        PrinterConnection.bluetooth => bluetooth.send(bytes, settings),
      };
}
