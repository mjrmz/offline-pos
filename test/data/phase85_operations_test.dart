import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/operational_summary_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';

void main() {
  test('operations separates out of stock, low stock and customer debt',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final customer =
        await DirectoryRepository(db).saveCustomer(auth.current!, name: 'Juan');
    final pos = PosRepository(db);
    await pos.saveProduct(name: 'Empty item', priceCents: 100, costCents: 0);
    final product = await pos.saveProduct(
        name: 'Low item',
        priceCents: 100,
        costCents: 0,
        startingStock: 2,
        lowStockThreshold: 3);
    await pos.completeCreditSale(
        [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
    final summary = await OperationalSummaryRepository(db).load();
    expect(summary.outOfStock.single, contains('Empty item'));
    expect(summary.lowStock.single, contains('Low item'));
    expect(summary.outstandingCredit.single.$2, 100);
  });
}
