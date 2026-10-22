import 'package:drift/drift.dart';

import '../database.dart';

class CustomerPurchaseSummary {
  final int count;
  final int completedCount;
  final int grossCents;
  final int returnedCents;
  const CustomerPurchaseSummary(
      this.count, this.completedCount, this.grossCents, this.returnedCents);
  int get netCents => grossCents - returnedCents;
  int get averageCents => completedCount == 0 ? 0 : netCents ~/ completedCount;
}

class CustomerPurchaseRepository {
  final AppDatabase db;
  const CustomerPurchaseRepository(this.db);

  List<Variable> _scope(String customerId, DateTime from, DateTime until) => [
        Variable.withString(customerId),
        Variable.withInt(from.millisecondsSinceEpoch ~/ 1000),
        Variable.withInt(until.millisecondsSinceEpoch ~/ 1000),
      ];

  Future<CustomerPurchaseSummary> summary(
      String customerId, DateTime from, DateTime until) async {
    final row = await db.customSelect('''
      SELECT COUNT(*) AS count,
        COALESCE(SUM(CASE WHEN s.status='completed' THEN 1 ELSE 0 END),0) AS completed,
        COALESCE(SUM(CASE WHEN s.status='completed' THEN s.total_cents ELSE 0 END),0) AS gross,
        COALESCE((SELECT SUM(r.refund_value_cents) FROM sale_returns r
          JOIN sales original ON original.id=r.original_sale_id
          WHERE original.customer_id=? AND original.status='completed'
            AND original.created_at>=? AND original.created_at<?
            AND r.status='finalized'),0) AS returned
      FROM sales s WHERE s.customer_id=? AND s.created_at>=? AND s.created_at<?
    ''', variables: [
      ..._scope(customerId, from, until),
      ..._scope(customerId, from, until),
    ]).getSingle();
    return CustomerPurchaseSummary(
        row.read<int>('count'),
        row.read<int>('completed'),
        row.read<int>('gross'),
        row.read<int>('returned'));
  }

  Future<List<Sale>> page(
          String customerId, DateTime from, DateTime until, int page) =>
      (db.select(db.sales)
            ..where((s) =>
                s.customerId.equals(customerId) &
                s.createdAt.isBiggerOrEqualValue(from) &
                s.createdAt.isSmallerThanValue(until))
            ..orderBy([
              (s) =>
                  OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc)
            ])
            ..limit(50, offset: page * 50))
          .get();

  Future<List<Sale>> recent(String customerId, {int limit = 5}) =>
      (db.select(db.sales)
            ..where((s) => s.customerId.equals(customerId))
            ..orderBy([
              (s) =>
                  OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc)
            ])
            ..limit(limit))
          .get();

  Future<Map<String, String>> paymentMethods(List<Sale> sales) async {
    if (sales.isEmpty) return {};
    final ids = sales.map((sale) => sale.id).toList();
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''
      SELECT sale_id, GROUP_CONCAT(DISTINCT method) AS methods
      FROM payments WHERE sale_id IN ($marks) GROUP BY sale_id
    ''', variables: [for (final id in ids) Variable.withString(id)]).get();
    return {
      for (final row in rows)
        row.read<String>('sale_id'): row.read<String>('methods')
    };
  }

  Future<Map<String, int>> returnedValues(List<Sale> sales) async {
    if (sales.isEmpty) return {};
    final ids = sales.map((sale) => sale.id).toList();
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''
      SELECT original_sale_id, COALESCE(SUM(refund_value_cents),0) AS returned
      FROM sale_returns
      WHERE status='finalized' AND original_sale_id IN ($marks)
      GROUP BY original_sale_id
    ''', variables: [for (final id in ids) Variable.withString(id)]).get();
    return {
      for (final row in rows)
        row.read<String>('original_sale_id'): row.read<int>('returned')
    };
  }
}
