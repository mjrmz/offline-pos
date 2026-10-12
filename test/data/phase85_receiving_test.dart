import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';

void main() {
  test('multi-item supplier receiving preserves costs, batch and movements',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-receiving-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      await BusinessFeatureRepository(db)
          .setEnabled(BusinessFeature.expiryBatchTracking, true, actor);
      final supplier =
          await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier A');
      final pos = PosRepository(db);
      final ordinary = await pos.saveProduct(
          name: 'Cable', priceCents: 10000, costCents: 5000);
      final batch = await pos.saveProduct(
          name: 'Milk',
          priceCents: 9000,
          costCents: 6000,
          business: const BusinessProduct(batch: true));
      final repo = StockReceivingRepository(db);
      final expiry = DateTime.now().add(const Duration(days: 100));
      final receiving = await repo.receive(
          actor,
          supplier.id,
          [
            ReceivingLineRequest(ordinary, 3000, 5500),
            ReceivingLineRequest(batch, 5000, 6500,
                batchNumber: 'LOT-A', expiryDate: expiry),
          ],
          externalReference: 'DR-123');
      expect(
          (await repo.items(receiving.id)).map((i) => i.unitCostCents).toList(),
          [5500, 6500]);
      expect(await pos.stockMilli(ordinary), 3000);
      expect(await pos.stockMilli(batch), 5000);
      expect((await pos.batches(batch)).single.batchNumber, 'LOT-A');
      expect((await pos.movements(batch)).single.referenceId, receiving.id);
      expect((await repo.history(supplierId: supplier.id)).single.id,
          receiving.id);
      final backup = await BackupService(db, Directory('${dir.path}/backup'))
          .create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect(
            (await restored.select(restored.stockReceivingItems).get()).length,
            2);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('receiving error rolls back header, lines, inventory and audit',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier A');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Cable', priceCents: 10000, costCents: 5000);
    await expectLater(
        StockReceivingRepository(db).receive(actor, supplier.id, [
          ReceivingLineRequest(product, 3000, 5500),
          ReceivingLineRequest(product, -1000, 5500),
        ]),
        throwsA(isA<StateError>()));
    expect(await db.select(db.stockReceivings).get(), isEmpty);
    expect(await db.select(db.stockReceivingItems).get(), isEmpty);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
    expect(await pos.stockMilli(product), 0);
  });

  test('serialized receiving and sale preserve historical identity', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-serial-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      final supplier =
          await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier');
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Laptop',
          priceCents: 50000,
          costCents: 30000,
          serialTracking: true);
      final receiving = StockReceivingRepository(db);
      await expectLater(
          receiving.receive(actor, supplier.id, [
            ReceivingLineRequest(product, 2000, 30000,
                serialNumbers: ['L-1', 'L-1'])
          ]),
          throwsA(isA<StateError>()));
      expect(await db.select(db.stockReceivings).get(), isEmpty);
      final header = await receiving.receive(actor, supplier.id, [
        ReceivingLineRequest(product, 2000, 30000,
            serialNumbers: ['L-1', 'L-2'])
      ]);
      final item = (await receiving.items(header.id)).single;
      final serials = await receiving.serialsForItem(item.id);
      expect(serials.map((s) => s.serialNumber).toSet(), {'L-1', 'L-2'});
      await receiving.correctUnsoldSerial(actor, serials.last.id, 'L-2B');
      expect(
          (await receiving.serialsForItem(item.id)).last.serialNumber, 'L-2B');
      final sale = await pos.completeCashSale([
        SaleLineRequest(product, 1, serialIds: [serials.first.id])
      ], 50000, ownerId);
      final detail = await SalesRepository(db).detail(actor, sale.saleId);
      expect(detail.serialNumbersByItem[detail.items.single.id],
          [serials.first.serialNumber]);
      final receipt = ReceiptDocument.fromDetail(detail, 'Store');
      expect(receipt.lines.single.serialNumbers, [serials.first.serialNumber]);
      expect(String.fromCharCodes(EscPosEncoder().encode(receipt, 80)),
          contains('Serial: L-1'));
      await expectLater(
          receiving.correctUnsoldSerial(actor, serials.first.id, 'Changed'),
          throwsA(isA<StateError>()));
      await expectLater(
          pos.completeCashSale([
            SaleLineRequest(product, 1, serialIds: [serials.first.id])
          ], 50000, ownerId),
          throwsA(isA<StateError>()));
      await SalesRepository(db)
          .reverse(actor, sale.saleId, 'void', stockRestored: true);
      expect((await pos.availableSerials(product)).length, 2);
      expect(
          (await SalesRepository(db).detail(actor, sale.saleId))
              .serialNumbersByItem[detail.items.single.id],
          [serials.first.serialNumber]);
      await expectLater(
          receiving.correctUnsoldSerial(actor, serials.first.id, 'Changed'),
          throwsA(isA<StateError>()));
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect((await restored.select(restored.serialUnits).get()).length, 2);
        expect(
            (await restored.select(restored.serialSaleLinks).get()).length, 1);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
