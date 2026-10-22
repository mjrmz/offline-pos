import 'package:drift/drift.dart';

import '../database.dart';

class SupplierCostChange {
  final String productId;
  final String productName;
  final int lastCostCents;
  final int previousCostCents;
  final DateTime lastReceivedAt;
  const SupplierCostChange(this.productId, this.productName, this.lastCostCents,
      this.previousCostCents, this.lastReceivedAt);
}

class SupplierProcurementSummary {
  final int openOrders;
  final int incomingQuantityMilli;
  final int incomingValueCents;
  final PurchaseOrder? lastOrder;
  final StockReceiving? lastReceiving;
  final List<int> firstDeliveryDays;
  final List<int> completionDays;
  final int onTimeCount;
  final int expectedDateSamples;
  final int deliveredOrders;
  final int partialDeliveries;
  final int completedOrders;
  final List<SupplierCostChange> costChanges;
  const SupplierProcurementSummary(
      this.openOrders,
      this.incomingQuantityMilli,
      this.incomingValueCents,
      this.lastOrder,
      this.lastReceiving,
      this.firstDeliveryDays,
      this.completionDays,
      this.onTimeCount,
      this.expectedDateSamples,
      this.deliveredOrders,
      this.partialDeliveries,
      this.completedOrders,
      this.costChanges);

  double? get averageFirstDeliveryDays => firstDeliveryDays.length < 2
      ? null
      : firstDeliveryDays.reduce((a, b) => a + b) / firstDeliveryDays.length;
  double? get averageCompletionDays => completionDays.length < 2
      ? null
      : completionDays.reduce((a, b) => a + b) / completionDays.length;
  double? get onTimeRate =>
      expectedDateSamples < 2 ? null : onTimeCount * 100 / expectedDateSamples;
  double? get partialDeliveryRate =>
      deliveredOrders < 2 ? null : partialDeliveries * 100 / deliveredOrders;
}

class SupplierProcurementRepository {
  final AppDatabase db;
  const SupplierProcurementRepository(this.db);

  static int calendarDays(DateTime start, DateTime end) =>
      DateTime.utc(end.year, end.month, end.day)
          .difference(DateTime.utc(start.year, start.month, start.day))
          .inDays;

  static String deliveryPerformance(DateTime expected, DateTime delivered) {
    final days = calendarDays(expected, delivered);
    if (days < 0) return 'Early';
    if (days > 0) return 'Late';
    return 'On time';
  }

  Future<SupplierProcurementSummary> summary(String supplierId) async {
    final lastOrder = await (db.select(db.purchaseOrders)
          ..where((o) => o.supplierId.equals(supplierId))
          ..orderBy([
            (o) => OrderingTerm(expression: o.sequence, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
    final lastReceiving = await (db.select(db.stockReceivings)
          ..where((r) => r.supplierId.equals(supplierId))
          ..orderBy([
            (r) =>
                OrderingTerm(expression: r.receivedAt, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
    final orders = await db.customSelect('''
      WITH received_lines AS (
        SELECT purchase_order_line_id AS line_id,
          SUM(quantity_milli) AS received_qty
        FROM stock_receiving_items WHERE purchase_order_line_id IS NOT NULL
        GROUP BY purchase_order_line_id
      ), quantities AS (
        SELECT pl.purchase_order_id,
          SUM(COALESCE(rl.received_qty,0)) AS received_qty,
          SUM(MAX(pl.ordered_qty_milli - pl.cancelled_qty_milli
              - COALESCE(rl.received_qty,0),0)) AS remaining_qty,
          CAST(SUM(MAX(pl.ordered_qty_milli - pl.cancelled_qty_milli
              - COALESCE(rl.received_qty,0),0)
              * pl.expected_unit_cost_cents / 1000) AS INTEGER) AS remaining_value
        FROM purchase_order_lines pl
        LEFT JOIN received_lines rl ON rl.line_id=pl.id
        GROUP BY pl.purchase_order_id
      ), deliveries AS (
        SELECT purchase_order_id, COUNT(*) AS deliveries,
          MIN(received_at) AS first_at, MAX(received_at) AS last_at
        FROM stock_receivings WHERE purchase_order_id IS NOT NULL
        GROUP BY purchase_order_id
      )
      SELECT po.status, po.sent_at, po.expected_delivery_date,
        COALESCE(q.received_qty,0) AS received_qty,
        COALESCE(q.remaining_qty,0) AS remaining_qty,
        COALESCE(q.remaining_value,0) AS remaining_value,
        COALESCE(d.deliveries,0) AS deliveries, d.first_at, d.last_at
      FROM purchase_orders po
      LEFT JOIN quantities q ON q.purchase_order_id=po.id
      LEFT JOIN deliveries d ON d.purchase_order_id=po.id
      WHERE po.supplier_id=? ORDER BY po.sequence DESC
    ''', variables: [Variable.withString(supplierId)]).get();
    var open = 0;
    var incomingQuantityMilli = 0;
    var incomingValueCents = 0;
    final firstDays = <int>[];
    final completionDays = <int>[];
    var onTime = 0;
    var expectedSamples = 0;
    var deliveredOrders = 0;
    var partialDeliveries = 0;
    var completedOrders = 0;
    DateTime fromSeconds(int value) =>
        DateTime.fromMillisecondsSinceEpoch(value * 1000);
    for (final row in orders) {
      final stored = row.read<String>('status');
      final received = row.read<int>('received_qty');
      final remaining = row.read<int>('remaining_qty');
      final deliveries = row.read<int>('deliveries');
      final status = {'draft', 'cancelled', 'closed'}.contains(stored)
          ? stored
          : received == 0
              ? 'sent'
              : remaining == 0
                  ? 'fully_received'
                  : 'partially_received';
      if (deliveries > 0) {
        deliveredOrders++;
        if (deliveries > 1 || status == 'partially_received') {
          partialDeliveries++;
        }
      }
      if ({'fully_received', 'closed'}.contains(status)) completedOrders++;
      if ({'sent', 'partially_received'}.contains(status) && remaining > 0) {
        open++;
        incomingQuantityMilli += remaining;
        incomingValueCents += row.read<int>('remaining_value');
      }
      final sentRaw = row.read<int?>('sent_at');
      final firstRaw = row.read<int?>('first_at');
      if (sentRaw == null || firstRaw == null) continue;
      final sent = fromSeconds(sentRaw);
      final first = fromSeconds(firstRaw);
      final elapsed = calendarDays(sent, first);
      if (elapsed < 0) continue;
      firstDays.add(elapsed);
      final expectedRaw = row.read<int?>('expected_delivery_date');
      if (expectedRaw != null) {
        expectedSamples++;
        if (calendarDays(fromSeconds(expectedRaw), first) <= 0) onTime++;
      }
      if ({'fully_received', 'closed'}.contains(status)) {
        final last = row.read<int?>('last_at');
        if (last != null) {
          final days = calendarDays(sent, fromSeconds(last));
          if (days >= 0) completionDays.add(days);
        }
      }
    }
    final costs = await db.customSelect('''
      WITH ranked AS (
        SELECT i.product_id, p.name AS product_name,
          i.unit_cost_cents, r.received_at,
          ROW_NUMBER() OVER (
            PARTITION BY i.product_id
            ORDER BY r.received_at DESC, r.sequence DESC, i.id DESC
          ) AS position
        FROM stock_receiving_items i
        JOIN stock_receivings r ON r.id=i.receiving_id
        JOIN products p ON p.id=i.product_id
        WHERE r.supplier_id=? AND r.finalized_at IS NOT NULL
      )
      SELECT * FROM ranked WHERE position<=2 ORDER BY product_name, position
    ''', variables: [Variable.withString(supplierId)]).get();
    final recent = <String, List<(int, DateTime)>>{};
    final names = <String, String>{};
    for (final row in costs) {
      final id = row.read<String>('product_id');
      names[id] = row.read<String>('product_name');
      recent.putIfAbsent(id, () => []).add((
        row.read<int>('unit_cost_cents'),
        fromSeconds(row.read<int>('received_at')),
      ));
    }
    final changes = <SupplierCostChange>[
      for (final entry in recent.entries)
        if (entry.value.length >= 2)
          SupplierCostChange(entry.key, names[entry.key] ?? 'Product',
              entry.value[0].$1, entry.value[1].$1, entry.value[0].$2)
    ];
    return SupplierProcurementSummary(
        open,
        incomingQuantityMilli,
        incomingValueCents,
        lastOrder,
        lastReceiving,
        firstDays,
        completionDays,
        onTime,
        expectedSamples,
        deliveredOrders,
        partialDeliveries,
        completedOrders,
        changes);
  }
}
