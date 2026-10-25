import 'package:drift/drift.dart';

import '../database.dart';

class ReceivableAge {
  const ReceivableAge(this.saleId, this.reference, this.date,
      this.originalCents, this.paidCents, this.remainingCents, this.ageDays);
  final String saleId;
  final String reference;
  final DateTime date;
  final int originalCents;
  final int paidCents;
  final int remainingCents;
  final int ageDays;
}

class CustomerAging {
  const CustomerAging(this.sales, this.buckets);
  final List<ReceivableAge> sales;
  final Map<String, int> buckets;
  int get totalCents => buckets.values.fold(0, (sum, value) => sum + value);
  static const labels = [
    'Current',
    '1–30 days',
    '31–60 days',
    '61–90 days',
    '90+ days'
  ];
}

class StatementSummary {
  const StatementSummary(
      this.start,
      this.end,
      this.openingCents,
      this.chargesCents,
      this.paymentsCents,
      this.adjustmentsCents,
      this.closingCents,
      this.count);
  final DateTime start;
  final DateTime end;
  final int openingCents;
  final int chargesCents;
  final int paymentsCents;
  final int adjustmentsCents;
  final int closingCents;
  final int count;
}

class StatementLine {
  const StatementLine(this.date, this.reference, this.description,
      this.chargeCents, this.paymentCreditCents, this.balanceCents);
  final DateTime date;
  final String reference;
  final String description;
  final int chargeCents;
  final int paymentCreditCents;
  final int balanceCents;
}

class StatementPage {
  const StatementPage(this.summary, this.lines, this.page);
  final StatementSummary summary;
  final List<StatementLine> lines;
  final int page;
}

class ReceivablesReportingRepository {
  const ReceivablesReportingRepository(this.db);
  final AppDatabase db;

  static const _saleSql = '''
    WITH charge AS (
      SELECT sale_id, SUM(amount_cents) original
      FROM customer_credit_entries
      WHERE customer_id=? AND kind='credit_sale' AND sale_id IS NOT NULL
      GROUP BY sale_id
    ), adjustment AS (
      SELECT sale_id, SUM(-amount_cents) amount
      FROM customer_credit_entries
      WHERE customer_id=? AND sale_id IS NOT NULL
        AND kind NOT IN ('credit_sale','payment') AND amount_cents<0
      GROUP BY sale_id
    ), allocation AS (
      SELECT a.sale_id, SUM(a.amount_cents) amount
      FROM customer_credit_payment_allocations a
      JOIN customer_credit_entries e ON e.id=a.payment_entry_id
      WHERE e.customer_id=? GROUP BY a.sale_id
    ), payment_allocation AS (
      SELECT payment_entry_id, SUM(amount_cents) amount
      FROM customer_credit_payment_allocations GROUP BY payment_entry_id
    ), pool AS (
      SELECT COALESCE(SUM(-e.amount_cents-COALESCE(a.amount,0)),0) amount
      FROM customer_credit_entries e
      LEFT JOIN payment_allocation a ON a.payment_entry_id=e.id
      WHERE e.customer_id=? AND e.kind='payment'
    ), base AS (
      SELECT s.id sale_id, s.receipt_number, s.bir_invoice_number,
        s.created_at sale_date, c.original,
        CASE WHEN s.status='completed'
          THEN MAX(0,c.original-COALESCE(j.amount,0)) ELSE 0 END adjusted,
        COALESCE(a.amount,0) allocated
      FROM charge c JOIN sales s ON s.id=c.sale_id
      LEFT JOIN adjustment j ON j.sale_id=s.id
      LEFT JOIN allocation a ON a.sale_id=s.id
    ), share AS (
      SELECT *, MIN(adjusted,allocated) kept,
        adjusted-MIN(adjusted,allocated) initial FROM base
    ), pool_total AS (
      SELECT pool.amount + COALESCE(SUM(share.allocated-share.kept),0) amount
      FROM pool LEFT JOIN share ON 1=1
    ), ranked AS (
      SELECT *, COALESCE(SUM(initial) OVER (
        ORDER BY sale_date,sale_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) earlier
      FROM share
    )
    SELECT ranked.*, MAX(0,initial-MAX(0,pool_total.amount-earlier)) remaining
    FROM ranked CROSS JOIN pool_total
    ORDER BY sale_date,sale_id
  ''';

  Future<CustomerAging> aging(String customerId, {DateTime? asOf}) async {
    final now = asOf ?? DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final rows = await db.customSelect(_saleSql, variables: [
      for (var i = 0; i < 4; i++) Variable.withString(customerId)
    ]).get();
    final sales = <ReceivableAge>[];
    final buckets = {for (final label in CustomerAging.labels) label: 0};
    for (final row in rows) {
      final remaining = row.read<int>('remaining');
      if (remaining <= 0) continue;
      final date = DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('sale_date') * 1000);
      final age = today
          .difference(DateTime(date.year, date.month, date.day))
          .inDays
          .clamp(0, 999999);
      final bucket = age == 0
          ? CustomerAging.labels[0]
          : age <= 30
              ? CustomerAging.labels[1]
              : age <= 60
                  ? CustomerAging.labels[2]
                  : age <= 90
                      ? CustomerAging.labels[3]
                      : CustomerAging.labels[4];
      buckets[bucket] = buckets[bucket]! + remaining;
      final invoice = row.read<int?>('bir_invoice_number');
      final original = row.read<int>('original');
      final adjusted = row.read<int>('adjusted');
      sales.add(ReceivableAge(
          row.read<String>('sale_id'),
          row.read<String?>('receipt_number') ??
              (invoice == null ? 'Legacy credit sale' : 'Invoice #$invoice'),
          date,
          original,
          adjusted - remaining,
          remaining,
          age));
    }
    return CustomerAging(sales, buckets);
  }

  static int _seconds(DateTime date) =>
      DateTime(date.year, date.month, date.day).millisecondsSinceEpoch ~/ 1000;

  Future<StatementSummary> statementSummary(
      String customerId, DateTime start, DateTime end) async {
    if (!end.isAfter(start)) {
      throw ArgumentError('Statement end must follow start');
    }
    final from = _seconds(start), until = _seconds(end);
    final opening = await db.customSelect('''
      SELECT COALESCE(SUM(amount_cents),0) total FROM customer_credit_entries
      WHERE customer_id=? AND created_at<?
    ''', variables: [
      Variable.withString(customerId),
      Variable.withInt(from)
    ]).getSingle();
    final period = await db.customSelect('''
      SELECT COUNT(*) count,
        COALESCE(SUM(CASE WHEN kind='credit_sale' THEN amount_cents ELSE 0 END),0) charges,
        COALESCE(SUM(CASE WHEN kind='payment' THEN -amount_cents ELSE 0 END),0) payments,
        COALESCE(SUM(CASE WHEN kind NOT IN ('credit_sale','payment') AND amount_cents<0 THEN -amount_cents ELSE 0 END),0) adjustments,
        COALESCE(SUM(amount_cents),0) net
      FROM customer_credit_entries WHERE customer_id=? AND created_at>=? AND created_at<?
    ''', variables: [
      Variable.withString(customerId),
      Variable.withInt(from),
      Variable.withInt(until)
    ]).getSingle();
    final before = opening.read<int>('total');
    return StatementSummary(
        start,
        end,
        before,
        period.read<int>('charges'),
        period.read<int>('payments'),
        period.read<int>('adjustments'),
        before + period.read<int>('net'),
        period.read<int>('count'));
  }

  Future<StatementPage> statementPage(
      String customerId, DateTime start, DateTime end,
      {int page = 0}) async {
    if (page < 0) throw ArgumentError.value(page, 'page');
    final summary = await statementSummary(customerId, start, end);
    final rows = await db.customSelect('''
      SELECT * FROM (
        SELECT e.id, e.created_at, e.amount_cents, e.kind, e.reference,
          s.receipt_number, s.bir_invoice_number,
          SUM(e.amount_cents) OVER (ORDER BY e.created_at,
            CASE WHEN e.kind='credit_sale' THEN 0 WHEN e.kind='payment' THEN 1 ELSE 2 END,
            e.id ROWS UNBOUNDED PRECEDING) period_running
        FROM customer_credit_entries e LEFT JOIN sales s ON s.id=e.sale_id
        WHERE e.customer_id=? AND e.created_at>=? AND e.created_at<?
      ) ORDER BY created_at,
        CASE WHEN kind='credit_sale' THEN 0 WHEN kind='payment' THEN 1 ELSE 2 END,
        id LIMIT 50 OFFSET ?
    ''', variables: [
      Variable.withString(customerId),
      Variable.withInt(_seconds(start)),
      Variable.withInt(_seconds(end)),
      Variable.withInt(page * 50)
    ]).get();
    final lines = <StatementLine>[];
    for (final row in rows) {
      final amount = row.read<int>('amount_cents');
      final kind = row.read<String>('kind');
      final invoice = row.read<int?>('bir_invoice_number');
      lines.add(StatementLine(
          DateTime.fromMillisecondsSinceEpoch(
              row.read<int>('created_at') * 1000),
          row.read<String?>('reference') ??
              row.read<String?>('receipt_number') ??
              (invoice == null
                  ? (kind == 'payment'
                      ? 'Legacy payment'
                      : 'Legacy credit sale')
                  : 'Invoice #$invoice'),
          kind == 'credit_sale'
              ? 'Credit sale'
              : kind == 'payment'
                  ? 'Payment'
                  : kind.contains('refund')
                      ? 'Return adjustment'
                      : 'Credit adjustment',
          amount > 0 ? amount : 0,
          amount < 0 ? -amount : 0,
          summary.openingCents + row.read<int>('period_running')));
    }
    return StatementPage(summary, lines, page);
  }
}
