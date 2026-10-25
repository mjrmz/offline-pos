import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../shared/widgets/record_details_drawer.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String orderDate(DateTime date) {
  final local = date.toLocal();
  return '${_months[local.month - 1]} ${local.day}, ${local.year}';
}

String orderSchedule(BuildContext context, DateTime? date) {
  if (date == null) return 'Not scheduled';
  final local = date.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final label = day == today ? 'Today' :
    day == today.add(const Duration(days: 1)) ? 'Tomorrow' :
    '${_months[local.month - 1]} ${local.day}';
  return '$label • ${TimeOfDay.fromDateTime(local).format(context)}';
}

String physicalLabel(String status) => switch (status) {
  'out_for_delivery' => 'Out for delivery',
  'failed_delivery' => 'Failed delivery',
  'picked_up' => 'Picked up',
  'delivered' => 'Delivered',
  'scheduled' => 'Scheduled',
  'ready' => 'Ready',
  'cancelled' => 'Cancelled',
  _ => 'Pending',
};

String methodLabel(String? method) => switch (method) {
  'pickup' => 'Pickup', 'delivery' => 'Delivery', _ => 'Not configured',
};

AppStatusTone physicalTone(String status) => switch (status) {
  'ready' || 'delivered' || 'picked_up' => AppStatusTone.success,
  'scheduled' => AppStatusTone.info,
  'out_for_delivery' => AppStatusTone.active,
  'failed_delivery' => AppStatusTone.warning,
  'cancelled' => AppStatusTone.danger,
  _ => AppStatusTone.neutral,
};

class OrderStateBadge extends StatelessWidget {
  const OrderStateBadge({super.key, required this.label, required this.tone});
  final String label;
  final AppStatusTone tone;
  @override
  Widget build(BuildContext context) => AppStatusBadge(
    label: label, color: appStatusColor(context, tone));
}

class SalesOrderListRow extends StatelessWidget {
  const SalesOrderListRow({super.key, required this.order,
    required this.inventoryState, required this.queue, required this.onOpen});
  final SalesOrder order;
  final String inventoryState;
  final bool queue;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final needsAttention = order.physicalStatus == 'failed_delivery' ||
      (order.scheduledAt?.isBefore(DateTime.now()) == true &&
        !{'delivered','picked_up','cancelled'}.contains(order.physicalStatus));
    final name = Column(crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min, children: [
      Text(order.reference, style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(fontWeight: FontWeight.w700)),
      Text(order.customerNameSnapshot, maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: scheme.onSurfaceVariant)),
      if (queue && order.contactPhoneSnapshot?.isNotEmpty == true)
        Text(order.contactPhoneSnapshot!, maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall),
    ]);
    final states = Wrap(spacing: 6, runSpacing: 4, children: [
      OrderStateBadge(label: 'Inventory: $inventoryState', tone: switch (inventoryState) {
        'Fulfilled' => AppStatusTone.success,
        'Partially fulfilled' => AppStatusTone.warning,
        _ => AppStatusTone.neutral,
      }),
      OrderStateBadge(label: '${methodLabel(order.fulfillmentMethod)}: ${physicalLabel(order.physicalStatus)}',
        tone: physicalTone(order.physicalStatus)),
      if (needsAttention && order.physicalStatus != 'failed_delivery')
        const OrderStateBadge(label: 'Needs attention', tone: AppStatusTone.warning),
    ]);
    final schedule = Text(orderSchedule(context, order.scheduledAt),
      maxLines: 1, overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: needsAttention ? appStatusColor(context, AppStatusTone.warning)
          : scheme.onSurfaceVariant));
    return Column(children: [
      Material(color: Colors.transparent, child: InkWell(
        onTap: onOpen,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: LayoutBuilder(builder: (context, bounds) {
            if (bounds.maxWidth < 760) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Expanded(child: name),
                  Text(formatPeso(order.totalCents + order.deliveryFeeCents),
                    style: const TextStyle(fontWeight: FontWeight.w600))]),
                const SizedBox(height: 7), states,
                const SizedBox(height: 4), schedule,
              ]);
            }
            return Row(children: [
              Expanded(flex: 3, child: name),
              const SizedBox(width: 12),
              Expanded(flex: 5, child: states),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: schedule),
              const SizedBox(width: 12),
              SizedBox(width: 110, child: Text(
                formatPeso(order.totalCents + order.deliveryFeeCents),
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w600))),
              if (queue) const Padding(padding: EdgeInsets.only(left: 10),
                child: Icon(Icons.chevron_right, size: 18)),
            ]);
          })))),
      Divider(height: 1, color: scheme.outlineVariant),
    ]);
  }
}

class SalesOrderDetailView extends StatelessWidget {
  const SalesOrderDetailView({super.key, required this.order,
    required this.lines, required this.fulfilledByLine,
    required this.reservedByLine, required this.reservations,
    required this.fulfillmentSales, required this.physicalEvents,
    required this.actorNames, required this.user, required this.physicalActions,
    required this.onPhysicalAction, required this.onConfigure,
    required this.onReserve, required this.onRelease,
    required this.onFulfill, required this.onEditDraft,
    required this.onConfirm, required this.onCancelOrder});

  final SalesOrder order;
  final List<SalesOrderLine> lines;
  final Map<String, int> fulfilledByLine;
  final Map<String, int> reservedByLine;
  final List<StockReservation> reservations;
  final List<Sale> fulfillmentSales;
  final List<SalesOrderPhysicalEvent> physicalEvents;
  final Map<String, String> actorNames;
  final ActiveUser user;
  final List<String> physicalActions;
  final ValueChanged<String> onPhysicalAction;
  final VoidCallback onConfigure;
  final ValueChanged<SalesOrderLine> onReserve;
  final ValueChanged<StockReservation> onRelease;
  final VoidCallback? onFulfill;
  final VoidCallback onEditDraft;
  final VoidCallback onConfirm;
  final VoidCallback onCancelOrder;

  bool get complete => lines.isNotEmpty &&
    lines.every((line) => (fulfilledByLine[line.id] ?? 0) >= line.quantityMilli);
  bool get partial => fulfilledByLine.values.any((quantity) => quantity > 0);
  String get inventoryState => complete ? 'Fulfilled' :
      partial ? 'Partially fulfilled' : 'Unfulfilled';
  int get remainingMilli => lines.fold(0, (sum, line) =>
    sum + line.quantityMilli - (fulfilledByLine[line.id] ?? 0));
  String? get primaryPhysical => physicalActions.where((action) =>
      action != 'cancelled' &&
      !(action == 'scheduled' && order.physicalStatus == 'scheduled'))
    .firstOrNull;
  String _actionLabel(String action) => switch (action) {
    'scheduled' => order.physicalStatus == 'pending' ? 'Schedule' : 'Reschedule',
    'ready' => 'Mark Ready',
    'out_for_delivery' => 'Mark Out for Delivery',
    'delivered' => 'Mark Delivered',
    'picked_up' => 'Mark Picked Up',
    'failed_delivery' => 'Record Failed Delivery',
    'cancelled' => 'Cancel handoff',
    _ => action,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canManage = user.can(PosPermission.manageSalesOrders);
    final primary = canManage ? primaryPhysical : null;
    final readyBlocked = primary == 'ready' && !complete;
    final feeSale = fulfillmentSales.where((sale) => sale.status != 'voided' &&
      sale.deliveryFeeCents > 0).firstOrNull;
    return RecordDetailsDrawer(
      width: 800,
      title: Text(order.reference),
      subtitle: Text(order.customerNameSnapshot),
      badges: [
        OrderStateBadge(label: 'Order: ${order.status[0].toUpperCase()}${order.status.substring(1)}',
          tone: order.status == 'cancelled' ? AppStatusTone.danger : AppStatusTone.neutral),
        OrderStateBadge(label: 'Inventory: $inventoryState',
          tone: complete ? AppStatusTone.success : partial ? AppStatusTone.warning : AppStatusTone.neutral),
        OrderStateBadge(label: '${methodLabel(order.fulfillmentMethod)}: ${physicalLabel(order.physicalStatus)}',
          tone: physicalTone(order.physicalStatus)),
      ],
      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DrawerSection(title: 'Order summary', child: Column(children: [
          DrawerLabelValue(label: 'Customer', value: order.customerNameSnapshot),
          DrawerLabelValue(label: 'Created', value: orderDate(order.createdAt)),
          if (order.requestedDate != null)
            DrawerLabelValue(label: 'Requested', value: orderDate(order.requestedDate!)),
          DrawerLabelValue(label: 'Method', value: methodLabel(order.fulfillmentMethod)),
          if (order.sourceQuotationId != null)
            const DrawerLabelValue(label: 'Source', value: 'Quotation'),
          if (order.notes?.isNotEmpty == true)
            DrawerLabelValue(label: 'Notes', value: order.notes!),
          const Divider(height: 16),
          DrawerLabelValue(label: 'Items subtotal', value: formatPeso(order.subtotalCents)),
          if (order.discountCents > 0)
            DrawerLabelValue(label: 'Item discounts', value: '-${formatPeso(order.discountCents)}'),
          if (order.deliveryFeeCents > 0)
            DrawerLabelValue(label: 'Delivery fee', value: formatPeso(order.deliveryFeeCents)),
          DrawerLabelValue(label: 'Order total',
            value: formatPeso(order.totalCents + order.deliveryFeeCents)),
        ])),
        DrawerSection(title: 'Items', child: Column(children: [
          for (final line in lines) ...[
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text(line.descriptionSnapshot,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                Text(formatPeso(line.lineTotalCents))]),
              const SizedBox(height: 4),
              Text('${line.skuSnapshot ?? ''} • ${line.unitSnapshot} • ${formatPeso(line.unitPriceCents)} each',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 5),
              Wrap(spacing: 16, runSpacing: 4, children: [
                Text('Ordered ${Quantity.format(line.quantityMilli)}'),
                Text('Fulfilled ${Quantity.format(fulfilledByLine[line.id] ?? 0)}'),
                Text('Reserved ${Quantity.format(reservedByLine[line.id] ?? 0)}'),
                Text('Remaining ${Quantity.format(line.quantityMilli - (fulfilledByLine[line.id] ?? 0))}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
              if (order.status == 'confirmed' && line.productId != null &&
                  line.quantityMilli > (reservedByLine[line.id] ?? 0) +
                    (fulfilledByLine[line.id] ?? 0) &&
                  user.can(PosPermission.manageStockReservations))
                Align(alignment: Alignment.centerRight, child: TextButton(
                  onPressed: () => onReserve(line), child: const Text('Reserve stock'))),
              for (final reservation in reservations.where((r) =>
                  r.salesOrderLineId == line.id && r.status == 'active'))
                Row(children: [Expanded(child: Text('${reservation.reference} • ${Quantity.format(reservation.quantityMilli)} reserved')),
                  if (user.can(PosPermission.manageStockReservations))
                    TextButton(onPressed: () => onRelease(reservation),
                      child: const Text('Release reservation'))]),
            ])),
            Divider(height: 1, color: scheme.outlineVariant),
          ],
        ])),
        DrawerSection(title: 'Inventory fulfillment', child: Column(children: [
          DrawerLabelValue(label: 'State', value: inventoryState),
          DrawerLabelValue(label: 'Remaining quantity', value: Quantity.format(remainingMilli)),
          if (!complete && order.status == 'confirmed' && onFulfill != null)
            Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
              onPressed: onFulfill, icon: const Icon(Icons.point_of_sale),
              label: const Text('Fulfill Order'))),
        ])),
        DrawerSection(title: 'Delivery / Pickup', child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          DrawerLabelValue(label: 'Method', value: methodLabel(order.fulfillmentMethod)),
          DrawerLabelValue(label: 'Physical status', value: physicalLabel(order.physicalStatus)),
          DrawerLabelValue(label: 'Scheduled', value: orderSchedule(context, order.scheduledAt)),
          if (order.contactNameSnapshot != null)
            DrawerLabelValue(label: 'Contact', value: order.contactNameSnapshot!),
          if (order.contactPhoneSnapshot?.isNotEmpty == true)
            DrawerLabelValue(label: 'Phone', value: order.contactPhoneSnapshot!),
          if (order.deliveryAddressSnapshot?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text('Delivery address', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(order.deliveryAddressSnapshot!,
              style: Theme.of(context).textTheme.bodyMedium),
          ],
          if (order.fulfillmentInstructions?.isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text('Instructions', style: Theme.of(context).textTheme.labelMedium),
            Text(order.fulfillmentInstructions!),
          ],
          if (order.deliveryFeeCents > 0) ...[
            const SizedBox(height: 8),
            DrawerLabelValue(label: 'Delivery fee', value: formatPeso(order.deliveryFeeCents)),
            Text(feeSale == null ? 'Pending final fulfillment Sale' :
              'Charged on ${feeSale.receiptNumber ?? 'Sale'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
          if (order.physicalCompletedAt != null) ...[
            const SizedBox(height: 8),
            DrawerLabelValue(label: 'Completed', value: orderSchedule(context, order.physicalCompletedAt)),
            if (order.recipientName != null)
              DrawerLabelValue(label: order.fulfillmentMethod == 'pickup' ? 'Released to' : 'Recipient',
                value: order.recipientName!),
          ],
          if (readyBlocked)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(
              'Complete inventory fulfillment before marking this order ready.',
              style: TextStyle(color: scheme.onSurfaceVariant))),
        ])),
        if (fulfillmentSales.isNotEmpty)
          DrawerSection(title: 'Sales fulfillment', child: Column(children: [
            for (final sale in fulfillmentSales)
              ListTile(dense: true, contentPadding: EdgeInsets.zero,
                title: Text(sale.receiptNumber ?? 'Sale'),
                subtitle: Text(orderDate(sale.createdAt)),
                trailing: Text(formatPeso(sale.totalCents))),
          ])),
        if (physicalEvents.isNotEmpty)
          DrawerSection(title: '${methodLabel(order.fulfillmentMethod)} activity',
            child: Column(children: [
              for (final event in physicalEvents.reversed)
                ListTile(dense: true, contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle, size: 8, color: scheme.primary),
                  title: Text(physicalLabel(event.newStatus)),
                  subtitle: Text('${orderSchedule(context, event.occurredAt)} • ${actorNames[event.actorId] ?? 'Staff'}${event.notes?.isNotEmpty == true ? '\n${event.notes}' : ''}')),
            ])),
      ]),
      primaryAction: primary == null ?
        (order.status == 'draft' && canManage ? FilledButton(
          onPressed: onConfirm, child: const Text('Confirm order')) : null) :
        FilledButton(onPressed: readyBlocked ? null : () => onPhysicalAction(primary),
          child: Text(_actionLabel(primary))),
      secondaryActions: [
        if (canManage && order.status != 'cancelled' &&
            {'pending','scheduled','failed_delivery'}.contains(order.physicalStatus))
          OutlinedButton(onPressed: onConfigure,
            child: const Text('Edit contact and method')),
        if (order.status == 'draft' && canManage &&
            lines.every((line) => line.productId != null))
          OutlinedButton(onPressed: onEditDraft, child: const Text('Edit draft')),
        if (canManage && order.status != 'cancelled' && physicalActions.contains('scheduled') &&
            primary != 'scheduled')
          OutlinedButton(onPressed: () => onPhysicalAction('scheduled'),
            child: const Text('Reschedule')),
        if (canManage && physicalActions.contains('failed_delivery'))
          OutlinedButton(onPressed: () => onPhysicalAction('failed_delivery'),
            child: const Text('Record Failed Delivery')),
      ],
      tertiaryAction: canManage && (order.status == 'confirmed' ||
          physicalActions.contains('cancelled')) ? PopupMenuButton<String>(
        tooltip: 'More order actions',
        onSelected: (value) => value == 'order'
            ? onCancelOrder() : onPhysicalAction('cancelled'),
        itemBuilder: (_) => [
          if (physicalActions.contains('cancelled'))
            const PopupMenuItem(value: 'physical', child: Text('Cancel handoff')),
          if (order.status == 'confirmed')
            const PopupMenuItem(value: 'order', child: Text('Cancel order')),
        ],
        child: const Padding(padding: EdgeInsets.all(8), child: Text('More actions')),
      ) : null,
    );
  }
}
