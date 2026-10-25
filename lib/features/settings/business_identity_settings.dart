import 'package:flutter/material.dart';
import 'dart:io';
import '../../core/models/printer_settings.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../shared/theme/theme_mode_controller.dart';

/// Edits the shared business identity used by receipts and the sidebar.
class BusinessIdentitySettings extends StatefulWidget {
  const BusinessIdentitySettings(
      {super.key, required this.store, this.onDirtyChanged});
  final PrinterSettingsStore store;
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<BusinessIdentitySettings> createState() =>
      _BusinessIdentitySettingsState();
}

class _BusinessIdentitySettingsState extends State<BusinessIdentitySettings> {
  final name = TextEditingController();
  final address = TextEditingController();
  final contact = TextEditingController();
  bool loaded = false;
  bool saving = false;
  String? error;
  List<String> saved = const [];

  @override
  void initState() {
    super.initState();
    for (final field in [name, address, contact]) {
      field.addListener(_edited);
    }
    widget.store.load().then((value) {
      if (!mounted) return;
      name.text = value.storeName;
      address.text = value.storeAddress;
      contact.text = value.storeContact;
      setState(() {
        saved = [name.text, address.text, contact.text];
        loaded = true;
      });
    }).catchError((Object cause) {
      if (mounted) setState(() => error = '$cause');
    });
  }

  void _edited() {
    if (mounted && loaded) {
      setState(() {});
      widget.onDirtyChanged?.call(changed);
    }
  }

  bool get changed =>
      loaded &&
      (name.text != saved[0] ||
          address.text != saved[1] ||
          contact.text != saved[2]);

  @override
  void dispose() {
    name.dispose();
    address.dispose();
    contact.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Enter a business name.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final current = await widget.store.load();
      await widget.store.save(PrinterSettings(
        enabled: current.enabled,
        transport: current.transport,
        host: current.host,
        port: current.port,
        deviceId: current.deviceId,
        deviceName: current.deviceName,
        widthMm: current.widthMm,
        drawerEnabled: current.drawerEnabled,
        storeName: name.text.trim(),
        storeAddress: address.text.trim(),
        storeContact: contact.text.trim(),
        receiptHeader: current.receiptHeader,
        receiptFooter: current.receiptFooter,
      ));
      if (mounted) {
        setState(() => saved = [name.text, address.text, contact.text]);
        widget.onDirtyChanged?.call(false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Business identity saved.'),
            duration: Duration(seconds: 3)));
      }
    } catch (cause) {
      if (mounted) setState(() => error = '$cause');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appearance = AppThemeController.maybeOf(context);
    final sidebarColor =
        appearance?.effectiveSidebarColor ?? SidebarColorPreset.navy;
    final logoPath = appearance?.logoPath;
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Business identity',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text('These details identify your business on receipts.'),
        const SizedBox(height: 16),
        TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Business name')),
        const SizedBox(height: 16),
        TextField(
            controller: address,
            decoration: const InputDecoration(labelText: 'Address')),
        const SizedBox(height: 16),
        TextField(
            controller: contact,
            decoration: const InputDecoration(labelText: 'Contact number')),
        const SizedBox(height: 20),
        Text('Sidebar preview', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Container(
          width: 240,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: sidebarColor.color,
              borderRadius: BorderRadius.circular(10)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              SizedBox(
                  width: 28,
                  height: 28,
                  child: logoPath == null
                      ? Icon(Icons.storefront_outlined,
                          color: sidebarColor.foreground)
                      : Image.file(File(logoPath),
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                              Icons.storefront_outlined,
                              color: sidebarColor.foreground))),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      name.text.trim().isEmpty
                          ? 'Vertex POS'
                          : name.text.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: sidebarColor.foreground,
                          fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 12),
            for (final label in ['POS', 'Sales', 'Inventory'])
              Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(label,
                      style: TextStyle(
                          color:
                              sidebarColor.foreground.withValues(alpha: .8)))),
          ]),
        ),
        if (error != null)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        const SizedBox(height: 16),
        Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
                onPressed: saving || !changed ? null : save,
                child: const Text('Save changes'))),
      ]),
    ));
  }
}
