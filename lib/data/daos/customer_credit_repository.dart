import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class CustomerCreditActivitySummary {
  final int total;
  final int creditSales;
  final int payments;
  final DateTime? lastActivity;
  const CustomerCreditActivitySummary(
      this.total, this.creditSales, this.payments, this.lastActivity);
}

class CustomerCreditRepository {
  final AppDatabase db;
  CustomerCreditRepository(this.db);

  Future<List<CustomerCreditEntry>> entries(String customerId) =>
      (db.select(db.customerCreditEntries)
            ..where((e) => e.customerId.equals(customerId))
            ..orderBy([(e) => OrderingTerm(expression: e.createdAt)]))
          .get();

  Future<CustomerCreditActivitySummary> activitySummary(
      String customerId) async {
    final row = await db.customSelect('''
      SELECT COUNT(*) AS total,
        COALESCE(SUM(CASE WHEN kind='credit_sale' THEN 1 ELSE 0 END),0) AS sales,
        COALESCE(SUM(CASE WHEN kind='payment' THEN 1 ELSE 0 END),0) AS payments,
        MAX(created_at) AS last_activity
      FROM customer_credit_entries WHERE customer_id=?
    ''', variables: [Variable.withString(customerId)]).getSingle();
    final seconds = row.readNullable<int>('last_activity');
    return CustomerCreditActivitySummary(
        row.read<int>('total'),
        row.read<int>('sales'),
        row.read<int>('payments'),
        seconds == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
  }

  Future<List<CustomerCreditEntry>> entriesPage(String customerId, int page) =>
      (db.select(db.customerCreditEntries)
            ..where((e) => e.customerId.equals(customerId))
            ..orderBy([
              (e) =>
                  OrderingTerm(expression: e.createdAt, mode: OrderingMode.desc)
            ])
            ..limit(50, offset: page * 50))
          .get();

  Future<Map<String, String>> saleReferences(
      List<CustomerCreditEntry> entries) async {
    final ids = entries
        .map((entry) => entry.saleId)
        .whereType<String>()
        .toSet()
        .toList();
    if (ids.isEmpty) return {};
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''
      SELECT id, receipt_number FROM sales WHERE id IN ($marks)
    ''', variables: [for (final id in ids) Variable.withString(id)]).get();
    return {
      for (final row in rows)
        if (row.readNullable<String>('receipt_number') != null)
          row.read<String>('id'): row.read<String>('receipt_number')
    };
  }

  Future<int> balance(String customerId) async {
    final row = await db.customSelect('''
      SELECT COALESCE(SUM(amount_cents), 0) AS balance
      FROM customer_credit_entries WHERE customer_id=?
    ''', variables: [Variable.withString(customerId)]).getSingle();
    return row.read<int>('balance');
  }

  Future<List<CustomerRefundObligation>> refundObligations(String customerId) =>
      (db.select(db.customerRefundObligations)
            ..where((r) => r.customerId.equals(customerId))
            ..orderBy([(r) => OrderingTerm(expression: r.createdAt)]))
          .get();

  Future<void> settleRefund(
          ActiveUser actor, String obligationId, int amountCents, String method,
          {String? note}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.customerCredit);
        if (method != 'cash' && method != 'gcash') {
          throw ArgumentError('Choose cash or confirmed GCash');
        }
        final row = await (db.select(db.customerRefundObligations)
              ..where((r) => r.id.equals(obligationId)))
            .getSingleOrNull();
        if (row == null) throw StateError('Refund obligation not found');
        if (amountCents <= 0 ||
            amountCents > row.amountCents - row.settledCents) {
          throw StateError('Refund exceeds amount due');
        }
        CashSession? session;
        if (method == 'cash') {
          session = await (db.select(db.cashSessions)
                ..where((s) => s.closedAt.isNull()))
              .getSingleOrNull();
          if (session == null) throw StateError('Open a cash session first');
        }
        await (db.update(db.customerRefundObligations)
              ..where((r) => r.id.equals(obligationId)))
            .write(CustomerRefundObligationsCompanion(
                settledCents: Value(row.settledCents + amountCents)));
        final settlement = await db
            .into(db.customerRefundSettlements)
            .insertReturning(CustomerRefundSettlementsCompanion.insert(
                obligationId: obligationId,
                userId: live.id,
                amountCents: amountCents,
                method: method,
                note:
                    Value(note?.trim().isEmpty == true ? null : note?.trim())));
        if (session != null) {
          await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: session.id,
              referenceId: Value(settlement.id),
              amountCents: -amountCents,
              kind: 'customer_credit_refund'));
        }
        await AuthRepository(db).audit(live.id, 'customer_credit.refund',
            '$obligationId:$amountCents:$method');
      });

  Future<List<Sale>> purchases(String customerId) => (db.select(db.sales)
        ..where((s) => s.customerId.equals(customerId))
        ..orderBy([
          (s) => OrderingTerm(expression: s.createdAt, mode: OrderingMode.desc)
        ]))
      .get();

  Future<CustomerCreditEntry> payment(
          ActiveUser actor, String customerId, int amountCents, String method,
          {String? note}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.customerCredit);
        if (method != 'cash' && method != 'gcash') {
          throw ArgumentError('Choose cash or confirmed GCash');
        }
        if (amountCents <= 0 || amountCents > await balance(customerId)) {
          throw StateError('Payment exceeds outstanding balance');
        }
        final customer = await (db.select(db.customers)
              ..where((c) => c.id.equals(customerId)))
            .getSingleOrNull();
        if (customer == null) throw StateError('Customer not found');
        CashSession? session;
        if (method == 'cash') {
          session = await (db.select(db.cashSessions)
                ..where((s) => s.closedAt.isNull()))
              .getSingleOrNull();
          if (session == null) throw StateError('Open a cash session first');
        }
        final entry = await db.into(db.customerCreditEntries).insertReturning(
              CustomerCreditEntriesCompanion.insert(
                customerId: customerId,
                userId: live.id,
                amountCents: -amountCents,
                kind: 'payment',
                paymentMethod: Value(method),
                note: Value(note?.trim().isEmpty == true ? null : note?.trim()),
              ),
            );
        if (session != null) {
          await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: session.id,
              amountCents: amountCents,
              kind: 'credit_payment'));
        }
        await AuthRepository(db)
            .audit(live.id, 'customer_credit.payment', '${entry.id}:$method');
        return entry;
      });
}
