import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/import_repository.dart';
import '../../data/daos/opening_inventory_import_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';

class ImportWizard extends StatefulWidget {
  const ImportWizard(
      {super.key,
      required this.repository,
      required this.user,
      this.onViewImported,
      this.onViewMovements});
  final ImportRepository repository;
  final ActiveUser user;
  final ValueChanged<ImportKind>? onViewImported;
  final VoidCallback? onViewMovements;
  @override
  State<ImportWizard> createState() => _ImportWizardState();
}

class _ImportWizardState extends State<ImportWizard> {
  late ImportKind kind = widget.user.can(PosPermission.manageCatalog)
      ? ImportKind.products
      : widget.user.can(PosPermission.manageContacts)
          ? ImportKind.customers
          : ImportKind.openingInventory;
  List<List<String>>? csv;
  String? fileName;
  Map<String, String> mapping = {};
  ImportPreview? preview;
  ImportResult? result;
  bool createCategories = false;
  bool busy = false;
  String? error;
  int step = 0;
  String filter = 'All';
  OpeningInventoryImportRepository get opening =>
      OpeningInventoryImportRepository(widget.repository.db);
  bool get isOpening => kind == ImportKind.openingInventory;

  Future<void> pick() async {
    try {
      final files = await FilePicker.pickFiles(
          type: FileType.custom, allowedExtensions: ['csv']);
      if (files.isEmpty || files.single.path == null) return;
      final path = files.single.path!;
      if (!path.toLowerCase().endsWith('.csv')) {
        throw const FormatException('Select a CSV file');
      }
      final source =
          utf8.decode(await File(path).readAsBytes(), allowMalformed: false);
      final parsed = await compute(ImportCsv.parse, source);
      setState(() {
        csv = parsed;
        fileName = files.single.name;
        mapping = ImportCsv.autoMap(parsed.first, kind);
        preview = null;
        error = null;
        step = 1;
      });
    } catch (e) {
      setState(() => error = e is FormatException
          ? e.message
          : 'File cannot be read. Check that it is UTF-8 CSV.');
    }
  }

  Future<void> template() async {
    try {
      await FilePicker.saveFile(
          fileName: '${kind.name}_template.csv',
          bytes: Uint8List.fromList(utf8.encode(ImportCsv.template(kind))),
          mimeType: 'text/csv',
          type: FileType.custom,
          allowedExtensions: ['csv']);
    } catch (_) {
      setState(() => error = 'Template could not be saved');
    }
  }

  Future<void> validate() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = isOpening
          ? await opening.validate(csv!, mapping)
          : await widget.repository.validate(kind, csv!, mapping,
              createCategories: createCategories);
      if (mounted) {
        setState(() {
          preview = value;
          step = 2;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() =>
            error = e is FormatException ? e.message : 'Validation failed: $e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> commit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = isOpening
          ? await opening.commit(
              widget.user, preview!, csv!, mapping, fileName!)
          : await widget.repository.commit(
              widget.user, kind, preview!, mapping, fileName!,
              createCategories: createCategories);
      if (mounted) {
        setState(() {
          result = value;
          step = 4;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error =
              'Import failed. No records were imported. ${e is StateError ? e.message : 'Check the file and try again.'}';
          step = 3;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const labels = [
      'Choose file',
      'Map columns',
      'Validate',
      'Review',
      'Results'
    ];
    return PopScope(
        canPop: !busy,
        child: Material(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: AppWorkspacePadding(
            child: SingleChildScrollView(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
              const AppPageHeader(
                  title: 'Import Data',
                  subtitle:
                      'Import master records or opening inventory from a local CSV file.'),
              Wrap(spacing: 8, children: [
                for (var i = 0; i < labels.length; i++)
                  Chip(
                      label: Text('${i < step ? '✓' : i + 1} ${labels[i]}'),
                      backgroundColor: i == step
                          ? Theme.of(context).colorScheme.primaryContainer
                          : null)
              ]),
              if (error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              if (step == 0)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Choose data type'),
                              DropdownButton<ImportKind>(
                                  value: kind,
                                  items: [
                                    for (final k in ImportKind.values)
                                      if (k == ImportKind.products
                                          ? widget.user
                                              .can(PosPermission.manageCatalog)
                                          : k == ImportKind.openingInventory
                                              ? widget.user.can(
                                                  PosPermission.stockReceiving)
                                              : widget.user.can(
                                                  PosPermission.manageContacts))
                                        DropdownMenuItem(
                                            value: k,
                                            child: Text(
                                                k == ImportKind.openingInventory
                                                    ? 'Opening Inventory'
                                                    : k.name[0].toUpperCase() +
                                                        k.name.substring(1)))
                                  ],
                                  onChanged: (k) {
                                    if (k != null) {
                                      setState(() {
                                        kind = k;
                                        csv = null;
                                      });
                                    }
                                  }),
                              const SizedBox(height: 8),
                              Wrap(spacing: 12, children: [
                                OutlinedButton.icon(
                                    onPressed: template,
                                    icon: const Icon(Icons.download_outlined),
                                    label: const Text('Download template')),
                                FilledButton.icon(
                                    onPressed: pick,
                                    icon: const Icon(Icons.upload_file),
                                    label: const Text('Select CSV'))
                              ]),
                              const SizedBox(height: 8),
                              Text(isOpening
                                  ? 'Opening Inventory is for stock held before using this POS. Later stock belongs in Receiving or Stock Adjustments. CSV expiry dates use YYYY-MM-DD.'
                                  : 'Products import master data only. Opening stock, inventory layers, and movements are not imported.'),
                            ]))),
              if (step == 1 && csv != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${csv!.length - 1} rows in $fileName'),
                              const SizedBox(height: 8),
                              Text(isOpening
                                  ? 'Map quantity and unit cost. Identify each existing product by SKU, barcode, or exact name.'
                                  : 'Map CSV columns to app fields. Name is required.'),
                              for (final header in csv!.first)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(children: [
                                    Expanded(child: Text(header)),
                                    Expanded(
                                        child: DropdownButton<String>(
                                      isExpanded: true,
                                      value: mapping[header],
                                      hint: const Text('Ignore'),
                                      items: [
                                        const DropdownMenuItem<String>(
                                            value: null, child: Text('Ignore')),
                                        for (final field
                                            in ImportCsv.fields(kind))
                                          DropdownMenuItem(
                                              value: field,
                                              child: Text([
                                                'name',
                                                'quantity',
                                                'unit_cost'
                                              ].contains(field)
                                                  ? '$field *'
                                                  : field)),
                                      ],
                                      onChanged: (value) => setState(() {
                                        mapping
                                            .removeWhere((k, v) => v == value);
                                        if (value == null) {
                                          mapping.remove(header);
                                        } else {
                                          mapping[header] = value;
                                        }
                                      }),
                                    )),
                                  ]),
                                ),
                              if (kind == ImportKind.products &&
                                  csv!.first.any((h) => [
                                        'quantity',
                                        'stock',
                                        'opening_stock',
                                        'opening quantity'
                                      ].contains(h.trim().toLowerCase())))
                                const Text(
                                    'Opening inventory columns are ignored. No stock will be created.'),
                              if (kind == ImportKind.products)
                                SwitchListTile(
                                    value: createCategories,
                                    title:
                                        const Text('Create missing categories'),
                                    subtitle: const Text(
                                        'Off by default; review new category names before import.'),
                                    onChanged: (v) =>
                                        setState(() => createCategories = v)),
                              Row(children: [
                                TextButton(
                                    onPressed: () => setState(() => step = 0),
                                    child: const Text('Back')),
                                FilledButton(
                                    onPressed: busy ? null : validate,
                                    child: const Text('Validate'))
                              ]),
                            ]))),
              if ((step == 2 || step == 3) && preview != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${preview!.rows.length} rows • ${preview!.ready} ready • ${preview!.warnings} warnings • ${preview!.errors} errors'),
                              if (preview!.missingCategories.isNotEmpty)
                                Text(
                                    'New categories: ${preview!.missingCategories.join(', ')}'),
                              if (isOpening)
                                Text(
                                    'Products: ${preview!.rows.where((r) => r.ready).map((r) => r.existingId).toSet().length} • Layers: ${preview!.ready} • Opening value: ${_money(preview!.rows.where((r) => r.ready).fold<int>(0, (sum, r) => sum + OpeningInventoryImportRepository.valueCents(r)))}'),
                              Wrap(spacing: 8, children: [
                                for (final f in [
                                  'All',
                                  'Ready',
                                  'Warnings',
                                  'Errors'
                                ])
                                  ChoiceChip(
                                      label: Text(f),
                                      selected: filter == f,
                                      onSelected: (_) =>
                                          setState(() => filter = f))
                              ]),
                              SizedBox(
                                  height: 360,
                                  child: ListView.builder(
                                      itemCount: preview!.rows
                                          .where((r) =>
                                              filter == 'All' ||
                                              (filter == 'Ready' && r.ready) ||
                                              (filter == 'Warnings' &&
                                                  r.warnings.isNotEmpty) ||
                                              (filter == 'Errors' &&
                                                  r.errors.isNotEmpty))
                                          .length,
                                      itemBuilder: (context, index) {
                                        final r = preview!.rows
                                            .where((r) =>
                                                filter == 'All' ||
                                                (filter == 'Ready' &&
                                                    r.ready) ||
                                                (filter == 'Warnings' &&
                                                    r.warnings.isNotEmpty) ||
                                                (filter == 'Errors' &&
                                                    r.errors.isNotEmpty))
                                            .elementAt(index);
                                        return ListTile(
                                            title: Text(isOpening
                                                ? 'Row ${r.number} • ${r.existingName ?? r.values['product'] ?? r.values['sku'] ?? r.values['barcode'] ?? ''} • ${r.values['quantity'] ?? ''} × ${r.values['unit_cost'] ?? ''} = ${_money(OpeningInventoryImportRepository.valueCents(r))}'
                                                : 'Row ${r.number} • ${r.values['name'] ?? ''}'),
                                            subtitle: Text([
                                              ...r.errors,
                                              ...r.warnings,
                                              if (r.action ==
                                                  ImportAction.update)
                                                ...r.changes.entries.map((e) =>
                                                    '${e.key}: ${e.value}'),
                                            ].isEmpty
                                                ? 'Ready'
                                                : [
                                                    ...r.errors,
                                                    ...r.warnings,
                                                    if (r.action ==
                                                        ImportAction.update)
                                                      ...r.changes.entries.map(
                                                          (e) =>
                                                              '${e.key}: ${e.value}'),
                                                  ].join(' • ')),
                                            trailing: (isOpening
                                                    ? !r.warnings.any((w) =>
                                                        w.contains(
                                                            'Prior opening'))
                                                    : r.existingId == null)
                                                ? null
                                                : DropdownButton<ImportAction>(
                                                    value: r.action,
                                                    items: (isOpening
                                                            ? [
                                                                ImportAction
                                                                    .skip,
                                                                ImportAction
                                                                    .create
                                                              ]
                                                            : ImportAction
                                                                .values)
                                                        .map((a) => DropdownMenuItem(
                                                            value: a,
                                                            child: Text(isOpening && a == ImportAction.create ? 'Add another layer' : a.name)))
                                                        .toList(),
                                                    onChanged: (a) => setState(() => r.action = a!)));
                                      })),
                              if (step == 2)
                                Row(children: [
                                  TextButton(
                                      onPressed: () => setState(() => step = 1),
                                      child: const Text('Back')),
                                  FilledButton(
                                      onPressed: preview!.ready == 0
                                          ? null
                                          : () => setState(() => step = 3),
                                      child: const Text('Review import'))
                                ]),
                              if (step == 3)
                                Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(isOpening
                                          ? 'Import opening inventory? ${preview!.ready} layers will be created. Value: ${_money(preview!.rows.where((r) => r.ready).fold<int>(0, (sum, r) => sum + OpeningInventoryImportRepository.valueCents(r)))}. ${preview!.rows.length - preview!.ready} rows will be skipped.'
                                          : 'Import ${preview!.ready} ${kind.name}? ${preview!.rows.length - preview!.ready} will be skipped.'),
                                      Text(isOpening
                                          ? 'This creates actual stock and inventory movements. It creates no Receiving or Purchase Order records.'
                                          : 'Blank cells leave existing values unchanged on update. Product cost changes the reference cost only. No inventory quantity will change.'),
                                      Row(children: [
                                        TextButton(
                                            onPressed: busy
                                                ? null
                                                : () =>
                                                    setState(() => step = 2),
                                            child: const Text('Back')),
                                        FilledButton(
                                            onPressed: busy ? null : commit,
                                            child: Text(busy
                                                ? 'Importing…'
                                                : isOpening
                                                    ? 'Import opening inventory'
                                                    : 'Import ${preview!.ready}'))
                                      ])
                                    ]),
                            ]))),
              if (step == 4 && result != null)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(isOpening
                                  ? 'Opening inventory imported'
                                  : 'Import complete'),
                              Text(isOpening
                                  ? 'Products affected: ${result!.productsAffected} • Layers created: ${result!.created} • Serials created: ${result!.serialsCreated} • Value: ${_money(result!.valueCents)} • Skipped: ${result!.skipped}'
                                  : 'Created: ${result!.created} • Updated: ${result!.updated} • Skipped: ${result!.skipped} • Errors: 0'),
                              FilledButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('Done')),
                              if (widget.onViewImported != null &&
                                  (kind == ImportKind.products || isOpening))
                                TextButton(
                                    onPressed: () =>
                                        widget.onViewImported!(kind),
                                    child: Text(isOpening
                                        ? 'View inventory'
                                        : 'View imported records')),
                              if (isOpening && widget.onViewMovements != null)
                                TextButton(
                                    onPressed: widget.onViewMovements,
                                    child: const Text('View movements'))
                            ]))),
            ])))));
  }

  String _money(int cents) => formatPeso(cents);
}
