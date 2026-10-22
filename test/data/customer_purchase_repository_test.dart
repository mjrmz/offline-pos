import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_purchase_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('customer purchase dates and 50-row SQL pages', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    final second = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Other');
    final day = DateTime(2026, 10, 19, 12);
    for (var index = 0; index < 51; index++) {
      await db.into(db.sales).insert(SalesCompanion.insert(
          cashierId: auth.current!.id,
          customerId: Value(customer.id),
          totalCents: 1000,
          createdAt: Value(day.add(Duration(minutes: index)))));
    }
    await db.into(db.sales).insert(SalesCompanion.insert(
        cashierId: auth.current!.id,
        customerId: Value(second.id),
        totalCents: 9000,
        createdAt: Value(day)));
    final repo = CustomerPurchaseRepository(db);
    final from = DateTime(2026, 10, 19);
    final until = DateTime(2026, 10, 20);
    final summary = await repo.summary(customer.id, from, until);
    expect(summary.count, 51);
    expect(summary.netCents, 51000);
    final firstPage = await repo.page(customer.id, from, until, 0);
    expect(firstPage.length, 50);
    expect((await repo.page(customer.id, from, until, 1)).length, 1);
    await db.customStatement('''INSERT INTO sale_returns
      (id, reference, original_sale_id, actor_id, kind, status, reason,
       refund_value_cents, created_at)
      VALUES (?, ?, ?, ?, 'refund', 'finalized', 'Customer return', ?, ?)''',
      ['returned-1', 'RET-1', firstPage.first.id, auth.current!.id,
       250, day.millisecondsSinceEpoch ~/ 1000]);
    await db.customStatement('''INSERT INTO sale_returns
      (id, reference, original_sale_id, actor_id, kind, status, reason,
       refund_value_cents, created_at)
      VALUES (?, ?, ?, ?, 'refund', 'draft', 'Pending return', ?, ?)''',
      ['returned-2', 'RET-2', firstPage.first.id, auth.current!.id,
       500, day.millisecondsSinceEpoch ~/ 1000]);
    final returned = await repo.returnedValues(firstPage);
    expect(returned[firstPage.first.id], 250);
    expect(returned.length, 1);
    expect((await repo.summary(customer.id, from, until)).netCents, 50750);
    expect(
        (await repo.summary(customer.id, until, DateTime(2026, 10, 21))).count,
        0);
  });
}
