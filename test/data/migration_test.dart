import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('v3 reversal migration marks existing restored stock', () async {
    final dir = await Directory.systemTemp.createTemp('pos-migration-');
    final file = File('${dir.path}/legacy.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('CREATE TABLE sale_reversals (id TEXT PRIMARY KEY, '
        'sale_id TEXT NOT NULL UNIQUE, actor_id TEXT NOT NULL, '
        'kind TEXT NOT NULL, amount_cents INTEGER NOT NULL, '
        'created_at INTEGER NOT NULL)');
    raw.execute("INSERT INTO sale_reversals VALUES "
        "('r1', 's1', 'u1', 'refund', 4000, 0)");
    raw.execute('PRAGMA user_version = 3');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final reversal = (await db.select(db.saleReversals).get()).single;
      expect(reversal.id, 'r1');
      expect(reversal.stockRestored, true);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('v2 to v3 migration preserves Phase 2 sale and placeholder attribution',
      () async {
    final dir = await Directory.systemTemp.createTemp('pos-migration-');
    final file = File('${dir.path}/legacy.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
        'CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT NOT NULL, pin_hash TEXT, password_hash TEXT, role TEXT NOT NULL, is_active INTEGER NOT NULL DEFAULT 1)');
    raw.execute(
        'CREATE TABLE products (id TEXT PRIMARY KEY, sku TEXT, barcode TEXT, category_id TEXT, name TEXT NOT NULL, price_cents INTEGER NOT NULL, cost_cents INTEGER, is_active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE inventory (product_id TEXT PRIMARY KEY, quantity INTEGER NOT NULL DEFAULT 0)');
    raw.execute(
        'CREATE TABLE inventory_movements (id TEXT PRIMARY KEY, product_id TEXT NOT NULL, quantity_delta INTEGER NOT NULL, reason TEXT NOT NULL, reference_id TEXT, created_at INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE sales (id TEXT PRIMARY KEY, cashier_id TEXT NOT NULL, total_cents INTEGER NOT NULL, status TEXT NOT NULL DEFAULT \'completed\', created_at INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE sale_items (id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, product_id TEXT NOT NULL, quantity INTEGER NOT NULL, unit_price_cents INTEGER NOT NULL, line_total_cents INTEGER NOT NULL DEFAULT 0)');
    raw.execute(
        'CREATE TABLE payments (id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, method TEXT NOT NULL, amount_cents INTEGER NOT NULL)');
    raw.execute(
        "INSERT INTO users VALUES ('phase2-local-cashier', 'Local cashier', NULL, NULL, 'cashier', 1)");
    raw.execute(
        "INSERT INTO products VALUES ('p1', 'COKE', '123', NULL, 'Coke', 4000, 2000, 1, 0)");
    raw.execute("INSERT INTO inventory VALUES ('p1', 8)");
    raw.execute(
        "INSERT INTO inventory_movements VALUES ('m1', 'p1', 10, 'initial_stock', NULL, 0)");
    raw.execute(
        "INSERT INTO inventory_movements VALUES ('m2', 'p1', -2, 'sale', 's1', 0)");
    raw.execute(
        "INSERT INTO sales VALUES ('s1', 'phase2-local-cashier', 8000, 'completed', 0)");
    raw.execute(
        "INSERT INTO sale_items VALUES ('si1', 's1', 'p1', 2, 4000, 8000)");
    raw.execute("INSERT INTO payments VALUES ('pay1', 's1', 'cash', 8000)");
    raw.execute('PRAGMA user_version = 2');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect((await db.select(db.sales).get()).single.cashierId,
          'phase2-local-cashier');
      expect((await db.select(db.saleItems).get()).single.unitPriceCents, 4000);
      expect((await db.select(db.payments).get()).single.amountCents, 8000);
      expect((await db.select(db.inventory).get()).single.quantity, 8);
      expect((await db.select(db.inventoryMovements).get()).length, 2);
      expect((await db.select(db.products).get()).single.lowStockThreshold, 5);
      expect((await db.select(db.users).get()).single.name, 'Local cashier');
      expect(await db.select(db.saleReversals).get(), isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
