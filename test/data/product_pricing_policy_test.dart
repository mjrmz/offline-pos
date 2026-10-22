import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/core/models/quantity.dart';

void main() {
  test('layer products may omit a master price and edits retain policy',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final products = PosRepository(db);
    final freeId = await products.saveProduct(
        name: 'Complimentary item', priceCents: 0, costCents: 0);
    expect(
        (await products.products())
            .singleWhere((p) => p.id == freeId)
            .priceCents,
        0);
    final id = await products.saveProduct(
        name: 'Layer', priceCents: 0, costCents: 0, pricingPolicy: 'layer');
    expect(await products.stockMilli(id), 0);
    expect(await products.layersForProduct(id), isEmpty);
    await products.saveProduct(
        id: id, name: 'Layer renamed', priceCents: 0, costCents: 0);
    expect(
        (await products.products())
            .singleWhere((p) => p.id == id)
            .pricingPolicy,
        'layer');
  });

  test('layer-priced opening stock requires a layer price', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final products = PosRepository(db);
    await expectLater(
        products.saveProduct(
            name: 'Unpriced opening',
            priceCents: 0,
            costCents: 1000,
            pricingPolicy: 'layer',
            startingStock: 2),
        throwsArgumentError);
    final id = await products.saveProduct(
        name: 'Priced opening',
        priceCents: 0,
        costCents: 1000,
        pricingPolicy: 'layer',
        startingStock: 2,
        openingCostCents: 1100,
        openingSellingPriceCents: 1500);
    final layer = (await products.layersForProduct(id)).single;
    expect(layer.unitCostCents, 1100);
    expect(layer.unitSellingPriceCents, 1500);
  });

  test('current-price opening stock uses the product price', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final products = PosRepository(db);
    final id = await products.saveProduct(
        name: 'Current opening',
        priceCents: 1500,
        costCents: 1000,
        startingStock: 1);
    expect((await products.layersForProduct(id)).single.unitSellingPriceCents,
        isNull);
  });

  test('supplier receiving sets a layer price only when finalized', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final actor = auth.current!;
    final products = PosRepository(db);
    final id = await products.saveProduct(
        name: 'Supplier item',
        priceCents: 0,
        costCents: 0,
        pricingPolicy: 'layer');
    expect(await products.stockMilli(id), 0);
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier');
    await StockReceivingRepository(db).receive(actor, supplier.id,
        [ReceivingLineRequest(id, 2000, 1000, unitSellingPriceCents: 1500)]);
    final layer = (await products.layersForProduct(id)).single;
    expect(layer.unitSellingPriceCents, 1500);
    expect(await products.stockMilli(id), 2000);
  });

  test('opening batches keep independent costs, prices, and expiry', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, auth.current!);
    final products = PosRepository(db);
    final firstExpiry = DateTime(2030, 1, 1);
    final emptyId = await products.saveProduct(
        name: 'Unstocked batch',
        priceCents: 0,
        costCents: 0,
        pricingPolicy: 'layer',
        business: const BusinessProduct(batch: true));
    expect(await products.layersForProduct(emptyId), isEmpty);
    final secondExpiry = DateTime(2031, 1, 1);
    final id = await products.saveProduct(
        name: 'Batch medicine',
        priceCents: 0,
        costCents: 0,
        pricingPolicy: 'layer',
        startingStock: 3,
        business: const BusinessProduct(batch: true),
        openingBatches: [
          OpeningBatch(1000, 'LOT-1', firstExpiry,
              unitCostCents: 1000, unitSellingPriceCents: 1500),
          OpeningBatch(2000, 'LOT-2', secondExpiry,
              unitCostCents: 1100, unitSellingPriceCents: 1600),
        ]);
    final layers = await products.layersForProduct(id)
      ..sort((a, b) => (a.batchNumber ?? '').compareTo(b.batchNumber ?? ''));
    expect(layers.map((l) => l.batchNumber), ['LOT-1', 'LOT-2']);
    expect(layers.map((l) => l.unitCostCents), [1000, 1100]);
    expect(layers.map((l) => l.unitSellingPriceCents), [1500, 1600]);
    expect(layers.map((l) => l.expiryDate), [firstExpiry, secondExpiry]);
  });

  test('weighted layer prices and costs survive receiving and FIFO sale',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final actor = auth.current!;
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, actor);
    final products = PosRepository(db);
    final id = await products.saveProduct(
        name: 'Rice',
        priceCents: 0,
        costCents: 0,
        pricingPolicy: 'layer',
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    final supplier = await DirectoryRepository(db)
        .saveSupplier(actor, name: 'Rice supplier');
    final receiving = StockReceivingRepository(db);
    await receiving.receive(
        actor,
        supplier.id,
        [
          ReceivingLineRequest(id, 100000, 4200, unitSellingPriceCents: 5000),
        ],
        receivedAt: DateTime(2026, 1, 1));
    await receiving.receive(
        actor,
        supplier.id,
        [
          ReceivingLineRequest(id, 100000, 4600, unitSellingPriceCents: 5500),
        ],
        receivedAt: DateTime(2026, 1, 2));
    final layers = await products.layersForProduct(id)
      ..sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    expect(layers.length, 2);
    expect(layers.map((l) => l.unitCostCents), [4200, 4600]);
    expect(layers.map((l) => l.unitSellingPriceCents), [5000, 5500]);
    expect(layers.map((l) => l.quantityRemainingMilli), [100000, 100000]);
    final sale = await products.completeCashSale(
        [SaleLineRequest(id, 0, quantityMilli: 100500)], 1000000, actor.id);
    expect(sale.totalCents,
        Quantity.lineCents(5000, 100000) + Quantity.lineCents(5500, 500));
    final remaining = await products.layersForProduct(id)
      ..sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
    expect(remaining.map((l) => l.quantityRemainingMilli), [0, 99500]);
  });

  test('unsupported weight capability combinations are rejected', () {
    expect(
        () => const BusinessProduct(
                unit: SaleUnit.kilogram, weight: true, refill: true)
            .validate(5000),
        throwsArgumentError);
    expect(
        () => const BusinessProduct(
                unit: SaleUnit.kilogram, weight: true, tank: true)
            .validate(5000),
        throwsArgumentError);
    expect(
        () => const BusinessProduct(
                unit: SaleUnit.kilogram, weight: true, madeToOrder: true)
            .validate(5000),
        throwsArgumentError);
    expect(
        () => const BusinessProduct(unit: SaleUnit.kilogram, weight: true)
            .validate(0),
        returnsNormally);
  });
}
