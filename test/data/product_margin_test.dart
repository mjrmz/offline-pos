import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/product_margin_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  test('margin states preserve unknown cost and zero-price percentage', () {
    final positive = ProductMarginContext(10000, null, 7000, 'current');
    expect(positive.estimatedUnitMarginCents, 3000);
    expect(positive.estimatedMarginPercent, 30);
    final zero = ProductMarginContext(7000, null, 7000, 'current');
    expect(zero.estimatedUnitMarginCents, 0);
    final negative = ProductMarginContext(6000, null, 7000, 'current');
    expect(negative.estimatedUnitMarginCents, -1000);
    final unknown = ProductMarginContext(6000, null, null, 'current');
    expect(unknown.estimatedUnitMarginCents, isNull);
    expect(unknown.estimatedMarginPercent, isNull);
    final free = ProductMarginContext(0, null, 7000, 'current');
    expect(free.estimatedUnitMarginCents, -7000);
    expect(free.estimatedMarginPercent, isNull);
  });

  test('catalog price history excludes unchanged and cost-only edits', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(name: 'Rice', priceCents: 65000,
        costCents: 40000, actorId: ownerId);
    await pos.saveProduct(id: id, name: 'Rice premium', priceCents: 65000,
        costCents: 42000, actorId: ownerId);
    expect(await db.select(db.priceHistory).get(), isEmpty);
    await pos.saveProduct(id: id, name: 'Rice premium', priceCents: 69900,
        costCents: 42000, actorId: ownerId);
    final history = await ProductMarginRepository(db).history(auth.current!, id);
    expect(history, hasLength(1));
    expect(history.single.oldPriceCents, 65000);
    expect(history.single.newPriceCents, 69900);
    expect(history.single.userId, ownerId);
  });

  test('current costs use receiving and active FIFO layers', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final pos = PosRepository(db);
    final id = await pos.saveProduct(name: 'Cable', priceCents: 10000,
        costCents: 1000, startingStock: 1, openingCostCents: 4000);
    final margin = ProductMarginRepository(db);
    var context = await margin.context(actor, id);
    expect(context.lastReceivingCostCents, isNull);
    expect(context.nextFifoCostCents, 4000);
    final supplier = await DirectoryRepository(db).saveSupplier(actor,
        name: 'Supplier');
    await StockReceivingRepository(db).receive(actor, supplier.id,
        [ReceivingLineRequest(id, 2000, 5000)]);
    context = await margin.context(actor, id);
    expect(context.lastReceivingCostCents, 5000);
    expect(context.nextFifoCostCents, 4000);
    expect(context.estimatedUnitMarginCents, 6000);
    expect(context.estimatedMarginPercent, 60);
    expect(await margin.expectedCost(actor, id, 3000), 14000);
    expect(await margin.expectedCost(actor, id, 4000), isNull);
    expect(() => ProductMarginRepository.requireVisibility(
        const ActiveUser('cashier', 'Cashier', UserRole.cashier)),
        throwsStateError);
  });
}
