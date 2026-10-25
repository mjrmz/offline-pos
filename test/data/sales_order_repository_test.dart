import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_order_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('schema 46 adds order tables without changing business rows', () async {
    final dir = await Directory.systemTemp.createTemp('sales-order-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO categories (id, name) VALUES ('c1', 'Food')");
    await seed.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE sales_order_fulfillment_lines');
    raw.execute('DROP TABLE sales_order_fulfillments');
    raw.execute('DROP TABLE stock_reservations');
    raw.execute('DROP TABLE sales_order_lines');
    raw.execute('DROP TABLE sales_orders');
    raw.execute('PRAGMA user_version = 46');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    expect(db.schemaVersion, 50);
    expect((await db.select(db.categories).get()).single.name, 'Food');
    expect(await db.select(db.salesOrders).get(), isEmpty);
    expect(await db.select(db.salesOrderLines).get(), isEmpty);
    await db.close();
  });

  test('draft, snapshots, transitions and zero financial or stock effect', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('c1', 'Ana', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, sku, price_cents, created_at) VALUES ('p1', 'Bread', 'BRD', 12500, 0)");
    final repo = SalesOrderRepository(db);
    expect(() => repo.create(owner, 'c1', []), throwsStateError);
    expect(() => repo.create(owner, 'missing',
        [const SalesOrderLineRequest('p1', 1000, 12500)]), throwsStateError);
    expect(() => repo.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 0, 12500)]), throwsStateError);
    final order = await repo.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 12000, 12500)],
        fulfillmentMethod: 'pickup');
    expect(order.reference, 'SO-000001');
    expect(order.totalCents, 150000);
    await db.customStatement(
        "UPDATE products SET name='Renamed', price_cents=1 WHERE id='p1'");
    expect((await repo.lines(order.id)).single.descriptionSnapshot, 'Bread');
    expect((await repo.lines(order.id)).single.unitPriceCents, 12500);
    final revised = await repo.updateDraft(owner, order.id, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 10000)], notes: 'Updated');
    expect(revised.totalCents, 10000);
    expect(revised.notes, 'Updated');
    expect((await repo.transition(owner, order.id, 'confirmed')).status,
        'confirmed');
    expect(() => repo.updateDraft(owner, order.id, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 10000)]), throwsStateError);
    expect(() => repo.transition(owner, order.id, 'confirmed'),
        throwsStateError);
    expect((await repo.transition(owner, order.id, 'cancelled')).status,
        'cancelled');
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.cashMovements).get(), isEmpty);
    expect(await db.select(db.customerCreditEntries).get(), isEmpty);
    expect(await db.select(db.inventory).get(), isEmpty);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
    expect(await db.select(db.serialUnits).get(), isEmpty);
  });

  test('quotation conversion copies persisted values without changing quotation', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('c1', 'Ana', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, sku, price_cents, created_at) VALUES ('p1', 'New Bread', 'NEW', 50000, 0)");
    await db.customStatement(
        "INSERT INTO quotations (id, reference, customer_id, customer_name_snapshot, created_by, created_at) VALUES ('q1', 'Q-2026-000001', 'c1', 'Ana', ?, 0)",
        [id]);
    await db.customStatement(
        "INSERT INTO quotation_items (id, quotation_id, product_id, product_name_snapshot, sku_snapshot, quantity_milli, unit_snapshot, unit_price_cents, line_total_cents) VALUES ('qi1', 'q1', 'p1', 'Old Bread', 'OLD', 2000, 'pcs', 12500, 25000)");
    final repo = SalesOrderRepository(db);
    final order = await repo.convertQuotation(owner, 'q1');
    expect(order.sourceQuotationId, 'q1');
    expect(order.totalCents, 25000);
    final line = (await repo.lines(order.id)).single;
    expect(line.descriptionSnapshot, 'Old Bread');
    expect(line.skuSnapshot, 'OLD');
    expect(line.unitPriceCents, 12500);
    expect((await db.select(db.quotations).get()).single.status, 'open');
    expect((await db.select(db.quotationItems).get()).single.lineTotalCents,
        25000);
  });
}
