import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/sales_order_repository.dart';
import '../../data/daos/stock_reservation_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../hardware/printer/receipt_service.dart';
import '../pos_checkout/checkout_screen.dart';

class SalesOrdersScreen extends StatefulWidget {
  final SalesOrderRepository repository;
  final DirectoryRepository directory;
  final PosRepository products;
  final ActiveUser user;
  final AuthService? auth;
  final ReceiptService? receipts;
  final String? initialReference;
  final String? initialQuotationId;
  const SalesOrdersScreen({super.key, required this.repository,
    required this.directory, required this.products, required this.user,
    this.initialReference, this.initialQuotationId,
    this.auth, this.receipts});
  @override
  State<SalesOrdersScreen> createState() => _SalesOrdersScreenState();
}

class _SalesOrdersScreenState extends State<SalesOrdersScreen> {
  List<SalesOrder> orders = [];
  Map<String, String> fulfillmentStates = {};
  int total = 0, page = 0;
  String search = '', status = 'all';
  bool loading = false;
  String? error;
  Timer? debounce;
  int? _parseMoney(String value) {
    final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(value.trim());
    if (match == null) return null;
    return int.parse(match.group(1)!) * 100 +
        int.parse((match.group(2) ?? '').padRight(2, '0'));
  }
  @override
  void initState() {
    super.initState();
    refresh().then((_) async {
      if (!mounted) return;
      if (widget.initialReference != null) {
        final order = await widget.repository.byReference(widget.initialReference!);
        if (order != null && mounted) detail(order);
      } else if (widget.initialQuotationId != null) {
        final order = await widget.repository.convertQuotation(
            widget.user, widget.initialQuotationId!);
        if (mounted) { await refresh(); detail(order); }
      }
    });
  }
  @override
  void dispose() { debounce?.cancel(); super.dispose(); }
  Future<void> refresh() async {
    setState(() { loading = true; error = null; });
    try {
      final result = await widget.repository.page(
          page: page, search: search, status: status);
      final states = await widget.repository.fulfillmentStates(
          result.items.map((order) => order.id));
      if (mounted) {
        setState(() {
          orders = result.items; total = result.totalCount; loading = false;
          fulfillmentStates = states;
        });
      }
    } catch (e) {
      if (mounted) setState(() { error = e.toString(); loading = false; });
    }
  }
  Future<void> detail(SalesOrder order) async {
    final lines = await widget.repository.lines(order.id);
    final fulfilledByLine = await widget.repository.fulfilledByLine(order.id);
    final fulfillmentSales = await widget.repository.fulfillmentSales(order.id);
    final reservations = await StockReservationRepository(widget.repository.db)
        .forOrder(order.id);
    final reservedByLine = await StockReservationRepository(widget.repository.db)
        .activeByLine(order.id);
    if (!mounted) return;
    showDialog<void>(context: context, builder: (context) => Dialog(
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780,
          maxHeight: 700), child: Padding(padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(order.reference,
            style: Theme.of(context).textTheme.headlineSmall)),
            IconButton(onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close))]),
          Text('${order.customerNameSnapshot}  •  ${order.status}'),
          Text('Fulfillment: ${fulfilledByLine.values.fold<int>(0, (sum, quantity) => sum + quantity) == 0 ? 'Unfulfilled' : lines.every((line) => (fulfilledByLine[line.id] ?? 0) >= line.quantityMilli) ? 'Fulfilled' : 'Partially fulfilled'}'),
          Text('Created ${order.createdAt.toLocal().toString().split(' ').first}'),
          if (order.requestedDate != null)
            Text('Requested ${order.requestedDate!.toLocal().toString().split(' ').first}'),
          Text('Intent: ${order.fulfillmentMethod ?? 'Not set'}'),
          if (order.sourceQuotationId != null)
            FutureBuilder<Quotation?>(future: (widget.repository.db
                .select(widget.repository.db.quotations)
                  ..where((q) => q.id.equals(order.sourceQuotationId!)))
                .getSingleOrNull(), builder: (context, snapshot) =>
                  Text('Source quotation: ${snapshot.data?.reference ?? '…'}')),
          const Divider(),
          Expanded(child: ListView(children: [for (final line in lines) ...[
            ListTile(title: Text(line.descriptionSnapshot),
              subtitle: Text('${line.skuSnapshot ?? ''}  •  ${Quantity.format(line.quantityMilli)} ${line.unitSnapshot} × ${formatPeso(line.unitPriceCents)}'),
              trailing: Text(formatPeso(line.lineTotalCents))),
            Padding(padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Row(children: [
                Expanded(child: Text('Ordered ${Quantity.format(line.quantityMilli)}  •  Fulfilled ${Quantity.format(fulfilledByLine[line.id] ?? 0)}  •  Remaining ${Quantity.format(line.quantityMilli - (fulfilledByLine[line.id] ?? 0))}  •  Reserved ${Quantity.format(reservedByLine[line.id] ?? 0)}')),
                if (order.status == 'confirmed' && line.productId != null &&
                    line.quantityMilli > (reservedByLine[line.id] ?? 0) +
                        (fulfilledByLine[line.id] ?? 0) &&
                    widget.user.can(PosPermission.manageStockReservations))
                  TextButton(onPressed: () async {
                    Navigator.pop(context);
                    await _reserveLine(order, line);
                  }, child: const Text('Reserve stock')),
              ])),
            for (final reservation in reservations.where((r) =>
                r.salesOrderLineId == line.id && r.status == 'active'))
              Padding(padding: const EdgeInsets.only(left: 32),
                child: Row(children: [
                  Expanded(child: Text('${reservation.reference}  •  ${Quantity.format(reservation.quantityMilli)} reserved')),
                  if (widget.user.can(PosPermission.manageStockReservations))
                    TextButton(onPressed: () async {
                      Navigator.pop(context);
                      await StockReservationRepository(widget.repository.db)
                          .release(widget.user, reservation.id,
                              reason: 'Manual release');
                      await refresh();
                      if (mounted) detail(order);
                    }, child: const Text('Release reservation')),
                ])),
          ]])),
          if (fulfillmentSales.isNotEmpty) ...[
            const Divider(),
            Text('Fulfillment history',
                style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: 90, child: ListView(children: [
              for (final sale in fulfillmentSales)
                ListTile(dense: true,
                  title: Text(sale.receiptNumber ?? 'Sale'),
                  subtitle: Text(sale.createdAt.toLocal().toString().split(' ').first),
                  trailing: Text(formatPeso(sale.totalCents)))
            ])),
          ],
          const Divider(),
          Text('Subtotal ${formatPeso(order.subtotalCents)}'),
          if (order.discountCents > 0)
            Text('Discount ${formatPeso(order.discountCents)}'),
          Text('Total ${formatPeso(order.totalCents)}',
              style: Theme.of(context).textTheme.titleLarge),
          if (order.notes?.isNotEmpty == true) Text('Notes: ${order.notes}'),
          if (widget.user.can(PosPermission.manageSalesOrders))
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (order.status == 'confirmed' &&
                  lines.any((line) => line.quantityMilli >
                      (fulfilledByLine[line.id] ?? 0)) &&
                  widget.user.can(PosPermission.sell) && widget.auth != null)
                FilledButton(onPressed: () async {
                  Navigator.pop(context);
                  await _startFulfillment(order, lines, fulfilledByLine);
                }, child: const Text('Fulfill Order')),
              if (order.status == 'draft' &&
                  lines.every((line) => line.productId != null)) TextButton(
                onPressed: () { Navigator.pop(context); create(existing: order); },
                child: const Text('Edit draft')),
              if (order.status == 'draft') FilledButton(
                onPressed: () async { Navigator.pop(context);
                  await widget.repository.transition(widget.user, order.id,
                      'confirmed'); await refresh(); },
                child: const Text('Confirm')),
              if (order.status == 'confirmed') TextButton(
                onPressed: () async { Navigator.pop(context);
                  await widget.repository.transition(widget.user, order.id,
                      'cancelled'); await refresh(); },
                child: const Text('Cancel order')),
            ])
        ])))));
  }
  Future<void> _reserveLine(SalesOrder order, SalesOrderLine line) async {
    final repository = StockReservationRepository(widget.repository.db);
    final levels = await repository.stock(line.productId!);
    final reserved = (await repository.activeByLine(order.id))[line.id] ?? 0;
    final fulfilled = (await widget.repository.fulfilledByLine(order.id))
        [line.id] ?? 0;
    final remaining = line.quantityMilli - fulfilled - reserved;
    if (!mounted) return;
    final controller = TextEditingController(
        text: Quantity.format(remaining <= levels.available
            ? remaining : levels.available.clamp(0, remaining)));
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: Text('Reserve ${line.descriptionSnapshot}'),
      content: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Requested: ${Quantity.format(remaining)}'),
        Text('Available: ${Quantity.format(levels.available)}'),
        Text('Shortfall: ${Quantity.format((remaining - levels.available).clamp(0, remaining))}'),
        const SizedBox(height: 12),
        TextField(controller: controller,
          decoration: const InputDecoration(labelText: 'Quantity to reserve')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context),
          child: const Text('Close')),
        FilledButton(onPressed: () async {
          final quantity = Quantity.tryParse(controller.text);
          if (quantity == null) return;
          try {
            await repository.reserve(widget.user, line.id, quantity);
            if (context.mounted) Navigator.pop(context);
            await refresh();
            if (mounted) detail(order);
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(e.toString())));
            }
          }
        }, child: const Text('Reserve'))],
    ));
    controller.dispose();
  }
  Future<void> _startFulfillment(SalesOrder order,
      List<SalesOrderLine> lines, Map<String, int> fulfilled) async {
    final levels = await widget.products.stockLevels();
    final claims = await StockReservationRepository(widget.repository.db)
        .forOrder(order.id);
    final ownByProduct = <String, int>{};
    for (final claim in claims.where((claim) => claim.status == 'active')) {
      ownByProduct.update(claim.productId,
          (quantity) => quantity + claim.quantityMilli,
          ifAbsent: () => claim.quantityMilli);
    }
    final inputs = <String, TextEditingController>{
      for (final line in lines)
        if (line.productId != null &&
            line.quantityMilli > (fulfilled[line.id] ?? 0))
          line.id: TextEditingController(text: Quantity.format(
              line.quantityMilli - (fulfilled[line.id] ?? 0)))
    };
    if (!mounted) return;
    final chosen = await showDialog<Map<String, int>>(context: context,
      builder: (context) => AlertDialog(
        title: Text('Fulfill ${order.reference}'),
        content: SizedBox(width: 430, child: ListView(
          shrinkWrap: true, children: [
          const Text('Choose quantities for this Sale. Payment and allocation follow in checkout.'),
          for (final line in lines)
            if (inputs.containsKey(line.id))
              TextField(controller: inputs[line.id],
                decoration: InputDecoration(labelText:
                    '${line.descriptionSnapshot} (remaining ${Quantity.format(line.quantityMilli - (fulfilled[line.id] ?? 0))}; usable ${Quantity.format((levels[line.productId]?.$1 ?? 0) - (levels[line.productId]?.$2 ?? 0) + (ownByProduct[line.productId] ?? 0))})')),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(context),
          child: const Text('Close')),
          FilledButton(onPressed: () {
            final quantities = <String, int>{};
            for (final line in lines) {
              final input = inputs[line.id];
              if (input == null || input.text.trim().isEmpty ||
                  input.text.trim() == '0') {
                continue;
              }
              final qty = Quantity.tryParse(input.text);
              if (qty == null || qty > line.quantityMilli -
                  (fulfilled[line.id] ?? 0)) {
                return;
              }
              quantities[line.id] = qty;
            }
            if (quantities.isEmpty) return;
            Navigator.pop(context, quantities);
          }, child: const Text('Open checkout'))],
      ));
    for (final input in inputs.values) { input.dispose(); }
    if (chosen == null || !mounted) return;
    await Navigator.push<String>(context, MaterialPageRoute(
      builder: (_) => CheckoutScreen(repository: widget.products,
        user: widget.user, auth: widget.auth!, receipts: widget.receipts,
        salesOrderId: order.id, salesOrderReference: order.reference,
        salesOrderQuantities: chosen)));
    if (mounted) await refresh();
  }
  Future<void> create({SalesOrder? existing}) async {
    final customers = await widget.directory.customers();
    final products = await widget.products.products();
    final stock = await widget.products.stockLevels();
    final prior = existing == null ? <SalesOrderLine>[] :
        await widget.repository.lines(existing.id);
    if (!mounted) return;
    String? customerId = existing?.customerId, productId;
    String? intent = existing?.fulfillmentMethod;
    DateTime? requestedDate = existing?.requestedDate;
    final qty = TextEditingController(text: '1');
    final price = TextEditingController();
    final notes = TextEditingController(text: existing?.notes);
    final lines = <SalesOrderLineRequest>[
      for (final line in prior)
        if (line.productId != null)
          SalesOrderLineRequest(line.productId!, line.quantityMilli,
              line.unitPriceCents, discountCents: line.discountCents)];
    await showDialog<void>(context: context, builder: (context) =>
      StatefulBuilder(builder: (context, update) => Dialog(child:
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 780,
          maxHeight: 700), child: Padding(padding: const EdgeInsets.all(24),
          child: Column(children: [
            Text(existing == null ? 'New Sales Order' :
                'Edit ${existing.reference}',
                style: Theme.of(context).textTheme.headlineSmall),
            DropdownButtonFormField<String>(initialValue: customerId,
              decoration: const InputDecoration(labelText: 'Customer'),
              items: [for (final c in customers.where((c) => c.isActive))
                DropdownMenuItem(value: c.id, child: Text(c.name))],
              onChanged: (v) => update(() => customerId = v)),
            DropdownButtonFormField<String>(initialValue: intent,
              decoration: const InputDecoration(labelText: 'Fulfillment intent'),
              items: const [DropdownMenuItem(value: 'pickup', child: Text('Pickup')),
                DropdownMenuItem(value: 'delivery', child: Text('Delivery'))],
              onChanged: (v) => update(() => intent = v)),
            Row(children: [Expanded(child: Text(requestedDate == null
                ? 'No requested date' :
                'Requested ${requestedDate!.toLocal().toString().split(' ').first}')),
              TextButton(onPressed: () async {
                final picked = await showDatePicker(context: context,
                  initialDate: requestedDate ?? DateTime.now(),
                  firstDate: DateTime(2000), lastDate: DateTime(2100));
                if (picked != null) update(() => requestedDate = picked);
              }, child: const Text('Choose date'))]),
            Row(children: [Expanded(child: DropdownButtonFormField<String>(
              initialValue: productId,
              decoration: const InputDecoration(labelText: 'Product'),
              items: [for (final p in products.where((p) => p.isActive))
                DropdownMenuItem(value: p.id, child: Text(p.name))],
              onChanged: (v) => update(() { productId = v;
                final p = products.where((p) => p.id == v).firstOrNull;
                if (p != null) price.text = (p.priceCents / 100).toStringAsFixed(2);
              }))),
              SizedBox(width: 90, child: TextField(controller: qty,
                onChanged: (_) => update(() {}),
                decoration: const InputDecoration(labelText: 'Qty'))),
              SizedBox(width: 110, child: TextField(controller: price,
                decoration: const InputDecoration(labelText: 'Price'))),
              IconButton(icon: const Icon(Icons.add), onPressed: () {
                final p = products.where((p) => p.id == productId).firstOrNull;
                final amount = _parseMoney(price.text);
                final quantity = Quantity.tryParse(qty.text,
                    fractional: p?.business.fractional ?? false);
                if (p == null || amount == null || quantity == null) return;
                update(() => lines.add(SalesOrderLineRequest(
                    p.id, quantity, amount)));
              })]),
            if (productId != null)
              Align(alignment: Alignment.centerLeft,
                child: Text('On hand: ${Quantity.format(stock[productId]?.$1 ?? 0)}  •  Requested: ${qty.text}')),
            Expanded(child: ListView(children: [for (var i = 0; i < lines.length; i++)
              ListTile(title: Text(products.firstWhere((p) =>
                  p.id == lines[i].productId).name),
                subtitle: Text(Quantity.format(lines[i].quantityMilli)),
                trailing: IconButton(icon: const Icon(Icons.delete_outline),
                  onPressed: () => update(() => lines.removeAt(i))))])),
            TextField(controller: notes,
                decoration: const InputDecoration(labelText: 'Notes')),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context),
                  child: const Text('Close')),
              FilledButton(onPressed: () async {
                if (customerId == null || lines.isEmpty) return;
                final order = existing == null
                    ? await widget.repository.create(widget.user,
                        customerId!, lines, notes: notes.text,
                        fulfillmentMethod: intent,
                        requestedDate: requestedDate)
                    : await widget.repository.updateDraft(widget.user,
                        existing.id, customerId!, lines, notes: notes.text,
                        fulfillmentMethod: intent,
                        requestedDate: requestedDate);
                if (context.mounted) Navigator.pop(context);
                await refresh();
                if (mounted) detail(order);
              }, child: const Text('Save draft'))])
          ]))))));
    qty.dispose(); price.dispose(); notes.dispose();
  }
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24), child: Column(children: [
      AppPageHeader(title: 'Sales Orders',
        subtitle: 'Track confirmed customer orders before fulfillment.',
        action: widget.user.can(PosPermission.manageSalesOrders) ?
          FilledButton.icon(onPressed: create, icon: const Icon(Icons.add),
            label: const Text('New Sales Order')) : null),
      Row(children: [Expanded(child: TextField(
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
            hintText: 'Search reference or customer'),
        onChanged: (v) { debounce?.cancel(); debounce = Timer(
          const Duration(milliseconds: 250), () { search = v; page = 0; refresh(); }); })),
        const SizedBox(width: 12),
        DropdownButton<String>(value: status, items: const [
          DropdownMenuItem(value: 'all', child: Text('All')),
          DropdownMenuItem(value: 'draft', child: Text('Draft')),
          DropdownMenuItem(value: 'confirmed', child: Text('Confirmed')),
          DropdownMenuItem(value: 'cancelled', child: Text('Cancelled'))],
          onChanged: (v) { if (v == null) return;
            setState(() { status = v; page = 0; }); refresh(); })]),
      const SizedBox(height: 16),
      Expanded(child: AppPagedListPanel(title: 'Orders', total: total,
        count: orders.length, page: page, loading: loading, error: error,
        onRetry: refresh,
        onPrevious: page > 0 ? () { page--; refresh(); } : null,
        onNext: (page + 1) * 50 < total ? () { page++; refresh(); } : null,
        itemBuilder: (context, i) { final o = orders[i];
          return Material(color: Colors.transparent, child: ListTile(
            onTap: () => detail(o), title: Text(o.reference),
            subtitle: Text('${o.customerNameSnapshot}  •  ${o.createdAt.toLocal().toString().split(' ').first}  •  ${o.status}  •  ${fulfillmentStates[o.id] ?? 'Unfulfilled'}  •  ${o.fulfillmentMethod ?? 'No intent'}'),
            trailing: Text(formatPeso(o.totalCents)))); }))
    ]));
}
