import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/models/kit_component_choice.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/product_kit_repository.dart';
import 'package:modern_offline_pos/data/daos/product_margin_repository.dart';
import 'package:modern_offline_pos/data/daos/promotion_repository.dart';
import 'package:modern_offline_pos/data/daos/sale_return_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<(AppDatabase, ActiveUser, PosRepository, ProductKitRepository)> setup() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final auth = AuthService(AuthRepository(db));
  final ownerId = await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
  final owner = await auth.login(ownerId, 'ownerPassword123');
  final pos = PosRepository(db);
  return (db, owner, pos, ProductKitRepository(db));
}

Future<String> kit(PosRepository pos, ProductKitRepository kits, ActiveUser owner,
    String name, Map<String, int> components, {int price = 1000}) async {
  final id = await pos.saveProduct(name: name, sku: 'KIT-${name.replaceAll(' ', '-').toUpperCase()}', priceCents: price,
    costCents: 0, productType: 'kit', isActive: false);
  for (final entry in components.entries) {
    await kits.addComponent(owner, id, entry.key, entry.value);
  }
  await pos.saveProduct(id: id, name: name, sku: 'KIT-${name.replaceAll(' ', '-').toUpperCase()}', priceCents: price,
    costCents: 0, productType: 'kit', isActive: true);
  return id;
}

SaleLineRequest kitRequest(String id, int qty, String signature,
    {Map<String, KitComponentChoice> choices = const {}}) =>
    SaleLineRequest(id, qty, kitDefinition: signature, kitChoices: choices);

void main() {
  test('schema 54 migrates snapshots additively and backup accepts 55', () async {
    final dir = await Directory.systemTemp.createTemp('kit-sale-migrate-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    final product = await PosRepository(db).saveProduct(
      name: 'Existing', priceCents: 100, costCents: 20);
    await db.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE sale_item_kit_allocations');
    raw.execute('DROP TABLE sale_item_kit_components');
    raw.execute('ALTER TABLE sale_items DROP COLUMN sku_snapshot');
    raw.execute('''CREATE TRIGGER kit_no_sale_items_insert BEFORE INSERT ON sale_items
      WHEN (SELECT product_type FROM products WHERE id = NEW.product_id) = 'kit'
      BEGIN SELECT RAISE(ABORT, 'Kit products have no physical stock or O1 transactions'); END''');
    raw.execute('PRAGMA user_version = 54');
    raw.dispose();
    db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await db.select(db.products).getSingle()).id, product);
    expect(db.schemaVersion, 55);
    await db.close();
    expect(BackupService.verify(file), 55);
  });

  test('kit is one commercial line and allocates component FIFO exactly once', () async {
    final (db, owner, pos, kits) = await setup();
    addTearDown(db.close);
    final a = await pos.saveProduct(name: 'Keyboard', priceCents: 900,
      costCents: 100, startingStock: 1);
    await db.into(db.inventoryLayers).insert(InventoryLayersCompanion.insert(
      productId: a, quantityReceivedMilli: 2000,
      quantityRemainingMilli: 2000, unitCostCents: 200));
    await db.customStatement('''UPDATE inventory SET quantity = 3,
      quantity_milli = 3000 WHERE product_id = ?''', [a]);
    final b = await pos.saveProduct(name: 'Mouse', priceCents: 500,
      costCents: 50, startingStock: 3);
    final id = await kit(pos, kits, owner, 'Bundle', {a: 1000, b: 1000}, price: 1299);
    final signature = await kits.definitionSignature(id);
    await CashSessionRepository(db).open(owner, 0);
    final sale = await pos.completeCashSale([kitRequest(id, 2, signature)], 2598, owner.id);
    final items = await db.select(db.saleItems).get();
    expect(items, hasLength(1));
    expect(items.single.productId, id);
    expect(items.single.skuSnapshot, isNotNull);
    final originalSku = items.single.skuSnapshot;
    expect(items.single.lineTotalCents, 2598);
    expect(await pos.stockMilli(id), 0);
    expect(await pos.stockMilli(a), 1000);
    expect(await pos.stockMilli(b), 1000);
    final snapshots = await db.customSelect(
      'SELECT * FROM sale_item_kit_components WHERE sale_item_id = ?',
      variables: [Variable.withString(items.single.id)]).get();
    expect(snapshots, hasLength(2));
    expect(snapshots.map((r) => r.read<int>('allocated_cost_cents')).reduce((x,y) => x+y), 400);
    final allocations = await (db.select(db.saleItemInventoryAllocations)
      ..where((a) => a.saleItemId.equals(items.single.id))).get();
    expect(allocations, hasLength(3));
    expect(allocations.fold<int>(0, (n, a) => n + a.quantityMilli), 4000);
    expect((await db.select(db.inventoryMovements).get())
      .where((m) => m.referenceId == sale.saleId).map((m) => m.productId).toSet(),
      {a,b});
    expect((await kits.availability(id)).availableKits, 1);
    final detail = await SalesRepository(db).detail(owner, sale.saleId);
    expect(detail.kitComponentsByItem[items.single.id], hasLength(2));
    await kits.updateQuantity(owner, id, a, 2000);
    await pos.saveProduct(id: id, name: 'Renamed bundle', sku: 'NEW-KIT-SKU',
      priceCents: 5000, costCents: 0, productType: 'kit', isActive: true);
    expect((await db.select(db.saleItems).getSingle()).skuSnapshot, originalSku);
    expect((await db.select(db.saleItems).getSingle()).lineTotalCents, 2598);
    expect((await SalesRepository(db).detail(owner, sale.saleId))
      .kitComponentsByItem[items.single.id]!
      .any((c) => c.name == 'Keyboard' && c.quantityMilli == 2000), isTrue);
    expect((await SaleReturnRepository(db).returnable(sale.saleId)).single.limitation,
      contains('Kit returns'));
    await expectLater(SalesRepository(db).reverse(owner, sale.saleId, 'void',
      stockRestored: true),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Kit sale'))));
  });

  test('shared kit and direct demand cannot oversubscribe; failure rolls back', () async {
    final (db, owner, pos, kits) = await setup();
    addTearDown(db.close);
    final component = await pos.saveProduct(name: 'Cable', priceCents: 100,
      costCents: 20, startingStock: 3);
    final first = await kit(pos, kits, owner, 'First kit', {component: 2000});
    final second = await kit(pos, kits, owner, 'Second kit', {component: 1000});
    final firstSig = await kits.definitionSignature(first);
    final secondSig = await kits.definitionSignature(second);
    await expectLater(pos.completeCashSale([
      kitRequest(first, 1, firstSig), kitRequest(second, 1, secondSig),
      SaleLineRequest(component, 1)
    ], 2100, owner.id), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await pos.stockMilli(component), 3000);
    await expectLater(pos.completeCashSale([
      kitRequest(first, 1, firstSig), kitRequest(second, 2, secondSig)
    ], 3000, owner.id), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    await kits.updateQuantity(owner, first, component, 1000);
    await expectLater(pos.completeCashSale([
      kitRequest(first, 1, firstSig)
    ], 1000, owner.id), throwsA(isA<StateError>().having((e) => e.message,
      'message', contains('Kit definition changed'))));
  });

  test('kit promotion discounts one commercial line, not hidden components', () async {
    final (db, owner, pos, kits) = await setup();
    addTearDown(db.close);
    final component = await pos.saveProduct(name: 'Accessory', priceCents: 5000,
      costCents: 100, startingStock: 2);
    final id = await kit(pos, kits, owner, 'Promo kit', {component: 1000}, price: 1000);
    await PromotionRepository(db).createPromotion(owner, PromotionInput(
      name: 'Kit ten percent', type: 'percentage', rewardKind: 'percentage',
      rewardValue: 1000, targetMode: 'products', productIds: [id], active: true));
    final sale = await pos.completeCashSale([
      kitRequest(id, 1, await kits.definitionSignature(id))
    ], 900, owner.id);
    final items = await (db.select(db.saleItems)).get();
    expect(items, hasLength(1));
    expect(items.single.productId, id);
    expect(items.single.promotionDiscountCents, 100);
    expect(items.single.lineTotalCents, 900);
    expect((await db.select(db.salePromotionApplications).get()), hasLength(1));
    expect((await db.select(db.sales).getSingle()).id, sale.saleId);
  });

  test('kit expected margin and below-cost guard use component FIFO cost', () async {
    final (db, owner, pos, kits) = await setup();
    addTearDown(db.close);
    final component = await pos.saveProduct(name: 'Expensive component',
      priceCents: 50, costCents: 2000, openingCostCents: 2000,
      startingStock: 1);
    final id = await kit(pos, kits, owner, 'Loss kit', {component: 1000}, price: 1000);
    final signature = await kits.definitionSignature(id);
    final product = (await pos.products()).singleWhere((p) => p.id == id);
    final cart = Cart()..add(product);
    cart.lines.single.kitDefinition = signature;
    final quote = await ProductMarginRepository(db).quoteCart(cart, 1000);
    expect(quote.expectedCostCents, 2000);
    await expectLater(pos.completeCashSale([kitRequest(id, 1, signature)],
      1000, owner.id), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await pos.stockMilli(component), 1000);
  });

  test('kit credit sale uses normal receivable and one commercial line', () async {
    final (db, owner, pos, kits) = await setup();
    addTearDown(db.close);
    final component = await pos.saveProduct(name: 'Credit component',
      priceCents: 3000, costCents: 100, startingStock: 1);
    final id = await kit(pos, kits, owner, 'Credit kit', {component: 1000}, price: 2000);
    final customer = await db.into(db.customers).insertReturning(
      CustomersCompanion.insert(name: 'Kit customer'));
    final sale = await pos.completeCreditSale([
      kitRequest(id, 1, await kits.definitionSignature(id))
    ], 0, customer.id, owner.id);
    expect(sale.totalCents, 2000);
    expect((await db.select(db.saleItems).get()).single.productId, id);
    expect((await db.select(db.customerCreditEntries).get())
      .any((entry) => entry.saleId == sale.saleId), isTrue);
    expect(await pos.stockMilli(component), 0);
  });

  test('BIR kit sale advances one invoice for kit revenue only', () async {
    final dir = await Directory.systemTemp.createTemp('kit-bir-');
    addTearDown(() => dir.delete(recursive: true));
    final (db, owner, pos, kits) = await setup();
    addTearDown(db.close);
    final component = await pos.saveProduct(name: 'BIR component',
      priceCents: 5000, costCents: 100, startingStock: 1);
    final id = await kit(pos, kits, owner, 'BIR kit', {component: 1000}, price: 1000);
    final protection = ComplianceProtection(File('${dir.path}/compliance.json'));
    await CashSessionRepository(db, birReady: true, protection: protection)
      .open(owner, 0);
    final birPos = PosRepository(db, birReady: true, protection: protection);
    final sale = await birPos.completeCashSale([
      kitRequest(id, 1, await kits.definitionSignature(id))
    ], 1000, owner.id);
    expect(sale.birInvoiceNumber, 1);
    expect((await db.select(db.birComplianceState).getSingle()).grandTotalCents, 1000);
    expect((await db.select(db.saleItems).get()).single.productId, id);
    expect(await pos.stockMilli(component), 0);
  });

  test('serialized and batch components require exact selections', () async {
    final (db, owner, pos, kits) = await setup();
    addTearDown(db.close);
    await BusinessFeatureRepository(db).setEnabled(
      BusinessFeature.expiryBatchTracking, true, owner);
    final serialProduct = await pos.saveProduct(name: 'Monitor', priceCents: 1000,
      costCents: 400, startingStock: 1, serialTracking: true,
      openingSerials: ['MON-1']);
    final batchProduct = await pos.saveProduct(name: 'Food', priceCents: 100,
      costCents: 20, startingStock: 1,
      business: const BusinessProduct(batch: true), batchNumber: 'LOT-1');
    final id = await kit(pos, kits, owner, 'Special kit',
      {serialProduct: 1000, batchProduct: 1000}, price: 2000);
    final sig = await kits.definitionSignature(id);
    await expectLater(pos.completeCashSale([kitRequest(id, 1, sig)], 2000, owner.id),
      throwsStateError);
    final serial = (await pos.availableSerials(serialProduct)).single;
    final batch = (await pos.batches(batchProduct)).single;
    final sale = await pos.completeCashSale([kitRequest(id, 1, sig, choices: {
      serialProduct: KitComponentChoice(serialIds: [serial.id]),
      batchProduct: KitComponentChoice(batchId: batch.id),
    })], 2000, owner.id);
    expect((await db.select(db.serialUnits).get()).single.status, 'sold');
    expect((await pos.batches(batchProduct)).single.quantityMilli, 0);
    expect((await SalesRepository(db).detail(owner, sale.saleId))
      .kitComponentsByItem.values.single.any((c) => c.serials.contains('MON-1')),
      isTrue);
  });
}
