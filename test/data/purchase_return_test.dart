import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/historical_fixture.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_return_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  late AppDatabase db;
  late ActiveUser owner;
  late PosRepository pos;
  late StockReceivingRepository receiving;
  late PurchaseReturnRepository returns;
  late String supplierId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    owner = auth.current!;
    pos = PosRepository(db);
    receiving = StockReceivingRepository(db);
    returns = PurchaseReturnRepository(db);
    supplierId =
        (await DirectoryRepository(db).saveSupplier(owner, name: 'Supplier A'))
            .id;
  });
  tearDown(() async => db.close());

  test(
      'exact source layer depletes, receiving stays immutable, value snapshots',
      () async {
    final product = await pos.saveProduct(
        name: 'Widget', priceCents: 900, costCents: 700, startingStock: 0);
    final first = await receiving.receive(
        owner, supplierId, [ReceivingLineRequest(product, 100000, 500)]);
    final second = await receiving.receive(
        owner, supplierId, [ReceivingLineRequest(product, 20000, 800)]);
    final source = (await returns.sources(first.id)).single;
    final other = (await returns.sources(second.id)).single;
    final draft = await returns.createDraft(owner, first.id, [
      PurchaseReturnLineInput(
          source.item.id, 10000, PurchaseReturnReason.damaged)
    ]);
    expect(PurchaseReturnRepository.number(draft), 'PRT-000001');
    expect(await pos.stockMilli(product), 120000);
    await returns.finalize(owner, draft.id);
    expect(await pos.stockMilli(product), 110000);
    expect(
        (await returns.sources(first.id)).single.layer.quantityRemainingMilli,
        90000);
    expect(
        (await returns.sources(second.id)).single.layer.quantityRemainingMilli,
        other.layer.quantityRemainingMilli);
    expect((await receiving.items(first.id)).single.quantityMilli, 100000);
    expect((await returns.lines(draft.id)).single.returnValueCents, 5000);
    final movement = (await db.select(db.inventoryMovements).get())
        .where((m) => m.reason == 'purchase_return')
        .single;
    expect(movement.quantityDeltaMilli, -10000);
    expect(movement.inventoryLayerId, source.layer.id);
  });

  test('over-return and stale draft fail atomically', () async {
    final product = await pos.saveProduct(
        name: 'Widget', priceCents: 900, costCents: 700, startingStock: 0);
    final receipt = await receiving.receive(
        owner, supplierId, [ReceivingLineRequest(product, 10000, 500)]);
    final item = (await returns.sources(receipt.id)).single.item;
    final first = await returns.createDraft(owner, receipt.id,
        [PurchaseReturnLineInput(item.id, 7000, PurchaseReturnReason.other)]);
    final stale = await returns.createDraft(owner, receipt.id,
        [PurchaseReturnLineInput(item.id, 5000, PurchaseReturnReason.other)]);
    await returns.finalize(owner, first.id);
    await expectLater(returns.finalize(owner, stale.id), throwsStateError);
    expect(
        (await db.select(db.purchaseReturns).get())
            .where((r) => r.id == stale.id)
            .single
            .status,
        'draft');
    expect(await pos.stockMilli(product), 3000);
    expect(
        (await db.select(db.inventoryMovements).get())
            .where((m) => m.reason == 'purchase_return')
            .length,
        1);
  });

  test('exact serial returns while unavailable serial is blocked', () async {
    final product = await pos.saveProduct(
        name: 'Serial widget',
        priceCents: 900,
        costCents: 700,
        startingStock: 0,
        serialTracking: true);
    final receipt = await receiving.receive(owner, supplierId, [
      ReceivingLineRequest(product, 2000, 500,
          serialNumbers: ['SER-1', 'SER-2'])
    ]);
    final source = (await returns.sources(receipt.id)).single;
    final serial = source.serials.first;
    final draft = await returns.createDraft(owner, receipt.id, [
      PurchaseReturnLineInput(
          source.item.id, 1000, PurchaseReturnReason.defective,
          serialUnitIds: [serial.id])
    ]);
    await returns.finalize(owner, draft.id);
    expect(
        (await db.select(db.serialUnits).get())
            .firstWhere((s) => s.id == serial.id)
            .status,
        'supplier_returned');
    expect((await returns.sources(receipt.id)).single.serials.length, 1);
    await expectLater(
        returns.createDraft(owner, receipt.id, [
          PurchaseReturnLineInput(
              source.item.id, 1000, PurchaseReturnReason.defective,
              serialUnitIds: [serial.id])
        ]),
        throwsStateError);
    final sold = source.serials.last;
    await (db.update(db.serialUnits)..where((s) => s.id.equals(sold.id)))
        .write(const SerialUnitsCompanion(status: Value('sold')));
    await expectLater(
        returns.createDraft(owner, receipt.id, [
          PurchaseReturnLineInput(
              source.item.id, 1000, PurchaseReturnReason.defective,
              serialUnitIds: [sold.id])
        ]),
        throwsStateError);
  });

  test('batch return reduces only the selected received layer and lot',
      () async {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, owner);
    final product = await pos.saveProduct(
        name: 'Medicine',
        priceCents: 900,
        costCents: 700,
        startingStock: 0,
        business: const BusinessProduct(batch: true));
    final first = await receiving.receive(owner, supplierId,
        [ReceivingLineRequest(product, 10000, 500, batchNumber: 'LOT-A')]);
    final second = await receiving.receive(owner, supplierId,
        [ReceivingLineRequest(product, 20000, 800, batchNumber: 'LOT-B')]);
    final source = (await returns.sources(first.id)).single;
    final draft = await returns.createDraft(owner, first.id, [
      PurchaseReturnLineInput(
          source.item.id, 4000, PurchaseReturnReason.incorrectBatch)
    ]);
    await returns.finalize(owner, draft.id);
    expect(
        (await returns.sources(first.id)).single.layer.quantityRemainingMilli,
        6000);
    expect(
        (await returns.sources(second.id)).single.layer.quantityRemainingMilli,
        20000);
    expect(
        (await pos.batches(product))
            .firstWhere((b) => b.batchNumber == 'LOT-A')
            .quantityMilli,
        6000);
    expect(
        (await pos.batches(product))
            .firstWhere((b) => b.batchNumber == 'LOT-B')
            .quantityMilli,
        20000);
  });

  test(
      'supplier credit and replacement remain operational until receiving exists',
      () async {
    final product = await pos.saveProduct(
        name: 'Widget', priceCents: 900, costCents: 700, startingStock: 0);
    final receipt = await receiving.receive(
        owner, supplierId, [ReceivingLineRequest(product, 10000, 500)]);
    final item = (await returns.sources(receipt.id)).single.item;
    final draft = await returns.createDraft(owner, receipt.id,
        [PurchaseReturnLineInput(item.id, 1000, PurchaseReturnReason.other)]);
    await returns.finalize(owner, draft.id);
    await returns.setResolution(
        owner, draft.id, PurchaseReturnResolution.supplierCredit,
        creditReference: 'CREDIT-1', creditAmountCents: 500);
    var row = (await db.select(db.purchaseReturns).get()).single;
    expect(row.resolution, 'supplierCredit');
    expect(row.creditAmountCents, 500);
    await returns.setResolution(
        owner, draft.id, PurchaseReturnResolution.replacementExpected);
    await expectLater(
        returns.setResolution(
            owner, draft.id, PurchaseReturnResolution.replacementReceived),
        throwsStateError);
    final replacement = await receiving
        .receive(owner, supplierId, [ReceivingLineRequest(product, 1000, 500)]);
    await returns.setResolution(
        owner, draft.id, PurchaseReturnResolution.replacementReceived,
        replacementReceivingId: replacement.id);
    row = (await db.select(db.purchaseReturns).get()).single;
    expect(row.replacementReceivingId, replacement.id);
    expect(await pos.stockMilli(product), 10000);
  });

  test('receiving staff can draft but cannot finalize', () async {
    final auth = AuthService(AuthRepository(db));
    await auth.login(owner.id, 'password123');
    final code = await auth.createRole('Receiving staff',
        'Draft supplier returns', {PosPermission.stockReceiving});
    final id = await auth.createUserWithRole('Staff', code, 'staffPassword123');
    final staff = await auth.repository.requireActive(id);
    final product = await pos.saveProduct(
        name: 'Widget', priceCents: 900, costCents: 700, startingStock: 0);
    final receipt = await receiving
        .receive(owner, supplierId, [ReceivingLineRequest(product, 2000, 500)]);
    final item = (await returns.sources(receipt.id)).single.item;
    final draft = await returns.createDraft(staff, receipt.id,
        [PurchaseReturnLineInput(item.id, 1000, PurchaseReturnReason.other)]);
    await expectLater(returns.finalize(staff, draft.id), throwsStateError);
    expect(await pos.stockMilli(product), 2000);
  });

  test('schema 43 upgrades additively and preserves receiving and stock',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('purchase-return-migration-');
    final file = File('${directory.path}/store.sqlite');
    try {
      final prior = AppDatabase.forTesting(NativeDatabase(file));
      final auth = AuthService(AuthRepository(prior));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final actor = auth.current!;
      final product = await PosRepository(prior).saveProduct(
          name: 'Widget', priceCents: 900, costCents: 700, startingStock: 0);
      final supplier = await DirectoryRepository(prior)
          .saveSupplier(actor, name: 'Supplier B');
      final receipt = await StockReceivingRepository(prior).receive(
          actor, supplier.id, [ReceivingLineRequest(product, 5000, 450)]);
      await prior.close();
      await rebuildAsHistoricalFixture(file, 43);
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      expect(upgraded.schemaVersion, 55);
      expect(
          (await StockReceivingRepository(upgraded).items(receipt.id))
              .single
              .quantityMilli,
          5000);
      expect(await PosRepository(upgraded).stockMilli(product), 5000);
      expect(
          (await PurchaseReturnRepository(upgraded).sources(receipt.id))
              .single
              .layer
              .quantityRemainingMilli,
          5000);
      expect(
          (await AuthRepository(upgraded).requireActive(id))
              .can(PosPermission.finalizePurchaseReturn),
          isTrue);
      await upgraded.close();
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
