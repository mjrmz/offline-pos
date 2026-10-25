import 'package:flutter/material.dart';
import '../../core/models/printer_settings.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../hardware/printer/receipt_printer.dart';
import '../../hardware/printer/device_transports.dart';
import '../../hardware/printer/label_printing.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../../core/services/business_logo_store.dart';
import '../../shared/theme/theme_mode_controller.dart';
import '../../shared/widgets/app_workspace.dart';

class PrinterSettingsScreen extends StatefulWidget {
  final PrinterSettingsStore store;
  final ReceiptPrinter printer;
  final DevicePrinterClient devices;
  final bool embedded;
  final ValueChanged<bool>? onDirtyChanged;
  const PrinterSettingsScreen(
      {super.key,
      required this.store,
      required this.printer,
      required this.devices,
      this.embedded = false,
      this.onDirtyChanged});
  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  final host = TextEditingController();
  final port = TextEditingController(text: '9100');
  final storeName = TextEditingController();
  final storeAddress = TextEditingController();
  final storeContact = TextEditingController();
  final receiptHeader = TextEditingController();
  final receiptFooter = TextEditingController();
  bool enabled = false;
  bool drawer = false;
  int width = 80;
  PrinterConnection connection = PrinterConnection.lan;
  String deviceId = '';
  String deviceName = '';
  List<PrinterDevice> discovered = [];
  String? message;
  File? logo;
  int section = 0;
  List<LabelTemplate> labelTemplates = LabelTemplate.defaults;
  int labelWidth = 80;
  bool loaded = false;
  String savedSignature = '';
  String get signature => [
        enabled,
        drawer,
        width,
        connection.name,
        deviceId,
        deviceName,
        host.text,
        port.text,
        storeName.text,
        storeAddress.text,
        storeContact.text,
        receiptHeader.text,
        receiptFooter.text
      ].join('\u0000');
  bool get dirty => loaded && signature != savedSignature;
  void _edited() {
    widget.onDirtyChanged?.call(dirty);
  }

  @override
  void initState() {
    super.initState();
    for (final field in [
      storeName,
      storeAddress,
      storeContact,
      receiptHeader,
      receiptFooter,
      host,
      port,
    ]) {
      field.addListener(_previewChanged);
    }
    BusinessLogoStore().load().then((file) {
      if (mounted) setState(() => logo = file);
    });
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
        storeAddress.text = s.storeAddress;
        storeContact.text = s.storeContact;
        receiptHeader.text = s.receiptHeader;
        receiptFooter.text = s.receiptFooter;
        savedSignature = signature;
        loaded = true;
      });
      _edited();
    });
    LabelTemplateStore().load().then((value) {
      if (mounted) setState(() => labelTemplates = value);
    });
    LabelPrintingPreferences().loadWidth().then((value) {
      if (mounted) setState(() => labelWidth = value);
    });
  }

  void _previewChanged() {
    if (mounted) setState(() {});
    _edited();
  }

  @override
  void dispose() {
    host.dispose();
    port.dispose();
    storeName.dispose();
    storeAddress.dispose();
    storeContact.dispose();
    receiptHeader.dispose();
    receiptFooter.dispose();
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
        storeName: storeName.text.trim(),
        storeAddress: storeAddress.text.trim(),
        storeContact: storeContact.text.trim(),
        receiptHeader: receiptHeader.text.trim(),
        receiptFooter: receiptFooter.text.trim());
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
      if (mounted) {
        setState(() {
          message = 'Printer settings saved.';
          savedSignature = signature;
        });
        _edited();
      }
    } catch (_) {
      if (mounted) setState(() => message = 'Could not save printer settings.');
    }
  }

  Future<void> chooseLogo() async {
    final result = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg']);
    final path = result.isEmpty ? null : result.single.path;
    if (path == null) return;
    try {
      final file = await BusinessLogoStore().save(path);
      if (mounted) AppThemeController.maybeOf(context)?.setLogoPath(file.path);
      if (mounted) {
        setState(() {
          logo = file;
          message = 'Business logo saved.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            message = 'Could not save this logo. Choose a PNG or JPEG image.');
      }
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
  Widget build(BuildContext context) =>
      widget.embedded ? _content() : Scaffold(body: _content());

  Widget _content() => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(padding: const EdgeInsets.all(24), children: [
            if (!widget.embedded)
              const AppPageHeader(
                title: 'Printer & Receipt',
                subtitle:
                    'Configure receipt identity, printer, and cash drawer.',
              ),
            if (widget.embedded)
              Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Wrap(spacing: 8, children: [
                    for (var i = 0; i < 4; i++)
                      ChoiceChip(
                          label: Text(
                              const ['Receipt', 'Printer', 'Cash Drawer', 'Label Printing'][i]),
                          selected: section == i,
                          onSelected: (_) => setState(() => section = i)),
                  ])),
            if (!widget.embedded || section == 1)
              const Text(
                  'ESC/POS printer. LAN uses raw TCP; USB requires a Windows printer driver; Bluetooth requires a paired Android printer.'),
            if (!widget.embedded || section == 0) ...[
              const SizedBox(height: 24),
              Text('Receipt identity',
                  style: Theme.of(context).textTheme.titleLarge),
              TextField(
                  controller: storeName,
                  decoration: const InputDecoration(labelText: 'Store name')),
              const SizedBox(height: 12),
              Text('Business branding',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(children: [
                SizedBox(
                    width: 76,
                    height: 64,
                    child: logo == null
                        ? const Icon(Icons.storefront_outlined, size: 36)
                        : Image.file(logo!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.storefront_outlined,
                                size: 36))),
                const SizedBox(width: 12),
                OutlinedButton(
                    onPressed: chooseLogo, child: const Text('Choose logo')),
                if (logo != null)
                  TextButton(
                      onPressed: () async {
                        await BusinessLogoStore().remove();
                        if (mounted) {
                          AppThemeController.maybeOf(context)
                              ?.setLogoPath(null);
                        }
                        if (mounted) setState(() => logo = null);
                      },
                      child: const Text('Remove logo')),
              ]),
              TextField(
                  controller: storeAddress,
                  decoration: const InputDecoration(
                      labelText: 'Store address (optional)')),
              TextField(
                  controller: storeContact,
                  decoration: const InputDecoration(
                      labelText: 'Store contact (optional)')),
              TextField(
                  controller: receiptHeader,
                  decoration: const InputDecoration(
                      labelText: 'Receipt header (optional)')),
              TextField(
                  controller: receiptFooter,
                  decoration: const InputDecoration(
                      labelText: 'Receipt footer (optional)')),
              const SizedBox(height: 16),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('RECEIPT PREVIEW',
                                style: Theme.of(context).textTheme.labelMedium),
                            const Divider(),
                            Center(
                                child: Text(
                                    storeName.text.isEmpty
                                        ? 'Business name'
                                        : storeName.text,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium)),
                            if (storeAddress.text.isNotEmpty)
                              Center(child: Text(storeAddress.text)),
                            if (storeContact.text.isNotEmpty)
                              Center(child: Text(storeContact.text)),
                            if (receiptHeader.text.isNotEmpty)
                              Center(child: Text(receiptHeader.text)),
                            const Divider(),
                            const Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [Text('TOTAL'), Text('₱350.00')]),
                            const Divider(),
                            Center(
                                child: Text(receiptFooter.text.isEmpty
                                    ? 'Thank you!'
                                    : receiptFooter.text)),
                          ]))),
            ],
            if (!widget.embedded || section == 1) ...[
              const SizedBox(height: 20),
              Text('Printer', style: Theme.of(context).textTheme.titleLarge),
              SwitchListTile(
                  title: const Text('Enable printer'),
                  value: enabled,
                  onChanged: (v) {
                    setState(() => enabled = v);
                    _edited();
                  }),
              DropdownButtonFormField<PrinterConnection>(
                  key: ValueKey(connection),
                  initialValue: connection,
                  decoration: const InputDecoration(labelText: 'Transport'),
                  items: [
                    const DropdownMenuItem(
                        value: PrinterConnection.lan,
                        child: Text('LAN / raw TCP')),
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
                  onChanged: (value) {
                    setState(() {
                      connection = value ?? PrinterConnection.lan;
                      deviceId = '';
                      deviceName = '';
                      discovered = [];
                    });
                    _edited();
                  }),
              if (connection == PrinterConnection.lan) ...[
                TextField(
                    controller: host,
                    decoration: const InputDecoration(
                        labelText: 'Printer IP address or host')),
                TextField(
                    controller: port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'Port (usually 9100)')),
              ] else ...[
                Text('Selected: ${deviceName.isEmpty ? 'None' : deviceName}'),
                OutlinedButton(
                    onPressed: discover, child: const Text('Find printers')),
                for (final device in discovered)
                  ListTile(
                      title: Text(device.name),
                      subtitle: Text(device.id),
                      onTap: () {
                        setState(() {
                          deviceId = device.id;
                          deviceName = device.name;
                          message = null;
                        });
                        _edited();
                      }),
              ],
              DropdownButtonFormField<int>(
                  initialValue: width,
                  decoration: const InputDecoration(labelText: 'Paper width'),
                  items: const [
                    DropdownMenuItem(value: 58, child: Text('58 mm')),
                    DropdownMenuItem(value: 80, child: Text('80 mm'))
                  ],
                  onChanged: (v) {
                    setState(() => width = v ?? 80);
                    _edited();
                  }),
            ],
            if (!widget.embedded || section == 2) ...[
              Text('Cash Drawer',
                  style: Theme.of(context).textTheme.titleLarge),
              SwitchListTile(
                  title: const Text('Cash drawer through printer'),
                  value: drawer,
                  onChanged: (v) {
                    setState(() => drawer = v);
                    _edited();
                  }),
            ],
            if (!widget.embedded || section == 3) ...[
              const SizedBox(height: 20),
              Text('Label Printing', style: Theme.of(context).textTheme.titleLarge),
              const Text('Uses the currently configured ESC/POS printer. Labels print on 58 mm or 80 mm continuous thermal paper.'),
              DropdownButtonFormField<LabelTemplate>(
                key: ValueKey(labelTemplates.first),
                initialValue: labelTemplates.first,
                decoration: const InputDecoration(labelText: 'Default label template'),
                items: [for (final option in labelTemplates)
                  DropdownMenuItem(value: option, child: Text(option.name))],
                onChanged: (value) async {
                  if (value == null) return;
                  final next = [value, ...labelTemplates.where((t) => t != value)];
                  await LabelTemplateStore().save(next);
                  if (mounted) setState(() => labelTemplates = next);
                }),
              DropdownButtonFormField<int>(
                key: ValueKey(labelWidth),
                initialValue: labelWidth,
                decoration: const InputDecoration(labelText: 'Default label paper width'),
                items: const [DropdownMenuItem(value: 58, child: Text('58 mm')),
                  DropdownMenuItem(value: 80, child: Text('80 mm'))],
                onChanged: (value) async {
                  if (value == null) return;
                  await LabelPrintingPreferences().saveWidth(value);
                  if (mounted) setState(() => labelWidth = value);
                }),
            ],
            if (message != null) Text(message!),
            Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                    onPressed: dirty ? save : null,
                    child: const Text('Save changes'))),
            if (!widget.embedded || section == 1)
              OutlinedButton(
                  onPressed: test, child: const Text('Test printer')),
          ]),
        ),
      );
}
