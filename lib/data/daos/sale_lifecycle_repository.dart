import 'package:drift/drift.dart' show Variable;

import '../database.dart';
import 'sale_return_repository.dart';

/// Read-only commercial view. The original sale total is never changed.
class SaleLifecycleSummary {
  final int returnedCents;
  final int itemRefundCents;
  final int returnCount;
  final int exchangeCount;
  final int activeRmaCount;
  const SaleLifecycleSummary(this.returnedCents, this.itemRefundCents,
      this.returnCount, this.exchangeCount, this.activeRmaCount);

  int netRetained(int grossCents) =>
      (grossCents - returnedCents - itemRefundCents).clamp(0, grossCents);

  String status(String saleStatus, int grossCents) {
    if (saleStatus == 'voided') return 'Voided';
    if (saleStatus == 'refunded') return 'Refunded';
    if (exchangeCount > 0) {
      return netRetained(grossCents) == 0 ? 'Exchanged' : 'Partially exchanged';
    }
    if (returnedCents + itemRefundCents > 0) {
      return netRetained(grossCents) == 0
          ? 'Fully returned'
          : 'Partially returned';
    }
    return 'Completed';
  }
}

class SaleReturnLineSummary {
  final String productName;
  final int quantityMilli;
  final String unit;
  final String disposition;
  final List<String> serials;
  const SaleReturnLineSummary(this.productName, this.quantityMilli, this.unit,
      this.disposition, this.serials);
}

class SaleRmaSummary {
  final String productName;
  final String? serial;
  const SaleRmaSummary(this.productName, this.serial);
}

class SaleLifecycleRepository {
  final AppDatabase db;
  const SaleLifecycleRepository(this.db);

  Future<Map<String, SaleLifecycleSummary>> summaries() async {
    final returns = await db.customSelect('''SELECT original_sale_id AS sale_id,
      COALESCE(SUM(refund_value_cents),0) AS amount,
      COUNT(*) AS count,
      COALESCE(SUM(CASE WHEN kind='exchange' THEN 1 ELSE 0 END),0) AS exchanges
      FROM sale_returns WHERE status='finalized' GROUP BY original_sale_id''').get();
    final refunds = await db.customSelect('''SELECT sale_id,
      COALESCE(SUM(amount_cents),0) AS amount
      FROM sale_item_refunds GROUP BY sale_id''').get();
    final rmas = await db.customSelect('''SELECT sale_id, COUNT(*) AS count
      FROM rma_cases WHERE sale_id IS NOT NULL
      AND status NOT IN ('resolved','completed','rejected','cancelled','closed')
      GROUP BY sale_id''').get();
    final ids = <String>{
      ...returns.map((r) => r.read<String>('sale_id')),
      ...refunds.map((r) => r.read<String>('sale_id')),
      ...rmas.map((r) => r.read<String>('sale_id')),
    };
    Map<String, int> values(List<dynamic> rows, String field) => {
          for (final row in rows)
            row.read<String>('sale_id'): row.read<int>(field)
        };
    final returnValues = values(returns, 'amount');
    final returnCounts = values(returns, 'count');
    final exchangeCounts = values(returns, 'exchanges');
    final refundValues = values(refunds, 'amount');
    final rmaCounts = values(rmas, 'count');

    return {
      for (final id in ids)
        id: SaleLifecycleSummary(
          returnValues[id] ?? 0,
          refundValues[id] ?? 0,
          returnCounts[id] ?? 0,
          exchangeCounts[id] ?? 0,
          rmaCounts[id] ?? 0,
        )
    };
  }

  Future<List<CommercialReturn>> returns(String saleId) =>
      SaleReturnRepository(db).history(saleId);

  Future<List<RmaCase>> rmas(String saleId) =>
      (db.select(db.rmaCases)..where((r) => r.saleId.equals(saleId))).get();

  Future<Map<String, List<SaleReturnLineSummary>>> returnLines(
      String saleId) async {
    final rows = await db.customSelect('''SELECT r.id AS return_id,
      si.product_name, si.sale_unit, rl.quantity_milli, rl.disposition,
      GROUP_CONCAT(su.serial_number) AS serials
      FROM sale_returns r JOIN sale_return_lines rl ON rl.return_id=r.id
      JOIN sale_items si ON si.id=rl.sale_item_id
      LEFT JOIN sale_return_allocations ra ON ra.return_line_id=rl.id
      LEFT JOIN serial_units su ON su.id=ra.serial_unit_id
      WHERE r.original_sale_id=? AND r.status='finalized'
      GROUP BY r.id, rl.id ORDER BY r.created_at, r.reference''',
        variables: [Variable.withString(saleId)]).get();
    final result = <String, List<SaleReturnLineSummary>>{};
    for (final row in rows) {
      final serials = row.readNullable<String>('serials');
      (result[row.read<String>('return_id')] ??= []).add(SaleReturnLineSummary(
        row.read<String>('product_name'),
        row.read<int>('quantity_milli'),
        row.read<String>('sale_unit'),
        row.read<String>('disposition'),
        serials == null ? const [] : serials.split(','),
      ));
    }
    return result;
  }

  Future<Map<String, SaleRmaSummary>> rmaDetails(String saleId) async {
    final rows = await db.customSelect('''SELECT r.id,
      COALESCE(si.product_name,'Item unavailable') AS product_name,
      su.serial_number FROM rma_cases r
      LEFT JOIN sale_items si ON si.id=r.sale_item_id
      LEFT JOIN serial_units su ON su.id=r.serial_unit_id
      WHERE r.sale_id=?''', variables: [Variable.withString(saleId)]).get();
    return {
      for (final row in rows)
        row.read<String>('id'): SaleRmaSummary(
          row.read<String>('product_name'),
          row.readNullable<String>('serial_number'),
        )
    };
  }

  Future<Map<String, int>> returnedQuantities(String saleId) async {
    final rows = await db.customSelect('''SELECT rl.sale_item_id,
      COALESCE(SUM(rl.quantity_milli),0) AS qty
      FROM sale_return_lines rl JOIN sale_returns r ON r.id=rl.return_id
      WHERE r.original_sale_id=? AND r.status='finalized'
      GROUP BY rl.sale_item_id''',
        variables: [Variable.withString(saleId)]).get();
    return {
      for (final r in rows) r.read<String>('sale_item_id'): r.read<int>('qty')
    };
  }

  Future<Map<String, List<String>>> returnedSerials(String saleId) async {
    final rows = await db.customSelect('''SELECT rl.sale_item_id,
      su.serial_number FROM sale_return_allocations ra
      JOIN sale_return_lines rl ON rl.id=ra.return_line_id
      JOIN sale_returns r ON r.id=rl.return_id
      JOIN serial_units su ON su.id=ra.serial_unit_id
      WHERE r.original_sale_id=? AND r.status='finalized'
      ORDER BY r.created_at, su.serial_number''',
        variables: [Variable.withString(saleId)]).get();
    final result = <String, List<String>>{};
    for (final row in rows) {
      (result[row.read<String>('sale_item_id')] ??= [])
          .add(row.read<String>('serial_number'));
    }
    return result;
  }

  Future<CommercialReturn?> exchangeOrigin(String saleId) async {
    final rows =
        await db.customSelect('''SELECT original_sale_id FROM sale_returns
      WHERE replacement_sale_id=? AND kind='exchange' AND status='finalized'
      LIMIT 1''', variables: [Variable.withString(saleId)]).get();
    if (rows.isEmpty) return null;
    final origin = rows.first.read<String>('original_sale_id');
    final history = await SaleReturnRepository(db).history(origin);
    for (final row in history) {
      if (row.replacementSaleId == saleId) return row;
    }
    return null;
  }
}
