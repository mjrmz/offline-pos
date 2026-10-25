import 'package:flutter/material.dart';
import '../../shared/widgets/app_workspace.dart';
import 'package:drift/drift.dart' show Value;

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/stock_count_repository.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../shared/utils/money.dart';

class StockCountsScreen extends StatefulWidget {
  final StockCountRepository repository;
  final ActiveUser user;
  final String? initialAdjustmentProductId;
  final String? initialCountId;
  final String? initialAdjustmentBatch;
  final int? initialAdjustmentQtyMilli;
  const StockCountsScreen(
      {super.key,
      required this.repository,
      required this.user,
      this.initialCountId,
      this.initialAdjustmentProductId,
      this.initialAdjustmentBatch,
      this.initialAdjustmentQtyMilli});
  @override
  State<StockCountsScreen> createState() => _StockCountsScreenState();
}

class _StockCountsScreenState extends State<StockCountsScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.initialAdjustmentProductId != null &&
        widget.user.can(PosPermission.stockAdjust)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await loaded;
        if (mounted) {
          _adjust(
              productId: widget.initialAdjustmentProductId,
              batchNumber: widget.initialAdjustmentBatch,
              quantityMilli: widget.initialAdjustmentQtyMilli,
              initialReason: 'Expired');
        }
      });
    }
  }

  bool adjustments = false;
  StockCount? selected;
  String search = '';
  String filter = 'All';
  bool busy = false;
  late Future<void> loaded = _load();
  List<StockCount> counts = [];
  List<InventoryAdjustment> posts = [];
  Map<String, String> adjustmentByLine = {};
  List<StockCountLine> lines = [];
  Map<String, List<StockCountLine>> countLines = {};
  List<Product> products = [];
  Map<String, int> current = {};
  Map<String, int> movementCounts = {};
  Map<String, String> users = {};
  final Map<String, String> countErrors = {};
  Future<void> pendingCountWrites = Future.value();
  Object? countWriteError;

  Future<void> _load() async {
    counts = await widget.repository.counts();
    if (selected == null && widget.initialCountId != null) {
      selected = counts.where((c) => c.id == widget.initialCountId).firstOrNull;
    }
    countLines = {
      for (final c in counts) c.id: await widget.repository.lines(c.id)
    };
    posts = await widget.repository.adjustments();
    adjustmentByLine = {
      for (final post in posts)
        if (post.stockCountLineId != null)
          post.stockCountLineId!: post.reference
    };
    products =
        await widget.repository.db.select(widget.repository.db.products).get();
    current = {
      for (final row in await widget.repository.db
          .select(widget.repository.db.inventory)
          .get())
        row.productId: row.quantityMilli
    };
    movementCounts = {};
    for (final movement in await widget.repository.db
        .select(widget.repository.db.inventoryMovements)
        .get()) {
      movementCounts.update(movement.productId, (count) => count + 1,
          ifAbsent: () => 1);
    }
    users = {
      for (final row in await widget.repository.db
          .select(widget.repository.db.users)
          .get())
        row.id: row.name
    };
    if (selected != null) {
      selected = counts.where((c) => c.id == selected!.id).firstOrNull;
      lines =
          selected == null ? [] : await widget.repository.lines(selected!.id);
    }
  }

  void reload() => setState(() {
        loaded = _load();
      });
  Product? product(String id) => products.where((p) => p.id == id).firstOrNull;
  String qty(int milli) => Quantity.format(milli);
  String status(StockCountLine line) {
    if (line.countedMilli == null) return 'Uncounted';
    final delta = line.countedMilli! - line.expectedMilli;
    return delta == 0
        ? 'Matched'
        : delta < 0
            ? 'Short'
            : 'Over';
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      if (mounted) reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                error is StateError ? error.message.toString() : '$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _newCount() async {
    String scope = 'All active products';
    String? category;
    final choices = <String>{};
    final notes = TextEditingController();
    final categories = await widget.repository.db
        .select(widget.repository.db.categories)
        .get();
    if (!mounted) return;
    final result = await showDialog<
            ({
              String scope,
              String? category,
              List<String>? ids,
              String notes
            })>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Text('New Stock Count'),
                    content: SizedBox(
                        width: 480,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          DropdownButtonFormField<String>(
                              initialValue: scope,
                              decoration:
                                  const InputDecoration(labelText: 'Scope'),
                              items: [
                                'All active products',
                                'Category',
                                'Selected products'
                              ]
                                  .map((s) => DropdownMenuItem(
                                      value: s, child: Text(s)))
                                  .toList(),
                              onChanged: (s) => update(() => scope = s!)),
                          if (scope == 'Category')
                            DropdownButtonFormField<String>(
                                decoration: const InputDecoration(
                                    labelText: 'Category'),
                                items: categories
                                    .map((c) => DropdownMenuItem(
                                        value: c.id, child: Text(c.name)))
                                    .toList(),
                                onChanged: (s) => update(() => category = s)),
                          if (scope == 'Selected products')
                            SizedBox(
                                height: 180,
                                child: ListView(children: [
                                  for (final p
                                      in products.where((p) => p.isActive))
                                    CheckboxListTile(
                                        dense: true,
                                        title: Text(p.name),
                                        value: choices.contains(p.id),
                                        onChanged: (v) => update(() {
                                              if (v == true) {
                                                choices.add(p.id);
                                              } else {
                                                choices.remove(p.id);
                                              }
                                            }))
                                ])),
                          TextField(
                              controller: notes,
                              decoration:
                                  const InputDecoration(labelText: 'Notes')),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed:
                              (scope == 'Category' && category == null) ||
                                      (scope == 'Selected products' &&
                                          choices.isEmpty)
                                  ? null
                                  : () => Navigator.pop(context, (
                                        scope: scope,
                                        category: category,
                                        ids: scope == 'Selected products'
                                            ? choices.toList()
                                            : null,
                                        notes: notes.text
                                      )),
                          child: const Text('Create')),
                    ])));
    if (result == null) return;
    await _run(() async {
      selected = await widget.repository.createCount(widget.user,
          categoryId: result.scope == 'Category' ? result.category : null,
          productIds: result.ids,
          notes: result.notes);
    });
  }

  Future<void> _adjust(
      {String? productId,
      String? batchNumber,
      int? quantityMilli,
      String? initialReason}) async {
    String? id = productId;
    String reason = initialReason ?? 'Damaged';
    final amount = TextEditingController(
        text:
            quantityMilli == null ? '' : '-${Quantity.format(quantityMilli)}');
    final cost = TextEditingController();
    final price = TextEditingController();
    final batch = TextEditingController(text: batchNumber);
    final serials = TextEditingController();
    final notes = TextEditingController();
    final eligible = products.where((p) => p.isActive).toList();
    final result = await showDialog<AdjustmentRequest>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Text('Adjust Stock'),
                    content: SizedBox(
                        width: 500,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              DropdownButtonFormField<String>(
                                  initialValue: id,
                                  decoration: const InputDecoration(
                                      labelText: 'Product'),
                                  items: eligible
                                      .map((p) => DropdownMenuItem(
                                          value: p.id, child: Text(p.name)))
                                      .toList(),
                                  onChanged: (s) => update(() => id = s)),
                              if (id != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                            'Current stock: ${qty(current[id] ?? 0)}'))),
                              TextField(
                                  controller: amount,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true, signed: true),
                                  onChanged: (_) => update(() {}),
                                  decoration: const InputDecoration(
                                      labelText: 'Change (+ or -)',
                                      hintText: '-2')),
                              if (id != null &&
                                  _parseDelta(amount.text) != null)
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                        'After: ${qty((current[id] ?? 0) + _parseDelta(amount.text)!)}')),
                              DropdownButtonFormField<String>(
                                  initialValue: reason,
                                  decoration: const InputDecoration(
                                      labelText: 'Reason'),
                                  items: [
                                    'Damaged',
                                    'Expired',
                                    'Lost',
                                    'Shrinkage',
                                    'Stock found',
                                    'Count correction',
                                    'Breakage',
                                    'Other'
                                  ]
                                      .map((s) => DropdownMenuItem(
                                          value: s, child: Text(s)))
                                      .toList(),
                                  onChanged: (s) => update(() => reason = s!)),
                              if ((_parseDelta(amount.text) ?? 0) > 0) ...[
                                TextField(
                                    controller: cost,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                        labelText: 'Unit cost (₱, required)')),
                                if (product(id ?? '')?.pricingPolicy == 'layer')
                                  TextField(
                                      controller: price,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                          labelText:
                                              'Layer selling price (₱)')),
                              ],
                              TextField(
                                  controller: batch,
                                  decoration: const InputDecoration(
                                      labelText:
                                          'Batch number (batch products)')),
                              TextField(
                                  controller: serials,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                      labelText:
                                          'Exact serial numbers (one per line)')),
                              TextField(
                                  controller: notes,
                                  decoration: const InputDecoration(
                                      labelText: 'Notes')),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () {
                            final delta = _parseDelta(amount.text);
                            if (id == null || delta == null || delta == 0) {
                              return;
                            }
                            Navigator.pop(
                                context,
                                AdjustmentRequest(id!, delta, reason,
                                    notes: notes.text,
                                    unitCostCents: tryParsePeso(cost.text),
                                    unitSellingPriceCents:
                                        tryParsePeso(price.text),
                                    batchNumber: batch.text.trim().isEmpty
                                        ? null
                                        : batch.text.trim(),
                                    serialNumbers: serials.text
                                        .split(RegExp(r'[\n,]'))
                                        .map((s) => s.trim())
                                        .where((s) => s.isNotEmpty)
                                        .toList()));
                          },
                          child: const Text('Post adjustment')),
                    ])));
    if (result != null) {
      await _run(() async {
        await widget.repository.adjust(widget.user, result);
      });
    }
  }

  int? _parseDelta(String value) {
    final match =
        RegExp(r'^([+-]?)(\d+)(?:\.(\d{1,3}))?$').firstMatch(value.trim());
    if (match == null) return null;
    final whole = int.tryParse(match[2]!);
    final fraction = int.tryParse((match[3] ?? '').padRight(3, '0').isEmpty
        ? '0'
        : (match[3] ?? '').padRight(3, '0'));
    if (whole == null ||
        fraction == null ||
        whole > (0x7fffffffffffffff - fraction) ~/ 1000) {
      return null;
    }
    final magnitude = whole * 1000 + fraction;
    return match[1] == '-' ? -magnitude : magnitude;
  }

  Future<void> _review() async {
    if (countErrors.isNotEmpty) return;
    await pendingCountWrites;
    if (countWriteError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$countWriteError')));
      }
      return;
    }
    if (!mounted) return;
    lines = await widget.repository.lines(selected!.id);
    if (!mounted) return;
    setState(() {});
    final changed = lines
        .where(
            (l) => l.countedMilli != null && l.countedMilli != l.expectedMilli)
        .toList();
    final stale = lines
        .where((l) =>
            l.countedMilli != null &&
            (current[l.productId] != l.expectedMilli ||
                (movementCounts[l.productId] ?? 0) != l.movementCount))
        .toList();
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Review Stock Count'),
                content: SizedBox(
                    width: 540,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${lines.where((l) => l.countedMilli != null).length} counted; '
                              '${changed.length} variances'),
                          if (stale.isNotEmpty)
                            const Text(
                                'Stock changed during count. Refresh and recount affected lines.'),
                          const SizedBox(height: 12),
                          for (final l in changed)
                            Text('${product(l.productId)?.name ?? 'Product'}: '
                                '${qty(l.expectedMilli)} → ${qty(l.countedMilli!)} '
                                '(${qty(l.countedMilli! - l.expectedMilli)})'),
                          if (changed
                              .any((l) => l.countedMilli! > l.expectedMilli))
                            const Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Text(
                                    'Overages require a confirmed unit cost.')),
                        ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Back')),
                  FilledButton(
                      onPressed: stale.isNotEmpty
                          ? null
                          : () => Navigator.pop(context, true),
                      child: const Text('Finalize Stock Count')),
                ]));
    if (accepted != true) return;
    final details = <String, AdjustmentRequest>{};
    for (final line in changed) {
      final productRow = product(line.productId)!;
      final config = await BusinessFeatureRepository(widget.repository.db)
          .businessProduct(productRow.id);
      final delta = line.countedMilli! - line.expectedMilli;
      if (delta < 0 && !productRow.serialTracking && !config.batch) continue;
      final cost = TextEditingController();
      final price = TextEditingController();
      final batch = TextEditingController();
      final serials = TextEditingController();
      if (!mounted) return;
      final request = await showDialog<AdjustmentRequest>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text('Details: ${productRow.name} (${qty(delta)})'),
                  content: SizedBox(
                      width: 440,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (delta > 0) ...[
                          TextField(
                              controller: cost,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: 'Confirmed unit cost (₱)')),
                          if (productRow.pricingPolicy == 'layer')
                            TextField(
                                controller: price,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                    labelText: 'Layer selling price (₱)')),
                        ],
                        if (config.batch)
                          TextField(
                              controller: batch,
                              decoration: const InputDecoration(
                                  labelText: 'Affected batch number')),
                        if (productRow.serialTracking)
                          TextField(
                              controller: serials,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                  labelText: 'Exact serials, one per line')),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Back')),
                    FilledButton(
                        onPressed: () => Navigator.pop(
                            context,
                            AdjustmentRequest(
                                productRow.id, delta, 'Stock count variance',
                                unitCostCents: tryParsePeso(cost.text),
                                unitSellingPriceCents: tryParsePeso(price.text),
                                batchNumber: batch.text.trim().isEmpty
                                    ? null
                                    : batch.text.trim(),
                                serialNumbers: serials.text
                                    .split(RegExp(r'[\n,]'))
                                    .map((s) => s.trim())
                                    .where((s) => s.isNotEmpty)
                                    .toList())),
                        child: const Text('Continue')),
                  ]));
      if (request == null) return;
      details[line.id] = request;
    }
    await _run(() => widget.repository
        .finalize(widget.user, selected!.id, varianceDetails: details));
  }

  void _changeCount(StockCountLine line, int? value, String? error) {
    setState(() {
      if (error == null) {
        countErrors.remove(line.id);
        lines = [
          for (final item in lines)
            item.id == line.id
                ? item.copyWith(countedMilli: Value(value))
                : item
        ];
      } else {
        countErrors[line.id] = error;
      }
    });
    if (error != null) return;
    pendingCountWrites = pendingCountWrites.then((_) async {
      try {
        await widget.repository.setCount(widget.user, line.id, value);
        countWriteError = null;
      } catch (e) {
        countWriteError = e;
      }
    });
  }

  Future<void> _lineNotes(StockCountLine line) async {
    final controller = TextEditingController(text: line.notes ?? '');
    final editable = selected?.status == 'draft';
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(
                    'Notes: ${product(line.productId)?.name ?? 'Product'}'),
                content: editable
                    ? TextField(
                        controller: controller,
                        maxLines: 3,
                        decoration:
                            const InputDecoration(hintText: 'Count notes'))
                    : Text(line.notes?.isNotEmpty == true
                        ? line.notes!
                        : 'No notes'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(editable ? 'Cancel' : 'Close')),
                  if (editable)
                    FilledButton(
                        onPressed: () =>
                            Navigator.pop(context, controller.text),
                        child: const Text('Save notes')),
                ]));
    if (result != null) {
      await pendingCountWrites;
      if (countWriteError != null) return;
      final currentLine = lines.firstWhere((item) => item.id == line.id);
      await _run(() => widget.repository.setCount(
          widget.user, line.id, currentLine.countedMilli,
          notes: result));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
      future: loaded,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return AppWorkspacePadding(
            child: Column(children: [
          Row(children: [
            Text(selected?.reference ?? 'Stock Counts',
                style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            if (selected != null)
              TextButton.icon(
                  onPressed: () => setState(() => selected = null),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back')),
            if (selected == null) ...[
              OutlinedButton(
                  onPressed: busy ? null : _newCount,
                  child: const Text('+ New Stock Count')),
              const SizedBox(width: 8),
              if (widget.user.can(PosPermission.stockAdjust))
                FilledButton.tonal(
                    onPressed: busy ? null : () => _adjust(),
                    child: const Text('Adjust Stock')),
            ]
          ]),
          const SizedBox(height: 10),
          if (selected == null) ...[
            Row(children: [
              SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Counts')),
                    ButtonSegment(value: true, label: Text('Adjustments'))
                  ],
                  selected: {
                    adjustments
                  },
                  onSelectionChanged: (v) =>
                      setState(() => adjustments = v.first)),
              const SizedBox(width: 12),
              Expanded(
                  child: TextField(
                      decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search'),
                      onChanged: (s) =>
                          setState(() => search = s.toLowerCase()))),
            ]),
            const SizedBox(height: 8),
            Expanded(child: adjustments ? _adjustmentList() : _countList()),
          ] else ...[
            _countHeader(),
            Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        'Products ${lines.length}    Matched ${lines.where((l) => status(l) == 'Matched').length}    '
                        'Short ${lines.where((l) => status(l) == 'Short').length}    '
                        'Over ${lines.where((l) => status(l) == 'Over').length}    '
                        'Variances ${lines.where((l) => status(l) == 'Short' || status(l) == 'Over').length}'))),
            const SizedBox(height: 8),
            Row(children: [
              DropdownButton<String>(
                  value: filter,
                  items: ['All', 'Uncounted', 'Matched', 'Variance']
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (s) => setState(() => filter = s!)),
              const SizedBox(width: 12),
              Expanded(
                  child: TextField(
                      decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Product, SKU, barcode'),
                      onChanged: (s) =>
                          setState(() => search = s.toLowerCase()))),
            ]),
            const SizedBox(height: 8),
            const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Expanded(flex: 3, child: Text('PRODUCT')),
                  Expanded(child: Text('EXPECTED')),
                  SizedBox(width: 105, child: Text('COUNTED')),
                  Expanded(child: Text('VARIANCE')),
                  SizedBox(width: 60, child: Text('UNIT')),
                  SizedBox(width: 85, child: Text('STATUS')),
                  SizedBox(width: 48, child: Text('NOTES')),
                  SizedBox(width: 48),
                ])),
            Expanded(child: _lineList()),
            if (selected!.status == 'draft') _footer(),
          ]
        ]));
      });

  Widget _countList() => ListView(children: [
        const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              SizedBox(width: 115, child: Text('REFERENCE')),
              SizedBox(width: 140, child: Text('DATE')),
              Expanded(flex: 2, child: Text('SCOPE')),
              SizedBox(width: 110, child: Text('STATUS')),
              SizedBox(width: 115, child: Text('COUNTED')),
              SizedBox(width: 100, child: Text('VARIANCES')),
              Expanded(child: Text('CREATED BY')),
            ])),
        for (final c in counts.where((c) =>
            c.reference.toLowerCase().contains(search) ||
            c.scope.toLowerCase().contains(search)))
          InkWell(
              onTap: () {
                selected = c;
                countErrors.clear();
                countWriteError = null;
                filter = 'All';
                reload();
              },
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(children: [
                    SizedBox(width: 115, child: Text(c.reference)),
                    SizedBox(
                        width: 140,
                        child: Text(
                            c.createdAt.toLocal().toString().substring(0, 16))),
                    Expanded(flex: 2, child: Text(c.scope)),
                    SizedBox(width: 110, child: Text(c.status.toUpperCase())),
                    SizedBox(
                        width: 115,
                        child: Text(
                            '${countLines[c.id]?.where((l) => l.countedMilli != null).length ?? 0} / ${countLines[c.id]?.length ?? 0}')),
                    SizedBox(
                        width: 100,
                        child: Text(
                            '${countLines[c.id]?.where((l) => l.countedMilli != null && l.countedMilli != l.expectedMilli).length ?? 0}')),
                    Expanded(child: Text(users[c.createdBy] ?? c.createdBy)),
                  ]))),
      ]);

  Widget _adjustmentList() => ListView(children: [
        const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              SizedBox(width: 115, child: Text('REFERENCE')),
              SizedBox(width: 140, child: Text('DATE')),
              Expanded(flex: 2, child: Text('PRODUCT')),
              Expanded(child: Text('REASON')),
              SizedBox(width: 100, child: Text('CHANGE')),
              Expanded(child: Text('RECORDED BY')),
            ])),
        for (final a in posts.where((a) =>
            a.reference.toLowerCase().contains(search) ||
            (product(a.productId)?.name.toLowerCase().contains(search) ??
                false)))
          ListTile(
              dense: true,
              onTap: () => _showAdjustment(a),
              title: Row(children: [
                SizedBox(width: 115, child: Text(a.reference)),
                SizedBox(
                    width: 140,
                    child: Text(
                        a.createdAt.toLocal().toString().substring(0, 16))),
                Expanded(
                    flex: 2,
                    child: Text(product(a.productId)?.name ?? 'Product')),
                Expanded(child: Text(a.reason)),
                SizedBox(width: 100, child: Text(qty(a.deltaMilli))),
                Expanded(child: Text(users[a.createdBy] ?? a.createdBy)),
              ]),
              subtitle: Text(
                  '${users[a.createdBy] ?? a.createdBy} · Posted · ${a.notes ?? ''}')),
      ]);

  Future<void> _showAdjustment(InventoryAdjustment adjustment) async {
    final db = widget.repository.db;
    final allocations =
        (await db.select(db.inventoryAdjustmentAllocations).get())
            .where((a) => a.adjustmentId == adjustment.id)
            .toList();
    final layerById = {
      for (final layer in await db.select(db.inventoryLayers).get())
        layer.id: layer
    };
    final serialById = {
      for (final serial in await db.select(db.serialUnits).get())
        serial.id: serial
    };
    String? countReference;
    if (adjustment.stockCountLineId != null) {
      final line = (await db.select(db.stockCountLines).get())
          .where((l) => l.id == adjustment.stockCountLineId)
          .firstOrNull;
      if (line != null) {
        countReference = (await db.select(db.stockCounts).get())
            .where((c) => c.id == line.stockCountId)
            .firstOrNull
            ?.reference;
      }
    }
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(adjustment.reference),
                content: SizedBox(
                    width: 520,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${product(adjustment.productId)?.name ?? 'Product'}  ${qty(adjustment.deltaMilli)}'),
                          Text('Reason: ${adjustment.reason}'),
                          Text(
                              'Recorded by: ${users[adjustment.createdBy] ?? adjustment.createdBy}'),
                          Text('Posted: ${adjustment.createdAt.toLocal()}'),
                          if (countReference != null)
                            Text('Stock count: $countReference'),
                          if (adjustment.notes?.isNotEmpty == true)
                            Text('Notes: ${adjustment.notes}'),
                          const SizedBox(height: 12),
                          const Text('Affected layers',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          for (final allocation in allocations)
                            Text(
                                '${qty(allocation.quantityMilli)} at ${formatPeso(allocation.unitCostCents)}'
                                '${layerById[allocation.inventoryLayerId]?.batchNumber == null ? '' : ' · Batch ${layerById[allocation.inventoryLayerId]?.batchNumber}'}'
                                '${allocation.serialUnitId == null ? '' : ' · Serial ${serialById[allocation.serialUnitId]?.serialNumber}'}'),
                        ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ]));
  }

  Widget _countHeader() {
    final c = selected!;
    return Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 20, runSpacing: 4, children: [
          Text(c.status.toUpperCase()),
          Text('Scope: ${c.scope}'),
          Text('Created: ${c.createdAt.toLocal()}'),
          Text('By: ${users[c.createdBy] ?? c.createdBy}'),
          if (c.finalizedAt != null)
            Text('Finalized: ${c.finalizedAt!.toLocal()}'),
          if (c.finalizedBy != null)
            Text('Finalized by: ${users[c.finalizedBy] ?? c.finalizedBy}'),
          if (c.notes?.isNotEmpty == true) Text('Notes: ${c.notes}')
        ]));
  }

  Widget _lineList() {
    final visible = lines.where((l) {
      final p = product(l.productId);
      final matches =
          '${p?.name} ${p?.sku} ${p?.barcode}'.toLowerCase().contains(search);
      final state = status(l);
      return matches &&
          (filter == 'All' ||
              state == filter ||
              (filter == 'Variance' && (state == 'Short' || state == 'Over')));
    }).toList();
    return ListView.builder(
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final l = visible[index];
          final p = product(l.productId);
          final stale = selected!.status == 'draft' &&
              l.countedMilli != null &&
              (current[l.productId] != l.expectedMilli ||
                  (movementCounts[l.productId] ?? 0) != l.movementCount);
          return Card(
              margin: const EdgeInsets.only(bottom: 4),
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  child: Row(children: [
                    Expanded(
                        flex: 3,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p?.name ?? 'Product'),
                              Text(p?.sku ?? '',
                                  style: Theme.of(context).textTheme.bodySmall),
                              if (adjustmentByLine[l.id] != null)
                                Text(adjustmentByLine[l.id]!,
                                    style:
                                        Theme.of(context).textTheme.bodySmall)
                            ])),
                    Expanded(child: Text(qty(l.expectedMilli))),
                    SizedBox(
                        width: 105,
                        child: selected!.status == 'draft'
                            ? _CountField(
                                key: ValueKey(l.id),
                                initial: l.countedMilli == null
                                    ? ''
                                    : qty(l.countedMilli!),
                                fractional: l.unitLabel != 'pcs',
                                onChange: (v, error) =>
                                    _changeCount(l, v, error))
                            : Text(l.countedMilli == null
                                ? '—'
                                : qty(l.countedMilli!))),
                    Expanded(
                        child: Text(l.countedMilli == null
                            ? '—'
                            : qty(l.countedMilli! - l.expectedMilli))),
                    SizedBox(width: 60, child: Text(l.unitLabel)),
                    SizedBox(
                        width: 85, child: Text(stale ? 'Stale' : status(l))),
                    SizedBox(
                        width: 48,
                        child: IconButton(
                            tooltip: l.notes?.isNotEmpty == true
                                ? l.notes!
                                : 'Line notes',
                            onPressed: () => _lineNotes(l),
                            icon: const Icon(Icons.note_alt_outlined))),
                    if (stale && selected!.status == 'draft')
                      IconButton(
                          tooltip:
                              'Refresh and recount (current ${qty(current[l.productId] ?? 0)})',
                          onPressed: busy
                              ? null
                              : () => _run(() => widget.repository
                                  .refreshLine(widget.user, l.id)),
                          icon: const Icon(Icons.refresh)),
                    if (!stale || selected!.status != 'draft')
                      const SizedBox(width: 48),
                  ])));
        });
  }

  Widget _footer() => SafeArea(
      child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Text(
                'Counted ${lines.where((l) => l.countedMilli != null).length} / ${lines.length}    '
                'Variances ${lines.where((l) => l.countedMilli != null && l.countedMilli != l.expectedMilli).length}'),
            const Spacer(),
            TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() =>
                        widget.repository.cancel(widget.user, selected!.id)),
                child: const Text('Cancel count')),
            const SizedBox(width: 8),
            FilledButton(
                onPressed:
                    busy || !widget.user.can(PosPermission.finalizeStockCount)
                        ? null
                        : _review,
                child: const Text('Review & Finalize')),
          ])));
}

class _CountField extends StatefulWidget {
  final String initial;
  final bool fractional;
  final void Function(int?, String?) onChange;
  const _CountField(
      {super.key,
      required this.initial,
      required this.fractional,
      required this.onChange});
  @override
  State<_CountField> createState() => _CountFieldState();
}

class _CountFieldState extends State<_CountField> {
  late final controller = TextEditingController(text: widget.initial);
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void save() {
    final text = controller.text.trim();
    if (text.isEmpty) {
      setState(() => error = null);
      widget.onChange(null, null);
      return;
    }
    final parsed = RegExp(r'^0(?:\.0{1,3})?$').hasMatch(text)
        ? 0
        : Quantity.tryParse(text, fractional: widget.fractional);
    setState(() => error = parsed == null ? 'Enter a valid count' : null);
    widget.onChange(parsed, error);
  }

  @override
  Widget build(BuildContext context) => TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration:
          InputDecoration(isDense: true, hintText: 'Counted', errorText: error),
      onChanged: (_) => save());
}
