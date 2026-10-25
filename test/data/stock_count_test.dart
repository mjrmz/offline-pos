import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';

void main() {
  late AppDatabase db;
  late PosRepository pos;
  late StockCountRepository counts;
  late ActiveUser owner;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    pos = PosRepository(db);
    counts = StockCountRepository(db);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    owner = auth.current!;
  });
  tearDown(() async => db.close());

  test(
      'count snapshots blank and zero distinctly; finalize posts only variance',
      () async {
    final a = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 10);
    final b = await pos.saveProduct(
        name: 'B', priceCents: 1000, costCents: 500, startingStock: 3);
    final c = await counts.createCount(owner);
    expect(c.reference, 'SC-000001');
    final lines = await counts.lines(c.id);
    final first = lines.singleWhere((l) => l.productId == a);
    expect(first.expectedMilli, 10000);
    expect(first.countedMilli, isNull);
    await counts.setCount(owner, first.id, null, notes: 'Back shelf checked');
    await counts.setCount(owner, first.id, 0);
    expect(
        (await counts.lines(c.id)).singleWhere((l) => l.productId == a).notes,
        'Back shelf checked');
    await counts.setCount(
        owner, lines.singleWhere((l) => l.productId == b).id, 3000);
    expect(
        (await counts.lines(c.id))
            .singleWhere((l) => l.productId == a)
            .countedMilli,
        0);
    await counts.finalize(owner, c.id);
    expect(await pos.stockMilli(a), 0);
    expect(await pos.stockMilli(b), 3000);
    expect((await counts.adjustments()).single.deltaMilli, -10000);
    expect((await counts.adjustments()).single.reference, 'ADJ-000001');
    expect((await counts.counts()).single.status, 'finalized');
    await expectLater(counts.finalize(owner, c.id), throwsStateError);
    expect((await counts.adjustments()).length, 1);
  });

  test('cancelled count retains history without stock or movement change',
      () async {
    final id = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 2);
    final before = (await pos.movements(id)).length;
    final count = await counts.createCount(owner);
    await counts.setCount(owner, (await counts.lines(count.id)).single.id, 0);
    await counts.cancel(owner, count.id);
    expect((await counts.counts()).single.status, 'cancelled');
    expect(await pos.stockMilli(id), 2000);
    expect((await pos.movements(id)).length, before);
    expect(await counts.adjustments(), isEmpty);
    await expectLater(counts.finalize(owner, count.id), throwsStateError);
  });

  test('FIFO adjustment preserves allocation costs and positive origin',
      () async {
    final a = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 50, startingStock: 5);
    await counts.adjust(
        owner, AdjustmentRequest(a, 5000, 'Stock found', unitCostCents: 70));
    final down =
        await counts.adjust(owner, AdjustmentRequest(a, -7000, 'Lost'));
    final allocations =
        await (db.select(db.inventoryAdjustmentAllocations)).get();
    final used = allocations.where((x) => x.adjustmentId == down.id).toList();
    expect(used.map((x) => x.quantityMilli), [5000, 2000]);
    expect(used.map((x) => x.unitCostCents), [50, 70]);
    expect(await pos.stockMilli(a), 3000);
    expect(
        (await db.select(db.inventoryLayers).get())
            .where((l) => l.source == 'adjustment')
            .single
            .quantityRemainingMilli,
        3000);
    expect((await pos.movements(a)).last.reason, 'stock_adjustment_decrease');
    await expectLater(counts.adjust(owner, AdjustmentRequest(a, -4000, 'Lost')),
        throwsStateError);
    expect(await pos.stockMilli(a), 3000);
  });

  test('negative adjustment leaves historical sale COGS unchanged', () async {
    final id = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 10);
    await pos.completeCashSale([SaleLineRequest(id, 2)], 2000, owner.id);
    final saleAllocation =
        (await db.select(db.saleItemInventoryAllocations).get()).single;
    expect(saleAllocation.unitCostSnapshotCents, 500);
    await counts.adjust(owner, AdjustmentRequest(id, -3000, 'Lost'));
    expect(
        (await db.select(db.saleItemInventoryAllocations).get())
            .single
            .unitCostSnapshotCents,
        500);
    expect(await pos.stockMilli(id), 5000);
    await pos.completeCashSale([SaleLineRequest(id, 5)], 5000, owner.id);
    expect(
        (await db.select(db.saleItemInventoryAllocations).get())
            .every((a) => a.unitCostSnapshotCents == 500),
        isTrue);
  });

  test('existing product cannot directly set stock quantity', () async {
    final id = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 2);
    await expectLater(
        pos.saveProduct(
            id: id,
            name: 'A',
            priceCents: 1000,
            costCents: 500,
            startingStock: 8),
        throwsStateError);
    expect(await pos.stockMilli(id), 2000);
    expect((await counts.adjustments()), isEmpty);
  });

  test('stale count and invalid second line roll back all posts', () async {
    final a = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 10);
    final b = await pos.saveProduct(
        name: 'B', priceCents: 1000, costCents: 500, startingStock: 5);
    final c = await counts.createCount(owner);
    final lines = await counts.lines(c.id);
    await counts.setCount(
        owner, lines.singleWhere((l) => l.productId == a).id, 8000);
    await counts.setCount(
        owner, lines.singleWhere((l) => l.productId == b).id, 6000);
    await expectLater(counts.finalize(owner, c.id), throwsStateError);
    expect(await pos.stockMilli(a), 10000);
    expect((await counts.adjustments()), isEmpty);
    await counts.adjust(owner, AdjustmentRequest(a, -1000, 'Lost'));
    await expectLater(counts.finalize(owner, c.id), throwsStateError);
    expect((await counts.counts()).single.status, 'draft');
    await counts.refreshLine(
        owner, lines.singleWhere((l) => l.productId == a).id);
    expect(
        (await counts.lines(c.id))
            .singleWhere((l) => l.productId == a)
            .countedMilli,
        isNull);
  });

  test('count detects stock moved away and returned to snapshot quantity',
      () async {
    final id = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 10);
    final count = await counts.createCount(owner);
    await counts.setCount(
        owner, (await counts.lines(count.id)).single.id, 10000);
    await counts.adjust(owner, AdjustmentRequest(id, -1000, 'Lost'));
    await counts.adjust(
        owner, AdjustmentRequest(id, 1000, 'Stock found', unitCostCents: 500));
    expect(await pos.stockMilli(id), 10000);
    await expectLater(counts.finalize(owner, count.id), throwsStateError);
    expect((await counts.counts()).single.status, 'draft');
  });

  test('serialized adjustment requires exact serial and rejects duplicate',
      () async {
    final id = await pos.saveProduct(
        name: 'Device',
        priceCents: 1000,
        costCents: 500,
        startingStock: 2,
        serialTracking: true,
        openingSerials: ['SN001', 'SN002']);
    await expectLater(
        counts.adjust(owner, AdjustmentRequest(id, -1000, 'Lost')),
        throwsStateError);
    await counts.adjust(
        owner, AdjustmentRequest(id, -1000, 'Lost', serialNumbers: ['SN002']));
    expect((await pos.availableSerials(id)).single.serialNumber, 'SN001');
    await expectLater(
        counts.adjust(
            owner,
            AdjustmentRequest(id, 1000, 'Stock found',
                unitCostCents: 500, serialNumbers: ['SN001'])),
        throwsA(isA<Exception>()));
    await counts.adjust(
        owner,
        AdjustmentRequest(id, 1000, 'Stock found',
            unitCostCents: 500, serialNumbers: ['SN003']));
    expect((await pos.availableSerials(id)).map((s) => s.serialNumber).toSet(),
        {'SN001', 'SN003'});
  });

  test('batch reduction uses the chosen batch and leaves other batch intact',
      () async {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, owner);
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
    await counts.adjust(
        owner, AdjustmentRequest(id, -2000, 'Expired', batchNumber: 'LOT-B'));
    final layers = await pos.layersForProduct(id);
    expect(
        layers
            .singleWhere((l) => l.batchNumber == 'LOT-A')
            .quantityRemainingMilli,
        2000);
    expect(
        layers
            .singleWhere((l) => l.batchNumber == 'LOT-B')
            .quantityRemainingMilli,
        1000);
    expect(
        (await pos.batches(id))
            .singleWhere((l) => l.batchNumber == 'LOT-B')
            .quantityMilli,
        1000);
  });

  test('weight count uses exact thousandths', () async {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, owner);
    final id = await pos.saveProduct(
        name: 'Rice',
        priceCents: 5000,
        costCents: 3000,
        startingStockMilli: 25500,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    final count = await counts.createCount(owner);
    final line = (await counts.lines(count.id)).single;
    expect(line.expectedMilli, 25500);
    expect(line.unitLabel, 'kg');
    await counts.setCount(owner, line.id, 24875);
    await counts.finalize(owner, count.id);
    expect((await counts.adjustments()).single.deltaMilli, -625);
    expect(await pos.stockMilli(id), 24875);
  });

  test('cashier cannot create or post; manager cannot finalize or adjust',
      () async {
    final id = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 1);
    final cashier = await AuthRepository(db).createUser(
        actorId: owner.id,
        name: 'Cashier',
        role: UserRole.cashier,
        hash: 'hash');
    final manager = await AuthRepository(db).createUser(
        actorId: owner.id,
        name: 'Manager',
        role: UserRole.manager,
        hash: 'hash');
    final cashierActor = ActiveUser(cashier, 'Cashier', UserRole.cashier);
    final managerActor = ActiveUser(manager, 'Manager', UserRole.manager);
    await expectLater(counts.createCount(cashierActor), throwsStateError);
    final count = await counts.createCount(managerActor);
    await counts.setCount(
        managerActor, (await counts.lines(count.id)).single.id, 0);
    await expectLater(
        counts.finalize(managerActor, count.id), throwsStateError);
    await expectLater(
        counts.adjust(managerActor, AdjustmentRequest(id, -1000, 'Lost')),
        throwsStateError);
    expect(await pos.stockMilli(id), 1000);
  });

  test('backup retains counts, adjustments and layer allocations', () async {
    final id = await pos.saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 2);
    final count = await counts.createCount(owner);
    await counts.setCount(
        owner, (await counts.lines(count.id)).single.id, 1000);
    await counts.finalize(owner, count.id);
    final dir = await Directory.systemTemp.createTemp('stock-count-backup-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final backup = await BackupService(db, dir).create(BackupKind.manual);
    expect(BackupService.verify(backup.file), 46);
    final copy =
        sqlite.sqlite3.open(backup.file.path, mode: sqlite.OpenMode.readOnly);
    try {
      expect(
          copy.select('SELECT reference FROM stock_counts').single['reference'],
          'SC-000001');
      expect(
          copy
              .select('SELECT reference FROM inventory_adjustments')
              .single['reference'],
          'ADJ-000001');
      expect(
          copy.select('SELECT * FROM inventory_adjustment_allocations').length,
          1);
      expect(copy.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      copy.dispose();
    }
    expect(await pos.stockMilli(id), 1000);
  });
}
