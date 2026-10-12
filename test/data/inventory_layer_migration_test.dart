import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('v19 backfill preserves stock and marks unresolved opening quantity', () async {
    final dir = await Directory.systemTemp.createTemp('inventory-layer-migration-');
    final file = File('${dir.path}/pos.sqlite');
    final original = AppDatabase.forTesting(NativeDatabase(file));
    final auth = AuthService(AuthRepository(original));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final supplier = await DirectoryRepository(original)
        .saveSupplier(actor, name: 'Supplier');
    final pos = PosRepository(original);
    final product = await pos.saveProduct(name: 'Legacy mouse',
        priceCents: 70000, costCents: 50000, startingStock: 5);
    await StockReceivingRepository(original).receive(actor, supplier.id,
        [ReceivingLineRequest(product, 10000, 55000)]);
    expect(await pos.stockMilli(product), 15000);
    await original.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE sale_item_inventory_allocations');
    raw.execute('DROP TABLE inventory_layers');
    raw.execute('PRAGMA user_version = 19');
    raw.dispose();
    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await PosRepository(migrated).stockMilli(product), 15000);
      final layers = await PosRepository(migrated).layersForProduct(product);
      expect(layers.map((l) => l.quantityRemainingMilli).reduce((a, b) => a + b), 15000);
      expect(layers.where((l) => l.source == 'receiving').single.quantityRemainingMilli, 10000);
      expect(layers.where((l) => l.source == 'legacy_opening').single.quantityRemainingMilli, 5000);
      expect(layers.where((l) => l.source == 'legacy_opening').single.receivingItemId, null);
      expect(layers.where((l) => l.source == 'receiving').single.unitCostCents, 55000);
    } finally {
      await migrated.close();
      await dir.delete(recursive: true);
    }
  });

  test('v19 backfill follows surviving batches and serial identities', () async {
    final dir = await Directory.systemTemp.createTemp('inventory-tracking-migration-');
    final file = File('${dir.path}/pos.sqlite');
    final original = AppDatabase.forTesting(NativeDatabase(file));
    final auth = AuthService(AuthRepository(original));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final supplier = await DirectoryRepository(original)
        .saveSupplier(actor, name: 'Supplier');
    final pos = PosRepository(original);
    await BusinessFeatureRepository(original)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, actor);
    final batch = await pos.saveProduct(name: 'Milk', priceCents: 10000,
        costCents: 5000, business: const BusinessProduct(batch: true));
    final serial = await pos.saveProduct(name: 'Device', priceCents: 50000,
        costCents: 30000, serialTracking: true);
    final receiving = StockReceivingRepository(original);
    await receiving.receive(actor, supplier.id, [
      ReceivingLineRequest(batch, 10000, 5000, batchNumber: 'A'),
      ReceivingLineRequest(serial, 1000, 30000, serialNumbers: ['S-A']),
    ]);
    await receiving.receive(actor, supplier.id, [
      ReceivingLineRequest(batch, 20000, 5500, batchNumber: 'B'),
      ReceivingLineRequest(serial, 1000, 31000, serialNumbers: ['S-B']),
    ]);
    final lotA = (await pos.batches(batch)).firstWhere((b) => b.batchNumber == 'A');
    final serialA = (await pos.availableSerials(serial))
        .firstWhere((s) => s.serialNumber == 'S-A');
    await pos.completeCashSale([
      SaleLineRequest(batch, 5, batchId: lotA.id),
      SaleLineRequest(serial, 1, serialIds: [serialA.id]),
    ], 100000, ownerId);
    await original.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE sale_item_inventory_allocations');
    raw.execute('DROP TABLE inventory_layers');
    raw.execute('PRAGMA user_version = 19');
    raw.dispose();
    final migrated = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final batches = await PosRepository(migrated).layersForProduct(batch);
      expect(batches.firstWhere((l) => l.batchNumber == 'A').quantityRemainingMilli, 5000);
      expect(batches.firstWhere((l) => l.batchNumber == 'B').quantityRemainingMilli, 20000);
      final serialLayers = await PosRepository(migrated).layersForProduct(serial);
      final serials = await migrated.select(migrated.serialUnits).get();
      expect(serialLayers.firstWhere((l) => l.id == serials.firstWhere((s) => s.serialNumber == 'S-A').inventoryLayerId)
          .quantityRemainingMilli, 0);
      expect(serialLayers.firstWhere((l) => l.id == serials.firstWhere((s) => s.serialNumber == 'S-B').inventoryLayerId)
          .quantityRemainingMilli, 1000);
    } finally {
      await migrated.close();
      await dir.delete(recursive: true);
    }
  });
}
