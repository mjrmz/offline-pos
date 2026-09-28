import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/services/sale_service.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  late AppDatabase db;
  late PosRepository repo;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = PosRepository(db);
  });
  tearDown(() => db.close());

  test('barcode, category, initial stock, checkout and historical snapshot',
      () async {
    final category = await repo.addCategory('Drinks');
    final id = await repo.saveProduct(
        name: 'Coca-Cola 500ml',
        sku: 'COKE-500',
        barcode: '480000000001',
        categoryId: category,
        priceCents: 4000,
        costCents: 2000,
        startingStock: 10);
    expect((await repo.categories()).single.name, 'Drinks');
    expect(await repo.stock(id), 10);
    expect((await repo.movements(id)).single.quantityDelta, 10);
    expect((await repo.barcode('480000000001'))?.id, id);
    expect(await repo.barcode('missing'), isNull);
    await expectLater(
        repo.saveProduct(
            name: 'Duplicate',
            barcode: '480000000001',
            priceCents: 100,
            costCents: 0),
        throwsStateError);
    final cart = Cart()
      ..add((await repo.barcode('480000000001'))!)
      ..add((await repo.barcode('480000000001'))!);
    final result = await SaleService(repo).checkout(cart, 10000);
    expect(result.totalCents, 8000);
    expect(result.changeCents, 2000);
    expect(cart.isEmpty, true);
    expect(await repo.stock(id), 8);
    expect((await repo.movements(id)).map((m) => m.quantityDelta),
        containsAll([10, -2]));
    expect((await db.select(db.sales).get()).single.totalCents, 8000);
    final item = (await db.select(db.saleItems).get()).single;
    expect(item.quantity, 2);
    expect(item.unitPriceCents, 4000);
    expect(item.lineTotalCents, 8000);
    expect((await db.select(db.payments).get()).single.amountCents, 8000);
    await repo.saveProduct(
        id: id,
        name: 'Coca-Cola 500ml',
        sku: 'COKE-500',
        barcode: '480000000001',
        categoryId: category,
        priceCents: 4500,
        costCents: 2000);
    expect((await db.select(db.saleItems).get()).single.unitPriceCents, 4000);
  });

  test('failed checkout keeps cart and writes nothing', () async {
    final id = await repo.saveProduct(
        name: 'Coke', priceCents: 4000, costCents: 0, startingStock: 8);
    final cart = Cart()..add((await repo.products()).single);
    cart.setQuantity(id, 9);
    await expectLater(
        SaleService(repo).checkout(cart, 40000), throwsStateError);
    expect(cart.lines.single.quantity, 9);
    expect(await repo.stock(id), 8);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.saleItems).get(), isEmpty);
    expect(await db.select(db.payments).get(), isEmpty);
    expect((await repo.movements(id)).length, 1);
    cart.setQuantity(id, 2);
    await expectLater(SaleService(repo).checkout(cart, 5000), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    cart.clear();
    await expectLater(SaleService(repo).checkout(cart, 0), throwsStateError);
  });

  test('inactive product rejected at lookup and transaction', () async {
    final id = await repo.saveProduct(
        name: 'Coke',
        barcode: 'abc',
        priceCents: 4000,
        costCents: 0,
        startingStock: 2);
    final cart = Cart()..add((await repo.barcode('abc'))!);
    await repo.saveProduct(
        id: id,
        name: 'Coke',
        barcode: 'abc',
        priceCents: 4000,
        costCents: 0,
        isActive: false);
    await expectLater(repo.barcode('abc'), throwsStateError);
    await expectLater(SaleService(repo).checkout(cart, 4000), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
  });

  test('payment insert failure rolls back sale, items, stock and movement',
      () async {
    final id = await repo.saveProduct(
        name: 'Coke', priceCents: 4000, costCents: 0, startingStock: 10);
    final cart = Cart()..add((await repo.products()).single);
    await db.customStatement(
        "CREATE TRIGGER fail_payment BEFORE INSERT ON payments BEGIN SELECT RAISE(ABORT, 'forced failure'); END");
    await expectLater(SaleService(repo).checkout(cart, 4000), throwsException);
    expect(cart.isEmpty, false);
    expect(await repo.stock(id), 10);
    expect((await repo.movements(id)).length, 1);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.saleItems).get(), isEmpty);
    expect(await db.select(db.payments).get(), isEmpty);
  });

  test('concurrent duplicate submission is rejected', () async {
    final id = await repo.saveProduct(
        name: 'Coke', priceCents: 4000, costCents: 0, startingStock: 2);
    final cart = Cart()..add((await repo.products()).single);
    final gate = Completer<void>();
    final delayed = _DelayedRepository(db, gate);
    final service = SaleService(delayed);
    final first = service.checkout(cart, 4000);
    await expectLater(service.checkout(cart, 4000), throwsStateError);
    gate.complete();
    await first;
    expect(await repo.stock(id), 1);
    expect((await db.select(db.sales).get()).length, 1);
  });

  test('core rejects zero and insufficient cash without any sale writes',
      () async {
    final id = await repo.saveProduct(
        name: 'Coke', priceCents: 4000, costCents: 0, startingStock: 10);
    final cart = Cart()..add((await repo.products()).single);
    final service = SaleService(repo);
    await expectLater(service.checkout(cart, 0), throwsStateError);
    await expectLater(service.checkout(cart, -1), throwsStateError);
    await expectLater(service.checkout(cart, 3999), throwsStateError);
    expect(cart.isEmpty, false);
    expect(await repo.stock(id), 10);
    expect((await repo.movements(id)).length, 1);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.saleItems).get(), isEmpty);
    expect(await db.select(db.payments).get(), isEmpty);
  });
}

class _DelayedRepository extends PosRepository {
  final Completer<void> gate;
  _DelayedRepository(super.db, this.gate);
  @override
  Future<CommittedSale> completeCashSale(
      List<SaleLineRequest> items, int cashReceivedCents) async {
    await gate.future;
    return super.completeCashSale(items, cashReceivedCents);
  }
}
