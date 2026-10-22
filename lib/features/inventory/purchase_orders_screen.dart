import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../../shared/widgets/app_workspace.dart';
import '../../shared/widgets/record_details_drawer.dart';

import '../../core/models/active_user.dart';
import '../../core/models/product.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/daos/supplier_procurement_repository.dart';
import '../../data/daos/inventory_planning_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import 'documents/purchase_order_pdf.dart';

/// Keeps dialog-owned controllers alive through the route's exit animation.
class _OwnedTextControllers extends StatefulWidget {
  final List<TextEditingController> controllers;
  final Widget child;

  const _OwnedTextControllers({required this.controllers, required this.child});

  @override
  State<_OwnedTextControllers> createState() => _OwnedTextControllersState();
}

class _OwnedTextControllersState extends State<_OwnedTextControllers> {
  @override
  void dispose() {
    for (final controller in widget.controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _EscapeDismiss extends StatefulWidget {
  final VoidCallback onEscape;
  final Widget child;

  const _EscapeDismiss({required this.onEscape, required this.child});

  @override
  State<_EscapeDismiss> createState() => _EscapeDismissState();
}

class _EscapeDismissState extends State<_EscapeDismiss> {
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    // Keep the current route in place until all keyboard handlers have seen
    // this event, so a parent dialog cannot consume the same Escape press.
    if (!_scheduled) {
      _scheduled = true;
      Future.microtask(widget.onEscape);
    }
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class PurchaseOrdersScreen extends StatefulWidget {
  final PurchaseOrderRepository repository;
  final DirectoryRepository directory;
  final PosRepository products;
  final ActiveUser user;
  final ValueChanged<String> onReceive;
  final ValueChanged<String>? onOpenReceiving;
  final ValueChanged<String>? onOpenQuotation;
  final String? initialProductId;
  final String? initialExistingOrderId;
  final String? initialSelectedOrderId;
  final List<({String productId, int quantityMilli})>? initialLines;
  final String? initialSupplierId;
  final int? initialQuantityMilli;
  final String? initialQuotationReference;
  const PurchaseOrdersScreen(
      {super.key,
      required this.repository,
      required this.directory,
      required this.products,
      required this.user,
      required this.onReceive,
      this.onOpenReceiving,
      this.onOpenQuotation,
      this.initialProductId,
      this.initialExistingOrderId,
      this.initialSelectedOrderId,
      this.initialLines,
      this.initialSupplierId,
      this.initialQuantityMilli,
      this.initialQuotationReference});
  @override
  State<PurchaseOrdersScreen> createState() => _PurchaseOrdersScreenState();
}

class _PurchaseOrdersScreenState extends State<PurchaseOrdersScreen> {
  final GlobalKey _expandedOrderKey = GlobalKey();
  List<PurchaseOrder> orders = [];
  List<Supplier> suppliers = [];
  List<PosProduct> products = [];
  String? selectedId;
  String search = '';
  String filter = 'All';
  String? supplierFilter;
  DateTimeRange? orderRange;
  DateTimeRange? deliveryRange;
  String? error;
  bool busy = false;

  Future<void> _openQuickDetail(PurchaseOrder order,
      PurchaseOrderProgress progress, String supplier) async {
    final variance = progress.receivedTotal > 0
        ? await widget.repository.receivedCostVariance(order.id)
        : null;
    final receiptItems = await Future.wait(progress.receivings.map((receipt) =>
        StockReceivingRepository(widget.repository.db).items(receipt.id)));
    final receiptQuantities = <String, int>{
      for (var i = 0; i < progress.receivings.length; i++)
        progress.receivings[i].id: receiptItems[i]
            .fold<int>(0, (total, item) => total + item.quantityMilli),
    };
    final receiptComparable = <String, bool>{
      for (var i = 0; i < progress.receivings.length; i++)
        progress.receivings[i].id: (() {
          final labels = {
            for (final item in receiptItems[i])
              products
                  .where((p) => p.id == item.productId)
                  .firstOrNull
                  ?.business
                  .unit
                  .label
          };
          return !labels.contains(null) && labels.length <= 1;
        })(),
    };
    if (!mounted) return;
    final units = {
      for (final line in progress.lines)
        products
            .where((p) => p.id == line.productId)
            .firstOrNull
            ?.business
            .unit
            .label
    };
    final comparableQuantities = !units.contains(null) && units.length <= 1;
    final canReceive = (progress.status == 'sent' ||
            progress.status == 'partially_received') &&
        progress.lines.any((line) => progress.remaining(line) > 0);
    await showRecordDetailsDrawer<void>(
      context: context,
      builder: (drawerContext) => RecordDetailsDrawer(
        width: 680,
        title: Text(PurchaseOrderRepository.number(order)),
        subtitle: Text(
            '$supplier · Ordered ${MaterialLocalizations.of(drawerContext).formatMediumDate(order.orderDate)}'),
        badges: [
          DrawerStatusBadge(label(progress.status),
              color: progress.status == 'cancelled'
                  ? Theme.of(drawerContext).colorScheme.error
                  : null),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DrawerSection(
                title: 'Order snapshot',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DrawerMetricGrid(metrics: [
                      DrawerMetric(
                          label: 'Ordered',
                          value: Quantity.format(progress.ordered),
                          detail: comparableQuantities ? null : 'Mixed units'),
                      DrawerMetric(
                          label: 'Received',
                          value: Quantity.format(progress.receivedTotal),
                          detail: comparableQuantities ? null : 'Mixed units'),
                      DrawerMetric(
                          label: 'Remaining',
                          value: Quantity.format(progress.remainingTotal),
                          detail: comparableQuantities ? null : 'Mixed units'),
                    ]),
                    const SizedBox(height: 16),
                    DrawerProgressSummary(
                      value: !comparableQuantities || progress.ordered <= 0
                          ? null
                          : progress.receivedTotal / progress.ordered,
                      label: progress.status == 'cancelled'
                          ? 'Receiving stopped · Cancelled'
                          : progress.status == 'closed'
                              ? 'Receiving complete · Closed'
                              : 'Receiving progress',
                      detail: !comparableQuantities
                          ? 'Mixed units; review progress by item below.'
                          : progress.ordered <= 0
                              ? 'No order quantity to compare.'
                              : '${Quantity.format(progress.receivedTotal)} of ${Quantity.format(progress.ordered)} ordered units received.',
                    ),
                    const SizedBox(height: 12),
                    DrawerLabelValue(
                        label: 'Expected delivery',
                        value: order.expectedDeliveryDate == null
                            ? 'Not set'
                            : MaterialLocalizations.of(drawerContext)
                                .formatMediumDate(order.expectedDeliveryDate!)),
                    if (order.supplierReference?.isNotEmpty == true)
                      DrawerLabelValue(
                          label: 'Supplier reference',
                          value: order.supplierReference!),
                    if (order.notes?.isNotEmpty == true)
                      DrawerLabelValue(label: 'Notes', value: order.notes!),
                  ],
                )),
            DrawerSection(
                title: 'Financial summary',
                child: Column(
                  children: [
                    DrawerLabelValue(
                        label: 'Expected order value',
                        value: formatPeso(progress.estimatedTotal)),
                    if (variance != null) ...[
                      DrawerLabelValue(
                          label: 'Actual received cost',
                          value: formatPeso(variance.actualCents)),
                      if (variance.expectedCents > 0)
                        DrawerLabelValue(
                            label: 'Received cost variance',
                            value: formatPeso(variance.differenceCents)),
                    ],
                  ],
                )),
            DrawerSection(
                title: 'Items',
                child: Column(children: [
                  for (final line in progress.lines)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                products
                                        .where((x) => x.id == line.productId)
                                        .firstOrNull
                                        ?.name ??
                                    'Product',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(drawerContext)
                                    .textTheme
                                    .titleSmall),
                            const SizedBox(height: 6),
                            Text(
                                '${Quantity.format(line.orderedQtyMilli)} ordered · ${Quantity.format(progress.received[line.id] ?? 0)} received · ${Quantity.format(progress.remaining(line))} remaining'),
                            DrawerLabelValue(
                                label: 'Expected unit cost',
                                value: formatPeso(line.expectedUnitCostCents)),
                            DrawerLabelValue(
                                label: 'Expected subtotal',
                                value: formatPeso(Quantity.lineCents(
                                    line.expectedUnitCostCents,
                                    line.orderedQtyMilli))),
                          ],
                        ),
                      ),
                    ),
                ])),
            if (progress.receivings.isNotEmpty)
              DrawerSection(
                  title: 'Receiving history',
                  child: Column(
                    children: [
                      for (final receipt in progress.receivings)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.inventory_2_outlined,
                              color:
                                  Theme.of(drawerContext).colorScheme.primary),
                          title: Text(StockReceivingRepository.number(receipt)),
                          subtitle: Text(
                              '${MaterialLocalizations.of(drawerContext).formatMediumDate(receipt.receivedAt)} · ${receiptComparable[receipt.id] == true ? '${Quantity.format(receiptQuantities[receipt.id] ?? 0)} received' : 'Mixed units received'}'),
                          trailing: widget.onOpenReceiving == null
                              ? null
                              : const Icon(Icons.chevron_right),
                          onTap: widget.onOpenReceiving == null
                              ? null
                              : () {
                                  Navigator.pop(drawerContext);
                                  widget.onOpenReceiving!(receipt.id);
                                },
                        ),
                    ],
                  )),
          ],
        ),
        primaryAction: FilledButton(
          onPressed: () {
            Navigator.pop(drawerContext);
            setState(() => selectedId = order.id);
          },
          child: const Text('Open full details'),
        ),
        secondaryActions: [
          OutlinedButton(
              onPressed: () => exportOrder(order, print: true),
              child: const Text('Print PO')),
          OutlinedButton(
              onPressed: () => exportOrder(order, print: false),
              child: const Text('Save PDF')),
          OutlinedButton(
              onPressed: busy
                  ? null
                  : () async {
                      Navigator.pop(drawerContext);
                      await action(() async {
                        final copy = await widget.repository
                            .duplicate(widget.user, order.id);
                        if (mounted) setState(() => selectedId = copy.id);
                      });
                    },
              child: const Text('Duplicate PO')),
          OutlinedButton(
              onPressed: canReceive
                  ? () {
                      Navigator.pop(drawerContext);
                      widget.onReceive(order.id);
                    }
                  : null,
              child: const Text('Receive stock')),
        ],
      ),
    );
  }

  Future<void> exportOrder(PurchaseOrder order, {required bool print}) async {
    try {
      final bytes =
          await PurchaseOrderPdf(widget.repository.db).render(order.id);
      final filename = PurchaseOrderPdf.filename(order);
      if (print) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
      } else {
        final directory = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        final file =
            File('${directory.path}${Platform.pathSeparator}$filename');
        await file.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
        }
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  @override
  void initState() {
    super.initState();
    refresh().then((_) {
      if (!mounted) return;
      if (widget.initialSelectedOrderId != null) {
        setState(() => selectedId = widget.initialSelectedOrderId);
      }
      if (widget.initialExistingOrderId != null) {
        widget.repository.detail(widget.initialExistingOrderId!).then((order) {
          if (mounted) create(order);
        });
      } else if (widget.initialProductId?.isNotEmpty == true ||
          widget.initialLines?.isNotEmpty == true) {
        create();
      }
    });
  }

  Future<void> refresh() async {
    try {
      final rows = await widget.repository.list();
      final supplierRows = await widget.directory.suppliers();
      final productRows = await widget.products.products();
      if (mounted) {
        setState(() {
          orders = rows;
          suppliers = supplierRows;
          products = productRows;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> create([PurchaseOrderProgress? existing]) async {
    final supplierRows = suppliers.where((s) => s.isActive).toList();
    final productRows =
        products.where((p) => p.isActive && !p.business.madeToOrder).toList();
    String? supplierId = existing?.order.supplierId ?? widget.initialSupplierId;
    DateTime orderDate = existing?.order.orderDate ?? DateTime.now();
    DateTime? expectedDate = existing?.order.expectedDeliveryDate;
    final reference =
        TextEditingController(text: existing?.order.supplierReference ?? '');
    final notes = TextEditingController(
        text: existing?.order.notes ??
            (widget.initialQuotationReference == null
                ? ''
                : 'For quotation ${widget.initialQuotationReference}'));
    final lines = <PurchaseOrderLineInput>[
      for (final line in existing?.lines ?? <PurchaseOrderLine>[])
        PurchaseOrderLineInput(
            line.productId, line.orderedQtyMilli, line.expectedUnitCostCents,
            notes: line.notes),
    ];
    final sourceQuantities = <String, int>{};
    if (widget.initialQuotationReference != null) {
      if (widget.initialProductId != null &&
          widget.initialQuantityMilli != null) {
        sourceQuantities[widget.initialProductId!] =
            widget.initialQuantityMilli!;
      }
      for (final initial in widget.initialLines ??
          <({String productId, int quantityMilli})>[]) {
        sourceQuantities.update(
            initial.productId, (old) => old + initial.quantityMilli,
            ifAbsent: () => initial.quantityMilli);
      }
    }
    if (existing != null &&
        widget.initialProductId?.isNotEmpty == true &&
        widget.initialQuantityMilli != null &&
        widget.initialQuantityMilli! > 0) {
      final index =
          lines.indexWhere((line) => line.productId == widget.initialProductId);
      if (index >= 0) {
        final old = lines[index];
        lines[index] = PurchaseOrderLineInput(
            old.productId,
            old.quantityMilli + widget.initialQuantityMilli!,
            old.expectedUnitCostCents,
            notes: old.notes);
      } else {
        final product = productRows
            .where((p) => p.id == widget.initialProductId)
            .firstOrNull;
        if (product != null) {
          lines.add(PurchaseOrderLineInput(
              product.id, widget.initialQuantityMilli!, product.costCents));
        }
      }
      if (widget.initialQuotationReference != null &&
          !notes.text.contains(widget.initialQuotationReference!)) {
        notes.text =
            '${notes.text}${notes.text.isEmpty ? '' : '\n'}For quotation ${widget.initialQuotationReference}';
      }
    }
    if (existing == null && widget.initialProductId != null) {
      final product =
          productRows.where((p) => p.id == widget.initialProductId).firstOrNull;
      if (product != null) {
        final actualCost =
            (await InventoryPlanningRepository(widget.repository.db)
                    .load())[product.id]
                ?.lastPurchaseCostCents;
        if (!mounted) return;
        lines.add(PurchaseOrderLineInput(
            product.id,
            widget.initialQuantityMilli ?? Quantity.scale,
            actualCost ?? product.costCents));
      }
    }
    if (existing == null && widget.initialLines != null) {
      for (final initial in widget.initialLines!) {
        final product =
            productRows.where((p) => p.id == initial.productId).firstOrNull;
        if (product == null || initial.quantityMilli <= 0) continue;
        final index = lines.indexWhere((line) => line.productId == product.id);
        if (index >= 0) {
          final old = lines[index];
          lines[index] = PurchaseOrderLineInput(
              old.productId,
              old.quantityMilli + initial.quantityMilli,
              old.expectedUnitCostCents,
              notes: old.notes);
        } else {
          lines.add(PurchaseOrderLineInput(
              product.id, initial.quantityMilli, product.costCents));
        }
      }
    }
    String? formError;
    bool saving = false;
    bool closing = false;
    void dismiss(BuildContext dialogContext) {
      if (closing || ModalRoute.of(dialogContext)?.isCurrent != true) return;
      closing = true;
      Navigator.pop(dialogContext);
    }

    await showDialog<void>(
        context: context,
        builder: (dialogContext) => _EscapeDismiss(
            onEscape: () => dismiss(dialogContext),
            child: _OwnedTextControllers(
                controllers: [reference, notes],
                child: StatefulBuilder(
                    builder: (dialogContext, update) => Dialog(
                          child: SizedBox(
                              width: 920,
                              height: 680,
                              child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            existing == null
                                                ? 'New Purchase Order'
                                                : 'Edit ${PurchaseOrderRepository.number(existing.order)}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall),
                                        const SizedBox(height: 8),
                                        const Text(
                                            'Plan a supplier order. Stock changes only when Receiving is finalized.'),
                                        if (formError != null)
                                          Text(formError!,
                                              style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .error)),
                                        const SizedBox(height: 16),
                                        Expanded(
                                            child: ListView(children: [
                                          DropdownButtonFormField<String>(
                                              initialValue: supplierId,
                                              decoration: const InputDecoration(
                                                  labelText: 'Supplier *'),
                                              items: [
                                                for (final s in supplierRows)
                                                  DropdownMenuItem(
                                                      value: s.id,
                                                      child: Text(s.name))
                                              ],
                                              onChanged: (v) =>
                                                  update(() => supplierId = v)),
                                          const SizedBox(height: 12),
                                          Wrap(
                                              spacing: 12,
                                              runSpacing: 12,
                                              children: [
                                                OutlinedButton.icon(
                                                    icon:
                                                        const Icon(Icons.event),
                                                    label: Text(
                                                        'Order: ${MaterialLocalizations.of(context).formatMediumDate(orderDate)}'),
                                                    onPressed: () async {
                                                      final picked =
                                                          await showDatePicker(
                                                              context:
                                                                  dialogContext,
                                                              initialDate:
                                                                  orderDate,
                                                              firstDate:
                                                                  DateTime(
                                                                      2000),
                                                              lastDate:
                                                                  DateTime(
                                                                      2100));
                                                      if (picked != null) {
                                                        update(() =>
                                                            orderDate = picked);
                                                      }
                                                    }),
                                                OutlinedButton.icon(
                                                    icon: const Icon(
                                                        Icons.event_available),
                                                    label: Text(expectedDate ==
                                                            null
                                                        ? 'Expected delivery'
                                                        : 'Expected: ${MaterialLocalizations.of(context).formatMediumDate(expectedDate!)}'),
                                                    onPressed: () async {
                                                      final picked =
                                                          await showDatePicker(
                                                              context:
                                                                  dialogContext,
                                                              initialDate:
                                                                  expectedDate ??
                                                                      orderDate,
                                                              firstDate:
                                                                  DateTime(
                                                                      2000),
                                                              lastDate:
                                                                  DateTime(
                                                                      2100));
                                                      if (picked != null) {
                                                        update(() =>
                                                            expectedDate =
                                                                picked);
                                                      }
                                                    }),
                                              ]),
                                          TextField(
                                              controller: reference,
                                              decoration: const InputDecoration(
                                                  labelText:
                                                      'Supplier reference / quote no.')),
                                          TextField(
                                              controller: notes,
                                              decoration: const InputDecoration(
                                                  labelText: 'Notes'),
                                              maxLines: 2),
                                          const SizedBox(height: 20),
                                          Text('Items',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                          for (var i = 0; i < lines.length; i++)
                                            ListTile(
                                                title: Text(products
                                                        .where((p) =>
                                                            p.id ==
                                                            lines[i].productId)
                                                        .firstOrNull
                                                        ?.name ??
                                                    'Product'),
                                                subtitle: Text(
                                                    '${Quantity.format(lines[i].quantityMilli)} × '
                                                    '${formatPeso(lines[i].expectedUnitCostCents)}'),
                                                trailing: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(formatPeso(
                                                          Quantity.lineCents(
                                                              lines[i]
                                                                  .expectedUnitCostCents,
                                                              lines[i]
                                                                  .quantityMilli))),
                                                      IconButton(
                                                          icon: const Icon(Icons
                                                              .remove_circle_outline),
                                                          onPressed: () =>
                                                              update(() => lines
                                                                  .removeAt(
                                                                      i))),
                                                    ])),
                                          OutlinedButton.icon(
                                              icon: const Icon(Icons.add),
                                              label: const Text('Add item'),
                                              onPressed: () async {
                                                String? productId;
                                                final qty =
                                                    TextEditingController();
                                                final cost =
                                                    TextEditingController();
                                                String? lineError;
                                                await showDialog<void>(
                                                    context: dialogContext,
                                                    builder: (itemContext) =>
                                                        _EscapeDismiss(
                                                            onEscape: () =>
                                                                Navigator.pop(
                                                                    itemContext),
                                                            child: _OwnedTextControllers(
                                                                controllers: [qty, cost],
                                                                child: StatefulBuilder(
                                                                    builder: (itemContext, itemUpdate) => AlertDialog(
                                                                          title:
                                                                              const Text('Add product'),
                                                                          content: SizedBox(
                                                                              width: 480,
                                                                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                                                                if (lineError != null) Text(lineError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                                                                                Autocomplete<PosProduct>(
                                                                                    displayStringForOption: (p) => '${p.name} · ${p.sku ?? ''}',
                                                                                    optionsBuilder: (value) => productRows.where((p) => '${p.name} ${p.sku ?? ''} ${p.barcode ?? ''}'.toLowerCase().contains(value.text.toLowerCase()) && !lines.any((l) => l.productId == p.id)),
                                                                                    onSelected: (p) {
                                                                                      productId = p.id;
                                                                                      cost.text = '${p.costCents ~/ 100}.${(p.costCents % 100).toString().padLeft(2, '0')}';
                                                                                    },
                                                                                    fieldViewBuilder: (context, controller, focus, submit) => TextField(controller: controller, focusNode: focus, decoration: const InputDecoration(labelText: 'Search product, SKU or barcode *'))),
                                                                                TextField(controller: qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Ordered quantity *')),
                                                                                TextField(controller: cost, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Expected unit cost *')),
                                                                              ])),
                                                                          actions: [
                                                                            TextButton(
                                                                                onPressed: () => Navigator.pop(itemContext),
                                                                                child: const Text('Cancel')),
                                                                            FilledButton(
                                                                                onPressed: () {
                                                                                  final product = productRows.where((p) => p.id == productId).firstOrNull;
                                                                                  final amount = product == null ? null : Quantity.tryParse(qty.text, fractional: product.business.fractional);
                                                                                  final cents = tryParsePeso(cost.text);
                                                                                  if (product == null || amount == null || cents == null) {
                                                                                    itemUpdate(() => lineError = 'Select a product and enter valid quantity and cost.');
                                                                                    return;
                                                                                  }
                                                                                  update(() => lines.add(PurchaseOrderLineInput(product.id, amount, cents)));
                                                                                  Navigator.pop(itemContext);
                                                                                },
                                                                                child: const Text('Add'))
                                                                          ],
                                                                        )))));
                                              }),
                                          const SizedBox(height: 16),
                                          Text(
                                              'Estimated total: ${formatPeso(lines.fold<int>(0, (sum, l) => sum + Quantity.lineCents(l.expectedUnitCostCents, l.quantityMilli)))}'),
                                        ])),
                                        Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.end,
                                            children: [
                                              TextButton(
                                                  onPressed: saving
                                                      ? null
                                                      : () => dismiss(
                                                          dialogContext),
                                                  child: const Text('Cancel')),
                                              const SizedBox(width: 8),
                                              for (final sent in [
                                                false,
                                                true
                                              ]) ...[
                                                if (sent)
                                                  const SizedBox(width: 8),
                                                FilledButton(
                                                    onPressed: saving
                                                        ? null
                                                        : () async {
                                                            if (supplierId ==
                                                                null) {
                                                              update(() =>
                                                                  formError =
                                                                      'Select a supplier.');
                                                              return;
                                                            }
                                                            update(() =>
                                                                saving = true);
                                                            try {
                                                              final PurchaseOrder
                                                                  order;
                                                              if (existing ==
                                                                  null) {
                                                                order = await widget.repository.create(
                                                                    widget.user,
                                                                    supplierId!,
                                                                    orderDate,
                                                                    lines,
                                                                    expectedDeliveryDate:
                                                                        expectedDate,
                                                                    supplierReference:
                                                                        reference
                                                                            .text,
                                                                    notes: notes
                                                                        .text,
                                                                    sourceQuotationReference:
                                                                        widget
                                                                            .initialQuotationReference,
                                                                    sourceQuantitiesMilli:
                                                                        sourceQuantities,
                                                                    markSent:
                                                                        sent);
                                                              } else {
                                                                await widget.repository.updateDraft(
                                                                    widget.user,
                                                                    existing
                                                                        .order
                                                                        .id,
                                                                    supplierId!,
                                                                    orderDate,
                                                                    lines,
                                                                    expectedDeliveryDate:
                                                                        expectedDate,
                                                                    supplierReference:
                                                                        reference
                                                                            .text,
                                                                    notes: notes
                                                                        .text,
                                                                    sourceQuotationReference:
                                                                        widget
                                                                            .initialQuotationReference,
                                                                    sourceQuantitiesMilli:
                                                                        sourceQuantities,
                                                                    markSent:
                                                                        sent);
                                                                order = existing
                                                                    .order;
                                                              }
                                                              if (dialogContext
                                                                  .mounted) {
                                                                dismiss(
                                                                    dialogContext);
                                                              }
                                                              if (mounted) {
                                                                selectedId =
                                                                    order.id;
                                                                await refresh();
                                                              }
                                                            } catch (e) {
                                                              update(() {
                                                                formError =
                                                                    safeMessage(
                                                                        e);
                                                                saving = false;
                                                              });
                                                            }
                                                          },
                                                    child: Text(sent
                                                        ? 'Mark as Sent'
                                                        : 'Save draft')),
                                              ],
                                            ]),
                                      ]))),
                        )))));
  }

  Future<void> action(Future<void> Function() run) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await run();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String label(String status) => switch (status) {
        'fully_received' => 'Fully received',
        'partially_received' => 'Partially received',
        _ => '${status[0].toUpperCase()}${status.substring(1)}'
      };

  @override
  Widget build(BuildContext context) => Scaffold(
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: ListView(padding: const EdgeInsets.all(20), children: [
                if (selectedId != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => selectedId = null),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back to Purchase Orders'),
                    ),
                  ),
                AppPageHeader(
                  title: selectedId == null
                      ? 'Purchase Orders'
                      : orders
                              .where((order) => order.id == selectedId)
                              .map(PurchaseOrderRepository.number)
                              .firstOrNull ??
                          'Purchase Order',
                  subtitle: selectedId == null
                      ? 'Plan purchases and receive deliveries through Receiving.'
                      : null,
                  action: selectedId == null
                      ? FilledButton.icon(
                          onPressed: create,
                          icon: const Icon(Icons.add),
                          label: const Text('New Purchase Order'))
                      : null,
                ),
                if (error != null)
                  Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                const SizedBox(height: 16),
                if (selectedId == null)
                  Wrap(spacing: 12, children: [
                    SizedBox(
                        width: 280,
                        child: TextField(
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                labelText: 'Search PO, supplier, reference'),
                            onChanged: (v) => setState(() => search = v))),
                    DropdownButton<String>(
                        value: filter,
                        items: [
                          'All',
                          'Open',
                          'Awaiting delivery',
                          'Completed',
                          'Overdue',
                          'Draft',
                          'Sent',
                          'Partially received',
                          'Fully received',
                          'Closed',
                          'Cancelled'
                        ]
                            .map((v) =>
                                DropdownMenuItem(value: v, child: Text(v)))
                            .toList(),
                        onChanged: (v) => setState(() => filter = v ?? 'All')),
                    DropdownButton<String?>(
                        value: supplierFilter,
                        hint: const Text('All suppliers'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('All suppliers')),
                          for (final supplier in suppliers)
                            DropdownMenuItem<String?>(
                                value: supplier.id, child: Text(supplier.name)),
                        ],
                        onChanged: (v) => setState(() => supplierFilter = v)),
                    OutlinedButton(
                      onPressed: () async {
                        final range = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                            initialDateRange: orderRange);
                        if (range != null) setState(() => orderRange = range);
                      },
                      child: Text(orderRange == null
                          ? 'Order dates'
                          : 'Order: ${MaterialLocalizations.of(context).formatShortDate(orderRange!.start)}–${MaterialLocalizations.of(context).formatShortDate(orderRange!.end)}'),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        final range = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                            initialDateRange: deliveryRange);
                        if (range != null) {
                          setState(() => deliveryRange = range);
                        }
                      },
                      child: Text(deliveryRange == null
                          ? 'Expected delivery'
                          : 'Delivery: ${MaterialLocalizations.of(context).formatShortDate(deliveryRange!.start)}–${MaterialLocalizations.of(context).formatShortDate(deliveryRange!.end)}'),
                    ),
                    if (orderRange != null || deliveryRange != null)
                      TextButton(
                          onPressed: () => setState(() {
                                orderRange = null;
                                deliveryRange = null;
                              }),
                          child: const Text('Clear dates')),
                  ]),
                if (orders.isEmpty)
                  AppEmptyState(
                    title: 'No purchase orders yet',
                    message:
                        'Create a purchase order to track supplier orders and incoming stock.',
                    action: TextButton(
                      onPressed: create,
                      child: const Text('New Purchase Order'),
                    ),
                  ),
                for (final order in orders)
                  FutureBuilder<PurchaseOrderProgress>(
                      future: widget.repository.detail(order.id),
                      builder: (context, snapshot) {
                        final p = snapshot.data;
                        if (p == null) return const SizedBox.shrink();
                        final supplier = suppliers
                                .where((s) => s.id == order.supplierId)
                                .firstOrNull
                                ?.name ??
                            'Supplier';
                        final haystack =
                            '${PurchaseOrderRepository.number(order)} $supplier '
                                    '${order.supplierReference ?? ''}'
                                .toLowerCase();
                        final today = DateUtils.dateOnly(DateTime.now());
                        final expected = order.expectedDeliveryDate == null
                            ? null
                            : DateUtils.dateOnly(order.expectedDeliveryDate!);
                        final overdue = p.isOverdue(DateTime.now());
                        final dueLabel = expected == null
                            ? 'Expected not set'
                            : overdue
                                ? 'Overdue · ${today.difference(expected).inDays} ${today.difference(expected).inDays == 1 ? 'day' : 'days'}'
                                : expected == today
                                    ? 'Due today'
                                    : 'Expected ${MaterialLocalizations.of(context).formatMediumDate(expected)}';
                        final matchesStatus = filter == 'All' ||
                            (filter == 'Open' &&
                                p.remainingTotal > 0 &&
                                {'sent', 'partially_received'}
                                    .contains(p.status)) ||
                            (filter == 'Awaiting delivery' &&
                                p.status == 'sent') ||
                            (filter == 'Completed' &&
                                {'fully_received', 'closed'}
                                    .contains(p.status)) ||
                            (filter == 'Overdue' && overdue) ||
                            label(p.status).toLowerCase() ==
                                filter.toLowerCase();
                        bool inRange(DateTime value, DateTimeRange range) {
                          final day = DateUtils.dateOnly(value);
                          return !day.isBefore(range.start) &&
                              !day.isAfter(range.end);
                        }

                        if (selectedId != null && selectedId != order.id) {
                          return const SizedBox.shrink();
                        }
                        if (selectedId == null &&
                            (!haystack.contains(search.toLowerCase()) ||
                                !matchesStatus ||
                                (supplierFilter != null &&
                                    supplierFilter != order.supplierId) ||
                                (orderRange != null &&
                                    !inRange(order.orderDate, orderRange!)) ||
                                (deliveryRange != null &&
                                    (order.expectedDeliveryDate == null ||
                                        !inRange(order.expectedDeliveryDate!,
                                            deliveryRange!))))) {
                          return const SizedBox.shrink();
                        }
                        return Card(
                            child: Column(children: [
                          if (selectedId == null)
                            ListTile(
                                title: Text(
                                    '${PurchaseOrderRepository.number(order)} · $supplier'),
                                subtitle: Text(
                                    '${label(p.status)} · Ordered ${MaterialLocalizations.of(context).formatMediumDate(order.orderDate)} · $dueLabel\n'
                                    '${Quantity.format(p.ordered)} ordered · ${Quantity.format(p.receivedTotal)} received · ${Quantity.format(p.remainingTotal)} remaining · ${formatPeso(p.estimatedTotal)} expected'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () =>
                                    _openQuickDetail(order, p, supplier)),
                          if (selectedId == order.id)
                            Padding(
                                key: _expandedOrderKey,
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      TextButton.icon(
                                          onPressed: () =>
                                              setState(() => selectedId = null),
                                          icon: const Icon(Icons.arrow_back),
                                          label: const Text(
                                              'Back to Purchase Orders')),
                                      Text(
                                          'Supplier reference: ${order.supplierReference ?? '—'}'),
                                      Text(
                                          'Expected delivery: ${order.expectedDeliveryDate == null ? 'Not set' : MaterialLocalizations.of(context).formatMediumDate(order.expectedDeliveryDate!)}'),
                                      Text('Notes: ${order.notes ?? '—'}'),
                                      Text(
                                          'Remaining: ${Quantity.format(p.remainingTotal)}'),
                                      if (p.receivedTotal > 0)
                                        FutureBuilder<ReceivedCostVariance>(
                                            future: widget.repository
                                                .receivedCostVariance(order.id),
                                            builder: (context, snapshot) {
                                              final value = snapshot.data;
                                              if (value == null) {
                                                return const SizedBox.shrink();
                                              }
                                              final difference =
                                                  value.differenceCents;
                                              return Text(
                                                  'Expected value of received quantity: ${formatPeso(value.expectedCents)} · Actual received cost: ${formatPeso(value.actualCents)} · Variance: ${difference > 0 ? '+' : ''}${formatPeso(difference)}${value.percent == null ? '' : ' (${value.percent!.toStringAsFixed(1)}%)'}');
                                            }),
                                      if (order.cancelReason != null)
                                        Text(
                                            'Cancellation: ${order.cancelReason}'),
                                      const SizedBox(height: 12),
                                      FutureBuilder<
                                              Map<String, List<Quotation>>>(
                                          future: widget.repository
                                              .sourceQuotationsForOrder(
                                                  order.id),
                                          builder:
                                              (context, sources) => Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text('Items',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .titleMedium),
                                                        for (final line
                                                            in p.lines)
                                                          ListTile(
                                                              dense: true,
                                                              title: Text(products
                                                                      .where((x) =>
                                                                          x.id ==
                                                                          line
                                                                              .productId)
                                                                      .firstOrNull
                                                                      ?.name ??
                                                                  'Product'),
                                                              subtitle: Column(
                                                                  crossAxisAlignment:
                                                                      CrossAxisAlignment
                                                                          .start,
                                                                  children: [
                                                                    Text(
                                                                        'Ordered ${Quantity.format(line.orderedQtyMilli)} · Received ${Quantity.format(p.received[line.id] ?? 0)} · Remaining ${Quantity.format(p.remaining(line))} · Expected ${formatPeso(line.expectedUnitCostCents)}'),
                                                                    for (final quote
                                                                        in sources.data?[line.id] ??
                                                                            <Quotation>[])
                                                                      TextButton(
                                                                          onPressed: widget.onOpenQuotation == null
                                                                              ? null
                                                                              : () => widget.onOpenQuotation!(quote
                                                                                  .reference),
                                                                          child:
                                                                              Text('Source: ${quote.reference}')),
                                                                  ])),
                                                        if ((sources.data
                                                                    ?.isEmpty ??
                                                                false) &&
                                                            (order.notes?.contains(
                                                                    'For quotation') ??
                                                                false))
                                                          const Text(
                                                              'Legacy sourcing note (unverified link)'),
                                                      ])),
                                      if (p.receivings.isNotEmpty) ...[
                                        Text('Receiving history',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        for (final receipt in p.receivings)
                                          ListTile(
                                              dense: true,
                                              title: Text(
                                                  StockReceivingRepository
                                                      .number(receipt)),
                                              subtitle: Text(
                                                  '${MaterialLocalizations.of(context).formatMediumDate(receipt.receivedAt)} · ${receipt.externalReference?.isNotEmpty == true ? 'Supplier reference ${receipt.externalReference}' : 'No supplier reference'}'),
                                              onTap: widget.onOpenReceiving ==
                                                      null
                                                  ? null
                                                  : () =>
                                                      widget.onOpenReceiving!(
                                                          receipt.id)),
                                      ],
                                      if (order.sentAt != null) ...[
                                        const SizedBox(height: 8),
                                        Text(p.receivings.isEmpty
                                            ? 'Open for ${SupplierProcurementRepository.calendarDays(order.sentAt!, DateTime.now())} days'
                                            : 'First delivery: ${SupplierProcurementRepository.calendarDays(order.sentAt!, p.receivings.first.receivedAt)} days after sent${order.expectedDeliveryDate == null ? '' : ' · ${SupplierProcurementRepository.deliveryPerformance(order.expectedDeliveryDate!, p.receivings.first.receivedAt)}'}'),
                                        if (p.receivings.isNotEmpty &&
                                            {'fully_received', 'closed'}
                                                .contains(p.status))
                                          Text(
                                              'Completion: ${SupplierProcurementRepository.calendarDays(order.sentAt!, p.receivings.last.receivedAt)} days after sent'),
                                      ],
                                      const SizedBox(height: 12),
                                      Text('Activity',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      FutureBuilder<
                                              List<PurchaseOrderActivity>>(
                                          future: widget.repository
                                              .activity(order.id),
                                          builder: (context, snapshot) =>
                                              Column(children: [
                                                for (final event in snapshot
                                                        .data ??
                                                    <PurchaseOrderActivity>[])
                                                  ListTile(
                                                    dense: true,
                                                    title: Text(event.title),
                                                    subtitle: Text(
                                                        '${MaterialLocalizations.of(context).formatMediumDate(event.at)} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(event.at))} · ${event.detail}${event.actorName == null ? '' : ' · ${event.actorName}'}'),
                                                  ),
                                              ])),
                                      Wrap(spacing: 8, children: [
                                        OutlinedButton.icon(
                                            onPressed: () => setState(
                                                () => selectedId = null),
                                            icon: const Icon(Icons.arrow_back),
                                            label: const Text('Back to list')),
                                        OutlinedButton.icon(
                                            onPressed: () =>
                                                exportOrder(order, print: true),
                                            icon: const Icon(
                                                Icons.print_outlined),
                                            label: const Text('Print PO')),
                                        OutlinedButton.icon(
                                            onPressed: () => exportOrder(order,
                                                print: false),
                                            icon: const Icon(
                                                Icons.picture_as_pdf_outlined),
                                            label: const Text('Save PDF')),
                                        OutlinedButton(
                                            onPressed: busy
                                                ? null
                                                : () => action(() async {
                                                      final copy = await widget
                                                          .repository
                                                          .duplicate(
                                                              widget.user,
                                                              order.id);
                                                      if (mounted) {
                                                        setState(() =>
                                                            selectedId =
                                                                copy.id);
                                                      }
                                                    }),
                                            child: const Text('Duplicate PO')),
                                        if (p.status == 'draft')
                                          OutlinedButton(
                                              onPressed:
                                                  busy ? null : () => create(p),
                                              child: const Text('Edit draft')),
                                        if (p.status == 'draft')
                                          OutlinedButton(
                                              onPressed: busy
                                                  ? null
                                                  : () => action(() => widget
                                                      .repository
                                                      .markSent(widget.user,
                                                          order.id)),
                                              child:
                                                  const Text('Mark as Sent')),
                                        if ((p.status == 'sent' ||
                                                p.status ==
                                                    'partially_received') &&
                                            p.lines.any((line) =>
                                                p.remaining(line) > 0))
                                          FilledButton(
                                              onPressed: busy
                                                  ? null
                                                  : () => widget
                                                      .onReceive(order.id),
                                              child: const Text(
                                                  'Receive remaining')),
                                        if (widget.user.can(PosPermission
                                                .cancelPurchaseOrders) &&
                                            [
                                              'draft',
                                              'sent',
                                              'partially_received'
                                            ].contains(p.status))
                                          OutlinedButton(
                                              onPressed: busy
                                                  ? null
                                                  : () async {
                                                      final reason =
                                                          TextEditingController();
                                                      final text = await showDialog<
                                                              String>(
                                                          context: context,
                                                          builder: (ctx) =>
                                                              _OwnedTextControllers(
                                                                  controllers: [
                                                                    reason
                                                                  ],
                                                                  child: AlertDialog(
                                                                      title: const Text(
                                                                          'Cancel Purchase Order'),
                                                                      content: TextField(
                                                                          controller:
                                                                              reason,
                                                                          decoration:
                                                                              const InputDecoration(labelText: 'Reason *')),
                                                                      actions: [
                                                                        TextButton(
                                                                            onPressed: () =>
                                                                                Navigator.pop(ctx),
                                                                            child: const Text('Keep order')),
                                                                        FilledButton(
                                                                            onPressed: () =>
                                                                                Navigator.pop(ctx, reason.text),
                                                                            child: const Text('Cancel order'))
                                                                      ])));
                                                      if (text != null) {
                                                        await action(() =>
                                                            widget.repository
                                                                .cancel(
                                                                    widget.user,
                                                                    order.id,
                                                                    text));
                                                      }
                                                    },
                                              child:
                                                  const Text('Cancel order')),
                                        if (widget.user.can(PosPermission
                                                .cancelPurchaseOrders) &&
                                            p.status == 'fully_received')
                                          OutlinedButton(
                                              onPressed: busy
                                                  ? null
                                                  : () => action(() =>
                                                      widget.repository.close(
                                                          widget.user,
                                                          order.id)),
                                              child: const Text('Close order')),
                                      ]),
                                    ])),
                        ]));
                      }),
              ]))));
}
