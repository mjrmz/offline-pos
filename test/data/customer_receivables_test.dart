import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;
  late ActiveUser owner;
  late Customer customer;
  late CustomerCreditRepository credit;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    owner = auth.current!;
    customer =
        await DirectoryRepository(db).saveCustomer(owner, name: 'Customer');
    credit = CustomerCreditRepository(db);
  });
  tearDown(() => db.close());

  Future<Sale> charge(int cents, String ref, DateTime at) async {
    final sale = await db.into(db.sales).insertReturning(SalesCompanion.insert(
        cashierId: owner.id,
        customerId: Value(customer.id),
        totalCents: cents,
        receiptNumber: Value(ref),
        createdAt: Value(at)));
    await db.into(db.customerCreditEntries).insert(
        CustomerCreditEntriesCompanion.insert(
            customerId: customer.id,
            saleId: Value(sale.id),
            userId: owner.id,
            amountCents: cents,
            kind: 'credit_sale',
            createdAt: Value(at)));
    return sale;
  }

  test(
      'partial and full cash payments allocate oldest first without changing sale',
      () async {
    final first = await charge(50000, 'POS-000001', DateTime(2026, 1, 1));
    final second = await charge(70000, 'POS-000002', DateTime(2026, 1, 2));
    await charge(100000, 'POS-000003', DateTime(2026, 1, 3));
    final cash = CashSessionRepository(db);
    final session = await cash.open(owner, 10000);
    final payment = await credit.payment(owner, customer.id, 90000, 'cash');
    expect(payment.reference, 'CPAY-000001');
    final state = await credit.snapshot(customer.id);
    expect(state.outstandingCents, 130000);
    expect(
        state.sales.map((s) => s.remainingCents).toList(), [0, 30000, 100000]);
    expect(state.sales[1].status, 'Partially paid');
    expect(
        (await db.select(db.customerCreditPaymentAllocations).get())
            .map((a) => a.amountCents)
            .toList(),
        [50000, 40000]);
    expect(await cash.expected(session.id), 100000);
    expect(
        (await db.select(db.sales).get())
            .firstWhere((s) => s.id == first.id)
            .totalCents,
        50000);
    await credit.payment(owner, customer.id, 30000, 'gcash', saleId: second.id);
    expect((await credit.snapshot(customer.id)).sales[1].remainingCents, 0);
    await credit.payment(owner, customer.id, 100000, 'gcash');
    expect((await credit.snapshot(customer.id)).outstandingCents, 0);
    expect(await cash.expected(session.id), 100000);
    expect((await db.select(db.cashMovements).get()).length, 1);
  });

  test('overpayment and missing cash session roll back payment and audit',
      () async {
    await charge(10000, 'POS-000001', DateTime(2026, 1, 1));
    await expectLater(
        credit.payment(owner, customer.id, 10001, 'gcash'), throwsStateError);
    await expectLater(
        credit.payment(owner, customer.id, 5000, 'cash'), throwsStateError);
    expect((await db.select(db.customerCreditEntries).get()).length, 1);
    expect(await db.select(db.customerCreditPaymentAllocations).get(), isEmpty);
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'customer_credit.payment'),
        isEmpty);
  });

  test('allocation failure rolls back payment, drawer movement and audit',
      () async {
    await charge(10000, 'POS-000001', DateTime(2026, 1, 1));
    await CashSessionRepository(db).open(owner, 0);
    await db.customStatement(
        'CREATE TRIGGER reject_credit_allocation BEFORE INSERT ON customer_credit_payment_allocations BEGIN SELECT RAISE(ABORT, \'allocation rejected\'); END');
    await expectLater(
        credit.payment(owner, customer.id, 5000, 'cash'), throwsException);
    expect((await db.select(db.customerCreditEntries).get()).length, 1);
    expect(await db.select(db.customerCreditPaymentAllocations).get(), isEmpty);
    expect(await db.select(db.cashMovements).get(), isEmpty);
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'customer_credit.payment'),
        isEmpty);
  });

  test('posting rechecks a balance reduced after preview', () async {
    await charge(10000, 'POS-000001', DateTime(2026, 1, 1));
    final before = await credit.snapshot(customer.id);
    expect(before.outstandingCents, 10000);
    await credit.payment(owner, customer.id, 8000, 'gcash');
    await expectLater(
        credit.payment(owner, customer.id, 5000, 'gcash'), throwsStateError);
    expect((await credit.snapshot(customer.id)).outstandingCents, 2000);
  });

  test('legacy pooled payment is allocated virtually and limit is optional',
      () async {
    await charge(10000, 'POS-000001', DateTime(2026, 1, 1));
    await charge(20000, 'POS-000002', DateTime(2026, 1, 2));
    await db.into(db.customerCreditEntries).insert(
        CustomerCreditEntriesCompanion.insert(
            customerId: customer.id,
            userId: owner.id,
            amountCents: -15000,
            kind: 'payment',
            paymentMethod: const Value('gcash')));
    await credit.setCreditLimit(owner, customer.id, 50000);
    final state = await credit.snapshot(customer.id);
    expect(state.sales.map((s) => s.remainingCents).toList(), [0, 15000]);
    expect(state.availableCents, 35000);
  });

  test('reversal and void state do not leave collectible sale balance',
      () async {
    final sale = await charge(10000, 'POS-000001', DateTime(2026, 1, 1));
    await (db.update(db.sales)..where((s) => s.id.equals(sale.id)))
        .write(const SalesCompanion(status: Value('voided')));
    await db.into(db.customerCreditEntries).insert(
        CustomerCreditEntriesCompanion.insert(
            customerId: customer.id,
            saleId: Value(sale.id),
            userId: owner.id,
            amountCents: -10000,
            kind: 'sale_reversal'));
    expect((await credit.snapshot(customer.id)).outstandingCents, 0);
  });

  test('staff without customer credit permission cannot post', () async {
    await charge(10000, 'POS-000001', DateTime(2026, 1, 1));
    final role =
        await auth.createRole('Reports only', '', {PosPermission.reports});
    final staffId =
        await auth.createUserWithRole('Staff', role, 'staffPassword123');
    final staff = await auth.repository.requireActive(staffId);
    await expectLater(
        credit.payment(staff, customer.id, 1000, 'gcash'), throwsStateError);
  });
}
