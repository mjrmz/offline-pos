import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class CustomerCreditRepository {
  final AppDatabase db;
  CustomerCreditRepository(this.db);

  Future<List<CustomerCreditEntry>> entries(String customerId) =>
      (db.select(db.customerCreditEntries)
            ..where((e) => e.customerId.equals(customerId))
            ..orderBy([(e) => OrderingTerm(expression: e.createdAt)]))
          .get();

  Future<int> balance(String customerId) async =>
      (await entries(customerId)).fold<int>(0, (sum, e) => sum + e.amountCents);

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
