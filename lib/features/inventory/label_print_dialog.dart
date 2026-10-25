import 'package:flutter/material.dart';
import 'dart:async';
import '../../core/models/product.dart';
import '../../data/database.dart';
import '../../data/daos/auth_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../core/models/printer_settings.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../hardware/printer/device_transports.dart';
import '../../hardware/printer/receipt_printer.dart';
import '../../hardware/printer/label_printing.dart';
import 'code128_preview.dart';

Future<void> showLabelPrintDialog(BuildContext context, AppDatabase db,
    List<LabelItem> initialItems, {PosRepository? products, String? actorId}) => showDialog<void>(
  context: context,
  builder: (_) => _LabelPrintDialog(db: db, initialItems: initialItems,
    products: products, actorId: actorId),
);

class _LabelPrintDialog extends StatefulWidget {
  final AppDatabase db;
  final List<LabelItem> initialItems;
  final PosRepository? products;
  final String? actorId;
  const _LabelPrintDialog({required this.db, required this.initialItems,
    this.products, this.actorId});
  @override
  State<_LabelPrintDialog> createState() => _LabelPrintDialogState();
}

class _LabelPrintDialogState extends State<_LabelPrintDialog> {
  late final items = widget.initialItems.toList();
  List<LabelTemplate> templates = LabelTemplate.defaults;
  LabelTemplate template = LabelTemplate.defaults.first;
  final renderer = LabelRenderer();
  bool printing = false;
  String? error;
  int paperWidth = 80;
  List<PosProduct> results = [];
  int searchVersion = 0;
  Timer? debounce;
  int previewIndex = 0;

  @override
  void initState() {
    super.initState();
    LabelTemplateStore().load().then((loaded) {
      if (mounted) setState(() { templates = loaded; template = loaded.first; });
    });
    LabelPrintingPreferences().loadWidth().then((value) {
      if (mounted) setState(() => paperWidth = value);
    });
  }

  @override
  void dispose() { debounce?.cancel(); super.dispose(); }

  void searchProducts(String term) {
    debounce?.cancel();
    final version = ++searchVersion;
    debounce = Timer(const Duration(milliseconds: 250), () async {
      final found = await widget.products?.searchProductsForLabels(term) ?? <PosProduct>[];
      if (mounted && version == searchVersion) setState(() => results = found);
    });
  }

  void addProduct(PosProduct product) {
    setState(() {
      final existing = items.indexWhere((item) =>
        item.product.id == product.id && item.serialNumber == null);
      if (existing < 0) items.add(LabelItem(product, 1));
      previewIndex = existing < 0 ? items.length - 1 : existing;
      results = [];
    });
  }

  Future<void> editTemplate({bool duplicate = false}) async {
    final source = template;
    final name = TextEditingController(text: duplicate ? '${source.name} copy' : source.name);
    var price = source.price;
    var barcode = source.barcode;
    var barcodeText = source.barcodeText;
    var sku = source.sku;
    var batch = source.batch;
    var expiry = source.expiry;
    var businessName = source.businessName;
    final result = await showDialog<LabelTemplate>(context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) => AlertDialog(
        title: Text(duplicate ? 'Duplicate template' : 'Edit template'),
        content: SizedBox(width: 380, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            CheckboxListTile(title: const Text('Price'), value: price, onChanged: (v) => update(() => price = v ?? false)),
            CheckboxListTile(title: const Text('Barcode'), value: barcode, onChanged: (v) => update(() => barcode = v ?? false)),
            CheckboxListTile(title: const Text('Barcode text'), value: barcodeText, onChanged: (v) => update(() => barcodeText = v ?? false)),
            CheckboxListTile(title: const Text('SKU'), value: sku, onChanged: (v) => update(() => sku = v ?? false)),
            CheckboxListTile(title: const Text('Business name'), value: businessName, onChanged: (v) => update(() => businessName = v ?? false)),
            CheckboxListTile(title: const Text('Batch'), value: batch, onChanged: (v) => update(() => batch = v ?? false)),
            CheckboxListTile(title: const Text('Expiry'), value: expiry, onChanged: (v) => update(() => expiry = v ?? false)),
          ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            if (name.text.trim().isEmpty) return;
            Navigator.pop(context, LabelTemplate(name.text.trim(), price: price,
              barcode: barcode, barcodeText: barcodeText, sku: sku,
              batch: batch, expiry: expiry, businessName: businessName));
          }, child: const Text('Save'))],
      )));
    name.dispose();
    if (result == null || !mounted) return;
    final next = templates.toList();
    if (duplicate) { next.add(result); } else { next[next.indexOf(template)] = result; }
    await LabelTemplateStore().save(next);
    if (mounted) setState(() { templates = next; template = result; });
  }

  Future<void> setDefaultTemplate() async {
    final next = [template, ...templates.where((entry) => entry != template)];
    await LabelTemplateStore().save(next);
    if (mounted) setState(() => templates = next);
  }

  Future<void> print() async {
    final job = LabelJob(items, template);
    try {
      job.validate();
      final configured = await PrinterSettingsStore(widget.db).load();
      final settings = PrinterSettings(enabled: configured.enabled,
        transport: configured.transport, host: configured.host,
        port: configured.port, deviceId: configured.deviceId,
        deviceName: configured.deviceName, widthMm: paperWidth,
        storeName: configured.storeName);
      if (!mounted) return;
      if (job.total > 10) {
        final approved = await showDialog<bool>(context: context,
          builder: (context) => AlertDialog(
            title: Text('Print ${job.total} labels?'),
            content: Text('Products: ${items.length}\nPrinter: ${settings.deviceName.isEmpty ? settings.host : settings.deviceName}\nTemplate: ${template.name}'),
            actions: [TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true),
                child: Text('Print ${job.total} labels'))]));
        if (approved != true || !mounted) return;
      }
      setState(() { printing = true; error = null; });
      final device = PluginPrinterClient();
      final transport = ConfiguredPrinterTransport(LanEscPosTransport(),
          UsbEscPosTransport(device), BluetoothEscPosTransport(device));
      await LabelPrintService(transport, null, (printed, printer) =>
        AuthRepository(widget.db).audit(widget.actorId, 'product_labels.printed',
          'products=${printed.items.map((item) => item.product.id).toSet().length}; labels=${printed.total}; template=${printed.template.name}; transport=${printer.transport.name}; printer=${printer.deviceName.isEmpty ? printer.host : printer.deviceName}'))
        .print(job, settings);
      if (mounted) Navigator.pop(context);
    } on LabelAuditException catch (e) {
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.pop(context);
        messenger.showSnackBar(SnackBar(content: Text('$e')));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = LabelJob(items, template);
    return AlertDialog(
      title: const Text('Print labels'),
      content: SizedBox(width: 700, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<LabelTemplate>(
            initialValue: template,
            decoration: const InputDecoration(labelText: 'Template'),
            items: [for (final option in templates)
              DropdownMenuItem(value: option, child: Text(option.name))],
            onChanged: (value) { if (value != null) setState(() => template = value); }),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: () => editTemplate(), child: const Text('Edit template')),
            TextButton(onPressed: () => editTemplate(duplicate: true), child: const Text('Duplicate')),
            TextButton(onPressed: templates.first == template ? null : setDefaultTemplate,
              child: const Text('Set default')),
          ]),
          const SizedBox(height: 12),
          if (widget.products != null) ...[
            TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
              labelText: 'Add products by name, SKU, or barcode'),
              onChanged: searchProducts),
            for (final product in results)
              ListTile(title: Text(product.name),
                subtitle: Text('${product.sku ?? ''} · ${product.barcode ?? 'No barcode'}'),
                trailing: TextButton(onPressed: () => addProduct(product),
                  child: const Text('Add'))),
          ],
          if (items.isEmpty) const Text('No labels selected'),
          for (var index = 0; index < items.length; index++)
            _itemRow(index, items[index]),
          const SizedBox(height: 12),
          Text('Total: ${job.total} labels', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text('Preview · $paperWidth mm continuous paper',
              style: Theme.of(context).textTheme.titleSmall)),
            DropdownButton<int>(value: paperWidth,
              items: const [DropdownMenuItem(value: 58, child: Text('58 mm')),
                DropdownMenuItem(value: 80, child: Text('80 mm'))],
              onChanged: (value) { if (value != null) setState(() => paperWidth = value); }),
          ]),
          if (items.isNotEmpty) SizedBox(width: paperWidth == 58 ? 275 : 365,
            child: Card(child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final line in renderer.lines(items[previewIndex], template)) Text(line),
                if (template.barcode)
                  Code128Preview(items[previewIndex].product.barcode ?? ''),
              ])))),
          const Text('Receipt printer label mode · continuous thermal paper'),
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: printing || items.isEmpty ? null : print,
          child: Text(printing ? 'Printing…' : error == null ? 'Print labels' : 'Retry'))],
    );
  }

  Widget _itemRow(int index, LabelItem item) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(item.product.name),
    subtitle: Text('${item.product.barcode?.trim().isNotEmpty == true ? item.product.barcode! : 'No barcode assigned'} · ${template.name}'
      '${item.serialNumber == null ? '' : ' · Serial: ${item.serialNumber}'}'
      '${item.batchNumber == null ? '' : ' · Batch: ${item.batchNumber}'}'),
    onTap: () => setState(() => previewIndex = index),
    trailing: SizedBox(width: 140, child: Row(children: [Expanded(child: TextFormField(
      enabled: item.serialNumber == null,
      initialValue: '${item.quantity}',
      decoration: const InputDecoration(labelText: 'Qty'),
      keyboardType: TextInputType.number,
      onChanged: (value) {
        final count = int.tryParse(value);
        if (count != null) {
          setState(() => items[index] = LabelItem(item.product, count,
            batchNumber: item.batchNumber, expiryDate: item.expiryDate,
            serialNumber: item.serialNumber, receivingPriceCents: item.receivingPriceCents));
        }
      })), IconButton(icon: const Icon(Icons.close), tooltip: 'Remove',
        onPressed: () => setState(() {
          items.removeAt(index);
          if (previewIndex >= items.length) previewIndex = items.isEmpty ? 0 : items.length - 1;
        }))])),
  );
}
