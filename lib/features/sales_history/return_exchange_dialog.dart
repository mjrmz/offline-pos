import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../core/models/product.dart';
import '../../data/database.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/sale_return_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';

class ReturnExchangeDialog extends StatefulWidget {
  final SaleReturnRepository repository;
  final ActiveUser actor;
  final String saleId;
  final String receipt;
  final PosRepository? pos;
  const ReturnExchangeDialog(
      {super.key,
      required this.repository,
      required this.actor,
      required this.saleId,
      required this.receipt,
      this.pos});

  @override
  State<ReturnExchangeDialog> createState() => _ReturnExchangeDialogState();
}

class _ReturnExchangeDialogState extends State<ReturnExchangeDialog> {
  List<ReturnableLine>? lines;
  final quantities = <String, TextEditingController>{};
  final sellable = <String, bool>{};
  final serials = <String, Set<String>>{};
  final notes = TextEditingController();
  final cashTendered = TextEditingController(text: '0');
  final replacementSearch = TextEditingController();
  final replacementQuantity = TextEditingController(text: '1');
  List<PosProduct> products = [];
  PosProduct? replacement;
  List<SerialUnit> replacementSerials = [];
  List<ProductLot> replacementBatches = [];
  final replacementSerialIds = <String>{};
  final addedReplacements = <(SaleLineRequest, String, int)>[];
  String? replacementBatchId;
  String replacementMode = 'ordinary';
  bool exchange = false;
  String? reason;
  String? error;
  bool busy = false;
  static const reasons = [
    'Customer changed mind',
    'Wrong item',
    'Wrong quantity',
    'Defective on arrival',
    'Damaged',
    'Price correction',
    'Duplicate sale',
    'Other'
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.repository.returnable(widget.saleId);
      final catalog = await widget.pos?.products() ?? <PosProduct>[];
      if (mounted) {
        setState(() {
          lines = result;
          products = catalog;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  @override
  void dispose() {
    for (final controller in quantities.values) {
      controller.dispose();
    }
    notes.dispose();
    cashTendered.dispose();
    replacementSearch.dispose();
    replacementQuantity.dispose();
    super.dispose();
  }

  int _selected(ReturnableLine line) {
    if (line.serialized) {
      return (serials[line.item.id]?.length ?? 0) * Quantity.scale;
    }
    return Quantity.tryParse(quantities[line.item.id]?.text ?? '',
            fractional: line.item.saleUnit != 'pcs') ??
        0;
  }

  int _refund(ReturnableLine line) {
    final qty = _selected(line);
    if (qty <= 0 || qty > line.remainingMilli) return 0;
    final before =
        line.item.lineTotalCents * line.returnedMilli ~/ line.soldMilli;
    final after =
        line.item.lineTotalCents * (line.returnedMilli + qty) ~/ line.soldMilli;
    return after - before;
  }

  (SaleLineRequest, String, int)? _replacementDraft() {
    final product = replacement;
    if (product == null) return null;
    final milli = product.serialTracking
        ? replacementSerialIds.length * Quantity.scale
        : Quantity.tryParse(replacementQuantity.text,
            fractional: product.business.fractional);
    if (milli == null ||
        milli <= 0 ||
        product.business.batch && replacementBatchId == null) {
      throw StateError('Enter a valid replacement quantity and batch');
    }
    return (
      SaleLineRequest(product.id, milli ~/ Quantity.scale,
          quantityMilli: milli,
          mode: replacementMode,
          batchId: replacementBatchId,
          serialIds: replacementSerialIds.toList()),
      product.name,
      Quantity.lineCents(product.priceCents + _replacementExtra(product), milli)
    );
  }

  int _replacementExtra(PosProduct product) => switch (replacementMode) {
        'deposit' => product.business.depositCents,
        'container' => product.business.containerPriceCents,
        _ => 0,
      };

  void _addReplacement() {
    try {
      final draft = _replacementDraft();
      if (draft == null) return;
      setState(() {
        addedReplacements.add(draft);
        replacement = null;
        replacementSerialIds.clear();
        replacementBatchId = null;
        replacementMode = 'ordinary';
        replacementQuantity.text = '1';
        error = null;
      });
    } catch (e) {
      setState(() => error = safeMessage(e));
    }
  }

  Future<void> _finalize() async {
    if (busy) return;
    final selected = <ReturnSelection>[];
    for (final line in lines ?? const <ReturnableLine>[]) {
      final input = quantities[line.item.id]?.text.trim() ?? '';
      final qty = _selected(line);
      if (!line.serialized &&
          input.isNotEmpty &&
          !RegExp(r'^0(?:\.0{1,3})?$').hasMatch(input) &&
          qty == 0) {
        setState(() => error =
            'Enter a valid return quantity for ${line.item.productName}.');
        return;
      }
      if (qty == 0) continue;
      selected.add(ReturnSelection(line.item.id, qty,
          sellable: sellable[line.item.id] ?? true,
          serialIds: serials[line.item.id]?.toList() ?? const []));
    }
    if (selected.isEmpty) {
      setState(() => error = 'Select at least one item to return.');
      return;
    }
    if (reason == null || reason == 'Other' && notes.text.trim().isEmpty) {
      setState(() => error = 'Select a reason and add notes for Other.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      CommercialReturn result;
      if (exchange) {
        final draft = _replacementDraft();
        final requests = [
          ...addedReplacements.map((row) => row.$1),
          if (draft != null) draft.$1,
        ];
        final tendered = tryParsePeso(cashTendered.text);
        if (requests.isEmpty || widget.pos == null || tendered == null) {
          throw StateError(
              'Select replacement items and enter valid cash tendered');
        }
        result = await widget.repository.exchange(
            widget.actor, widget.saleId, selected, requests, widget.pos!,
            reason: reason!, notes: notes.text, cashTenderedCents: tendered);
      } else {
        result = await widget.repository.finalize(
            widget.actor, widget.saleId, selected,
            reason: reason!, notes: notes.text);
      }
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = safeMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = lines;
    final refund = data?.fold<int>(0, (sum, line) => sum + _refund(line)) ?? 0;
    final selectedLines = data?.where((line) => _selected(line) > 0).toList() ??
        const <ReturnableLine>[];
    final restoredLines =
        selectedLines.where((line) => sellable[line.item.id] ?? true).length;
    final draftMilli = replacement == null
        ? 0
        : replacement!.serialTracking
            ? replacementSerialIds.length * Quantity.scale
            : Quantity.tryParse(replacementQuantity.text,
                    fractional: replacement!.business.fractional) ??
                0;
    final replacementEstimate =
        addedReplacements.fold<int>(0, (sum, row) => sum + row.$3) +
            (replacement == null
                ? 0
                : Quantity.lineCents(
                    replacement!.priceCents + _replacementExtra(replacement!),
                    draftMilli));
    return Dialog(
        child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 1000,
                maxHeight: MediaQuery.sizeOf(context).height - 40),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 12, 8),
                  child: Row(children: [
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('Return / Exchange',
                              style: Theme.of(context).textTheme.headlineSmall),
                          Text('Original receipt: ${widget.receipt}')
                        ])),
                    IconButton(
                        tooltip: 'Close',
                        onPressed: busy ? null : () => Navigator.pop(context),
                        icon: const Icon(Icons.close))
                  ])),
              const Divider(),
              Flexible(
                  child: data == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          children: [
                              const Text('ITEMS'),
                              for (final line in data)
                                Card(
                                    child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(line.item.productName,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium),
                                              Text(
                                                  'Sold ${Quantity.format(line.soldMilli)} ${line.item.saleUnit}  •  '
                                                  'Already returned ${Quantity.format(line.returnedMilli)}  •  '
                                                  'Returnable ${Quantity.format(line.remainingMilli)}'),
                                              if (line.limitation != null)
                                                Text(line.limitation!,
                                                    style: TextStyle(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .error)),
                                              if (line.limitation == null &&
                                                  line.remainingMilli > 0) ...[
                                                if (line.serialized)
                                                  Wrap(spacing: 8, children: [
                                                    for (final serial in line
                                                        .returnableSerials)
                                                      FilterChip(
                                                          label: Text(serial
                                                              .serialNumber),
                                                          selected: serials[line
                                                                      .item.id]
                                                                  ?.contains(
                                                                      serial
                                                                          .id) ??
                                                              false,
                                                          onSelected: busy
                                                              ? null
                                                              : (value) =>
                                                                  setState(() {
                                                                    final selected = serials.putIfAbsent(
                                                                        line.item
                                                                            .id,
                                                                        () =>
                                                                            <String>{});
                                                                    value
                                                                        ? selected.add(serial
                                                                            .id)
                                                                        : selected
                                                                            .remove(serial.id);
                                                                  }))
                                                  ])
                                                else
                                                  SizedBox(
                                                      width: 180,
                                                      child: TextField(
                                                          controller: quantities
                                                              .putIfAbsent(
                                                                  line.item.id,
                                                                  () =>
                                                                      TextEditingController()),
                                                          enabled: !busy,
                                                          keyboardType:
                                                              const TextInputType
                                                                  .numberWithOptions(
                                                                  decimal:
                                                                      true),
                                                          decoration:
                                                              const InputDecoration(
                                                                  labelText:
                                                                      'Return now'),
                                                          onChanged: (_) =>
                                                              setState(() {}))),
                                                DropdownButton<bool>(
                                                    value: sellable[
                                                            line.item.id] ??
                                                        true,
                                                    items: const [
                                                      DropdownMenuItem(
                                                          value: true,
                                                          child: Text(
                                                              'Return to sellable stock')),
                                                      DropdownMenuItem(
                                                          value: false,
                                                          child: Text(
                                                              'Do not return to sellable stock'))
                                                    ],
                                                    onChanged: busy
                                                        ? null
                                                        : (value) => setState(
                                                            () => sellable[line
                                                                    .item.id] =
                                                                value ?? true)),
                                                Text(
                                                    'Line refund: ${formatPeso(_refund(line))}'),
                                                if (_selected(line) >
                                                    line.remainingMilli)
                                                  Text(
                                                      'Exceeds returnable quantity',
                                                      style: TextStyle(
                                                          color:
                                                              Theme.of(context)
                                                                  .colorScheme
                                                                  .error)),
                                              ]
                                            ]))),
                              DropdownButtonFormField<String>(
                                  initialValue: reason,
                                  decoration: const InputDecoration(
                                      labelText: 'Reason *'),
                                  items: [
                                    for (final value in reasons)
                                      DropdownMenuItem(
                                          value: value, child: Text(value))
                                  ],
                                  onChanged: busy
                                      ? null
                                      : (value) =>
                                          setState(() => reason = value)),
                              if (reason == 'Defective on arrival')
                                const Text(
                                    'For a warranty claim after use, open RMA from the sale detail instead.'),
                              TextField(
                                  controller: notes,
                                  enabled: !busy,
                                  decoration: InputDecoration(
                                      labelText: reason == 'Other'
                                          ? 'Notes *'
                                          : 'Notes')),
                              if (widget.pos != null) ...[
                                const SizedBox(height: 12),
                                SegmentedButton<bool>(
                                    segments: const [
                                      ButtonSegment(
                                          value: false, label: Text('Refund')),
                                      ButtonSegment(
                                          value: true, label: Text('Exchange'))
                                    ],
                                    selected: {
                                      exchange
                                    },
                                    onSelectionChanged: busy
                                        ? null
                                        : (values) => setState(
                                            () => exchange = values.first)),
                              ],
                              if (exchange) ...[
                                if (widget.pos!.birReady)
                                  const Text(
                                      'BIR-ready exchanges require a compliant credit document workflow.'),
                                TextField(
                                    controller: replacementSearch,
                                    decoration: const InputDecoration(
                                        labelText:
                                            'Search replacement name, SKU, or barcode'),
                                    onChanged: (_) => setState(() {})),
                                for (final product in products.where((p) {
                                  final q = replacementSearch.text
                                      .trim()
                                      .toLowerCase();
                                  return q.isNotEmpty &&
                                      p.isActive &&
                                      (p.name.toLowerCase().contains(q) ||
                                          (p.sku ?? '')
                                              .toLowerCase()
                                              .contains(q) ||
                                          (p.barcode ?? '')
                                              .toLowerCase()
                                              .contains(q));
                                }).take(6))
                                  ListTile(
                                      title: Text(product.name),
                                      subtitle:
                                          Text(formatPeso(product.priceCents)),
                                      trailing: const Icon(Icons.add),
                                      onTap: busy
                                          ? null
                                          : () async {
                                              final serials = product
                                                      .serialTracking
                                                  ? await widget.pos!
                                                      .availableSerials(
                                                          product.id)
                                                  : <SerialUnit>[];
                                              final batches =
                                                  product.business.batch
                                                      ? await widget.pos!
                                                          .batches(product.id)
                                                      : <ProductLot>[];
                                              if (mounted) {
                                                setState(() {
                                                  replacement = product;
                                                  replacementSerials = serials;
                                                  replacementBatches = batches;
                                                  replacementSerialIds.clear();
                                                  replacementBatchId = null;
                                                  replacementMode = product
                                                          .business.tank
                                                      ? 'exchange'
                                                      : product.business.refill
                                                          ? 'refill'
                                                          : product.business
                                                                  .madeToOrder
                                                              ? 'made_order'
                                                              : 'ordinary';
                                                  replacementSearch.clear();
                                                });
                                              }
                                            }),
                                if (replacement != null) ...[
                                  ListTile(
                                      title: Text(replacement!.name),
                                      subtitle: Text(
                                          'Current price: ${formatPeso(replacement!.priceCents)}'),
                                      trailing: IconButton(
                                          icon: const Icon(Icons.close),
                                          onPressed: () => setState(
                                              () => replacement = null))),
                                  if (replacement!.serialTracking)
                                    Wrap(spacing: 8, children: [
                                      for (final serial in replacementSerials)
                                        FilterChip(
                                            label: Text(serial.serialNumber),
                                            selected: replacementSerialIds
                                                .contains(serial.id),
                                            onSelected: (value) => setState(() {
                                                  value
                                                      ? replacementSerialIds
                                                          .add(serial.id)
                                                      : replacementSerialIds
                                                          .remove(serial.id);
                                                }))
                                    ])
                                  else
                                    TextField(
                                        controller: replacementQuantity,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(decimal: true),
                                        decoration: const InputDecoration(
                                            labelText: 'Replacement quantity'),
                                        onChanged: (_) => setState(() {})),
                                  if (replacement!.business.batch)
                                    DropdownButton<String>(
                                        value: replacementBatchId,
                                        hint: const Text(
                                            'Select replacement batch'),
                                        items: [
                                          for (final batch
                                              in replacementBatches.where(
                                                  (b) => b.quantityMilli > 0))
                                            DropdownMenuItem(
                                                value: batch.id,
                                                child: Text(batch.batchNumber))
                                        ],
                                        onChanged: (id) => setState(
                                            () => replacementBatchId = id)),
                                  if (replacement!.business.tank ||
                                      replacement!.business.refill)
                                    DropdownButton<String>(
                                        value: replacementMode,
                                        items: [
                                          for (final mode in replacement!
                                                  .business.tank
                                              ? const ['exchange', 'deposit']
                                              : const ['refill', 'container'])
                                            DropdownMenuItem(
                                                value: mode,
                                                child: Text(mode == 'exchange'
                                                    ? 'Tank exchange'
                                                    : mode == 'deposit'
                                                        ? 'Tank deposit'
                                                        : mode == 'refill'
                                                            ? 'Refill'
                                                            : 'Container'))
                                        ],
                                        onChanged: (mode) => setState(() =>
                                            replacementMode =
                                                mode ?? replacementMode)),
                                  TextButton.icon(
                                      onPressed: busy ? null : _addReplacement,
                                      icon: const Icon(Icons.add),
                                      label:
                                          const Text('Add replacement item')),
                                ],
                                for (var i = 0;
                                    i < addedReplacements.length;
                                    i++)
                                  ListTile(
                                      title: Text(addedReplacements[i].$2),
                                      subtitle: Text(
                                          'Estimated ${formatPeso(addedReplacements[i].$3)}'),
                                      trailing: IconButton(
                                          icon:
                                              const Icon(Icons.delete_outline),
                                          onPressed: busy
                                              ? null
                                              : () => setState(() =>
                                                  addedReplacements
                                                      .removeAt(i)))),
                                TextField(
                                    controller: cashTendered,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                        labelText:
                                            'Exact customer payment difference (peso; 0 if none)')),
                              ],
                              const SizedBox(height: 16),
                              Text('RETURN SUMMARY',
                                  style:
                                      Theme.of(context).textTheme.labelMedium),
                              Text('Items selected: ${selectedLines.length}'),
                              Text('Return to sellable stock: $restoredLines'),
                              Text(
                                  'Non-sellable: ${selectedLines.length - restoredLines}'),
                              Text('Refund subtotal: ${formatPeso(refund)}'),
                              Text(
                                  exchange
                                      ? replacementEstimate > refund
                                          ? 'Customer pays about ${formatPeso(replacementEstimate - refund)}'
                                          : replacementEstimate < refund
                                              ? 'Customer refund about ${formatPeso(refund - replacementEstimate)}'
                                              : 'Even exchange: no cash movement'
                                      : 'Cash refund: ${formatPeso(refund)}',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              if (error != null)
                                Text(error!,
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error)),
                              const SizedBox(height: 16),
                            ])),
              const Divider(),
              Padding(
                  padding: const EdgeInsets.all(12),
                  child:
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                        onPressed: busy ? null : () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(
                        onPressed: busy ||
                                data == null ||
                                (exchange && widget.pos?.birReady == true)
                            ? null
                            : _finalize,
                        child: Text(busy
                            ? 'Finalizing…'
                            : exchange
                                ? 'Finalize exchange'
                                : 'Finalize cash refund'))
                  ]))
            ])));
  }
}
