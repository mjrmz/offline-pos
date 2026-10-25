import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/import_repository.dart';
import 'package:modern_offline_pos/data/daos/inventory_layer_repository.dart';
import 'package:modern_offline_pos/data/daos/inventory_movement_repository.dart';
import 'package:modern_offline_pos/data/daos/opening_inventory_import_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  late AppDatabase db;
  late OpeningInventoryImportRepository opening;
  late ActiveUser owner;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    opening = OpeningInventoryImportRepository(db);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Recovery?', 'Baguio');
    owner = ActiveUser(id, 'Owner', UserRole.owner);
  });
  tearDown(() => db.close());

  Future<Product> product(String name, String sku,
      {bool serial = false, bool batch = false}) async {
    final row = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(
            name: name,
            priceCents: 1000,
            sku: Value(sku),
            serialTracking: Value(serial),
            costCents: const Value(500)));
    if (batch) {
      await db.into(db.productBusinessConfigurations).insert(
          ProductBusinessConfigurationsCompanion.insert(
              productId: row.id,
              featureId: BusinessFeature.expiryBatchTracking.name,
              configurationJson: '{"enabled":true}'));
    }
    return row;
  }

  Future<(ImportPreview, List<List<String>>, Map<String, String>)> check(
      String source) async {
    final csv = ImportCsv.parse(source);
    final mapping = ImportCsv.autoMap(csv.first, ImportKind.openingInventory);
    return (await opening.validate(csv, mapping), csv, mapping);
  }

  test(
      'normal opening creates stock, FIFO layer, movement, audit; no procurement',
      () async {
    final p = await product('A', 'A1');
    final (preview, csv, mapping) =
        await check('sku,quantity,unit_cost\nA1,2,5.25\n');
    expect(preview.ready, 1);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
    final result =
        await opening.commit(owner, preview, csv, mapping, 'opening.csv');
    expect(result.valueCents, 1050);
    final layer = (await db.select(db.inventoryLayers).get()).single;
    expect(layer.productId, p.id);
    expect(layer.source, 'opening');
    expect(layer.quantityRemainingMilli, 2000);
    expect(layer.unitCostCents, 525);
    expect((await db.select(db.inventory).get()).single.quantityMilli, 2000);
    expect((await db.select(db.inventoryMovements).get()).single.reason,
        'opening_inventory_import');
    final movementPage =
        await InventoryMovementRepository(db).page(type: 'Opening Inventory');
    expect(movementPage.items.length, 1);
    expect(
        (await InventoryMovementRepository(db)
                .page(search: 'Opening Inventory'))
            .items
            .length,
        1);
    expect(await db.select(db.stockReceivings).get(), isEmpty);
    expect(await db.select(db.purchaseOrders).get(), isEmpty);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.cashMovements).get(), isEmpty);
    expect(await db.select(db.pettyCashEntries).get(), isEmpty);
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'import.opening_inventory')
            .length,
        1);
  });

  test('batch rows create separate layers and exact lots', () async {
    await product('Medicine', 'M1', batch: true);
    final (preview, csv, mapping) = await check(
        'sku,quantity,unit_cost,batch_lot,expiry_date\nM1,10,5,B100,2027-01-31\nM1,5,5.20,B101,2027-02-28\n');
    expect(preview.ready, 2);
    await opening.commit(owner, preview, csv, mapping, 'batches.csv');
    final layers = await db.select(db.inventoryLayers).get();
    expect(layers.map((l) => l.batchNumber).toSet(), {'B100', 'B101'});
    expect(layers.map((l) => l.unitCostCents).toSet(), {500, 520});
    expect((await db.select(db.productLots).get()).length, 2);
  });

  test('serialized rows create available serials and reject duplicates',
      () async {
    await product('Laptop', 'L1', serial: true);
    final (preview, csv, mapping) = await check(
        'sku,quantity,unit_cost,serial_number\nL1,1,25000,SN001\nL1,1,25000,SN002\n');
    expect(preview.ready, 2);
    await opening.commit(owner, preview, csv, mapping, 'serials.csv');
    final serials = await db.select(db.serialUnits).get();
    expect(serials.map((s) => s.serialNumber).toSet(), {'SN001', 'SN002'});
    expect(
        serials.every(
            (s) => s.status == 'available' && s.inventoryLayerId != null),
        isTrue);
    final (duplicate, _, _) =
        await check('sku,quantity,unit_cost,serial_number\nL1,1,25000,SN001\n');
    expect(duplicate.errors, 1);
  });

  test(
      'real activity blocks, prior opening warns, invalid quantity and cost fail',
      () async {
    final p = await product('A', 'A1');
    final (first, csv, mapping) =
        await check('sku,quantity,unit_cost\nA1,1,5\n');
    await opening.commit(owner, first, csv, mapping, 'first.csv');
    final (again, _, _) = await check('sku,quantity,unit_cost\nA1,1,5\n');
    expect(again.rows.single.action, ImportAction.skip);
    await db.into(db.inventoryMovements).insert(
        InventoryMovementsCompanion.insert(
            productId: p.id,
            quantityDelta: 1,
            reason: 'stock_adjustment_increase'));
    final (blocked, _, _) = await check('sku,quantity,unit_cost\nA1,1,5\n');
    expect(blocked.errors, 1);
    final (invalid, _, _) =
        await check('sku,quantity,unit_cost\nA1,1.2345,abc\n');
    expect(invalid.rows.single.errors.length, greaterThanOrEqualTo(2));
  });

  test('opening layers enter FIFO in CSV row order', () async {
    final p = await product('A', 'A1');
    final (preview, csv, mapping) =
        await check('sku,quantity,unit_cost\nA1,1,2\nA1,1,3\n');
    await opening.commit(owner, preview, csv, mapping, 'fifo.csv');
    final selected =
        await InventoryLayerRepository(db).consume(p.id, 1000, commit: false);
    expect(selected.single.layer.unitCostCents, 200);
  });

  test('conflicting identifiers and invalid dates are rejected', () async {
    await product('A', 'A1');
    await product('B', 'B1');
    final (conflict, _, _) =
        await check('sku,product,quantity,unit_cost\nA1,B,1,5\n');
    expect(conflict.rows.single.errors,
        contains('Identifiers refer to different products'));
    final (date, _, _) =
        await check('sku,quantity,unit_cost,expiry_date\nA1,1,5,2027-02-30\n');
    expect(date.errors, 1);
  });

  test('unexpected conflict rolls back every opening row', () async {
    await product('A', 'A1', serial: true);
    final (preview, csv, mapping) = await check(
        'sku,quantity,unit_cost,serial_number\nA1,1,5,S1\nA1,1,5,S2\n');
    preview.rows.last.values['serial_number'] = 'S1';
    await expectLater(opening.commit(owner, preview, csv, mapping, 'bad.csv'),
        throwsStateError);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
    expect(await db.select(db.inventoryMovements).get(), isEmpty);
  });

  test('prior opening requires explicit add and keeps both layers', () async {
    await product('A', 'A1');
    final (first, csv, mapping) =
        await check('sku,quantity,unit_cost\nA1,1,5\n');
    await opening.commit(owner, first, csv, mapping, 'first.csv');
    final (second, csv2, mapping2) =
        await check('sku,quantity,unit_cost\nA1,2,6\n');
    expect(second.rows.single.action, ImportAction.skip);
    second.rows.single.action = ImportAction.create;
    await opening.commit(owner, second, csv2, mapping2, 'second.csv');
    expect((await db.select(db.inventoryLayers).get()).length, 2);
    expect((await db.select(db.inventory).get()).single.quantityMilli, 3000);
  });

  test('fractional quantity follows product unit configuration', () async {
    final p = await product('Flour', 'F1');
    await db.into(db.productBusinessConfigurations).insert(
          ProductBusinessConfigurationsCompanion.insert(
            productId: p.id,
            featureId: BusinessFeature.unitOfMeasureVariety.name,
            configurationJson: '{"enabled":true,"unit":"kilogram"}',
          ),
        );
    final (valid, csv, mapping) =
        await check('sku,quantity,unit_cost\nF1,2.500,12.50\n');
    expect(valid.ready, 1);
    await opening.commit(owner, valid, csv, mapping, 'fraction.csv');
    expect((await db.select(db.inventory).get()).single.quantityMilli, 2500);
  });
}
