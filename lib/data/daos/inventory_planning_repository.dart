import 'package:drift/drift.dart';

import '../database.dart';

/// Quantities are fixed point (1000 per whole unit); money is integer cents.
class InventoryPlanningRow {
  final String productId;
  final int availableMilli;
  final int incomingMilli;
  final int? reorderLevelMilli;
  final int? targetStockMilli;
  final String? preferredSupplierId;
  final int costValueCents;
  final DateTime? oldestStockAt;
  final int? lastPurchaseCostCents;
  final int? previousPurchaseCostCents;
  final DateTime? lastReceivedAt;
  final String? lastSupplierId;

  const InventoryPlanningRow(
      {required this.productId,
      required this.availableMilli,
      required this.incomingMilli,
      required this.reorderLevelMilli,
      required this.targetStockMilli,
      required this.preferredSupplierId,
      required this.costValueCents,
      required this.oldestStockAt,
      required this.lastPurchaseCostCents,
      required this.previousPurchaseCostCents,
      required this.lastReceivedAt,
      required this.lastSupplierId});

  int get projectedMilli => availableMilli + incomingMilli;
  int get suggestedReorderMilli => targetStockMilli == null
      ? 0
      : (targetStockMilli! - projectedMilli).clamp(0, 0x7fffffffffffffff);
  bool get belowReorderLevel =>
      reorderLevelMilli != null && availableMilli <= reorderLevelMilli!;
  bool get incomingCoversShortage =>
      belowReorderLevel && projectedMilli > reorderLevelMilli!;
}

class InventoryPlanningRepository {
  final AppDatabase db;
  const InventoryPlanningRepository(this.db);

  /// One batched read. Only sent/open PO remainders count as incoming.
  Future<Map<String, InventoryPlanningRow>> load() async {
    final rows = await db.customSelect('''
      WITH received AS (
        SELECT purchase_order_line_id AS line_id, SUM(quantity_milli) AS qty
        FROM stock_receiving_items WHERE purchase_order_line_id IS NOT NULL
        GROUP BY purchase_order_line_id
      ), incoming AS (
        SELECT l.product_id, SUM(MAX(0, l.ordered_qty_milli -
          l.cancelled_qty_milli - COALESCE(r.qty, 0))) AS qty
        FROM purchase_order_lines l
        JOIN purchase_orders o ON o.id = l.purchase_order_id
        LEFT JOIN received r ON r.line_id = l.id
        WHERE o.status = 'sent'
        GROUP BY l.product_id
      ), layers AS (
        SELECT product_id, SUM((quantity_remaining_milli * unit_cost_cents + 500) / 1000) AS value_cents,
          MIN(received_at) AS oldest_at
        FROM inventory_layers WHERE quantity_remaining_milli > 0
        GROUP BY product_id
      ), reserved AS (
        SELECT li.product_id, SUM(li.quantity_milli) AS qty
        FROM layaway_items li JOIN layaways la ON la.id = li.layaway_id
        WHERE la.status = 'active' GROUP BY li.product_id
      ), rma_reserved AS (
        SELECT product_id, COUNT(*) * 1000 AS qty FROM serial_units
        WHERE status = 'rma_reserved' GROUP BY product_id
      ), order_reserved AS (
        SELECT product_id, SUM(quantity_milli) AS qty
        FROM stock_reservations WHERE status = 'active'
        GROUP BY product_id
      ), costs AS (
        SELECT i.product_id, i.unit_cost_cents, r.received_at,
          r.supplier_id, ROW_NUMBER() OVER (
          PARTITION BY i.product_id ORDER BY r.received_at DESC, i.id DESC) AS rank
        FROM stock_receiving_items i
        JOIN stock_receivings r ON r.id = i.receiving_id
      )
      SELECT p.id, p.reorder_level_qty_milli, p.target_stock_qty_milli,
        p.preferred_supplier_id,
        COALESCE(v.quantity_milli, 0) - COALESCE(reserved.qty, 0)
          - COALESCE(rma_reserved.qty, 0)
          - COALESCE(order_reserved.qty, 0) AS available_milli,
        COALESCE(inc.qty, 0) AS incoming_milli,
        COALESCE(layers.value_cents, 0) AS cost_value_cents,
        layers.oldest_at, latest.unit_cost_cents AS last_cost,
        previous.unit_cost_cents AS previous_cost,
        latest.received_at AS last_received_at,
        latest.supplier_id AS last_supplier_id
      FROM products p LEFT JOIN inventory v ON v.product_id = p.id
      LEFT JOIN reserved ON reserved.product_id = p.id
      LEFT JOIN rma_reserved ON rma_reserved.product_id = p.id
      LEFT JOIN order_reserved ON order_reserved.product_id = p.id
      LEFT JOIN incoming inc ON inc.product_id = p.id
      LEFT JOIN layers ON layers.product_id = p.id
      LEFT JOIN costs latest ON latest.product_id = p.id AND latest.rank = 1
      LEFT JOIN costs previous ON previous.product_id = p.id AND previous.rank = 2
    ''').get();
    return {
      for (final row in rows)
        row.read<String>('id'): InventoryPlanningRow(
          productId: row.read<String>('id'),
          availableMilli: row.read<int>('available_milli'),
          incomingMilli: row.read<int>('incoming_milli'),
          reorderLevelMilli: row.readNullable<int>('reorder_level_qty_milli'),
          targetStockMilli: row.readNullable<int>('target_stock_qty_milli'),
          preferredSupplierId:
              row.readNullable<String>('preferred_supplier_id'),
          costValueCents: row.read<int>('cost_value_cents'),
          oldestStockAt: _date(row.readNullable<int>('oldest_at')),
          lastPurchaseCostCents: row.readNullable<int>('last_cost'),
          previousPurchaseCostCents: row.readNullable<int>('previous_cost'),
          lastReceivedAt: _date(row.readNullable<int>('last_received_at')),
          lastSupplierId: row.readNullable<String>('last_supplier_id'),
        ),
    };
  }

  Future<void> saveSettings(String productId,
      {int? reorderLevelMilli,
      int? targetStockMilli,
      String? preferredSupplierId}) async {
    if (reorderLevelMilli != null && reorderLevelMilli < 0 ||
        targetStockMilli != null && targetStockMilli < 0 ||
        reorderLevelMilli != null &&
            targetStockMilli != null &&
            targetStockMilli < reorderLevelMilli) {
      throw ArgumentError('Target and reorder levels must be valid');
    }
    await (db.update(db.products)..where((p) => p.id.equals(productId)))
        .write(ProductsCompanion(
      reorderLevelQtyMilli: Value(reorderLevelMilli),
      targetStockQtyMilli: Value(targetStockMilli),
      preferredSupplierId: Value(preferredSupplierId),
    ));
  }

  static DateTime? _date(int? seconds) => seconds == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}
