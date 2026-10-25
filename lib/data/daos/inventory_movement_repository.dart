import 'package:drift/drift.dart';

import '../database.dart';
import 'paged_result.dart';

class InventoryMovementRepository {
  const InventoryMovementRepository(this.db);
  final AppDatabase db;

  static const _reasons = <String, List<String>>{
    'Receiving': ['supplier_receiving', 'batch_received', 'receiving'],
    'Purchase Return': ['purchase_return'],
    'Sale': ['sale'],
    'Opening Inventory': ['initial_stock', 'opening_inventory_import'],
    'Return / Refund': ['refund', 'item_refund', 'void'],
    'Adjustment': [
      'adjustment',
      'stock_adjustment_increase',
      'stock_adjustment_decrease',
      'stock_count_variance',
    ],
    'RMA': ['inbound_rma', 'rma_replacement', 'rma_restock'],
  };

  Future<PagedResult<InventoryMovement>> page({
    int page = 0,
    String search = '',
    String type = 'All',
    String? productId,
    DateTime? from,
    DateTime? through,
  }) async {
    if (page < 0) throw ArgumentError.value(page, 'page');
    final conditions = <String>[];
    final variables = <Variable>[];
    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      conditions.add('''(
        instr(lower(p.name), ?) > 0 OR instr(lower(COALESCE(p.sku, '')), ?) > 0
        OR instr(lower(COALESCE(p.barcode, '')), ?) > 0
        OR instr(lower(COALESCE(m.reference_id, '')), ?) > 0
        OR EXISTS (SELECT 1 FROM sales s WHERE s.id = m.reference_id
          AND (instr(lower(COALESCE(s.receipt_number, '')), ?) > 0
            OR instr(lower(COALESCE(s.bir_invoice_number, '')), ?) > 0))
        OR EXISTS (SELECT 1 FROM stock_receivings r WHERE r.id = m.reference_id
          AND instr(lower(COALESCE(r.external_reference, '')), ?) > 0)
        OR EXISTS (SELECT 1 FROM inventory_adjustments a
          WHERE a.id = m.reference_id AND instr(lower(a.reference), ?) > 0)
        OR EXISTS (SELECT 1 FROM purchase_returns pr
          WHERE pr.id = m.reference_id AND instr(lower(printf('PRT-%06d', pr.sequence)), ?) > 0)
        OR (m.reason = 'opening_inventory_import' AND instr('opening inventory', ?) > 0)
      )''');
      variables.addAll(List.generate(10, (_) => Variable.withString(term)));
    }
    if (productId != null) {
      conditions.add('m.product_id = ?');
      variables.add(Variable.withString(productId));
    }
    if (type != 'All') {
      final reasons = _reasons[type];
      if (reasons == null) throw ArgumentError.value(type, 'type');
      conditions
          .add('m.reason IN (${List.filled(reasons.length, '?').join(',')})');
      variables.addAll(reasons.map(Variable.withString));
    }
    if (from != null) {
      conditions.add('m.created_at >= ?');
      variables.add(Variable.withInt(
          DateTime(from.year, from.month, from.day).millisecondsSinceEpoch ~/
              1000));
    }
    if (through != null) {
      conditions.add('m.created_at < ?');
      variables.add(Variable.withInt(
          DateTime(through.year, through.month, through.day + 1)
                  .millisecondsSinceEpoch ~/
              1000));
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    const joins =
        'FROM inventory_movements m JOIN products p ON p.id = m.product_id';
    return db.transaction(() async {
      final total = (await db
              .customSelect(
                'SELECT COUNT(*) AS total $joins $where',
                variables: variables,
              )
              .getSingle())
          .read<int>('total');
      final ids = (await db.customSelect(
        'SELECT m.id $joins $where ORDER BY m.created_at DESC, m.id DESC LIMIT 50 OFFSET ?',
        variables: [...variables, Variable.withInt(page * 50)],
      ).get())
          .map((row) => row.read<String>('id'))
          .toList();
      if (ids.isEmpty) {
        return PagedResult(
            items: <InventoryMovement>[], totalCount: total, page: page);
      }
      final rows = await (db.select(db.inventoryMovements)
            ..where((movement) => movement.id.isIn(ids)))
          .get();
      final byId = {for (final row in rows) row.id: row};
      return PagedResult(
        items: [for (final id in ids) byId[id]!],
        totalCount: total,
        page: page,
      );
    });
  }
}
