import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  test('FIFO spans suppliers and keeps cost and price snapshots', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final suppliers = DirectoryRepository(db);
    final a = await suppliers.saveSupplier(actor, name: 'Supplier A');
    final b = await suppliers.saveSupplier(actor, name: 'Supplier B');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(name: 'Mouse', priceCents: 76000,
        costCents: 40000, pricingPolicy: 'layer');
    final receiving = StockReceivingRepository(db);
    await receiving.receive(actor, a.id,
        [ReceivingLineRequest(id, 10000, 50000, unitSellingPriceCents: 70000)]);
    await Future<void>.delayed(const Duration(seconds: 1));
    await receiving.receive(actor, b.id,
        [ReceivingLineRequest(id, 20000, 55000, unitSellingPriceCents: 75000)]);
    expect(await pos.quoteLayerPrice(id, 12000), 850000);
    final sale = await pos.completeCashSale([SaleLineRequest(id, 12)], 850000, ownerId);
    expect(sale.totalCents, 850000);
    final items = await db.select(db.saleItems).get();
    expect(items.map((i) => i.unitPriceCents).toList(), [70000, 75000]);
    expect(items.map((i) => i.quantityMilli).toList(), [10000, 2000]);
    final allocations = await db.select(db.saleItemInventoryAllocations).get();
    expect(allocations.map((a) => a.unitCostSnapshotCents).toList(), [50000, 55000]);
    expect(allocations.map((a) => a.unitSellingPriceSnapshotCents).toList(), [70000, 75000]);
    final layers = await pos.layersForProduct(id);
    expect(layers.map((l) => l.quantityRemainingMilli).toList(), [0, 18000]);
    expect(layers.map((l) => l.receivingItemId).whereType<String>().length, 2);
    await pos.saveProduct(id: id, name: 'Mouse', priceCents: 90000,
        costCents: 60000);
    expect((await db.select(db.saleItems).get()).first.unitPriceCents, 70000);
    expect((await db.select(db.saleItemInventoryAllocations).get())
        .first.unitCostSnapshotCents, 50000);
    expect((await pos.layersForProduct(id)).first.unitCostCents, 50000);
    await expectLater(db.customStatement(
        'UPDATE stock_receiving_items SET unit_cost_cents = 1'),
        throwsA(isA<Exception>()));
    await expectLater(db.customStatement(
        'UPDATE inventory_layers SET unit_cost_cents = 1'),
        throwsA(isA<Exception>()));
    await expectLater(db.customStatement(
        'UPDATE sale_item_inventory_allocations SET unit_cost_snapshot_cents = 1'),
        throwsA(isA<Exception>()));
  });

  test('current price keeps one sale line with two FIFO allocations', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final supplier = await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(name: 'Cable', priceCents: 75000,
        costCents: 50000);
    final receiving = StockReceivingRepository(db);
    await receiving.receive(actor, supplier.id, [ReceivingLineRequest(id, 10000, 50000)]);
    await Future<void>.delayed(const Duration(seconds: 1));
    await receiving.receive(actor, supplier.id, [ReceivingLineRequest(id, 20000, 55000)]);
    final sale = await pos.completeCashSale([SaleLineRequest(id, 12)], 900000, ownerId);
    expect(sale.totalCents, 900000);
    expect((await db.select(db.saleItems).get()).length, 1);
    final allocations = await db.select(db.saleItemInventoryAllocations).get();
    expect(allocations.map((a) => a.quantityMilli).toList(), [10000, 2000]);
    expect(allocations.map((a) => a.unitSellingPriceSnapshotCents).toList(), [75000, 75000]);
    await SalesRepository(db).reverse(actor, sale.saleId, 'void',
        stockRestored: true);
    expect((await pos.layersForProduct(id)).map((l) => l.quantityRemainingMilli).toList(),
        [10000, 20000]);
  });

  test('selected serial uses its own supplier cost and layer price', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final suppliers = DirectoryRepository(db);
    final a = await suppliers.saveSupplier(actor, name: 'A');
    final b = await suppliers.saveSupplier(actor, name: 'B');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(name: 'Laptop', priceCents: 3900000,
        costCents: 3000000, pricingPolicy: 'layer', serialTracking: true);
    final receiving = StockReceivingRepository(db);
    await receiving.receive(actor, a.id, [ReceivingLineRequest(id, 1000,
        3000000, unitSellingPriceCents: 3900000, serialNumbers: ['A1'])]);
    await receiving.receive(actor, b.id, [ReceivingLineRequest(id, 1000,
        3150000, unitSellingPriceCents: 4000000, serialNumbers: ['B1'])]);
    final serial = (await pos.availableSerials(id)).firstWhere((s) => s.serialNumber == 'B1');
    final sale = await pos.completeCashSale(
        [SaleLineRequest(id, 1, serialIds: [serial.id])], 4000000, ownerId);
    expect(sale.totalCents, 4000000);
    final allocation = (await db.select(db.saleItemInventoryAllocations).get()).single;
    expect(allocation.serialUnitId, serial.id);
    expect(allocation.inventoryLayerId, serial.inventoryLayerId);
    expect(allocation.unitCostSnapshotCents, 3150000);
    expect(allocation.unitSellingPriceSnapshotCents, 4000000);
  });

  test('failed sale rolls back layer consumption and allocation', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(name: 'Cable', priceCents: 10000,
        costCents: 5000);
    await StockReceivingRepository(db).receive(auth.current!, supplier.id,
        [ReceivingLineRequest(id, 3000, 5500)]);
    await db.customStatement('CREATE TRIGGER fail_payment BEFORE INSERT ON payments '
        "BEGIN SELECT RAISE(ABORT, 'payment failed'); END");
    await expectLater(pos.completeCashSale([SaleLineRequest(id, 2)], 20000,
        ownerId), throwsA(isA<Exception>()));
    expect(await pos.stockMilli(id), 3000);
    expect((await pos.layersForProduct(id)).single.quantityRemainingMilli, 3000);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.saleItemInventoryAllocations).get(), isEmpty);
  });
}
