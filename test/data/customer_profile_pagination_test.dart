import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/loyalty_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  test('credit activity pages at 50 without changing its balance', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    for (var index = 0; index < 51; index++) {
      await db.into(db.customerCreditEntries).insert(
          CustomerCreditEntriesCompanion.insert(
              customerId: customer.id,
              userId: auth.current!.id,
              amountCents: 100,
              kind: 'credit_sale'));
    }
    final repository = CustomerCreditRepository(db);
    final summary = await repository.activitySummary(customer.id);
    expect(summary.total, 51);
    expect(summary.creditSales, 51);
    expect(await repository.balance(customer.id), 5100);
    expect((await repository.entriesPage(customer.id, 0)).length, 50);
    expect((await repository.entriesPage(customer.id, 1)).length, 1);
    final sale = await db.into(db.sales).insertReturning(SalesCompanion.insert(
        cashierId: auth.current!.id,
        customerId: Value(customer.id),
        receiptNumber: const Value('POS-000008'),
        totalCents: 500));
    final linked = await db.into(db.customerCreditEntries).insertReturning(
        CustomerCreditEntriesCompanion.insert(
            customerId: customer.id,
            userId: auth.current!.id,
            saleId: Value(sale.id),
            amountCents: 500,
            kind: 'credit_sale'));
    expect((await repository.saleReferences([linked]))[sale.id], 'POS-000008');
  });

  test('rewards ledger pages at 50 with correct running balances', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    for (var index = 0; index < 51; index++) {
      await db.customStatement('''
        INSERT INTO loyalty_ledger
          (id, customer_id, kind, points_delta, created_at)
        VALUES (?, ?, 'earn', 1, ?)
      ''', ['ledger-$index', customer.id, 1800000000 + index]);
    }
    final repository = LoyaltyRepository(db);
    final summary = await repository.ledgerSummary(customer.id);
    expect(summary.count, 51);
    expect(summary.earned, 51);
    final first = await repository.ledgerPage(customer.id, 0);
    final second = await repository.ledgerPage(customer.id, 1);
    expect(first.length, 50);
    expect(second.length, 1);
    expect(first.first.balance, 51);
    expect(second.single.balance, 1);
  });
}
