import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  test('zero-stock weighted product becomes available after receiving',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, actor);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(actor, name: 'Rice supplier');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'JASMINE RISE',
        priceCents: 5000,
        costCents: 3000,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    expect((await pos.stockLevels())[id], (0, 0));
    await StockReceivingRepository(db)
        .receive(actor, supplier.id, [ReceivingLineRequest(id, 100000, 3000)]);
    expect((await pos.products()).singleWhere((p) => p.id == id).business.unit,
        SaleUnit.kilogram);
    expect((await pos.stockLevels())[id], (100000, 0));
    expect(
        (await pos.layersForProduct(id)).single.quantityRemainingMilli, 100000);
  });

  test('received products enter the same live POS catalog and stock model',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final supplier = await DirectoryRepository(db)
        .saveSupplier(actor, name: 'Receiving supplier');
    final pos = PosRepository(db);
    final receiving = StockReceivingRepository(db);

    final rc = await pos.saveProduct(
        name: 'RC',
        sku: 'RC-1',
        barcode: '480000000101',
        priceCents: 5000,
        costCents: 3000);
    expect((await pos.products()).any((p) => p.id == rc), isTrue);
    expect((await pos.stockLevels())[rc]?.$1, 0);

    await receiving
        .receive(actor, supplier.id, [ReceivingLineRequest(rc, 100000, 3000)]);
    expect(
        (await pos.products()).singleWhere((p) => p.id == rc).isActive, isTrue);
    expect((await pos.stockLevels())[rc], (100000, 0));
    expect(await pos.stockMilli(rc), 100000);
    expect((await pos.layersForProduct(rc)).length, 1);

    await receiving
        .receive(actor, supplier.id, [ReceivingLineRequest(rc, 50000, 3200)]);
    expect((await pos.stockLevels())[rc], (150000, 0));
    final layers = await pos.layersForProduct(rc);
    expect(layers.map((layer) => layer.quantityRemainingMilli),
        unorderedEquals([100000, 50000]));
    expect(layers.map((layer) => layer.unitCostCents),
        unorderedEquals([3000, 3200]));
    expect((await pos.movements(rc)).length, 2);
  });
}
