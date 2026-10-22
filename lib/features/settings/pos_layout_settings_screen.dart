import 'package:flutter/material.dart';
import '../pos_checkout/pos_layout_preference.dart';

class PosLayoutSettingsScreen extends StatefulWidget {
  const PosLayoutSettingsScreen({super.key});
  @override
  State<PosLayoutSettingsScreen> createState() =>
      _PosLayoutSettingsScreenState();
}

class _PosLayoutSettingsScreenState extends State<PosLayoutSettingsScreen> {
  final preference = PosLayoutPreference.instance;
  PosLayoutType? preview;

  @override
  void initState() {
    super.initState();
    preference.addListener(_changed);
    preference.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    preference.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = preview ?? preference.layout;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings → POS')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        _heading('Checkout mode',
            'Choose the interface for this device. Your active sale stays intact when you switch.'),
        LayoutBuilder(builder: (context, box) {
          final cards = [
            _card(
                PosLayoutType.visualCatalog,
                'Visual Catalog',
                'Product-card checkout for specialty retail.',
                Icons.grid_view_outlined),
            _card(
                PosLayoutType.scanFirst,
                'Scan-First',
                'Fast barcode-led checkout for grocery, convenience and pharmacy.',
                Icons.qr_code_scanner),
          ];
          return box.maxWidth >= 720
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 16),
                  Expanded(child: cards[1])
                ])
              : Column(
                  children: [cards[0], const SizedBox(height: 12), cards[1]]);
        }),
        if (preview != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            'Preview: ${shown == PosLayoutType.scanFirst ? 'Scan-First' : 'Visual Catalog'}',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(shown == PosLayoutType.scanFirst
                            ? 'Scanner and customer → Full cart table → Total and Pay'
                            : 'Search and categories → Product cards | Current sale and Pay'),
                        TextButton(
                            onPressed: () => setState(() => preview = null),
                            child: const Text('Close preview')),
                      ]))),
        const SizedBox(height: 24),
        _heading('Startup behavior'),
        _toggle(
            'pos-start-focused-setting',
            'Start POS in Focus Mode',
            'Hide navigation and maximize checkout workspace when POS opens.',
            preference.startFocused,
            (v) => preference.setWorkspaceOption('startFocused', v)),
        const SizedBox(height: 24),
        _heading('Scan-First'),
        _note(
            'Barcode-led checkout uses the shared cart and existing sale flow.'),
        const SizedBox(height: 24),
        _heading('Visual Catalog'),
        _note('Product-card checkout for specialty retail.'),
        const SizedBox(height: 24),
        _heading('Scanner behavior'),
        const ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 16),
            title: Text('Add recognized barcode automatically'),
            subtitle: Text(
                'Adds a valid scanned product directly to the shared cart.'),
            trailing: Icon(Icons.check_circle_outline)),
        _scanner(
            'incrementRepeated',
            'Increment quantity for repeated identical scans',
            'Scanning the same normal product again increases its quantity when valid.',
            preference.incrementRepeated),
        _scanner(
            'keepReady',
            'Keep scanner ready after successful scan',
            'Returns focus to the scan field after a successful scan.',
            preference.keepReady),
        _scanner(
            'showLastScanned',
            'Show last scanned item',
            'Shows brief confirmation after an item is scanned.',
            preference.showLastScanned),
        const SizedBox(height: 24),
        _heading('Product lookup'),
        _scanner(
            'allowLookup',
            'Allow manual product lookup',
            'Enables F4 search when a barcode is unavailable or cannot be scanned.',
            preference.allowLookup),
        const SizedBox(height: 24),
        _heading('Keyboard & shortcuts'),
        _toggle(
            'pos-visual-shortcut-bar-setting',
            'Show shortcut bar in Visual Catalog',
            null,
            preference.showVisualCatalogShortcutBar,
            (v) => preference.setWorkspaceOption(
                'showVisualCatalogShortcutBar', v)),
        _toggle(
            'pos-scan-shortcut-bar-setting',
            'Show shortcut bar in Scan-First',
            null,
            preference.showScanFirstShortcutBar,
            (v) =>
                preference.setWorkspaceOption('showScanFirstShortcutBar', v)),
      ]),
    );
  }

  Widget _heading(String title, [String? description]) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(description)
          ],
        ]),
      );

  Widget _note(String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(text));

  Widget _card(
      PosLayoutType value, String title, String description, IconData icon) {
    final selected = preference.layout == value;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? scheme.primaryContainer.withValues(alpha: .28) : null,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant)),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium)),
              if (selected) Icon(Icons.check_circle, color: scheme.primary)
            ]),
            const SizedBox(height: 8),
            Text(description),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  onPressed: () => setState(() => preview = value),
                  child: const Text('Preview')),
              const SizedBox(width: 8),
              FilledButton(
                  onPressed:
                      selected ? null : () => preference.setLayout(value),
                  child: Text(selected ? 'Selected' : 'Apply')),
            ]),
          ])),
    );
  }

  Widget _toggle(String key, String title, String? helper, bool value,
          ValueChanged<bool> onChanged) =>
      SwitchListTile(
        key: Key(key),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(title),
        subtitle: helper == null ? null : Text(helper),
        value: value,
        onChanged: onChanged,
      );

  Widget _scanner(String key, String title, String helper, bool value) =>
      _toggle('pos-$key-setting', title, helper, value,
          (next) => preference.setScannerOption(key, next));
}
