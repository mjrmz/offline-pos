import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'cash_session_repository.dart';

class SupplierPayable {
  final String receivingId;
  final String reference;
  final String? invoice;
  final DateTime date;
  final DateTime finalizedDate;
  final int originalCents, paidCents, creditCents, unappliedCreditCents;
  const SupplierPayable(this.receivingId, this.reference, this.invoice,
      this.date, this.finalizedDate, this.originalCents, this.paidCents, this.creditCents,
      this.unappliedCreditCents);
  int ageDays(DateTime asOf) {
    final start = DateTime.utc(finalizedDate.year, finalizedDate.month, finalizedDate.day);
    final end = DateTime.utc(asOf.year, asOf.month, asOf.day);
    return end.difference(start).inDays < 0 ? 0 : end.difference(start).inDays;
  }
  int get remainingCents => originalCents - paidCents - creditCents;
  String get status => remainingCents == 0
      ? 'Paid'
      : paidCents > 0 || creditCents > 0
          ? 'Partially paid'
          : 'Unpaid';
}

class SupplierAllocation {
  final SupplierPayable payable;
  final int cents;
  const SupplierAllocation(this.payable, this.cents);
}

class SupplierLedgerEntry {
  final DateTime date;
  final String reference, type;
  final int purchaseCents, settlementCents, balanceCents;
  const SupplierLedgerEntry(this.date, this.reference, this.type,
      this.purchaseCents, this.settlementCents, this.balanceCents);
}

class SupplierPayableMetrics {
  final int openCount, creditsCents, paymentsThisMonthCents;
  const SupplierPayableMetrics(this.openCount, this.creditsCents,
      this.paymentsThisMonthCents);
}

class SupplierAgingSummary {
  final int currentCents, days1To30Cents, days31To60Cents,
      days61To90Cents, daysOver90Cents;
  const SupplierAgingSummary(this.currentCents, this.days1To30Cents,
      this.days31To60Cents, this.days61To90Cents, this.daysOver90Cents);
  int get totalCents => currentCents + days1To30Cents + days31To60Cents +
      days61To90Cents + daysOver90Cents;
}

class SupplierStatementSummary {
  final int openingCents, chargesCents, creditsCents, paymentsCents,
      unappliedCreditCents, count, legacyCount;
  const SupplierStatementSummary(this.openingCents, this.chargesCents,
      this.creditsCents, this.paymentsCents, this.unappliedCreditCents,
      this.count, this.legacyCount);
  int get closingCents => openingCents + chargesCents - creditsCents - paymentsCents;
}

class SupplierStatementPage {
  final SupplierStatementSummary summary;
  final List<SupplierLedgerEntry> lines;
  final int page;
  const SupplierStatementPage(this.summary, this.lines, this.page);
}

class SupplierPayablesRepository {
  final AppDatabase db;
  const SupplierPayablesRepository(this.db);

  static String number(SupplierPayment row) =>
      'SPAY-${row.sequence.toString().padLeft(6, '0')}';

  static const _balances = '''
    WITH amounts AS (
      SELECT r.id, r.sequence, r.external_reference, r.received_at, r.finalized_at,
        COALESCE((SELECT SUM((i.quantity_milli * i.unit_cost_cents + 500) / 1000)
          FROM stock_receiving_items i WHERE i.receiving_id = r.id), 0) AS original,
        COALESCE((SELECT SUM(a.allocated_cents)
          FROM supplier_payment_allocations a WHERE a.receiving_id = r.id), 0) AS paid,
        COALESCE((SELECT SUM(COALESCE(pr.credit_amount_cents,
          (SELECT SUM(l.return_value_cents) FROM purchase_return_lines l
           WHERE l.purchase_return_id = pr.id)))
          FROM purchase_returns pr WHERE pr.receiving_id = r.id
          AND pr.status = 'finalized' AND pr.resolution = 'supplierCredit'), 0) AS raw_credit
      FROM stock_receivings r
      JOIN supplier_payable_sources src ON src.receiving_id = r.id
      WHERE r.supplier_id = ? AND r.finalized_at IS NOT NULL
    )
    SELECT *, MIN(raw_credit, MAX(0, original - paid)) AS credit
    FROM amounts
  ''';

  static const _activity = '''
    WITH receipts AS ($_balances),
    credits AS (
      SELECT pr.sequence, pr.receiving_id, pr.return_date AS happened_at,
        COALESCE(pr.credit_amount_cents,
          (SELECT SUM(l.return_value_cents) FROM purchase_return_lines l
           WHERE l.purchase_return_id = pr.id), 0) AS raw,
        receipts.original - receipts.paid AS capacity
      FROM purchase_returns pr JOIN receipts ON receipts.id = pr.receiving_id
      WHERE pr.status = 'finalized' AND pr.resolution = 'supplierCredit'
    ),
    applied AS (
      SELECT *, MAX(0, MIN(raw, capacity - COALESCE(
        SUM(raw) OVER (PARTITION BY receiving_id
          ORDER BY happened_at, sequence ROWS BETWEEN UNBOUNDED PRECEDING
          AND 1 PRECEDING), 0))) AS amount FROM credits
    ),
    events AS (
      SELECT received_at AS happened_at, sequence AS ordering, 0 AS kind,
        printf('RCV-%06d', sequence) AS reference,
        'Receiving' AS type, original AS purchase, 0 AS settlement
      FROM receipts
      UNION ALL
      SELECT happened_at, sequence, 1,
        printf('PRT-%06d', sequence), 'Supplier credit', 0, amount
      FROM applied WHERE amount > 0
      UNION ALL
      SELECT p.paid_at, p.sequence, 2,
        printf('SPAY-%06d', p.sequence), 'Payment', 0, p.amount_cents
      FROM supplier_payments p WHERE p.supplier_id = ?
    )
  ''';

  Future<List<SupplierPayable>> payables(String supplierId,
      {int page = 0, bool openOnly = false}) async {
    if (page < 0) throw ArgumentError.value(page, 'page');
    final rows = await db.customSelect('''SELECT * FROM ($_balances)
      ${openOnly ? 'WHERE original > paid + credit' : ''}
      ORDER BY received_at ASC, sequence ASC LIMIT 50 OFFSET ?''', variables: [
      Variable.withString(supplierId), Variable.withInt(page * 50)
    ]).get();
    return [
      for (final row in rows)
        SupplierPayable(
            row.read<String>('id'),
            'RCV-${(row.read<int?>('sequence') ?? 0).toString().padLeft(6, '0')}',
            row.read<String?>('external_reference'),
            DateTime.fromMillisecondsSinceEpoch(row.read<int>('received_at') * 1000),
            DateTime.fromMillisecondsSinceEpoch(row.read<int>('finalized_at') * 1000),
            row.read<int>('original'),
            row.read<int>('paid'),
            row.read<int>('credit'),
            row.read<int>('raw_credit') - row.read<int>('credit'))
    ];
  }

  Future<int> outstanding(String supplierId) async {
    final row = await db.customSelect('''SELECT COALESCE(SUM(MAX(0,
      original - paid - credit)), 0) AS total FROM ($_balances)''',
        variables: [Variable.withString(supplierId)]).getSingle();
    return row.read<int>('total');
  }

  Future<SupplierAgingSummary> aging(String supplierId,
      {DateTime? asOf}) async {
    final day = asOf ?? DateTime.now();
    int start(int daysAgo) => DateTime(day.year, day.month, day.day - daysAgo)
        .millisecondsSinceEpoch ~/ 1000;
    final today = start(0);
    final day30 = start(30), day60 = start(60), day90 = start(90);
    final row = await db.customSelect('''SELECT
      COALESCE(SUM(CASE WHEN finalized_at >= ? THEN MAX(0, original-paid-credit) ELSE 0 END),0) AS current_bucket,
      COALESCE(SUM(CASE WHEN finalized_at < ? AND finalized_at >= ? THEN MAX(0, original-paid-credit) ELSE 0 END),0) AS days_1_30,
      COALESCE(SUM(CASE WHEN finalized_at < ? AND finalized_at >= ? THEN MAX(0, original-paid-credit) ELSE 0 END),0) AS days_31_60,
      COALESCE(SUM(CASE WHEN finalized_at < ? AND finalized_at >= ? THEN MAX(0, original-paid-credit) ELSE 0 END),0) AS days_61_90,
      COALESCE(SUM(CASE WHEN finalized_at < ? THEN MAX(0, original-paid-credit) ELSE 0 END),0) AS days_over_90
      FROM ($_balances)''', variables: [
      Variable.withInt(today), Variable.withInt(today), Variable.withInt(day30),
      Variable.withInt(day30), Variable.withInt(day60),
      Variable.withInt(day60), Variable.withInt(day90), Variable.withInt(day90),
      Variable.withString(supplierId)
    ]).getSingle();
    return SupplierAgingSummary(row.read<int>('current_bucket'),
        row.read<int>('days_1_30'), row.read<int>('days_31_60'),
        row.read<int>('days_61_90'), row.read<int>('days_over_90'));
  }

  Future<SupplierPayableMetrics> metrics(String supplierId) async {
    final balances = await db.customSelect('''SELECT
      COUNT(CASE WHEN original > paid + credit THEN 1 END) AS open_count,
      COALESCE(SUM(credit), 0) AS credits
      FROM ($_balances)''',
        variables: [Variable.withString(supplierId)]).getSingle();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month).millisecondsSinceEpoch ~/ 1000;
    final end = DateTime(now.year, now.month + 1).millisecondsSinceEpoch ~/ 1000;
    final payments = await db.customSelect('''SELECT COALESCE(SUM(amount_cents), 0)
      AS total FROM supplier_payments WHERE supplier_id = ?
      AND paid_at >= ? AND paid_at < ?''', variables: [
      Variable.withString(supplierId), Variable.withInt(start), Variable.withInt(end)
    ]).getSingle();
    return SupplierPayableMetrics(balances.read<int>('open_count'),
        balances.read<int>('credits'), payments.read<int>('total'));
  }

  Future<SupplierPayable?> forReceiving(StockReceiving receipt) async {
    final rows = await db.customSelect('SELECT * FROM ($_balances) WHERE id = ?',
        variables: [Variable.withString(receipt.supplierId),
          Variable.withString(receipt.id)]).get();
    if (rows.isEmpty) return null;
    final row = rows.single;
    return SupplierPayable(receipt.id,
        'RCV-${(receipt.sequence ?? 0).toString().padLeft(6, '0')}',
        receipt.externalReference, receipt.receivedAt,
        receipt.finalizedAt ?? receipt.receivedAt,
        row.read<int>('original'), row.read<int>('paid'), row.read<int>('credit'),
        row.read<int>('raw_credit') - row.read<int>('credit'));
  }

  Future<int> appliedCreditForReturn(PurchaseReturn entry) async {
    if (entry.status != 'finalized' || entry.resolution != 'supplierCredit') {
      return 0;
    }
    final receipt = await (db.select(db.stockReceivings)
          ..where((r) => r.id.equals(entry.receivingId))).getSingle();
    final payable = await forReceiving(receipt);
    if (payable == null) return 0;
    final prior = await db.customSelect('''SELECT COALESCE(SUM(COALESCE(
      credit_amount_cents, (SELECT SUM(return_value_cents)
      FROM purchase_return_lines WHERE purchase_return_id = pr.id))), 0) AS total
      FROM purchase_returns pr WHERE receiving_id = ? AND status = 'finalized'
      AND resolution = 'supplierCredit'
      AND (return_date < ? OR (return_date = ? AND sequence < ?))''',
      variables: [Variable.withString(entry.receivingId),
        Variable.withInt(entry.returnDate.millisecondsSinceEpoch ~/ 1000),
        Variable.withInt(entry.returnDate.millisecondsSinceEpoch ~/ 1000),
        Variable.withInt(entry.sequence)]).getSingle();
    final raw = entry.creditAmountCents ?? (await db.customSelect('''
      SELECT COALESCE(SUM(return_value_cents), 0) AS total
      FROM purchase_return_lines WHERE purchase_return_id = ?''',
      variables: [Variable.withString(entry.id)]).getSingle()).read<int>('total');
    final capacity = payable.originalCents - payable.paidCents - prior.read<int>('total');
    if (capacity <= 0) return 0;
    return raw < capacity ? raw : capacity;
  }

  Future<List<(SupplierPayment, int)>> paymentsForReceiving(String receivingId) async {
    final allocations = await (db.select(db.supplierPaymentAllocations)
          ..where((a) => a.receivingId.equals(receivingId))).get();
    final result = <(SupplierPayment, int)>[];
    for (final allocation in allocations) {
      final payment = await (db.select(db.supplierPayments)
            ..where((p) => p.id.equals(allocation.paymentId))).getSingle();
      result.add((payment, allocation.allocatedCents));
    }
    result.sort((a, b) => a.$1.paidAt.compareTo(b.$1.paidAt));
    return result;
  }

  Future<int> legacyCount(String supplierId) async => (await db.customSelect('''
    SELECT COUNT(*) AS total FROM stock_receivings r
    WHERE r.supplier_id = ?
    AND NOT EXISTS (SELECT 1 FROM supplier_payable_sources s
      WHERE s.receiving_id = r.id)''',
      variables: [Variable.withString(supplierId)]).getSingle()).read<int>('total');

  Future<List<SupplierAllocation>> preview(String supplierId, int amountCents,
      {String? receivingId}) async {
    if (amountCents <= 0) throw StateError('Enter a positive payment amount.');
    final total = await outstanding(supplierId);
    if (amountCents > total) {
      throw StateError("Payment exceeds this supplier's outstanding balance.");
    }
    var left = amountCents;
    final result = <SupplierAllocation>[];
    var page = 0;
    while (left > 0) {
      final rows = await payables(supplierId, page: page, openOnly: true);
      if (rows.isEmpty) break;
      for (final payable in rows) {
        if (receivingId != null && receivingId != payable.receivingId) continue;
        final applied = left < payable.remainingCents ? left : payable.remainingCents;
        if (applied > 0) result.add(SupplierAllocation(payable, applied));
        left -= applied;
        if (left == 0) break;
      }
      page++;
    }
    if (left != 0) throw StateError('Payment exceeds this payable balance.');
    return result;
  }

  Future<SupplierPayment> record(ActiveUser actor, String supplierId,
      int amountCents, String method, DateTime paidAt,
      {String? receivingId, String? notes}) => db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageExpenseFunds);
        if (!const {'cash', 'gcash', 'card', 'other'}.contains(method.toLowerCase())) {
          throw StateError('Select a supported payment method.');
        }
        final allocations = await preview(supplierId, amountCents,
            receivingId: receivingId);
        if (allocations.any((a) => paidAt.isBefore(a.payable.date))) {
          throw StateError('Payment date cannot precede the Receiving date.');
        }
        final session = method.toLowerCase() == 'cash'
            ? await CashSessionRepository(db).active()
            : null;
        if (method.toLowerCase() == 'cash' && session == null) {
          throw StateError('Open a cash session first.');
        }
        if (session != null &&
            await CashSessionRepository(db).expected(session.id) < amountCents) {
          throw StateError('Insufficient drawer cash.');
        }
        final next = (await db.customSelect(
                'SELECT COALESCE(MAX(sequence), 0) + 1 AS next FROM supplier_payments')
            .getSingle()).read<int>('next');
        final payment = await db.into(db.supplierPayments).insertReturning(
            SupplierPaymentsCompanion.insert(
                sequence: next,
                supplierId: supplierId,
                amountCents: amountCents,
                paymentMethod: method.toLowerCase(),
                paidAt: paidAt,
                paidBy: live.id,
                notes: Value(notes?.trim()),
                cashSessionId: Value(session?.id)));
        for (final allocation in allocations) {
          await db.into(db.supplierPaymentAllocations).insert(
              SupplierPaymentAllocationsCompanion.insert(
                  paymentId: payment.id,
                  receivingId: allocation.payable.receivingId,
                  allocatedCents: allocation.cents));
        }
        if (session != null) {
          await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: session.id,
              referenceId: Value(payment.id),
              amountCents: -amountCents,
              kind: 'supplier_payment'));
        }
        await AuthRepository(db).audit(live.id, 'supplier_payment.recorded',
            '${number(payment)}:$supplierId:$amountCents:$method');
        return payment;
      });

  Future<List<SupplierPayment>> payments(String supplierId, {int page = 0}) =>
      (db.select(db.supplierPayments)
            ..where((p) => p.supplierId.equals(supplierId))
            ..orderBy([(p) => OrderingTerm(
                expression: p.paidAt, mode: OrderingMode.desc)])
            ..limit(50, offset: page * 50))
          .get();

  Future<SupplierStatementPage> statementPage(String supplierId,
      DateTime start, DateTime end, {int page = 0}) async {
    if (page < 0 || !start.isBefore(end)) {
      throw ArgumentError('Select a valid statement period.');
    }
    final startSeconds = start.millisecondsSinceEpoch ~/ 1000;
    final endSeconds = end.millisecondsSinceEpoch ~/ 1000;
    final common = [Variable.withString(supplierId), Variable.withString(supplierId)];
    return db.transaction(() async {
      final totals = await db.customSelect('''$_activity
        SELECT
          COALESCE(SUM(CASE WHEN happened_at < ? THEN purchase-settlement ELSE 0 END),0) AS opening,
          COALESCE(SUM(CASE WHEN happened_at >= ? AND happened_at < ? THEN purchase ELSE 0 END),0) AS charges,
          COALESCE(SUM(CASE WHEN happened_at >= ? AND happened_at < ? AND kind = 1 THEN settlement ELSE 0 END),0) AS credits,
          COALESCE(SUM(CASE WHEN happened_at >= ? AND happened_at < ? AND kind = 2 THEN settlement ELSE 0 END),0) AS payments,
          COUNT(CASE WHEN happened_at >= ? AND happened_at < ? THEN 1 END) AS count
        FROM events''', variables: [
        ...common, Variable.withInt(startSeconds),
        Variable.withInt(startSeconds), Variable.withInt(endSeconds),
        Variable.withInt(startSeconds), Variable.withInt(endSeconds),
        Variable.withInt(startSeconds), Variable.withInt(endSeconds),
        Variable.withInt(startSeconds), Variable.withInt(endSeconds),
      ]).getSingle();
      final unapplied = await db.customSelect('''SELECT COALESCE(
        SUM(MAX(0, raw_credit-credit)), 0) AS total FROM ($_balances)''',
        variables: [Variable.withString(supplierId)]).getSingle();
      final rows = await db.customSelect('''$_activity,
        running AS (
          SELECT *, SUM(purchase-settlement) OVER
            (ORDER BY happened_at, kind, ordering ROWS UNBOUNDED PRECEDING)
            AS balance FROM events WHERE happened_at < ?
        )
        SELECT * FROM running WHERE happened_at >= ?
        ORDER BY happened_at, kind, ordering LIMIT 50 OFFSET ?''', variables: [
        ...common, Variable.withInt(endSeconds), Variable.withInt(startSeconds),
        Variable.withInt(page * 50)
      ]).get();
      final summary = SupplierStatementSummary(
          totals.read<int>('opening'), totals.read<int>('charges'),
          totals.read<int>('credits'), totals.read<int>('payments'),
          unapplied.read<int>('total'), totals.read<int>('count'),
          await legacyCount(supplierId));
      return SupplierStatementPage(summary, [
        for (final row in rows)
          SupplierLedgerEntry(
              DateTime.fromMillisecondsSinceEpoch(row.read<int>('happened_at') * 1000),
              row.read<String>('reference'), row.read<String>('type'),
              row.read<int>('purchase'), row.read<int>('settlement'),
              row.read<int>('balance'))
      ], page);
    });
  }

  Future<List<SupplierLedgerEntry>> ledger(String supplierId,
      {int page = 0}) async {
    final rows = await db.customSelect('''$_activity
      SELECT *, SUM(purchase - settlement) OVER
        (ORDER BY happened_at, kind, ordering ROWS UNBOUNDED PRECEDING) AS balance
      FROM events ORDER BY happened_at DESC, kind DESC, ordering DESC
      LIMIT 50 OFFSET ?
    ''', variables: [Variable.withString(supplierId),
      Variable.withString(supplierId), Variable.withInt(page * 50)]).get();
    return [for (final row in rows)
      SupplierLedgerEntry(
          DateTime.fromMillisecondsSinceEpoch(row.read<int>('happened_at') * 1000),
          row.read<String>('reference'), row.read<String>('type'),
          row.read<int>('purchase'), row.read<int>('settlement'),
          row.read<int>('balance'))];
  }
}
