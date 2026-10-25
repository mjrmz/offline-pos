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
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_feedback.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../shared/widgets/record_details_drawer.dart';
import '../../hardware/printer/receipt_service.dart';
import '../pos_checkout/checkout_screen.dart';
import 'sales_order_presentation.dart';

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
  Map<String, int> metrics = {};
  bool queue = false;
  String physicalFilter = 'active', methodFilter = 'all',
      queueMethodFilter = 'all', orderPhysicalFilter = 'all';
  int total = 0, page = 0;
  String search = '', status = 'all';
  DateTime? createdOn;
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
      final result = queue
          ? await widget.repository.physicalQueue(page: page,
              method: queueMethodFilter, status: physicalFilter)
          : await widget.repository.page(page: page, search: search,
              status: status, method: methodFilter,
              physicalStatus: orderPhysicalFilter, createdOn: createdOn);
      final states = await widget.repository.fulfillmentStates(
          result.items.map((order) => order.id));
      final counts = await widget.repository.workspaceMetrics();
      if (mounted) {
        setState(() {
          orders = result.items; total = result.totalCount; loading = false;
          fulfillmentStates = states;
          metrics = counts;
        });
      }
    } catch (e) {
      if (mounted) setState(() { error = safeMessage(e); loading = false; });
    }
  }
  Future<void> detail(SalesOrder order) async {
    order = await widget.repository.byReference(order.reference) ?? order;
    final lines = await widget.repository.lines(order.id);
    final fulfilled = await widget.repository.fulfilledByLine(order.id);
    final sales = await widget.repository.fulfillmentSales(order.id);
    final reservations = await StockReservationRepository(widget.repository.db)
        .forOrder(order.id);
    final reserved = await StockReservationRepository(widget.repository.db)
        .activeByLine(order.id);
    final events = await widget.repository.physicalEvents(order.id);
    final actorIds = events.map((event) => event.actorId).toSet();
    final users = actorIds.isEmpty ? <User>[] : await (
      widget.repository.db.select(widget.repository.db.users)
        ..where((user) => user.id.isIn(actorIds))).get();
    if (!mounted) return;
    void openAction(String next) {
      Navigator.pop(context);
      _physicalAction(order, next);
    }
    await showRecordDetailsDrawer<void>(context: context,
      builder: (context) => SalesOrderDetailView(
        order: order, lines: lines, fulfilledByLine: fulfilled,
        reservedByLine: reserved, reservations: reservations,
        fulfillmentSales: sales, physicalEvents: events,
        actorNames: {for (final user in users) user.id: user.name},
        user: widget.user, physicalActions: _physicalActions(order),
        onPhysicalAction: openAction,
        onConfigure: () { Navigator.pop(context); _configurePhysical(order); },
        onReserve: (line) { Navigator.pop(context); _reserveLine(order, line); },
        onRelease: (reservation) async {
          Navigator.pop(context);
          try {
            await StockReservationRepository(widget.repository.db)
                .release(widget.user, reservation.id, reason: 'Manual release');
            if (mounted) showAppFeedback(this.context, 'Reservation released');
            await refresh();
            if (mounted) detail(order);
          } catch (error) {
            if (mounted) showAppFeedback(this.context, safeMessage(error));
          }
        },
        onFulfill: order.status == 'confirmed' &&
            lines.any((line) => line.quantityMilli > (fulfilled[line.id] ?? 0)) &&
            widget.user.can(PosPermission.manageSalesOrders) &&
            widget.user.can(PosPermission.sell) && widget.auth != null
            ? () { Navigator.pop(context); _startFulfillment(order, lines, fulfilled); }
            : null,
        onEditDraft: () { Navigator.pop(context); create(existing: order); },
        onConfirm: () async {
          Navigator.pop(context);
          try {
            await widget.repository.transition(widget.user, order.id, 'confirmed');
            if (mounted) showAppFeedback(this.context, 'Order confirmed');
            await refresh();
          } catch (error) {
            if (mounted) showAppFeedback(this.context, safeMessage(error));
          }
        },
        onCancelOrder: () => _confirmCancelOrder(order),
      ));
  }
  Future<void> _confirmCancelOrder(SalesOrder order) async {
    final confirmed = await showDialog<bool>(context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Cancel ${order.reference}?'),
        content: const Text('This ends the order and active handoff. Completed Sales are not voided or refunded.'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep order')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel order'))]));
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.transition(widget.user, order.id, 'cancelled');
      if (!mounted) return;
      Navigator.pop(context);
      showAppFeedback(context, 'Order cancelled');
      await refresh();
    } catch (error) {
      if (mounted) showAppFeedback(context, safeMessage(error));
    }
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
            if (mounted) showAppFeedback(this.context, 'Stock reserved');
            await refresh();
            if (mounted) detail(order);
          } catch (e) {
            if (context.mounted) {
              showAppFeedback(context, safeMessage(e));
            }
          }
        }, child: const Text('Reserve'))],
    ));
    controller.dispose();
  }
  List<String> _physicalActions(SalesOrder order) {
    if (order.status != 'confirmed' || order.fulfillmentMethod == null) return [];
    switch (order.physicalStatus) {
      case 'pending': return ['scheduled', 'cancelled'];
      case 'scheduled': return ['scheduled', 'ready', 'cancelled'];
      case 'ready': return order.fulfillmentMethod == 'delivery'
          ? ['out_for_delivery', 'cancelled'] : ['picked_up', 'cancelled'];
      case 'out_for_delivery': return ['delivered', 'failed_delivery', 'cancelled'];
      case 'failed_delivery': return ['scheduled', 'cancelled'];
      default: return [];
    }
  }
  String _actionLabel(String next, String current) => switch (next) {
    'scheduled' => current == 'pending' ? 'Schedule' : 'Reschedule',
    'ready' => 'Mark Ready',
    'out_for_delivery' => 'Mark Out for Delivery',
    'delivered' => 'Mark Delivered',
    'picked_up' => 'Mark Picked Up',
    'failed_delivery' => 'Record Failed Delivery',
    'cancelled' => 'Cancel handoff',
    _ => next,
  };
  Future<void> _configurePhysical(SalesOrder order) async {
    final customer = await (widget.repository.db.select(widget.repository.db.customers)
      ..where((c) => c.id.equals(order.customerId))).getSingle();
    if (!mounted) return;
    var method = order.fulfillmentMethod ?? 'pickup';
    final name = TextEditingController(text: order.contactNameSnapshot ?? customer.name);
    final phone = TextEditingController(text: order.contactPhoneSnapshot ?? customer.phone);
    final address = TextEditingController(text: order.deliveryAddressSnapshot ?? customer.address);
    final instructions = TextEditingController(text: order.fulfillmentInstructions);
    final fee = TextEditingController(text: (order.deliveryFeeCents / 100).toStringAsFixed(2));
    await showDialog<void>(context: context, builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(title: Text('Delivery / Pickup - ${order.reference}'),
        content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Method', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(initialValue: method,
            decoration: const InputDecoration(labelText: 'Method'),
            items: const [DropdownMenuItem(value: 'pickup', child: Text('Pickup')),
              DropdownMenuItem(value: 'delivery', child: Text('Delivery'))],
            onChanged: (v) { if (v != null) update(() => method = v); }),
          const SizedBox(height: 16),
          Text(method == 'pickup' ? 'Pickup contact' : 'Delivery contact',
            style: Theme.of(context).textTheme.titleSmall),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Contact name')),
          TextField(controller: phone, decoration: const InputDecoration(labelText: 'Phone')),
          if (method == 'delivery') ...[
            const SizedBox(height: 16),
            Text('Delivery address', style: Theme.of(context).textTheme.titleSmall),
            Text('Copied to this order; changes here do not update the customer profile.',
              style: Theme.of(context).textTheme.bodySmall),
            TextField(controller: address, minLines: 2, maxLines: 4,
              decoration: const InputDecoration(labelText: 'Delivery address')),
            const SizedBox(height: 16),
            Text('Delivery fee', style: Theme.of(context).textTheme.titleSmall),
            TextField(controller: fee, keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount',
                helperText: 'Charged once on the final fulfillment Sale.')),
          ],
          const SizedBox(height: 16),
          TextField(controller: instructions, maxLines: 2,
            decoration: const InputDecoration(labelText: 'Instructions')),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context),
          child: const Text('Close')),
          FilledButton(onPressed: () async {
            try {
              final cents = method == 'delivery' ? _parseMoney(fee.text) : 0;
              if (cents == null) throw StateError('Enter a valid delivery fee');
              if (method == 'pickup' && order.deliveryFeeCents > 0) {
                final confirmed = await showDialog<bool>(context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Remove delivery fee?'),
                    content: Text('Changing to Pickup removes the ${formatPeso(order.deliveryFeeCents)} delivery fee from this order.'),
                    actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Keep Delivery')),
                      FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Change to Pickup'))]));
                if (confirmed != true) return;
              }
              await widget.repository.configurePhysical(widget.user, order.id,
                method: method, contactName: name.text, contactPhone: phone.text,
                address: address.text, instructions: instructions.text,
                deliveryFeeCents: cents);
              if (context.mounted) Navigator.pop(context);
              if (mounted) showAppFeedback(this.context, 'Handoff details saved');
              await refresh();
              if (mounted) detail(order);
            } catch (e) {
              if (context.mounted) {
                showAppFeedback(context, safeMessage(e));
              }
            }
          }, child: const Text('Save'))])));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose(); phone.dispose(); address.dispose(); instructions.dispose(); fee.dispose();
  }
  Future<void> _physicalAction(SalesOrder order, String next) async {
    DateTime? scheduledAt = order.scheduledAt;
    final recipient = TextEditingController();
    final notes = TextEditingController();
    final isSchedule = next == 'scheduled';
    final isCompletion = next == 'delivered' || next == 'picked_up';
    final isFailure = next == 'failed_delivery';
    final isCancel = next == 'cancelled';
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (dialogContext) =>
      StatefulBuilder(builder: (dialogContext, update) => AlertDialog(
        title: Text(_actionLabel(next, order.physicalStatus)),
        content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${order.reference} - ${order.customerNameSnapshot}',
            style: Theme.of(dialogContext).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(methodLabel(order.fulfillmentMethod)),
          if (order.contactNameSnapshot != null)
            Text('Contact: ${order.contactNameSnapshot}${order.contactPhoneSnapshot?.isNotEmpty == true ? ' - ${order.contactPhoneSnapshot}' : ''}'),
          if (order.fulfillmentMethod == 'delivery' &&
              order.deliveryAddressSnapshot?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text('Delivery address', style: Theme.of(dialogContext).textTheme.labelMedium),
            Text(order.deliveryAddressSnapshot!),
          ],
          if (order.fulfillmentInstructions?.isNotEmpty == true)
            Padding(padding: const EdgeInsets.only(top: 8),
              child: Text('Instructions: ${order.fulfillmentInstructions}')),
          if (order.scheduledAt != null && !isSchedule)
            Padding(padding: const EdgeInsets.only(top: 8),
              child: Text('Scheduled: ${orderSchedule(dialogContext, order.scheduledAt)}')),
          if (isSchedule) ...[
            const SizedBox(height: 12),
            const Text('Choose a date and time for this handoff.'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(scheduledAt == null ? 'Choose date' : orderDate(scheduledAt!)),
                onPressed: () async {
                  final picked = await showDatePicker(context: dialogContext,
                    initialDate: scheduledAt ?? DateTime.now(),
                    firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (picked == null || !dialogContext.mounted) return;
                  final previous = scheduledAt ?? DateTime.now();
                  update(() => scheduledAt = DateTime(picked.year, picked.month,
                    picked.day, previous.hour, previous.minute));
                }),
              OutlinedButton.icon(icon: const Icon(Icons.schedule, size: 18),
                label: Text(scheduledAt == null ? 'Choose time' :
                  TimeOfDay.fromDateTime(scheduledAt!).format(dialogContext)),
                onPressed: () async {
                  final picked = await showTimePicker(context: dialogContext,
                    initialTime: scheduledAt == null ? TimeOfDay.now() :
                      TimeOfDay.fromDateTime(scheduledAt!));
                  if (picked == null || !dialogContext.mounted) return;
                  final previous = scheduledAt ?? DateTime.now();
                  update(() => scheduledAt = DateTime(previous.year,
                    previous.month, previous.day, picked.hour, picked.minute));
                }),
            ]),
            if (order.fulfillmentMethod == 'delivery' &&
                order.deliveryFeeCents > 0)
              Padding(padding: const EdgeInsets.only(top: 8),
                child: Text('Delivery fee: ${formatPeso(order.deliveryFeeCents)}')),
            TextButton(onPressed: () {
              Navigator.pop(dialogContext);
              _configurePhysical(order);
            }, child: const Text('Edit contact and address')),
          ],
          if (next == 'ready')
            const Padding(padding: EdgeInsets.only(top: 12),
              child: Text('Mark this order ready for handoff?')),
          if (next == 'out_for_delivery')
            const Padding(padding: EdgeInsets.only(top: 12),
              child: Text('Record that this order has left for delivery.')),
          if (isCompletion) ...[
            const SizedBox(height: 12),
            TextField(controller: recipient, autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: next == 'delivered' ?
                'Recipient name *' : 'Released to *')),
          ],
          if (isFailure) ...[
            const SizedBox(height: 12),
            Text('Attempted: ${orderSchedule(dialogContext, DateTime.now())}'),
          ],
          if (isCancel)
            const Padding(padding: EdgeInsets.only(top: 12),
              child: Text('This handoff cannot be restarted after cancellation. Completed Sales remain unchanged.')),
          if (!isCancel) ...[
            const SizedBox(height: 12),
            TextField(controller: notes, maxLines: 2,
              decoration: InputDecoration(labelText: isFailure ?
                'Failure reason *' : 'Notes (optional)')),
          ],
        ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close')),
          FilledButton(onPressed: isSchedule && scheduledAt == null ? null : () async {
            try {
              await widget.repository.transitionPhysical(widget.user,
                order.id, next, scheduledAt: scheduledAt,
                recipientName: recipient.text, notes: notes.text);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) {
                showAppFeedback(context, switch (next) {
                'scheduled' => order.physicalStatus == 'pending' ?
                  'Handoff scheduled' : 'Schedule updated',
                'ready' => 'Order marked ready',
                'out_for_delivery' => 'Delivery started',
                'delivered' => 'Order delivered',
                'picked_up' => 'Pickup completed',
                'failed_delivery' => 'Failed delivery recorded',
                _ => 'Handoff cancelled',
                });
              }
              await refresh();
              if (mounted) detail(order);
            } catch (error) {
              if (dialogContext.mounted) {
                showAppFeedback(dialogContext, safeMessage(error));
              }
            }
          }, child: Text(_actionLabel(next, order.physicalStatus)))],
      )));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    recipient.dispose();
    notes.dispose();
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
                child: Text('On hand: ${Quantity.format(stock[productId]?.$1 ?? 0)}  -  Requested: ${qty.text}')),
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
  Widget _metric(String label, String key, IconData icon) => AppMetricTile(
    label: label, value: '${metrics[key] ?? 0}', icon: icon);

  Widget _orderFilters() => Wrap(spacing: 10, runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center, children: [
    SizedBox(width: 280, height: 48, child: TextField(
      decoration: const InputDecoration(prefixIcon: Icon(Icons.search),
        hintText: 'Reference or customer', isDense: true),
      onChanged: (value) {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 250), () {
          search = value; page = 0; refresh();
        });
      })),
    SizedBox(width: 140, child: DropdownButtonFormField<String>(
      key: ValueKey('order-status-$status'),
      isExpanded: true,
      initialValue: status, decoration: const InputDecoration(
        labelText: 'Order status', isDense: true),
      items: const [DropdownMenuItem(value: 'all', child: Text('All')),
        DropdownMenuItem(value: 'draft', child: Text('Draft')),
        DropdownMenuItem(value: 'confirmed', child: Text('Confirmed')),
        DropdownMenuItem(value: 'cancelled', child: Text('Cancelled'))],
      onChanged: (value) { if (value != null) {
        setState(() { status = value; page = 0; }); refresh();
      } })),
    SizedBox(width: 150, child: DropdownButtonFormField<String>(
      key: ValueKey('method-$methodFilter'),
      isExpanded: true,
      initialValue: methodFilter, decoration: const InputDecoration(
        labelText: 'Method', isDense: true),
      items: const [DropdownMenuItem(value: 'all', child: Text('All methods')),
        DropdownMenuItem(value: 'pickup', child: Text('Pickup')),
        DropdownMenuItem(value: 'delivery', child: Text('Delivery'))],
      onChanged: (value) { if (value != null) {
        setState(() { methodFilter = value; page = 0; }); refresh();
      } })),
    SizedBox(width: 185, child: DropdownButtonFormField<String>(
      key: ValueKey('physical-$orderPhysicalFilter'),
      isExpanded: true,
      initialValue: orderPhysicalFilter,
      decoration: const InputDecoration(labelText: 'Physical status', isDense: true),
      items: const [DropdownMenuItem(value: 'all', child: Text('All states')),
        DropdownMenuItem(value: 'pending', child: Text('Pending')),
        DropdownMenuItem(value: 'scheduled', child: Text('Scheduled')),
        DropdownMenuItem(value: 'ready', child: Text('Ready')),
        DropdownMenuItem(value: 'out_for_delivery', child: Text('Out for delivery')),
        DropdownMenuItem(value: 'failed_delivery', child: Text('Failed delivery')),
        DropdownMenuItem(value: 'delivered', child: Text('Delivered')),
        DropdownMenuItem(value: 'picked_up', child: Text('Picked up'))],
      onChanged: (value) { if (value != null) {
        setState(() { orderPhysicalFilter = value; page = 0; }); refresh();
      } })),
    OutlinedButton.icon(icon: const Icon(Icons.calendar_today_outlined, size: 18),
      label: Text(createdOn == null ? 'Created date' : orderDate(createdOn!)),
      onPressed: () async {
        final picked = await showDatePicker(context: context,
          initialDate: createdOn ?? DateTime.now(),
          firstDate: DateTime(2000), lastDate: DateTime(2100));
        if (picked == null || !mounted) return;
        setState(() { createdOn = picked; page = 0; }); refresh();
      }),
    if (createdOn != null) IconButton(
      tooltip: 'Clear date filter', icon: const Icon(Icons.close),
      onPressed: () { setState(() { createdOn = null; page = 0; }); refresh(); }),
  ]);

  Widget _queueFilters() => Wrap(spacing: 6, runSpacing: 2, children: [
    AppFilterChip(label: 'All Active', selected: physicalFilter == 'active' && queueMethodFilter == 'all',
      onSelected: () { setState(() { physicalFilter = 'active'; queueMethodFilter = 'all'; page = 0; }); refresh(); }),
    AppFilterChip(label: 'Today', selected: physicalFilter == 'today',
      onSelected: () { setState(() { physicalFilter = 'today'; page = 0; }); refresh(); }),
    AppFilterChip(label: 'Pickup', selected: queueMethodFilter == 'pickup',
      onSelected: () { setState(() { queueMethodFilter = queueMethodFilter == 'pickup' ? 'all' : 'pickup'; page = 0; }); refresh(); }),
    AppFilterChip(label: 'Delivery', selected: queueMethodFilter == 'delivery',
      onSelected: () { setState(() { queueMethodFilter = queueMethodFilter == 'delivery' ? 'all' : 'delivery'; page = 0; }); refresh(); }),
    AppFilterChip(label: 'Ready', selected: physicalFilter == 'ready',
      onSelected: () { setState(() { physicalFilter = 'ready'; page = 0; }); refresh(); }),
    AppFilterChip(label: 'Out for Delivery', selected: physicalFilter == 'out_for_delivery',
      onSelected: () { setState(() { physicalFilter = 'out_for_delivery'; page = 0; }); refresh(); }),
    AppFilterChip(label: 'Needs Attention', selected: physicalFilter == 'attention',
      onSelected: () { setState(() { physicalFilter = 'attention'; page = 0; }); refresh(); }),
  ]);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, bounds) =>
    AppWorkspacePadding(child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    AppPageHeader(title: 'Sales Orders',
      subtitle: 'Track customer orders, fulfillment, pickup, and delivery.',
      action: widget.user.can(PosPermission.manageSalesOrders)
        ? FilledButton.icon(onPressed: create, icon: const Icon(Icons.add),
            label: const Text('New Sales Order')) : null),
    AppWorkspaceTabs(labels: const ['Orders', 'Fulfillment Queue'],
      selectedIndex: queue ? 1 : 0,
      onSelected: (index) {
        if (queue == (index == 1)) return;
        setState(() { queue = index == 1; page = 0; }); refresh();
      }),
    const SizedBox(height: 8),
    if (bounds.maxHeight >= 720) AppMetricGrid(children: queue ? [
      _metric('Scheduled Today', 'today', Icons.today_outlined),
      _metric('Ready', 'ready', Icons.inventory_2_outlined),
      _metric('Out for Delivery', 'out_for_delivery', Icons.local_shipping_outlined),
      _metric('Needs Attention', 'attention', Icons.priority_high_outlined),
    ] : [
      _metric('Open Orders', 'open_orders', Icons.assignment_outlined),
      _metric('Partially Fulfilled', 'partial_orders', Icons.pie_chart_outline),
      _metric('Ready for Handoff', 'ready', Icons.inventory_2_outlined),
      _metric('Needs Attention', 'attention', Icons.priority_high_outlined),
    ]),
    const SizedBox(height: 12),
    queue ? _queueFilters() : _orderFilters(),
    const SizedBox(height: 12),
    Expanded(child: AppPagedListPanel(
      title: queue ? 'Fulfillment Queue' : 'Orders', total: total,
      count: orders.length, page: page, loading: loading, error: error,
      emptyTitle: queue ? 'Nothing needs fulfillment right now' : 'No sales orders yet',
      emptyMessage: queue ? 'Scheduled, ready, and delivery orders will appear here.' :
        'Create a Sales Order when a customer needs items prepared or fulfilled later.',
      onRetry: refresh,
      onPrevious: page > 0 ? () { page--; refresh(); } : null,
      onNext: (page + 1) * 50 < total ? () { page++; refresh(); } : null,
      itemBuilder: (context, index) {
        final order = orders[index];
        return SalesOrderListRow(order: order, queue: queue,
          inventoryState: fulfillmentStates[order.id] ?? 'Unfulfilled',
          onOpen: () => detail(order));
      },
    )),
  ])));
}
