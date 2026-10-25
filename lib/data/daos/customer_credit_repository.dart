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

class CreditSaleBalance {
  const CreditSaleBalance(this.sale, this.reference, this.originalCents,
      this.adjustedCents, this.paidCents);
  final Sale sale;
  final String reference;
  final int originalCents;
  final int adjustedCents;
  final int paidCents;
  int get remainingCents => adjustedCents - paidCents;
  String get status => remainingCents == 0
      ? 'Paid'
      : paidCents == 0
          ? 'Unpaid'
          : 'Partially paid';
}

class CreditLedgerLine {
  const CreditLedgerLine(this.entry, this.reference, this.runningCents);
  final CustomerCreditEntry entry;
  final String reference;
  final int runningCents;
}

class CustomerCreditSnapshot {
  const CustomerCreditSnapshot(this.sales, this.ledger, this.creditLimitCents);
  final List<CreditSaleBalance> sales;
  final List<CreditLedgerLine> ledger;
  final int? creditLimitCents;
  int get outstandingCents =>
      sales.fold(0, (sum, sale) => sum + sale.remainingCents);
  int? get availableCents => creditLimitCents == null
      ? null
      : (creditLimitCents! - outstandingCents).clamp(0, creditLimitCents!);
  int get openSales => sales.where((sale) => sale.remainingCents > 0).length;
}

class CustomerCreditRepository {
  final AppDatabase db;
  CustomerCreditRepository(this.db);

  Future<CustomerCreditSnapshot> snapshot(String customerId) async {
    final customer = await (db.select(db.customers)
          ..where((c) => c.id.equals(customerId)))
        .getSingle();
    final entries = await (db.select(db.customerCreditEntries)
          ..where((e) => e.customerId.equals(customerId))
          ..orderBy([
            (e) => OrderingTerm(expression: e.createdAt),
            (e) => OrderingTerm(expression: e.id)
          ]))
        .get();
    int priority(CustomerCreditEntry entry) => entry.kind == 'credit_sale'
        ? 0
        : entry.kind == 'payment'
            ? 1
            : 2;
    entries.sort((a, b) {
      final date = a.createdAt.compareTo(b.createdAt);
      if (date != 0) return date;
      final type = priority(a).compareTo(priority(b));
      return type != 0 ? type : a.id.compareTo(b.id);
    });
    final saleIds = entries.map((e) => e.saleId).whereType<String>().toSet();
    final sales = saleIds.isEmpty
        ? <Sale>[]
        : await (db.select(db.sales)..where((s) => s.id.isIn(saleIds))).get();
    final saleById = {for (final sale in sales) sale.id: sale};
    final paymentIds =
        entries.where((e) => e.kind == 'payment').map((e) => e.id).toSet();
    final allocations = paymentIds.isEmpty
        ? <CustomerCreditPaymentAllocation>[]
        : await (db.select(db.customerCreditPaymentAllocations)
              ..where((a) => a.paymentEntryId.isIn(paymentIds)))
            .get();
    final allocatedByPayment = <String, int>{};
    final allocatedBySale = <String, int>{};
    for (final allocation in allocations) {
      allocatedByPayment.update(
          allocation.paymentEntryId, (v) => v + allocation.amountCents,
          ifAbsent: () => allocation.amountCents);
      allocatedBySale.update(
          allocation.saleId, (v) => v + allocation.amountCents,
          ifAbsent: () => allocation.amountCents);
    }
    final original = <String, int>{}, adjustment = <String, int>{};
    var pooledPayments = 0;
    for (final entry in entries) {
      if (entry.kind == 'credit_sale' && entry.saleId != null) {
        original.update(entry.saleId!, (v) => v + entry.amountCents,
            ifAbsent: () => entry.amountCents);
      } else if (entry.kind == 'payment') {
        pooledPayments +=
            -entry.amountCents - (allocatedByPayment[entry.id] ?? 0);
      } else if (entry.saleId != null && entry.amountCents < 0) {
        adjustment.update(entry.saleId!, (v) => v - entry.amountCents,
            ifAbsent: () => -entry.amountCents);
      }
    }
    final ordered = sales.where((s) => original.containsKey(s.id)).toList()
      ..sort((a, b) {
        final date = a.createdAt.compareTo(b.createdAt);
        return date != 0 ? date : a.id.compareTo(b.id);
      });
    final lines = <CreditSaleBalance>[];
    for (final sale in ordered) {
      final charge = original[sale.id]!;
      final adjusted = sale.status == 'completed'
          ? (charge - (adjustment[sale.id] ?? 0)).clamp(0, charge)
          : 0;
      final allocated = allocatedBySale[sale.id] ?? 0;
      final kept = allocated.clamp(0, adjusted);
      pooledPayments += allocated - kept;
      lines.add(CreditSaleBalance(
          sale,
          sale.receiptNumber ??
              (sale.birInvoiceNumber == null
                  ? 'Legacy credit sale'
                  : 'Invoice #${sale.birInvoiceNumber}'),
          charge,
          adjusted,
          kept));
    }
    final settled = <CreditSaleBalance>[];
    for (final line in lines) {
      final take = pooledPayments.clamp(0, line.remainingCents);
      pooledPayments -= take;
      settled.add(CreditSaleBalance(line.sale, line.reference,
          line.originalCents, line.adjustedCents, line.paidCents + take));
    }
    var running = 0;
    final ledger = <CreditLedgerLine>[];
    for (final entry in entries) {
      running += entry.amountCents;
      final reference = entry.reference ??
          (entry.saleId == null
              ? 'Legacy payment'
              : (saleById[entry.saleId!]?.receiptNumber ??
                  (saleById[entry.saleId!]?.birInvoiceNumber == null
                      ? 'Legacy credit sale'
                      : 'Invoice #${saleById[entry.saleId!]!.birInvoiceNumber}')));
      ledger.add(CreditLedgerLine(entry, reference, running));
    }
    return CustomerCreditSnapshot(settled, ledger, customer.creditLimitCents);
  }

  Future<void> setCreditLimit(
          ActiveUser actor, String customerId, int? limitCents) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageContacts);
        if (limitCents != null && limitCents < 0) {
          throw ArgumentError('Credit limit cannot be negative');
        }
        final count = await (db.update(db.customers)
              ..where((c) => c.id.equals(customerId)))
            .write(CustomersCompanion(creditLimitCents: Value(limitCents)));
        if (count != 1) throw StateError('Customer not found');
        await AuthRepository(db).audit(live.id, 'customer.credit_limit',
            '$customerId:${limitCents ?? 'none'}');
      });

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
          {String? note, String? saleId}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.customerCredit);
        if (method != 'cash' && method != 'gcash') {
          throw ArgumentError('Choose cash or confirmed GCash');
        }
        final state = await snapshot(customerId);
        if (amountCents <= 0 || amountCents > state.outstandingCents) {
          throw StateError(
              'Payment exceeds the customer\'s outstanding credit balance');
        }
        if (saleId != null &&
            !state.sales.any((s) =>
                s.sale.id == saleId && s.remainingCents >= amountCents)) {
          throw StateError('Payment exceeds the selected credit sale balance');
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
        final sequence = await db
            .customSelect(
                "SELECT COALESCE(MAX(CAST(substr(reference, 6) AS INTEGER)),0) AS last_number FROM customer_credit_entries WHERE reference LIKE 'CPAY-%'")
            .getSingle();
        final reference =
            'CPAY-${(sequence.read<int>('last_number') + 1).toString().padLeft(6, '0')}';
        final entry = await db.into(db.customerCreditEntries).insertReturning(
              CustomerCreditEntriesCompanion.insert(
                customerId: customerId,
                userId: live.id,
                amountCents: -amountCents,
                kind: 'payment',
                paymentMethod: Value(method),
                reference: Value(reference),
                note: Value(note?.trim().isEmpty == true ? null : note?.trim()),
              ),
            );
        var remaining = amountCents;
        final targets = saleId == null
            ? state.sales.where((s) => s.remainingCents > 0)
            : state.sales.where((s) => s.sale.id == saleId);
        for (final sale in targets) {
          if (remaining == 0) break;
          final applied =
              remaining < sale.remainingCents ? remaining : sale.remainingCents;
          await db.into(db.customerCreditPaymentAllocations).insert(
              CustomerCreditPaymentAllocationsCompanion.insert(
                  paymentEntryId: entry.id,
                  saleId: sale.sale.id,
                  amountCents: applied));
          remaining -= applied;
        }
        if (remaining != 0) throw StateError('Payment allocation failed');
        if (session != null) {
          await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: session.id,
              referenceId: Value(entry.id),
              amountCents: amountCents,
              kind: 'credit_payment'));
        }
        await AuthRepository(db).audit(live.id, 'customer_credit.payment',
            '$customerId:$reference:$amountCents:$method');
        return entry;
      });
}
