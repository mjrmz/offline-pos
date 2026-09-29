import 'package:flutter/material.dart';
import '../../core/models/printer_settings.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../hardware/printer/receipt_printer.dart';
import '../../hardware/printer/device_transports.dart';
import 'dart:io';

class PrinterSettingsScreen extends StatefulWidget {
  final PrinterSettingsStore store;
  final ReceiptPrinter printer;
  final DevicePrinterClient devices;
  const PrinterSettingsScreen(
      {super.key,
      required this.store,
      required this.printer,
      required this.devices});
  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final host = TextEditingController();
  final port = TextEditingController(text: '9100');
  final storeName = TextEditingController();
  bool enabled = false;
  bool drawer = false;
  int width = 80;
  PrinterConnection connection = PrinterConnection.lan;
  String deviceId = '';
  String deviceName = '';
  List<PrinterDevice> discovered = [];
  String? message;
  @override
  void initState() {
    super.initState();
    widget.store.load().then((s) {
      if (!mounted) return;
      setState(() {
        enabled = s.enabled;
        drawer = s.drawerEnabled;
        width = s.widthMm;
        connection = s.transport;
        deviceId = s.deviceId;
        deviceName = s.deviceName;
        host.text = s.host;
        port.text = '${s.port}';
        storeName.text = s.storeName;
      });
    });
  }

  @override
  void dispose() {
    host.dispose();
    port.dispose();
    storeName.dispose();
    super.dispose();
  }

  PrinterSettings? values() {
    final number = int.tryParse(port.text.trim());
    if (number == null ||
        number < 1 ||
        number > 65535 ||
        (enabled &&
            connection == PrinterConnection.lan &&
            host.text.trim().isEmpty) ||
        (enabled && connection != PrinterConnection.lan && deviceId.isEmpty)) {
      setState(() => message =
          'Enter a LAN address or select a printer, and use a valid port.');
      return null;
    }
    return PrinterSettings(
        enabled: enabled,
        transport: connection,
        host: host.text.trim(),
        port: number,
        deviceId: deviceId,
        deviceName: deviceName,
        widthMm: width,
        drawerEnabled: drawer,
        storeName: storeName.text.trim());
  }

  Future<void> discover() async {
    try {
      final results = await widget.devices.discover(connection);
      if (mounted) {
        setState(() {
          discovered = results;
          message = results.isEmpty
              ? 'No printers found. Check connection and permissions.'
              : null;
        });
      }
    } on HardwareException catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => message =
            'Could not discover printers. Check the device connection.');
      }
    }
  }

  Future<void> save() async {
    final settings = values();
    if (settings == null) return;
    try {
      await widget.store.save(settings);
      if (mounted) setState(() => message = 'Printer settings saved.');
    } catch (_) {
      if (mounted) setState(() => message = 'Could not save printer settings.');
    }
  }

  Future<void> test() async {
    final settings = values();
    if (settings == null) return;
    if (!settings.configured) {
      setState(() => message = 'Enable and configure a printer first.');
      return;
    }
    try {
      await widget.printer.test(settings);
      if (mounted) {
        setState(() => message = 'Test data sent. Check the printed page.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => message =
            'Test print failed. Check printer power, address, and connection.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Printer settings')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text(
              'ESC/POS printer. LAN uses raw TCP; USB requires a Windows printer driver; Bluetooth requires a paired Android printer.'),
          SwitchListTile(
              title: const Text('Enable printer'),
              value: enabled,
              onChanged: (v) => setState(() => enabled = v)),
          TextField(
              controller: storeName,
              decoration: const InputDecoration(labelText: 'Store name')),
          DropdownButtonFormField<PrinterConnection>(
              key: ValueKey(connection),
              initialValue: connection,
              decoration: const InputDecoration(labelText: 'Transport'),
              items: [
                const DropdownMenuItem(
                    value: PrinterConnection.lan, child: Text('LAN / raw TCP')),
                DropdownMenuItem(
                    value: PrinterConnection.usb,
                    child: Text(Platform.isWindows
                        ? 'USB printer'
                        : 'USB (unsupported here)')),
                DropdownMenuItem(
                    value: PrinterConnection.bluetooth,
                    child: Text(Platform.isAndroid
                        ? 'Bluetooth printer'
                        : 'Bluetooth (unsupported here)')),
              ],
              onChanged: (value) => setState(() {
                    connection = value ?? PrinterConnection.lan;
                    deviceId = '';
                    deviceName = '';
                    discovered = [];
                  })),
          if (connection == PrinterConnection.lan) ...[
            TextField(
                controller: host,
                decoration: const InputDecoration(
                    labelText: 'Printer IP address or host')),
            TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Port (usually 9100)')),
          ] else ...[
            Text('Selected: ${deviceName.isEmpty ? 'None' : deviceName}'),
            OutlinedButton(
                onPressed: discover, child: const Text('Find printers')),
            for (final device in discovered)
              ListTile(
                  title: Text(device.name),
                  subtitle: Text(device.id),
                  onTap: () => setState(() {
                        deviceId = device.id;
                        deviceName = device.name;
                        message = null;
                      })),
          ],
          DropdownButtonFormField<int>(
              initialValue: width,
              decoration: const InputDecoration(labelText: 'Paper width'),
              items: const [
                DropdownMenuItem(value: 58, child: Text('58 mm')),
                DropdownMenuItem(value: 80, child: Text('80 mm'))
              ],
              onChanged: (v) => setState(() => width = v ?? 80)),
          SwitchListTile(
              title: const Text('Cash drawer through printer'),
              value: drawer,
              onChanged: (v) => setState(() => drawer = v)),
          if (message != null) Text(message!),
          FilledButton(onPressed: save, child: const Text('Save')),
          OutlinedButton(onPressed: test, child: const Text('Test printer')),
        ]),
      );
}
