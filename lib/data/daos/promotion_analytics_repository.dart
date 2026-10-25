import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class PromotionPeriod {
  final DateTime start;
  final DateTime end;
  final String label;
  const PromotionPeriod(this.start, this.end, this.label);

  factory PromotionPeriod.named(String key, DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return switch (key) {
      'Today' =>
        PromotionPeriod(day, DateTime(day.year, day.month, day.day + 1), key),
      'This week' => PromotionPeriod(
          day.subtract(Duration(days: day.weekday - 1)),
          day.add(Duration(days: 8 - day.weekday)),
          key),
      'This month' => PromotionPeriod(DateTime(day.year, day.month),
          DateTime(day.year, day.month + 1), key),
      'This year' =>
        PromotionPeriod(DateTime(day.year), DateTime(day.year + 1), key),
      _ => throw ArgumentError('Unknown period'),
    };
  }

  factory PromotionPeriod.custom(DateTime first, DateTime last) =>
      PromotionPeriod(DateTime(first.year, first.month, first.day),
          DateTime(last.year, last.month, last.day + 1), 'Custom');
}

class PromotionMetrics {
  final int sales, grossCents, discountCents, netCents;
  final DateTime? firstUse, lastUse;
  const PromotionMetrics(this.sales, this.grossCents, this.discountCents,
      this.netCents, this.firstUse, this.lastUse);
  int get averageDiscountCents =>
      sales == 0 ? 0 : (discountCents / sales).round();
}

class PromotionSaleRow {
  final String saleId, receipt, customer;
  final DateTime date;
  final int grossCents, discountCents, netCents;
  const PromotionSaleRow(this.saleId, this.receipt, this.customer, this.date,
      this.grossCents, this.discountCents, this.netCents);
}

class PromotionSaleLine {
  final String name, unit;
  final int quantityMilli, netCents, discountCents;
  const PromotionSaleLine(this.name, this.unit, this.quantityMilli,
      this.netCents, this.discountCents);
}

class PromotionProductRow {
  final String name, unit;
  final int quantityMilli, grossCents, discountCents, netCents;
  const PromotionProductRow(this.name, this.unit, this.quantityMilli,
      this.grossCents, this.discountCents, this.netCents);
}

class PromotionActivityRow {
  final DateTime date;
  final String actor, action;
  const PromotionActivityRow(this.date, this.actor, this.action);
}

class PromotionDiscountSummary {
  final int promotedSales, promotionCents, manualCents;
  final String? topPromotion;
  const PromotionDiscountSummary(this.promotedSales, this.promotionCents,
      this.manualCents, this.topPromotion);
  int get totalCents => promotionCents + manualCents;
}

/// Read-only aggregates over immutable completed-sale snapshots.
class PromotionAnalyticsRepository {
  final AppDatabase db;
  const PromotionAnalyticsRepository(this.db);

  Future<void> _view(ActiveUser actor) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.viewPromotions);
  }

  List<Variable> _args(String id, PromotionPeriod period) => [
        Variable.withString(id),
        Variable.withDateTime(period.start),
        Variable.withDateTime(period.end),
      ];

  Future<PromotionMetrics> metrics(
      ActiveUser actor, String id, PromotionPeriod period) async {
    await _view(actor);
    final row = await db.customSelect('''
      SELECT COUNT(*) AS sales,
        COALESCE(SUM(gross_cents), 0) AS gross_cents,
        COALESCE(SUM(discount_cents), 0) AS discount_cents,
        COALESCE(SUM(net_cents), 0) AS net_cents,
        MIN(created_at) AS first_use, MAX(created_at) AS last_use
      FROM (
        SELECT s.id, s.created_at,
          (SELECT COALESCE(SUM(i.line_total_cents + i.promotion_discount_cents + i.manual_discount_cents), 0)
             FROM sale_items i WHERE i.sale_id = s.id) AS gross_cents,
          SUM(a.discount_cents) AS discount_cents,
          (SELECT COALESCE(SUM(i.line_total_cents), 0)
             FROM sale_items i WHERE i.sale_id = s.id) AS net_cents
        FROM sale_promotion_applications a JOIN sales s ON s.id = a.sale_id
        WHERE a.promotion_id = ? AND s.status IN ('completed', 'refunded')
          AND s.created_at >= ? AND s.created_at < ?
        GROUP BY s.id
      )
    ''', variables: _args(id, period)).getSingle();
    DateTime? date(String key) {
      final value = row.readNullable<int>(key);
      return value == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(value * 1000);
    }

    return PromotionMetrics(
        row.read<int>('sales'),
        row.read<int>('gross_cents'),
        row.read<int>('discount_cents'),
        row.read<int>('net_cents'),
        date('first_use'),
        date('last_use'));
  }

  Future<List<PromotionSaleRow>> sales(
      ActiveUser actor, String id, PromotionPeriod period,
      {int page = 0}) async {
    await _view(actor);
    final rows = await db.customSelect('''
      SELECT s.id, COALESCE(s.receipt_number, s.id) AS receipt,
        COALESCE(c.name, NULLIF(s.walk_in_name, ''), 'Walk-in / Anonymous') AS customer,
        s.created_at,
        (SELECT COALESCE(SUM(i.line_total_cents + i.promotion_discount_cents + i.manual_discount_cents), 0)
           FROM sale_items i WHERE i.sale_id = s.id) AS gross_cents,
        SUM(a.discount_cents) AS discount_cents,
        (SELECT COALESCE(SUM(i.line_total_cents), 0)
           FROM sale_items i WHERE i.sale_id = s.id) AS net_cents
      FROM sale_promotion_applications a
      JOIN sales s ON s.id = a.sale_id
      LEFT JOIN customers c ON c.id = s.customer_id
      WHERE a.promotion_id = ? AND s.status IN ('completed', 'refunded')
        AND s.created_at >= ? AND s.created_at < ?
      GROUP BY s.id
      ORDER BY s.created_at DESC, s.id DESC LIMIT 50 OFFSET ?
    ''', variables: [..._args(id, period), Variable.withInt(page * 50)]).get();
    return [
      for (final row in rows)
        PromotionSaleRow(
            row.read<String>('id'),
            row.read<String>('receipt'),
            row.read<String>('customer'),
            DateTime.fromMillisecondsSinceEpoch(
                row.read<int>('created_at') * 1000),
            row.read<int>('gross_cents'),
            row.read<int>('discount_cents'),
            row.read<int>('net_cents'))
    ];
  }

  Future<List<PromotionSaleLine>> saleLines(
      ActiveUser actor, String saleId) async {
    await _view(actor);
    final rows = await (db.select(db.saleItems)
          ..where((item) => item.saleId.equals(saleId))
          ..orderBy([(item) => OrderingTerm.asc(item.productName)]))
        .get();
    return [
      for (final item in rows)
        PromotionSaleLine(
            item.productName,
            item.saleUnit,
            item.quantityMilli == 0 ? item.quantity * 1000 : item.quantityMilli,
            item.lineTotalCents,
            item.promotionDiscountCents)
    ];
  }

  /// Per-line allocation cannot identify an individual rule in a stacked sale.
  /// Only single-rule sales contribute to these product totals.
  Future<List<PromotionProductRow>> topProducts(
      ActiveUser actor, String id, PromotionPeriod period) async {
    await _view(actor);
    final rows = await db.customSelect('''
      SELECT i.product_name, i.sale_unit,
        SUM(CASE WHEN i.promotion_discount_cents > 0 THEN i.quantity_milli ELSE 0 END) AS quantity_milli,
        SUM(i.line_total_cents + i.promotion_discount_cents) AS gross_cents,
        SUM(i.promotion_discount_cents) AS discount_cents,
        SUM(i.line_total_cents) AS net_cents
      FROM sale_items i JOIN sales s ON s.id = i.sale_id
      JOIN sale_promotion_applications a ON a.sale_id = s.id
      WHERE a.promotion_id = ? AND s.status IN ('completed', 'refunded')
        AND s.created_at >= ? AND s.created_at < ?
        AND i.promotion_discount_cents > 0
        AND (SELECT COUNT(*) FROM sale_promotion_applications x WHERE x.sale_id = s.id) = 1
      GROUP BY i.product_name, i.sale_unit
      ORDER BY discount_cents DESC, gross_cents DESC, i.product_name ASC LIMIT 10
    ''', variables: _args(id, period)).get();
    return [
      for (final row in rows)
        PromotionProductRow(
            row.read<String>('product_name'),
            row.read<String>('sale_unit'),
            row.read<int>('quantity_milli'),
            row.read<int>('gross_cents'),
            row.read<int>('discount_cents'),
            row.read<int>('net_cents'))
    ];
  }

  Future<List<PromotionActivityRow>> activity(
      ActiveUser actor, String id) async {
    await _view(actor);
    final rows = await db.customSelect('''
      SELECT a.created_at, COALESCE(u.name, 'Unknown user') AS actor, a.action
      FROM audit_logs a LEFT JOIN users u ON u.id = a.user_id
      WHERE a.action IN ('promotion_created', 'promotion_edited',
        'promotion_activated', 'promotion_deactivated', 'promotion_duplicated')
        AND a.details LIKE ?
      ORDER BY a.created_at DESC, a.id DESC LIMIT 100
    ''', variables: [Variable.withString('%"promotionId":"$id"%')]).get();
    return [
      for (final row in rows)
        PromotionActivityRow(
            DateTime.fromMillisecondsSinceEpoch(
                row.read<int>('created_at') * 1000),
            row.read<String>('actor'),
            row.read<String>('action'))
    ];
  }

  Future<PromotionDiscountSummary> discountSummary(
      ActiveUser actor, PromotionPeriod period) async {
    await _view(actor);
    final row = await db.customSelect('''
      SELECT COUNT(DISTINCT CASE WHEN s.discount_source = 'promotion' THEN s.id END) AS promoted_sales,
        COALESCE((SELECT SUM(a.discount_cents) FROM sale_promotion_applications a
          JOIN sales p ON p.id = a.sale_id WHERE p.status IN ('completed', 'refunded')
          AND p.created_at >= ? AND p.created_at < ?), 0) AS promotion_cents,
        COALESCE((SELECT SUM(d.effect_cents) FROM sale_manual_discounts d
          JOIN sales m ON m.id = d.sale_id WHERE m.status IN ('completed', 'refunded')
          AND m.created_at >= ? AND m.created_at < ?), 0) AS manual_cents
      FROM sales s WHERE s.status IN ('completed', 'refunded')
        AND s.created_at >= ? AND s.created_at < ?
    ''', variables: [
      for (var i = 0; i < 3; i++) ...[
        Variable.withDateTime(period.start),
        Variable.withDateTime(period.end)
      ]
    ]).getSingle();
    final top = await db.customSelect('''
      SELECT a.promotion_name FROM sale_promotion_applications a
      JOIN sales s ON s.id = a.sale_id
      WHERE s.status IN ('completed', 'refunded') AND s.created_at >= ? AND s.created_at < ?
      GROUP BY a.promotion_id, a.promotion_name
      ORDER BY SUM(a.discount_cents) DESC, a.promotion_name ASC LIMIT 1
    ''', variables: [
      Variable.withDateTime(period.start),
      Variable.withDateTime(period.end)
    ]).getSingleOrNull();
    return PromotionDiscountSummary(
        row.read<int>('promoted_sales'),
        row.read<int>('promotion_cents'),
        row.read<int>('manual_cents'),
        top?.read<String>('promotion_name'));
  }
}
