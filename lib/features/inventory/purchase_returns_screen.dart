import 'package:drift/drift.dart' show OrderingTerm, OrderingMode;
import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/purchase_return_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../data/daos/supplier_payables_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_confirm_dialog.dart';
import '../../shared/widgets/app_workspace.dart';

class PurchaseReturnsScreen extends StatefulWidget {
  final PurchaseReturnRepository repository;
  final ActiveUser user;
  final String? initialReceivingId;
  final String? initialSupplierId;
  final String? initialReturnId;
  const PurchaseReturnsScreen(
      {super.key,
      required this.repository,
      required this.user,
      this.initialReceivingId,
      this.initialSupplierId,
      this.initialReturnId});
  @override
  State<PurchaseReturnsScreen> createState() => _PurchaseReturnsScreenState();
}

class _PurchaseReturnsScreenState extends State<PurchaseReturnsScreen> {
  int page = 0;
  String search = '', status = 'All', resolution = 'All';
  String? supplierFilter;
  DateTimeRange? dateRange;
  String? receivingId;
  bool editing = false, busy = false;
  PurchaseReturn? editingDraft;
  List<StockReceiving> receivings = [];
  List<Supplier> suppliers = [];
  List<PurchaseOrder> purchaseOrders = [];
  List<PurchaseReturnSource> sources = [];
  final quantities = <String, TextEditingController>{};
  final reasons = <String, PurchaseReturnReason>{};
  final selectedSerials = <String, Set<String>>{};
  PurchaseReturnResolution draftResolution =
      PurchaseReturnResolution.unresolved;
  final notes = TextEditingController();
  final supplierReference = TextEditingController();
  late Future<dynamic> rows;
  AppDatabase get db => widget.repository.db;
  bool initialOpened = false;

  @override
  void initState() {
    super.initState();
    receivingId = widget.initialReceivingId;
    editing = receivingId != null;
    _reload();
    _loadSources();
  }

  @override
  void dispose() {
    for (final controller in quantities.values) {
      controller.dispose();
    }
    notes.dispose();
    supplierReference.dispose();
    super.dispose();
  }

  void _reload() {
    rows = widget.repository.page(
        page: page,
        search: search,
        status: status,
        resolution: resolution,
        supplierId: widget.initialSupplierId ?? supplierFilter,
        from: dateRange?.start,
        through: dateRange?.end);
    _loadLookups();
  }

  Future<void> _loadLookups() async {
    final receipts = await (db.select(db.stockReceivings)
          ..orderBy([
            (r) =>
                OrderingTerm(expression: r.receivedAt, mode: OrderingMode.desc)
          ]))
        .get();
    final supplierRows = await db.select(db.suppliers).get();
    final orderRows = await db.select(db.purchaseOrders).get();
    if (mounted) {
      setState(() {
        receivings = receipts
            .where((r) =>
                widget.initialSupplierId == null ||
                r.supplierId == widget.initialSupplierId)
            .toList();
        suppliers = supplierRows;
        purchaseOrders = orderRows;
      });
      if (!initialOpened && widget.initialReturnId != null) {
        initialOpened = true;
        final row = await (db.select(db.purchaseReturns)
              ..where((r) => r.id.equals(widget.initialReturnId!)))
            .getSingleOrNull();
        if (row != null && mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _detail(row);
          });
        }
      }
    }
  }

  Future<void> _loadSources() async {
    final id = receivingId;
    if (id == null) return;
    final result = await widget.repository.sources(id);
    if (mounted && receivingId == id) {
      setState(() {
        sources = result;
      });
    }
  }

  String _supplier(String id) =>
      suppliers.where((s) => s.id == id).firstOrNull?.name ?? 'Supplier';
  String _receiving(String id) =>
      receivings.where((r) => r.id == id).firstOrNull == null
          ? 'Receiving'
          : StockReceivingRepository.number(
              receivings.firstWhere((r) => r.id == id));
  String _order(String? id) => id == null
      ? ''
      : purchaseOrders.where((o) => o.id == id).firstOrNull == null
          ? ''
          : PurchaseOrderRepository.number(
              purchaseOrders.firstWhere((o) => o.id == id));

  void _start([String? id]) {
    setState(() {
      editing = true;
      editingDraft = null;
      receivingId = id;
      sources = [];
    });
    _loadSources();
  }

  Future<void> _edit(PurchaseReturn row) async {
    final lines = await widget.repository.lines(row.id);
    final sourceRows = await widget.repository.sources(row.receivingId);
    for (final controller in quantities.values) {
      controller.dispose();
    }
    quantities.clear();
    reasons.clear();
    selectedSerials.clear();
    for (final line in lines) {
      final controller = quantities.putIfAbsent(
          line.receivingItemId, TextEditingController.new);
      final old = Quantity.tryParse(controller.text) ?? 0;
      controller.text = Quantity.format(old + line.quantityMilli);
      reasons[line.receivingItemId] =
          PurchaseReturnReason.values.byName(line.reason);
      if (line.serialUnitId != null) {
        final source = sourceRows
            .where((s) => s.item.id == line.receivingItemId)
            .firstOrNull;
        if (source?.serials.any((s) => s.id == line.serialUnitId) == true) {
          selectedSerials
              .putIfAbsent(line.receivingItemId, () => <String>{})
              .add(line.serialUnitId!);
        }
      }
    }
    for (final source in sourceRows.where((s) => s.product.serialTracking)) {
      quantities.putIfAbsent(source.item.id, TextEditingController.new).text =
          '${selectedSerials[source.item.id]?.length ?? 0}';
    }
    if (!mounted) return;
    setState(() {
      editing = true;
      editingDraft = row;
      receivingId = row.receivingId;
      sources = sourceRows;
      notes.text = row.notes ?? '';
      supplierReference.text = row.supplierReturnReference ?? '';
      draftResolution = PurchaseReturnResolution.values.byName(row.resolution);
    });
  }

  List<PurchaseReturnLineInput> _inputs() {
    final result = <PurchaseReturnLineInput>[];
    for (final source in sources) {
      final qty =
          Quantity.tryParse(quantities[source.item.id]?.text ?? '') ?? 0;
      if (qty <= 0) continue;
      result.add(PurchaseReturnLineInput(source.item.id, qty,
          reasons[source.item.id] ?? PurchaseReturnReason.other,
          serialUnitIds: selectedSerials[source.item.id]?.toList() ?? []));
    }
    return result;
  }

  Future<void> _save({required bool finalize}) async {
    if (receivingId == null) {
      _error('Select a source receiving');
      return;
    }
    List<PurchaseReturnLineInput> lines;
    try {
      lines = _inputs();
    } catch (_) {
      _error('Enter valid return quantities');
      return;
    }
    if (lines.isEmpty) {
      _error('Select at least one item');
      return;
    }
    final totalQty =
        lines.fold<int>(0, (sum, line) => sum + line.quantityMilli);
    setState(() => busy = true);
    try {
      final row = await widget.repository.createDraft(
          widget.user, receivingId!, lines,
          notes: notes.text.trim(),
          supplierReturnReference: supplierReference.text.trim(),
          resolution: draftResolution,
          existingId: editingDraft?.id);
      if (finalize) {
        if (!mounted) return;
        final approved = await showAppDestructiveConfirmDialog(
            context: context,
            title: 'Finalize purchase return?',
            impact:
                'This will remove ${Quantity.format(totalQty)} units from available inventory and record ${PurchaseReturnRepository.number(row)}. The original Receiving record will remain unchanged.',
            confirmLabel: 'Finalize return',
            cancelLabel: 'Keep editing');
        if (!approved) {
          if (mounted) {
            setState(() {
              editingDraft = row;
              busy = false;
            });
          }
          return;
        }
      }
      if (finalize) await widget.repository.finalize(widget.user, row.id);
      if (!mounted) return;
      setState(() {
        busy = false;
        editing = false;
        page = 0;
        _reload();
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '${PurchaseReturnRepository.number(row)} ${finalize ? 'finalized' : 'saved as draft'}')));
    } catch (error) {
      if (!mounted) return;
      setState(() => busy = false);
      _error(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  void _error(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _review() async {
    final lines = _inputs();
    if (lines.isEmpty || receivingId == null) {
      _error('Select at least one item');
      return;
    }
    final receipt = receivings.where((r) => r.id == receivingId).firstOrNull;
    final total = lines.fold<int>(0, (sum, line) {
      final source =
          sources.firstWhere((s) => s.item.id == line.receivingItemId);
      return sum +
          Quantity.lineCents(source.layer.unitCostCents, line.quantityMilli);
    });
    await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: const Text('Review purchase return'),
              content: SizedBox(
                  width: 620,
                  child: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                            '${_supplier(receipt?.supplierId ?? '')} · ${_receiving(receivingId!)}'),
                        for (final line in lines)
                          Builder(builder: (_) {
                            final source = sources.firstWhere(
                                (s) => s.item.id == line.receivingItemId);
                            return ListTile(
                                dense: true,
                                title: Text(source.product.name),
                                subtitle: Text(
                                    '${Quantity.format(line.quantityMilli)} · ${formatPeso(source.layer.unitCostCents)} · ${line.reason.label}'
                                    '${source.layer.batchNumber == null ? '' : ' · ${source.layer.batchNumber}'}'),
                                trailing: Text(formatPeso(Quantity.lineCents(
                                    source.layer.unitCostCents,
                                    line.quantityMilli))));
                          }),
                        Text('Total return value: ${formatPeso(total)}'),
                        Text('Resolution: ${draftResolution.label}'),
                        const SizedBox(height: 8),
                        const Text(
                            'Finalizing will remove these items from available inventory.'),
                      ]))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Keep editing')),
                FilledButton(
                    onPressed: () {
                      Navigator.pop(dialog);
                      _save(finalize: true);
                    },
                    child: const Text('Continue to finalization')),
              ],
            ));
  }

  Future<void> _detail(PurchaseReturn row) async {
    final lines = await widget.repository.lines(row.id);
    final appliedCredit = await SupplierPayablesRepository(db)
        .appliedCreditForReturn(row);
    final products = await db.select(db.products).get();
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: Text(PurchaseReturnRepository.number(row)),
              content: SizedBox(
                  width: 640,
                  child: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(
                            '${_supplier(row.supplierId)} · ${_receiving(row.receivingId)}'),
                        Text(
                            'Status: ${row.status} · ${PurchaseReturnResolution.values.byName(row.resolution).label}'),
                        if (_order(row.purchaseOrderId).isNotEmpty)
                          Text(
                              'Purchase Order: ${_order(row.purchaseOrderId)}'),
                        if (row.supplierReturnReference?.isNotEmpty == true)
                          Text(
                              'Supplier reference: ${row.supplierReturnReference}'),
                        if (row.creditReference?.isNotEmpty == true)
                          Text('Credit reference: ${row.creditReference}'),
                        if (row.creditAmountCents != null)
                          Text(
                              'Confirmed credit: ${formatPeso(row.creditAmountCents!)}'),
                        if (row.status == 'finalized' && row.resolution == 'supplierCredit')
                          Text('Applied to payable ${_receiving(row.receivingId)}: '
                              '${formatPeso(appliedCredit)}'),
                        if (row.replacementReceivingId != null)
                          Text(
                              'Replacement Receiving: ${_receiving(row.replacementReceivingId!)}'),
                        const SizedBox(height: 12),
                        for (final line in lines)
                          ListTile(
                              dense: true,
                              title: Text(
                                  '${products.where((p) => p.id == line.productId).firstOrNull?.name ?? 'Product'} · ${Quantity.format(line.quantityMilli)} ${line.unit}'),
                              subtitle: Text(
                                  '${line.batchNumber == null ? '' : 'Batch ${line.batchNumber} · '}${line.serialNumber == null ? '' : 'Serial ${line.serialNumber} · '}${line.reason}'),
                              trailing:
                                  Text(formatPeso(line.returnValueCents))),
                        Text(
                            'Total: ${formatPeso(lines.fold<int>(0, (n, l) => n + l.returnValueCents))}'),
                      ]))),
              actions: [
                if (row.status == 'draft')
                  TextButton(
                      onPressed: () {
                        Navigator.pop(dialog);
                        _edit(row);
                      },
                      child: const Text('Edit draft')),
                if (row.status == 'finalized' &&
                    widget.user.can(PosPermission.stockReceiving))
                  TextButton(
                      onPressed: () {
                        Navigator.pop(dialog);
                        _changeResolution(row);
                      },
                      child: const Text('Update resolution')),
                if (row.status == 'draft')
                  TextButton(
                      onPressed: () async {
                        try {
                          await widget.repository.cancel(widget.user, row.id);
                          if (!dialog.mounted) return;
                          Navigator.pop(dialog);
                          setState(_reload);
                        } catch (e) {
                          _error('$e');
                        }
                      },
                      child: const Text('Cancel draft')),
                if (row.status == 'draft' &&
                    widget.user.can(PosPermission.finalizePurchaseReturn))
                  FilledButton(
                      onPressed: () async {
                        try {
                          await widget.repository.finalize(widget.user, row.id);
                          if (!dialog.mounted) return;
                          Navigator.pop(dialog);
                          setState(_reload);
                        } catch (e) {
                          _error('$e');
                        }
                      },
                      child: const Text('Finalize return')),
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('Close')),
              ],
            ));
  }

  Future<void> _changeResolution(PurchaseReturn row) async {
    var chosen = PurchaseReturnResolution.values.byName(row.resolution);
    String? replacementId = row.replacementReceivingId;
    final creditReference = TextEditingController(text: row.creditReference);
    final creditAmount = TextEditingController(
        text: row.creditAmountCents == null
            ? ''
            : (row.creditAmountCents! / 100).toStringAsFixed(2));
    await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
            builder: (context, refresh) => AlertDialog(
                  title: Text(
                      'Resolution · ${PurchaseReturnRepository.number(row)}'),
                  content: SizedBox(
                      width: 460,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        DropdownButtonFormField<PurchaseReturnResolution>(
                            initialValue: chosen,
                            items: [
                              for (final value
                                  in PurchaseReturnResolution.values)
                                DropdownMenuItem(
                                    value: value, child: Text(value.label))
                            ],
                            onChanged: (value) =>
                                refresh(() => chosen = value!)),
                        if (chosen ==
                            PurchaseReturnResolution.supplierCredit) ...[
                          TextField(
                              controller: creditReference,
                              decoration: const InputDecoration(
                                  labelText: 'Supplier credit reference')),
                          TextField(
                              controller: creditAmount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Confirmed credit amount')),
                        ],
                        if (chosen ==
                            PurchaseReturnResolution.replacementReceived)
                          DropdownButtonFormField<String>(
                              initialValue: replacementId,
                              decoration: const InputDecoration(
                                  labelText: 'Replacement Receiving'),
                              items: [
                                for (final receipt in receivings.where((r) =>
                                    r.supplierId == row.supplierId &&
                                    r.id != row.receivingId))
                                  DropdownMenuItem(
                                      value: receipt.id,
                                      child: Text(
                                          StockReceivingRepository.number(
                                              receipt)))
                              ],
                              onChanged: (value) =>
                                  refresh(() => replacementId = value)),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () async {
                          final amountText = creditAmount.text.trim();
                          final amount = amountText.isEmpty
                              ? null
                              : ((double.tryParse(amountText) ?? -1) * 100)
                                  .round();
                          try {
                            await widget.repository.setResolution(
                                widget.user, row.id, chosen,
                                creditReference: chosen ==
                                        PurchaseReturnResolution.supplierCredit
                                    ? creditReference.text.trim()
                                    : null,
                                creditAmountCents: chosen ==
                                        PurchaseReturnResolution.supplierCredit
                                    ? amount
                                    : null,
                                replacementReceivingId: chosen ==
                                        PurchaseReturnResolution
                                            .replacementReceived
                                    ? replacementId
                                    : null);
                            if (!dialog.mounted) return;
                            Navigator.pop(dialog);
                            setState(_reload);
                          } catch (error) {
                            _error('$error');
                          }
                        },
                        child: const Text('Save resolution')),
                  ],
                )));
    creditReference.dispose();
    creditAmount.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AppWorkspacePadding(child: editing ? _editor() : _list());

  Widget _list() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppPageHeader(
            title: 'Purchase Returns',
            subtitle:
                'Track stock returned to suppliers and supplier resolutions.',
            action: FilledButton.icon(
                onPressed: () => _start(),
                icon: const Icon(Icons.add),
                label: const Text('New purchase return'))),
        FutureBuilder(
            future: widget.repository.metrics(),
            builder: (context, snapshot) {
              final value = snapshot.data;
              if (value == null) return const SizedBox.shrink();
              return Wrap(spacing: 8, runSpacing: 8, children: [
                for (final metric in [
                  ('Draft', value.draft),
                  ('Finalized', value.finalized),
                  ('Awaiting resolution', value.unresolved),
                  ('Replacement expected', value.replacementExpected)
                ])
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text('${metric.$1} · ${metric.$2}'))),
              ]);
            }),
        TextField(
            decoration: const InputDecoration(
                labelText:
                    'Search reference, supplier, product, receiving or PO'),
            onChanged: (value) => setState(() {
                  search = value;
                  page = 0;
                  _reload();
                })),
        Wrap(spacing: 12, children: [
          DropdownButton<String>(
              value: status,
              items: const ['All', 'draft', 'finalized', 'cancelled']
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (s) => setState(() {
                    status = s!;
                    page = 0;
                    _reload();
                  })),
          DropdownButton<String>(
              value: resolution,
              items: [
                'All',
                ...PurchaseReturnResolution.values.map((r) => r.name)
              ]
                  .map((s) => DropdownMenuItem(
                      value: s,
                      child: Text(s == 'All'
                          ? s
                          : PurchaseReturnResolution.values.byName(s).label)))
                  .toList(),
              onChanged: (s) => setState(() {
                    resolution = s!;
                    page = 0;
                    _reload();
                  })),
          if (widget.initialSupplierId == null)
            DropdownButton<String>(
                value: supplierFilter,
                hint: const Text('All suppliers'),
                items: [
                  const DropdownMenuItem<String>(
                      value: null, child: Text('All suppliers')),
                  for (final supplier in suppliers)
                    DropdownMenuItem(
                        value: supplier.id, child: Text(supplier.name))
                ],
                onChanged: (id) => setState(() {
                      supplierFilter = id;
                      page = 0;
                      _reload();
                    })),
          TextButton.icon(
              onPressed: () async {
                final range = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                    initialDateRange: dateRange);
                if (range != null && mounted) {
                  setState(() {
                    dateRange = range;
                    page = 0;
                    _reload();
                  });
                }
              },
              icon: const Icon(Icons.date_range),
              label: Text(dateRange == null
                  ? 'All dates'
                  : '${dateRange!.start.toLocal().toString().split(' ').first} to ${dateRange!.end.toLocal().toString().split(' ').first}')),
          if (dateRange != null)
            IconButton(
                onPressed: () => setState(() {
                      dateRange = null;
                      page = 0;
                      _reload();
                    }),
                icon: const Icon(Icons.close),
                tooltip: 'Clear date filter'),
        ]),
        Expanded(
            child: FutureBuilder<dynamic>(
                future: rows,
                builder: (context, snapshot) {
                  final result = snapshot.data;
                  if (snapshot.hasError) {
                    return Center(
                        child: Text(
                            'Unable to load purchase returns: ${snapshot.error}'));
                  }
                  if (result == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final items = result.items as List<PurchaseReturn>;
                  return Column(children: [
                    Expanded(
                        child: items.isEmpty
                            ? const Center(
                                child: Text('No purchase returns yet'))
                            : FutureBuilder(
                                future: widget.repository
                                    .summaries(items.map((r) => r.id)),
                                builder: (context, summarySnapshot) =>
                                    ListView.builder(
                                        itemCount: items.length,
                                        itemBuilder: (context, index) {
                                          final row = items[index];
                                          final summary =
                                              summarySnapshot.data?[row.id];
                                          return ListTile(
                                              title: Text(
                                                  '${PurchaseReturnRepository.number(row)} · ${_supplier(row.supplierId)}'),
                                              subtitle: Text(
                                                  '${row.returnDate.toLocal().toString().split(' ').first} · ${_receiving(row.receivingId)}'
                                                  '${_order(row.purchaseOrderId).isEmpty ? '' : ' · ${_order(row.purchaseOrderId)}'} · ${summary?.items ?? 0} items'
                                                  ' · ${PurchaseReturnResolution.values.byName(row.resolution).label}'),
                                              trailing: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.end,
                                                  children: [
                                                    Text(formatPeso(
                                                        summary?.valueCents ??
                                                            0)),
                                                    Text(row.status)
                                                  ]),
                                              onTap: () => _detail(row));
                                        }))),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text(
                          '${page * 50 + 1}-${page * 50 + items.length} of ${result.totalCount}'),
                      IconButton(
                          onPressed: page > 0
                              ? () => setState(() {
                                    page--;
                                    _reload();
                                  })
                              : null,
                          icon: const Icon(Icons.chevron_left)),
                      IconButton(
                          onPressed: (page + 1) * 50 < result.totalCount
                              ? () => setState(() {
                                    page++;
                                    _reload();
                                  })
                              : null,
                          icon: const Icon(Icons.chevron_right)),
                    ])
                  ]);
                }))
      ]);

  Widget _editor() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(
              onPressed: () => setState(() => editing = false),
              icon: const Icon(Icons.arrow_back)),
          Text('New purchase return',
              style: Theme.of(context).textTheme.headlineSmall)
        ]),
        Expanded(
            child: ListView(children: [
          DropdownButtonFormField<String>(
              initialValue: receivingId,
              decoration: const InputDecoration(labelText: 'Source Receiving'),
              items: [
                for (final row in receivings)
                  DropdownMenuItem(
                      value: row.id,
                      child: Text(
                          '${StockReceivingRepository.number(row)} · ${_supplier(row.supplierId)}'))
              ],
              onChanged: editingDraft != null
                  ? null
                  : (id) {
                      setState(() {
                        receivingId = id;
                        sources = [];
                      });
                      _loadSources();
                    }),
          const SizedBox(height: 16),
          for (final source in sources)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(source.product.name,
                              style: Theme.of(context).textTheme.titleMedium),
                          Text(
                              'Received ${Quantity.format(source.item.quantityMilli)} · Available ${Quantity.format(source.layer.quantityRemainingMilli)}'
                              '${source.layer.batchNumber == null ? '' : ' · Batch ${source.layer.batchNumber}'}'),
                          Text(
                              'Actual unit cost ${formatPeso(source.layer.unitCostCents)}'),
                          if (source.product.serialTracking) ...[
                            for (final serial in source.serials)
                              CheckboxListTile(
                                  dense: true,
                                  title: Text(serial.serialNumber),
                                  value: selectedSerials[source.item.id]
                                          ?.contains(serial.id) ??
                                      false,
                                  onChanged: (selected) => setState(() {
                                        final ids = selectedSerials.putIfAbsent(
                                            source.item.id, () => <String>{});
                                        if (selected == true) {
                                          ids.add(serial.id);
                                        } else {
                                          ids.remove(serial.id);
                                        }
                                        quantities
                                            .putIfAbsent(source.item.id,
                                                TextEditingController.new)
                                            .text = '${ids.length}';
                                      })),
                          ] else
                            TextField(
                                controller: quantities.putIfAbsent(
                                    source.item.id, TextEditingController.new),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                decoration: const InputDecoration(
                                    labelText: 'Return quantity')),
                          DropdownButtonFormField<PurchaseReturnReason>(
                              initialValue: reasons[source.item.id] ??
                                  PurchaseReturnReason.other,
                              decoration:
                                  const InputDecoration(labelText: 'Reason'),
                              items: [
                                for (final reason
                                    in PurchaseReturnReason.values)
                                  DropdownMenuItem(
                                      value: reason, child: Text(reason.label))
                              ],
                              onChanged: (reason) => setState(
                                  () => reasons[source.item.id] = reason!)),
                        ]))),
          TextField(
              controller: supplierReference,
              decoration: const InputDecoration(
                  labelText: 'Supplier return reference')),
          TextField(
              controller: notes,
              decoration: const InputDecoration(labelText: 'Notes')),
          DropdownButtonFormField<PurchaseReturnResolution>(
              initialValue: draftResolution,
              decoration:
                  const InputDecoration(labelText: 'Supplier resolution'),
              items: [
                for (final value in PurchaseReturnResolution.values.where(
                    (r) => r != PurchaseReturnResolution.replacementReceived))
                  DropdownMenuItem(value: value, child: Text(value.label))
              ],
              onChanged: (value) => setState(() => draftResolution = value!)),
          const SizedBox(height: 12),
          const Text(
              'Finalizing removes the selected items from available inventory. The original Receiving record remains unchanged.'),
        ])),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          OutlinedButton(
              onPressed: busy ? null : () => _save(finalize: false),
              child: const Text('Save draft')),
          const SizedBox(width: 8),
          if (widget.user.can(PosPermission.finalizePurchaseReturn))
            FilledButton(
                onPressed: busy ? null : _review,
                child: const Text('Review and finalize')),
        ])
      ]);
}
