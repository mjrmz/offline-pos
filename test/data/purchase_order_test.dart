import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  test(
      'purchase orders plan stock; only linked finalized receipts create layers',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final pos = PosRepository(db);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(actor, name: 'ABC Distribution');
    final productId = await pos.saveProduct(
        name: 'Product A',
        priceCents: 70000,
        costCents: 50000,
        startingStock: 0);
    final po = PurchaseOrderRepository(db);
    final order = await po.create(actor, supplier.id, DateTime(2026, 10, 15),
        [PurchaseOrderLineInput(productId, 10000, 50000)]);
    expect(PurchaseOrderRepository.number(order), 'PO-000001');
    expect((await po.detail(order.id)).status, 'draft');
    expect(await pos.stockMilli(productId), 0);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
    expect(await db.select(db.inventoryMovements).get(), isEmpty);
    expect(await db.select(db.businessCashMovements).get(), isEmpty);
    expect(await db.select(db.pettyCashEntries).get(), isEmpty);
    await po.markSent(actor, order.id);
    final line = (await po.detail(order.id)).lines.single;
    final receiving = StockReceivingRepository(db);
    await receiving.receive(
        actor,
        supplier.id,
        [
          ReceivingLineRequest(productId, 4000, 52000,
              purchaseOrderLineId: line.id)
        ],
        purchaseOrderId: order.id,
        externalReference: 'INV-001');
    var progress = await po.detail(order.id);
    expect(StockReceivingRepository.number(progress.receivings.single),
        'RCV-000001');
    expect(
        (await receiving.duplicateReference(supplier.id, 'inv-001')).length, 1);
    await expectLater(
        receiving.receive(actor, supplier.id,
            [ReceivingLineRequest(productId, 1000, 50000,
                purchaseOrderLineId: line.id)],
            purchaseOrderId: order.id,
            externalReference: 'inv-001'),
        throwsStateError);
    expect((await po.receivedCostVariance(order.id)).expectedCents, 200000);
    expect((await po.receivedCostVariance(order.id)).actualCents, 208000);
    expect(progress.status, 'partially_received');
    expect(progress.receivedTotal, 4000);
    expect(progress.remainingTotal, 6000);
    expect(await pos.stockMilli(productId), 4000);
    expect((await db.select(db.inventoryLayers).get()).single.unitCostCents,
        52000);
    expect(progress.lines.single.expectedUnitCostCents, 50000);
    await expectLater(
        receiving.receive(
            actor,
            supplier.id,
            [
              ReceivingLineRequest(productId, 7000, 51500,
                  purchaseOrderLineId: line.id)
            ],
            purchaseOrderId: order.id),
        throwsStateError);
    expect(await pos.stockMilli(productId), 4000);
    expect((await po.detail(order.id)).receivedTotal, 4000);
    await receiving.receive(
        actor,
        supplier.id,
        [
          ReceivingLineRequest(productId, 6000, 51500,
              purchaseOrderLineId: line.id)
        ],
        purchaseOrderId: order.id);
    progress = await po.detail(order.id);
    expect(progress.status, 'fully_received');
    expect(progress.remainingTotal, 0);
    expect(progress.receivings.length, 2);
    expect(progress.receivings.map(StockReceivingRepository.number),
        ['RCV-000001', 'RCV-000002']);
    final variance = await po.receivedCostVariance(order.id);
    expect(variance.expectedCents, 500000);
    expect(variance.actualCents, 517000);
    expect(await pos.stockMilli(productId), 10000);
    expect(
        (await pos.layersForProduct(productId))
            .map((l) => l.unitCostCents)
            .toList(),
        unorderedEquals([52000, 51500]));
    await po.close(actor, order.id);
    final copy = await po.duplicate(actor, order.id);
    final copied = await po.detail(copy.id);
    expect(copied.status, 'draft');
    expect(PurchaseOrderRepository.number(copy), 'PO-000002');
    expect(copied.lines.single.orderedQtyMilli, 10000);
    expect(copied.receivings, isEmpty);
    expect(copied.receivedTotal, 0);
    await expectLater(
        receiving.receive(
            actor,
            supplier.id,
            [
              ReceivingLineRequest(productId, 1000, 50000,
                  purchaseOrderLineId: line.id)
            ],
            purchaseOrderId: order.id),
        throwsStateError);
  });

  test('cancelled remainder leaves received stock and history intact',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final pos = PosRepository(db);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(actor, name: 'ABC Distribution');
    final productId = await pos.saveProduct(
        name: 'Product A',
        priceCents: 70000,
        costCents: 50000,
        startingStock: 0);
    final po = PurchaseOrderRepository(db);
    final order = await po.create(actor, supplier.id, DateTime.now(),
        [PurchaseOrderLineInput(productId, 10000, 50000)],
        markSent: true);
    final line = (await po.detail(order.id)).lines.single;
    await StockReceivingRepository(db).receive(
        actor,
        supplier.id,
        [
          ReceivingLineRequest(productId, 4000, 52000,
              purchaseOrderLineId: line.id)
        ],
        purchaseOrderId: order.id);
    expect(await po.incomingForProduct(productId), 6000);
    await po.cancel(actor, order.id, 'Supplier cannot deliver remainder');
    final progress = await po.detail(order.id);
    expect(progress.status, 'cancelled');
    expect(progress.receivedTotal, 4000);
    expect(progress.lines.single.cancelledQtyMilli, 6000);
    expect(progress.remainingTotal, 0);
    expect(await po.incomingForProduct(productId), 0);
    expect(progress.order.cancelReason, 'Supplier cannot deliver remainder');
    expect(await pos.stockMilli(productId), 4000);
    expect(progress.receivings.length, 1);
    final receiving = StockReceivingRepository(db);
    expect(await receiving.duplicateReference(supplier.id, ''), isEmpty);
  });

  test(
      'expected delivery uses local date and only open remaining orders are overdue',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final supplier = await DirectoryRepository(db)
        .saveSupplier(actor, name: 'ABC Distribution');
    final productId = await PosRepository(db).saveProduct(
        name: 'Product A',
        priceCents: 70000,
        costCents: 50000,
        startingStock: 0);
    final po = PurchaseOrderRepository(db);
    final order = await po.create(actor, supplier.id, DateTime(2026, 10, 10),
        [PurchaseOrderLineInput(productId, 1000, 50000)],
        expectedDeliveryDate: DateTime(2026, 10, 16));
    expect(
        (await po.detail(order.id)).isOverdue(DateTime(2026, 10, 17)), false);
    await po.markSent(actor, order.id);
    expect((await po.detail(order.id)).isOverdue(DateTime(2026, 10, 16, 23)),
        false);
    expect((await po.detail(order.id)).isOverdue(DateTime(2026, 10, 17)), true);
    final line = (await po.detail(order.id)).lines.single;
    await StockReceivingRepository(db).receive(
        actor,
        supplier.id,
        [
          ReceivingLineRequest(productId, 1000, 50000,
              purchaseOrderLineId: line.id)
        ],
        purchaseOrderId: order.id);
    expect(
        (await po.detail(order.id)).isOverdue(DateTime(2026, 10, 17)), false);
    await po.close(actor, order.id);
    expect(
        (await po.detail(order.id)).isOverdue(DateTime(2026, 10, 17)), false);
  });

  test('purchase order and receiving links survive backup', () async {
    final dir = await Directory.systemTemp.createTemp('po-backup-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final supplier = await DirectoryRepository(db)
          .saveSupplier(actor, name: 'ABC Distribution');
      final productId = await pos.saveProduct(
          name: 'Product A',
          priceCents: 70000,
          costCents: 50000,
          startingStock: 0);
      final po = PurchaseOrderRepository(db);
      final order = await po.create(actor, supplier.id, DateTime.now(),
          [PurchaseOrderLineInput(productId, 10000, 50000)],
          markSent: true);
      final line = (await po.detail(order.id)).lines.single;
      await StockReceivingRepository(db).receive(
          actor,
          supplier.id,
          [
            ReceivingLineRequest(productId, 4000, 52000,
                purchaseOrderLineId: line.id)
          ],
          purchaseOrderId: order.id);
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        final restoredProgress =
            await PurchaseOrderRepository(restored).detail(order.id);
        expect(restoredProgress.receivedTotal, 4000);
        expect(restoredProgress.remainingTotal, 6000);
        expect(restoredProgress.receivings.single.purchaseOrderId, order.id);
        expect(
            (await restored.select(restored.stockReceivingItems).get())
                .single
                .purchaseOrderLineId,
            line.id);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
