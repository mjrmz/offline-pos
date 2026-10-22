import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'dart:io';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';

void main() {
  test('opening serials belong to an opening layer without receiving',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Device',
        priceCents: 350000,
        costCents: 250000,
        pricingPolicy: 'layer',
        serialTracking: true,
        startingStock: 2,
        openingSellingPriceCents: 350000,
        openingSerials: [' SN001 ', 'SN002']);
    final layer = (await pos.layersForProduct(id)).single;
    expect(layer.source, 'opening');
    expect(layer.receivingItemId, isNull);
    expect(layer.unitCostCents, 250000);
    expect(layer.unitSellingPriceCents, 350000);
    final serials = await pos.availableSerials(id);
    expect(serials.map((s) => s.serialNumber).toSet(), {'SN001', 'SN002'});
    expect(
        serials.every(
            (s) => s.inventoryLayerId == layer.id && s.receivingItemId == null),
        isTrue);
    expect(await pos.stockMilli(id), 2000);
    expect((await db.select(db.stockReceivings).get()), isEmpty);
    expect((await pos.movements(id)).single.reason, 'initial_stock');
  });

  test('opening stock rejects missing, repeated, and existing serials',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final pos = PosRepository(db);
    Future<String> save(List<String> serials) => pos.saveProduct(
        name: 'Device',
        priceCents: 1000,
        costCents: 500,
        serialTracking: true,
        startingStock: 2,
        openingSerials: serials);
    await expectLater(save(['ONE']), throwsStateError);
    await expectLater(save(['ONE', 'ONE']), throwsStateError);
    await save(['ONE', 'TWO']);
    await expectLater(save(['ONE', 'THREE']), throwsStateError);
    expect((await pos.products()).length, 1);
  });

  test('multiple opening batches preserve separate layers and lots', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, auth.current!);
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Medicine',
        priceCents: 1000,
        costCents: 500,
        startingStock: 5,
        business: const BusinessProduct(batch: true),
        openingBatches: const [
          OpeningBatch(2000, 'LOT-A', null),
          OpeningBatch(3000, 'LOT-B', null)
        ]);
    expect((await pos.layersForProduct(id)).map((l) => l.batchNumber).toSet(),
        {'LOT-A', 'LOT-B'});
    expect((await pos.batches(id)).map((b) => b.quantityMilli).toList(),
        [2000, 3000]);
    expect(await pos.stockMilli(id), 5000);
  });

  test('weighted opening stock keeps fractional quantity in its layer',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, auth.current!);
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Rice',
        priceCents: 5000,
        costCents: 3000,
        startingStockMilli: 25500,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    expect(await pos.stockMilli(id), 25500);
    expect(
        (await pos.layersForProduct(id)).single.quantityRemainingMilli, 25500);
  });

  test('version 20 serial upgrade retains persisted receiving provenance',
      () async {
    final dir =
        await Directory.systemTemp.createTemp('opening-serial-upgrade-');
    final file = File('${dir.path}/pos.sqlite');
    try {
      final original = AppDatabase.forTesting(NativeDatabase(file));
      final pos = PosRepository(original);
      final id = await pos.saveProduct(
          name: 'Existing',
          priceCents: 1000,
          costCents: 500,
          serialTracking: true);
      final layer = await original
          .into(original.inventoryLayers)
          .insertReturning(InventoryLayersCompanion.insert(
              productId: id,
              source: const Value('receiving'),
              quantityReceivedMilli: 1000,
              quantityRemainingMilli: 1000,
              unitCostCents: 500));
      final serial = await original.into(original.serialUnits).insertReturning(
          SerialUnitsCompanion.insert(
              productId: id,
              serialNumber: 'OLD-SN',
              receivingItemId: const Value(null),
              inventoryLayerId: Value(layer.id)));
      await original.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 20');
      raw.dispose();
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      try {
        final units = await upgraded.select(upgraded.serialUnits).get();
        expect(units.single.id, serial.id);
        expect(units.single.inventoryLayerId, layer.id);
        await upgraded.into(upgraded.serialUnits).insert(
            SerialUnitsCompanion.insert(
                productId: id,
                serialNumber: 'OPEN-SN',
                receivingItemId: const Value(null),
                inventoryLayerId: Value(layer.id)));
      } finally {
        await upgraded.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('opening layer sells first by FIFO and exact opening serial allocates',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final normal = await pos.saveProduct(
        name: 'Cable', priceCents: 1000, costCents: 400, startingStock: 2);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await StockReceivingRepository(db).receive(
        auth.current!, supplier.id, [ReceivingLineRequest(normal, 2000, 500)]);
    await pos.completeCashSale([SaleLineRequest(normal, 3)], 3000, owner);
    final layers = await pos.layersForProduct(normal);
    expect(layers.map((l) => l.quantityRemainingMilli).toList(), [0, 1000]);
    final allocations = await db.select(db.saleItemInventoryAllocations).get();
    expect(
        allocations.map((a) => a.unitCostSnapshotCents).toList(), [400, 500]);

    final serialized = await pos.saveProduct(
        name: 'Board',
        priceCents: 2000,
        costCents: 1000,
        serialTracking: true,
        startingStock: 2,
        openingSerials: ['S1', 'S2']);
    final chosen = (await pos.availableSerials(serialized))
        .firstWhere((s) => s.serialNumber == 'S2');
    final serializedSale = await pos.completeCashSale([
      SaleLineRequest(serialized, 1, serialIds: [chosen.id])
    ], 2000, owner);
    final allAllocations =
        await db.select(db.saleItemInventoryAllocations).get();
    expect(allAllocations.last.serialUnitId, chosen.id);
    expect(allAllocations.last.inventoryLayerId, chosen.inventoryLayerId);
    await SalesRepository(db).reverse(auth.current!, serializedSale.saleId,
        'void', stockRestored: true);
    expect((await pos.availableSerials(serialized)).map((s) => s.id),
        contains(chosen.id));
  });
}
