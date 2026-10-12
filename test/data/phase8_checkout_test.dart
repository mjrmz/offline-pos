import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;
  late PosRepository pos;
  late String ownerId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(AuthRepository(db));
    ownerId = await auth.bootstrap(
        'Owner', 'password123', 'Recovery question?', 'Secret answer');
    await auth.login(ownerId, 'password123');
    pos = PosRepository(db);
    final features = BusinessFeatureRepository(db);
    for (final feature in BusinessFeature.values) {
      await features.setEnabled(feature, true, auth.current!);
    }
  });
  tearDown(() => db.close());

  test('weight and meter quantities deduct exact fixed-point stock', () async {
    final rice = await pos.saveProduct(
        name: 'Rice',
        priceCents: 5000,
        costCents: 0,
        startingStockMilli: 10000,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    final cable = await pos.saveProduct(
        name: 'Cable',
        priceCents: 3000,
        costCents: 0,
        startingStockMilli: 5000,
        business: const BusinessProduct(unit: SaleUnit.meter));
    final sale = await pos.completeCashSale([
      SaleLineRequest(rice, 0, quantityMilli: 750),
      SaleLineRequest(cable, 0, quantityMilli: 2500),
    ], 12000, ownerId);
    expect(sale.totalCents, 11250);
    expect(await pos.stockMilli(rice), 9250);
    expect(await pos.stockMilli(cable), 2500);
    final items = await db.select(db.saleItems).get();
    expect(items.map((i) => i.quantityMilli), containsAll([750, 2500]));
    expect(items.map((i) => i.saleUnit), containsAll(['kg', 'm']));
    final movements = await db.select(db.inventoryMovements).get();
    expect(
        movements.map((m) => m.quantityDeltaMilli), containsAll([-750, -2500]));
    final detail = await SalesRepository(db).detail(auth.current!, sale.saleId);
    final document = ReceiptDocument.fromDetail(detail, 'Test store');
    final text = String.fromCharCodes(EscPosEncoder().encode(document, 80));
    expect(text, contains('0.75 kg'));
    expect(text, contains('2.5 m'));
    await expectLater(
        pos.completeCashSale([
          SaleLineRequest(rice, 0, quantityMilli: 10000),
        ], 50000, ownerId),
        throwsStateError);
    expect(await pos.stockMilli(rice), 9250);
  });

  test('disabled store flag retains existing specialty checkout behavior',
      () async {
    final rice = await pos.saveProduct(
        name: 'Rice',
        priceCents: 5000,
        costCents: 0,
        startingStockMilli: 2000,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, false, auth.current!);
    final loaded = (await pos.products()).single;
    expect(loaded.business.weight, true);
    final sale = await pos.completeCashSale([
      SaleLineRequest(rice, 0, quantityMilli: 500),
    ], 2500, ownerId);
    expect(sale.totalCents, 2500);
    expect(await pos.stockMilli(rice), 1500);
  });

  test('refill and tank choices snapshot price and empty returns', () async {
    final water = await pos.saveProduct(
        name: 'Water',
        priceCents: 3000,
        costCents: 0,
        startingStock: 10,
        business: const BusinessProduct(
            unit: SaleUnit.bottle, refill: true, containerPriceCents: 2000));
    final lpg = await pos.saveProduct(
        name: 'LPG',
        priceCents: 100000,
        costCents: 0,
        startingStock: 10,
        business: const BusinessProduct(tank: true, depositCents: 50000));
    final sale = await pos.completeCashSale([
      SaleLineRequest(water, 1, mode: 'container'),
      SaleLineRequest(lpg, 1, mode: 'exchange'),
    ], 105000, ownerId);
    expect(sale.totalCents, 105000);
    expect(await pos.stockMilli(water), 9000);
    expect(await pos.stockMilli(lpg), 9000);
    expect(
        (await db.select(db.tankEmptyMovements).get()).single.quantityDelta, 1);
    final items = await db.select(db.saleItems).get();
    expect(
        items.map((i) => i.saleMode), containsAll(['container', 'exchange']));
    expect(items.where((i) => i.productId == water).single.extraCents, 2000);
    final depositSale = await pos.completeCashSale([
      SaleLineRequest(lpg, 1, mode: 'deposit'),
    ], 150000, ownerId);
    expect(depositSale.totalCents, 150000);
    expect((await db.select(db.tankEmptyMovements).get()).length, 1);
    final detail = await SalesRepository(db).detail(auth.current!, sale.saleId);
    final receipt = String.fromCharCodes(EscPosEncoder()
        .encode(ReceiptDocument.fromDetail(detail, 'Store'), 80));
    expect(receipt, contains('Refill + container'));
    expect(receipt, contains('Empty tank returned'));
    await SalesRepository(db)
        .reverse(auth.current!, sale.saleId, 'void', stockRestored: true);
    expect(await pos.emptyTankCount(lpg), 0);
    expect(await pos.stockMilli(lpg), 9000);
  });

  test('batches remain separate and made order advances without stock',
      () async {
    final medicine = await pos.saveProduct(
        name: 'Item with expiry',
        priceCents: 1000,
        costCents: 0,
        startingStock: 5,
        batchNumber: 'A',
        business: const BusinessProduct(batch: true));
    await pos.receiveBatch(medicine, 'B', DateTime(2030), 10000, ownerId);
    final lots = await pos.batches(medicine);
    expect(lots.map((b) => b.quantityMilli), [5000, 10000]);
    final cake = await pos.saveProduct(
        name: 'Cake order',
        priceCents: 20000,
        costCents: 0,
        business: const BusinessProduct(madeToOrder: true));
    final sale = await pos.completeCashSale([
      SaleLineRequest(medicine, 2, batchId: lots[1].id),
      SaleLineRequest(cake, 1, mode: 'made_order'),
    ], 22000, ownerId);
    expect(sale.totalCents, 22000);
    expect((await pos.batches(medicine)).map((b) => b.quantityMilli),
        [5000, 8000]);
    expect(await pos.stockMilli(medicine), 13000);
    expect(await pos.stockMilli(cake), 0);
    final item = (await db.select(db.saleItems).get())
        .where((i) => i.productId == medicine)
        .single;
    expect(item.batchId, lots[1].id);
    expect(item.batchNumber, 'B');
    final orders = await SalesRepository(db).madeOrders(auth.current!);
    expect(orders.single.order.status, 'ordered');
    for (final status in ['preparing', 'ready', 'completed']) {
      await SalesRepository(db)
          .advanceMadeOrder(auth.current!, orders.single.order.id);
      expect(
          (await SalesRepository(db).madeOrders(auth.current!))
              .single
              .order
              .status,
          status);
    }
    await SalesRepository(db)
        .reverse(auth.current!, sale.saleId, 'void', stockRestored: true);
    expect(
        (await SalesRepository(db).madeOrders(auth.current!))
            .single
            .order
            .status,
        'cancelled');
    expect((await pos.batches(medicine))[1].quantityMilli, 10000);
    expect(await pos.stockMilli(medicine), 15000);
    await pos.completeCashSale([
      SaleLineRequest(medicine, 5, batchId: lots[0].id),
    ], 5000, ownerId);
    expect((await pos.batches(medicine)).first.quantityMilli, 0);
    expect((await pos.batches(medicine)).length, 2);
  });

  test('specialty payment failure rolls back stock, batch and sale', () async {
    final product = await pos.saveProduct(
        name: 'Batch',
        priceCents: 100,
        costCents: 0,
        startingStock: 2,
        batchNumber: 'A',
        business: const BusinessProduct(batch: true));
    final batch = (await pos.batches(product)).single;
    await db.customStatement(
        'CREATE TRIGGER fail_payment BEFORE INSERT ON payments '
        "BEGIN SELECT RAISE(ABORT, 'payment failure'); END");
    await expectLater(
        pos.completeCashSale([
          SaleLineRequest(product, 1, batchId: batch.id),
        ], 100, ownerId),
        throwsA(isA<Exception>()));
    expect(await pos.stockMilli(product), 2000);
    expect((await pos.batches(product)).single.quantityMilli, 2000);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.saleItems).get(), isEmpty);
  });

  test('BIR mixed specialty cart uses one invoice and exact grand total',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase8-bir-');
    try {
      final protection =
          ComplianceProtection(File('${dir.path}/compliance.json'));
      final rice = await pos.saveProduct(
          name: 'Rice',
          priceCents: 5000,
          costCents: 0,
          startingStockMilli: 3000,
          business:
              const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
      final plain = await pos.saveProduct(
          name: 'Can', priceCents: 1000, costCents: 0, startingStock: 5);
      final cable = await pos.saveProduct(
          name: 'Cable',
          priceCents: 3000,
          costCents: 0,
          startingStockMilli: 5000,
          business: const BusinessProduct(unit: SaleUnit.meter));
      final water = await pos.saveProduct(
          name: 'Water refill',
          priceCents: 3000,
          costCents: 0,
          startingStock: 3,
          business: const BusinessProduct(
              unit: SaleUnit.bottle, refill: true, containerPriceCents: 2000));
      final tank = await pos.saveProduct(
          name: 'LPG',
          priceCents: 100000,
          costCents: 0,
          startingStock: 3,
          business: const BusinessProduct(tank: true, depositCents: 50000));
      final batchProduct = await pos.saveProduct(
          name: 'Batch',
          priceCents: 1000,
          costCents: 0,
          startingStock: 3,
          batchNumber: 'LOT-1',
          business: const BusinessProduct(batch: true));
      final batchId = (await pos.batches(batchProduct)).single.id;
      final cake = await pos.saveProduct(
          name: 'Cake',
          priceCents: 20000,
          costCents: 0,
          business: const BusinessProduct(madeToOrder: true));
      await CashSessionRepository(db, birReady: true, protection: protection)
          .open(auth.current!, 0);
      final bir = PosRepository(db, birReady: true, protection: protection);
      final sale = await bir.completeCashSale([
        SaleLineRequest(plain, 2),
        SaleLineRequest(rice, 0, quantityMilli: 750),
        SaleLineRequest(cable, 0, quantityMilli: 2500),
        SaleLineRequest(water, 1, mode: 'refill'),
        SaleLineRequest(tank, 1, mode: 'exchange'),
        SaleLineRequest(batchProduct, 1, batchId: batchId),
        SaleLineRequest(cake, 1, mode: 'made_order'),
      ], 137250, ownerId);
      expect(sale.totalCents, 137250);
      expect(sale.birInvoiceNumber, 1);
      final state = (await db.select(db.birComplianceState).get()).single;
      expect(state.grandTotalCents, 137250);
      expect((await db.select(db.sales).get()).length, 1);
      expect((await db.select(db.saleItems).get()).length, 7);
      final historical = ReceiptDocument.fromDetail(
          await SalesRepository(db).detail(auth.current!, sale.saleId),
          'Store');
      await pos.saveProduct(
          id: rice, name: 'Rice renamed', priceCents: 8000, costCents: 0);
      final reprint = ReceiptDocument.fromDetail(
          await SalesRepository(db).detail(auth.current!, sale.saleId),
          'Store');
      expect(EscPosEncoder().encode(reprint, 80),
          EscPosEncoder().encode(historical, 80));
      await CashSessionRepository(db, birReady: true, protection: protection)
          .close(auth.current!, 137250);
      expect(
          (await db.select(db.zReadings).get()).single.grandTotalCents, 137250);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('failed BIR weighted sale rolls back and does not issue invoice',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase8-bir-failure-');
    try {
      final protection =
          ComplianceProtection(File('${dir.path}/compliance.json'));
      final rice = await pos.saveProduct(
          name: 'Rice',
          priceCents: 5000,
          costCents: 0,
          startingStockMilli: 2000,
          business:
              const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
      await CashSessionRepository(db, birReady: true, protection: protection)
          .open(auth.current!, 0);
      final bir = PosRepository(db, birReady: true, protection: protection);
      await db.customStatement(
          'CREATE TRIGGER fail_payment BEFORE INSERT ON payments '
          "BEGIN SELECT RAISE(ABORT, 'payment failure'); END");
      await expectLater(
          bir.completeCashSale([
            SaleLineRequest(rice, 0, quantityMilli: 500),
          ], 2500, ownerId),
          throwsA(isA<Exception>()));
      expect(await db.select(db.sales).get(), isEmpty);
      expect(await db.select(db.birComplianceState).get(), isEmpty);
      expect(await pos.stockMilli(rice), 2000);
      await db.customStatement('DROP TRIGGER fail_payment');
      final committed = await bir.completeCashSale([
        SaleLineRequest(rice, 0, quantityMilli: 500),
      ], 2500, ownerId);
      expect(committed.birInvoiceNumber, 1);
      expect(
          (await db.select(db.birComplianceState).get()).single.grandTotalCents,
          2500);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('backup preserves specialty stock, lots, order and sale snapshots',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase8-snapshot-');
    try {
      final batchProduct = await pos.saveProduct(
          name: 'Batch stock',
          priceCents: 1000,
          costCents: 0,
          startingStock: 3,
          batchNumber: 'LOT-A',
          business: const BusinessProduct(batch: true));
      final orderProduct = await pos.saveProduct(
          name: 'Cake',
          priceCents: 2000,
          costCents: 0,
          business: const BusinessProduct(madeToOrder: true));
      final lot = (await pos.batches(batchProduct)).single;
      await pos.completeCashSale([
        SaleLineRequest(batchProduct, 1, batchId: lot.id),
        SaleLineRequest(orderProduct, 1, mode: 'made_order'),
      ], 3000, ownerId);
      final backup = await BackupService(db, Directory('${dir.path}/backups'))
          .create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect(
            (await restored.select(restored.inventory).get())
                .where((i) => i.productId == batchProduct)
                .single
                .quantityMilli,
            2000);
        expect(
            (await restored.select(restored.productLots).get())
                .single
                .quantityMilli,
            2000);
        expect((await restored.select(restored.madeOrders).get()).single.status,
            'ordered');
        expect(
            (await restored.select(restored.saleItems).get())
                .where((i) => i.productId == batchProduct)
                .single
                .batchNumber,
            'LOT-A');
        expect(
            (await BusinessFeatureRepository(restored).availability())
                .values
                .every((v) => v),
            true);
      } finally {
        await restored.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
