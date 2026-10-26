import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/global_search_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/product_barcode_alias_repository.dart';
import 'package:modern_offline_pos/data/daos/product_kit_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('schema 53 upgrades existing products as standard and backup accepts 55',
      () async {
    final dir = await Directory.systemTemp.createTemp('kit-migrate-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    final productId = await PosRepository(db)
        .saveProduct(name: 'Existing', priceCents: 100, costCents: 20);
    await db.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TRIGGER kit_product_type_immutable');
    raw.execute('DROP TRIGGER kit_activation_requires_component');
    raw.execute('DROP TRIGGER kit_create_inactive');
    raw.execute('DROP TRIGGER kit_component_archive_guard');
    raw.execute('DROP TRIGGER kit_component_validate_insert');
    raw.execute('DROP TRIGGER kit_component_validate_update');
    raw.execute('DROP TRIGGER kit_last_component_guard');
    for (final row in raw.select(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'kit_no_%'")) {
      raw.execute('DROP TRIGGER ${row['name']}');
    }
    raw.execute('DROP TABLE product_kit_components');
    raw.execute('ALTER TABLE products DROP COLUMN product_type');
    raw.execute('PRAGMA user_version = 53');
    raw.dispose();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await db.select(db.products).getSingle()).id, productId);
    expect((await db.select(db.products).getSingle()).productType, 'standard');
    expect(db.schemaVersion, 55);
    await db.close();
    expect(BackupService.verify(file), 55);
  });

  test('kit availability, cost, price, validation and transaction guards',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    final owner = await auth.login(ownerId, 'ownerPassword123');
    final pos = PosRepository(db);
    final kits = ProductKitRepository(db);
    final a = await pos.saveProduct(
        name: 'A', priceCents: 500, costCents: 100, startingStock: 7);
    final b = await pos.saveProduct(
        name: 'B', priceCents: 300, costCents: 50, startingStock: 10);
    final kit = await pos.saveProduct(
        name: 'Bundle',
        barcode: 'KIT-001',
        priceCents: 1299,
        costCents: 0,
        productType: 'kit',
        isActive: false,
        actorId: owner.id);
    expect(await pos.stockMilli(kit), 0);
    expect(await db.select(db.inventory).get(), hasLength(2));
    await expectLater(
        pos.saveProduct(
            id: kit,
            name: 'Bundle',
            priceCents: 1299,
            costCents: 0,
            productType: 'kit',
            isActive: true),
        throwsStateError);
    await kits.addComponent(owner, kit, a, 2000);
    await kits.addComponent(owner, kit, b, 1000);
    await kits.updateQuantity(owner, kit, b, 2000);
    await kits.updateQuantity(owner, kit, b, 1000);
    await kits.removeComponent(owner, kit, b);
    await kits.addComponent(owner, kit, b, 1000);
    await expectLater(
        kits.addComponent(owner, kit, a, 1000), throwsA(anything));
    await expectLater(
        kits.addComponent(owner, kit, kit, 1000), throwsStateError);
    final nested = await pos.saveProduct(
        name: 'Nested',
        priceCents: 100,
        costCents: 0,
        productType: 'kit',
        isActive: false);
    await expectLater(
        kits.addComponent(owner, kit, nested, 1000), throwsStateError);
    final result = await kits.availability(kit);
    expect(result.availableKits, 3);
    expect(result.limitingComponent, 'A');
    expect(result.estimatedCostCents, 250);
    final customer = await db
        .into(db.customers)
        .insertReturning(CustomersCompanion.insert(name: 'Customer'));
    final layaway = await db.into(db.layaways).insertReturning(
        LayawaysCompanion.insert(
            reference: 'KIT-TEST-LAY',
            customerId: customer.id,
            createdBy: owner.id,
            totalCents: 100));
    await db.into(db.layawayItems).insert(LayawayItemsCompanion.insert(
        layawayId: layaway.id,
        productId: a,
        quantityMilli: 2000,
        unitSnapshot: 'pcs',
        unitPriceCents: 100,
        lineTotalCents: 200));
    expect((await kits.availability(kit)).availableKits, 2);
    await expectLater(
        db.into(db.layawayItems).insert(LayawayItemsCompanion.insert(
            layawayId: layaway.id,
            productId: kit,
            quantityMilli: 1000,
            unitSnapshot: 'pcs',
            unitPriceCents: 1299,
            lineTotalCents: 1299)),
        throwsA(anything));
    await pos.saveProduct(id: a, name: 'A', priceCents: 900, costCents: 100);
    expect((await pos.productsByIds([kit])).single.priceCents, 1299);
    await pos.saveProduct(
        id: kit,
        name: 'Bundle',
        barcode: 'KIT-001',
        priceCents: 1299,
        costCents: 0,
        productType: 'kit',
        isActive: true);
    await ProductBarcodeAliasRepository(db).add(owner, kit, 'KIT-ALT');
    expect((await pos.barcode('KIT-001'))?.id, kit);
    expect((await pos.barcode('KIT-ALT'))?.id, kit);
    expect(
        (await GlobalSearchRepository(db).search(owner, 'KIT-ALT')).any(
            (row) => row.kind == GlobalSearchKind.product && row.id == kit),
        isTrue);
    await CashSessionRepository(db).open(owner, 0);
    await expectLater(
        pos.completeCashSale([SaleLineRequest(kit, 1)], 1299, owner.id),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('Kit definition changed'))));
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await pos.stockMilli(a), 7000);
    await kits.removeComponent(owner, kit, b);
    await expectLater(kits.removeComponent(owner, kit, a), throwsStateError);
    await kits.addComponent(owner, kit, b, 1000);
    await expectLater(
        pos.saveProduct(
            id: a, name: 'A', priceCents: 900, costCents: 100, isActive: false),
        throwsA(anything));
    await expectLater(
        db.customStatement(
            'INSERT INTO inventory (product_id) VALUES (?)', [kit]),
        throwsA(anything));
    await expectLater(
        db.customStatement(
            'INSERT INTO inventory_layers (id, product_id, source, quantity_received_milli, quantity_remaining_milli, unit_cost_cents, received_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
            ['x', kit, 'opening', 1000, 1000, 100, 0]),
        throwsA(anything));
    await expectLater(
        db.customStatement(
            'INSERT INTO purchase_order_lines (id, purchase_order_id, product_id, ordered_qty_milli, expected_unit_cost_cents) VALUES (?, ?, ?, ?, ?)',
            ['po-kit', 'missing', kit, 1000, 100]),
        throwsA(anything));
    await expectLater(
        db.customStatement(
            'INSERT INTO stock_receiving_items (id, receiving_id, product_id, quantity_milli, unit_cost_cents) VALUES (?, ?, ?, ?, ?)',
            ['recv-kit', 'missing', kit, 1000, 100]),
        throwsA(anything));
    await expectLater(
        db.customStatement(
            'INSERT INTO sale_items (id, sale_id, product_id, quantity, unit_price_cents) VALUES (?, ?, ?, ?, ?)',
            ['sale-kit', 'missing', kit, 1, 1299]),
        throwsA(anything));
    await db.into(db.users).insert(UsersCompanion.insert(
        id: const Value('cashier'), name: 'Cashier', role: 'cashier'));
    await expectLater(
        kits.addComponent(
            const ActiveUser('cashier', 'Cashier', UserRole.cashier),
            kit,
            b,
            1000),
        throwsStateError);
    final actions =
        (await db.select(db.auditLogs).get()).map((row) => row.action).toSet();
    expect(
        actions,
        containsAll([
          'kit.created',
          'kit.component_added',
          'kit.component_quantity_changed',
          'kit.component_removed'
        ]));
  });

  test(
      'fractional requirements use fixed point units and missing cost is unknown',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    final owner = await auth.login(ownerId, 'ownerPassword123');
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.unitOfMeasureVariety, true, owner);
    final pos = PosRepository(db);
    final flour = await pos.saveProduct(
        name: 'Flour',
        priceCents: 100,
        costCents: 40,
        startingStockMilli: 1500,
        business: const BusinessProduct(unit: SaleUnit.kilogram));
    final kit = await pos.saveProduct(
        name: 'Baking Kit',
        priceCents: 500,
        costCents: 0,
        productType: 'kit',
        isActive: false);
    final kits = ProductKitRepository(db);
    await kits.addComponent(owner, kit, flour, 500);
    expect((await kits.availability(kit)).availableKits, 3);
    expect((await kits.availability(kit)).estimatedCostCents, 20);
    final empty =
        await pos.saveProduct(name: 'Empty', priceCents: 100, costCents: 0);
    await kits.addComponent(owner, kit, empty, 1000);
    final view = await kits.availability(kit);
    expect(view.availableKits, 0);
    expect(view.estimatedCostCents, isNull);
  });
}
