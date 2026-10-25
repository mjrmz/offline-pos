import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/receivables_reporting_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/customer_statement_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ReceivablesReportingRepository reports;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    reports = ReceivablesReportingRepository(db);
  });
  tearDown(() => db.close());

  Future<void> entry(String kind, int cents, DateTime at,
      {String? saleId, String? reference}) async {
    await db.into(db.customerCreditEntries).insert(
        CustomerCreditEntriesCompanion.insert(
            customerId: 'c',
            userId: 'u',
            amountCents: cents,
            kind: kind,
            saleId: Value(saleId),
            reference: Value(reference),
            createdAt: Value(at)));
  }

  Future<Sale> sale(String ref, DateTime at, int cents) async {
    final row = await db.into(db.sales).insertReturning(SalesCompanion.insert(
        cashierId: 'u',
        customerId: const Value('c'),
        totalCents: cents,
        receiptNumber: Value(ref),
        createdAt: Value(at)));
    await entry('credit_sale', cents, at, saleId: row.id);
    return row;
  }

  setUp(() async {
    await db.into(db.users).insert(UsersCompanion.insert(
        id: const Value('u'), name: 'Owner', role: 'owner'));
    await db.into(db.customers).insert(
        CustomersCompanion.insert(id: const Value('c'), name: 'Customer'));
  });

  test('five aging buckets sum to outstanding after partial payment', () async {
    final asOf = DateTime(2026, 10, 24);
    for (final (i, age) in [0, 10, 45, 75, 120].indexed) {
      await sale('POS-${i + 1}', asOf.subtract(Duration(days: age)), 10000);
    }
    await entry('payment', -4000, asOf, reference: 'CPAY-000001');
    final aged = await reports.aging('c', asOf: asOf);
    expect(aged.buckets.values.toList(), [10000, 10000, 10000, 10000, 6000]);
    expect(aged.totalCents, 46000);
    expect(aged.totalCents,
        (await CustomerCreditRepository(db).snapshot('c')).outstandingCents);
  });

  test('statement opening, charges, payments and adjustment reconcile',
      () async {
    await sale('POS-OLD', DateTime(2026, 9, 20), 20000);
    final current = await sale('POS-NEW', DateTime(2026, 10, 2), 10000);
    await entry('payment', -5000, DateTime(2026, 10, 10),
        reference: 'CPAY-000001');
    await entry('item_refund_reversal', -2000, DateTime(2026, 10, 15),
        saleId: current.id);
    final summary = await reports.statementSummary(
        'c', DateTime(2026, 10, 1), DateTime(2026, 11, 1));
    expect([
      summary.openingCents,
      summary.chargesCents,
      summary.paymentsCents,
      summary.adjustmentsCents,
      summary.closingCents
    ], [
      20000,
      10000,
      5000,
      2000,
      23000
    ]);
    final page = await reports.statementPage(
        'c', DateTime(2026, 10, 1), DateTime(2026, 11, 1));
    expect(
        page.lines.map((r) => r.balanceCents).toList(), [30000, 25000, 23000]);
    expect(page.lines.last.description, 'Return adjustment');
    expect(page.lines.last.reference, 'POS-NEW');
    final custom = await reports.statementSummary(
        'c', DateTime(2026, 10, 10), DateTime(2026, 10, 16));
    expect(custom.openingCents, 30000);
    expect(custom.closingCents, 23000);
  });

  test('page 2 running balance includes prior 50 rows', () async {
    final start = DateTime(2026, 10, 1);
    for (var i = 0; i < 55; i++) {
      await sale('POS-${i.toString().padLeft(3, '0')}',
          start.add(Duration(minutes: i)), 100);
    }
    final page =
        await reports.statementPage('c', start, DateTime(2026, 11, 1), page: 1);
    expect(page.summary.count, 55);
    expect(page.lines.length, 5);
    expect(page.lines.first.balanceCents, 5100);
    expect(page.lines.last.balanceCents, 5500);
  });

  test('voided sale is removed from aging after reversal entry', () async {
    final row = await sale('POS-VOID', DateTime(2026, 10, 1), 10000);
    await (db.update(db.sales)..where((s) => s.id.equals(row.id)))
        .write(const SalesCompanion(status: Value('voided')));
    await entry('sale_reversal', -10000, DateTime(2026, 10, 2), saleId: row.id);
    expect(
        (await reports.aging('c', asOf: DateTime(2026, 10, 24))).totalCents, 0);
  });

  test('printable statement uses ledger facts without changing sales',
      () async {
    final saleRow = await sale('POS-PRINT', DateTime(2026, 10, 2), 2500);
    await entry('payment', -500, DateTime(2026, 10, 3),
        reference: 'CPAY-000001');
    final bytes = await CustomerStatementPdf(db)
        .render('c', DateTime(2026, 10, 1), DateTime(2026, 11, 1));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect((await db.select(db.sales).get()).single.totalCents, 2500);
    expect((await db.select(db.sales).get()).single.id, saleRow.id);
  });
}
