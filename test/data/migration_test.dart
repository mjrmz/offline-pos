import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:modern_offline_pos/backup/backup_service.dart';

void main() {
  test('v1 to v7 preserves historic sale, stock, cash session and audit',
      () async {
    final dir = await Directory.systemTemp.createTemp('pos-migration-v1-');
    final file = File('${dir.path}/phase1.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
        'CREATE TABLE products (id TEXT PRIMARY KEY, sku TEXT, barcode TEXT, '
        'name TEXT NOT NULL, price_cents INTEGER NOT NULL, cost_cents INTEGER, '
        'is_active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL)');
    raw.execute('CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
        'pin_hash TEXT, password_hash TEXT, role TEXT NOT NULL, '
        'is_active INTEGER NOT NULL DEFAULT 1)');
    raw.execute('CREATE TABLE inventory_movements (id TEXT PRIMARY KEY, '
        'product_id TEXT NOT NULL, quantity_delta INTEGER NOT NULL, '
        'reason TEXT NOT NULL, reference_id TEXT, created_at INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE sales (id TEXT PRIMARY KEY, cashier_id TEXT NOT NULL, '
        'total_cents INTEGER NOT NULL, status TEXT NOT NULL DEFAULT \'completed\', '
        'created_at INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE sale_items (id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, '
        'product_id TEXT NOT NULL, quantity INTEGER NOT NULL, '
        'unit_price_cents INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE payments (id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, '
        'method TEXT NOT NULL, amount_cents INTEGER NOT NULL)');
    raw.execute('CREATE TABLE cash_sessions (id TEXT PRIMARY KEY, '
        'opened_by_user_id TEXT NOT NULL, starting_cash_cents INTEGER NOT NULL, '
        'expected_cash_cents INTEGER, actual_cash_cents INTEGER, '
        'opened_at INTEGER NOT NULL, closed_at INTEGER)');
    raw.execute('CREATE TABLE audit_logs (id TEXT PRIMARY KEY, user_id TEXT, '
        'action TEXT NOT NULL, details TEXT, created_at INTEGER NOT NULL)');
    raw.execute(
        "INSERT INTO users VALUES ('u1', 'Owner', NULL, NULL, 'owner', 1)");
    raw.execute(
        "INSERT INTO products VALUES ('p1', 'SKU', '123', 'Legacy', 400, 100, 1, 0)");
    raw.execute(
        "INSERT INTO inventory_movements VALUES ('m1', 'p1', 5, 'initial_stock', NULL, 0)");
    raw.execute(
        "INSERT INTO inventory_movements VALUES ('m2', 'p1', -1, 'sale', 's1', 0)");
    raw.execute("INSERT INTO sales VALUES ('s1', 'u1', 400, 'completed', 0)");
    raw.execute("INSERT INTO sale_items VALUES ('si1', 's1', 'p1', 1, 400)");
    raw.execute("INSERT INTO payments VALUES ('pay1', 's1', 'cash', 400)");
    raw.execute(
        "INSERT INTO cash_sessions VALUES ('cs1', 'u1', 1000, NULL, NULL, 0, NULL)");
    raw.execute(
        "INSERT INTO audit_logs VALUES ('a1', 'u1', 'login_success', NULL, 0)");
    raw.execute('PRAGMA user_version = 1');
    raw.dispose();
    expect(BackupService.verify(file), 1);
    final db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect((await db.select(db.products).get()).single.name, 'Legacy');
      expect((await db.select(db.inventory).get()).single.quantity, 4);
      expect((await db.select(db.inventoryMovements).get()).length, 2);
      expect((await db.select(db.sales).get()).single.totalCents, 400);
      expect(
          (await db.select(db.saleItems).get()).single.productName, 'Legacy');
      expect((await db.select(db.payments).get()).single.amountCents, 400);
      expect((await db.select(db.users).get()).single.name, 'Owner');
      expect(
          (await db.select(db.auditLogs).get()).single.action, 'login_success');
      expect((await db.select(db.cashSessions).get()).single.startingCashCents,
          1000);
      expect(await db.select(db.settings).get(), isEmpty);
      expect(await db.select(db.cashMovements).get(), isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
  test('v6 to v7 adds cash movements and preserves Phase 4 data', () async {
    final dir = await Directory.systemTemp.createTemp('pos-migration-');
    final file = File('${dir.path}/phase4.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customStatement(
        "INSERT INTO users (id, name, role) VALUES ('owner', 'Owner', 'owner')");
    await db.customStatement(
        "INSERT INTO settings (id, store_name, printer_enabled) VALUES (1, 'Store', 1)");
    await db.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute("INSERT INTO categories (id, name) VALUES ('c1', 'Goods')");
    raw.execute(
        "INSERT INTO products (id, category_id, name, price_cents, created_at) "
        "VALUES ('p1', 'c1', 'Product', 500, 0)");
    raw.execute(
        "INSERT INTO inventory (product_id, quantity) VALUES ('p1', 4)");
    raw.execute("INSERT INTO inventory_movements "
        "(id, product_id, quantity_delta, reason, created_at) "
        "VALUES ('m1', 'p1', 4, 'initial_stock', 0)");
    raw.execute(
        "INSERT INTO sales (id, cashier_id, total_cents, status, created_at) "
        "VALUES ('s1', 'owner', 500, 'refunded', 0)");
    raw.execute("INSERT INTO sale_items "
        "(id, sale_id, product_id, product_name, quantity, unit_price_cents, line_total_cents) "
        "VALUES ('si1', 's1', 'p1', 'Product', 1, 500, 500)");
    raw.execute("INSERT INTO payments (id, sale_id, method, amount_cents) "
        "VALUES ('pay1', 's1', 'cash', 500)");
    raw.execute("INSERT INTO sale_reversals "
        "(id, sale_id, actor_id, kind, amount_cents, stock_restored, created_at) "
        "VALUES ('r1', 's1', 'owner', 'refund', 500, 1, 0)");
    raw.execute(
        "INSERT INTO cash_sessions (id, opened_by_user_id, starting_cash_cents, opened_at) "
        "VALUES ('cs1', 'owner', 1000, 0)");
    raw.execute("INSERT INTO audit_logs (id, user_id, action, created_at) "
        "VALUES ('a1', 'owner', 'login_success', 0)");
    raw.execute('DROP TABLE cash_movements');
    raw.execute('DROP INDEX cash_sessions_one_open');
    raw.execute('PRAGMA user_version = 6');
    raw.dispose();
    expect(BackupService.verify(file), 6);
    db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect((await db.select(db.settings).get()).single.storeName, 'Store');
      expect((await db.select(db.users).get()).single.name, 'Owner');
      expect((await db.select(db.categories).get()).single.name, 'Goods');
      expect((await db.select(db.products).get()).single.name, 'Product');
      expect((await db.select(db.inventory).get()).single.quantity, 4);
      expect(
          (await db.select(db.inventoryMovements).get()).single.quantityDelta,
          4);
      expect((await db.select(db.sales).get()).single.status, 'refunded');
      expect(
          (await db.select(db.saleItems).get()).single.productName, 'Product');
      expect((await db.select(db.payments).get()).single.amountCents, 500);
      expect((await db.select(db.saleReversals).get()).single.kind, 'refund');
      expect((await db.select(db.cashSessions).get()).single.startingCashCents,
          1000);
      expect(
          (await db.select(db.auditLogs).get()).single.action, 'login_success');
      expect(await db.select(db.cashMovements).get(), isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
  test('v5 to v6 adds Settings without changing existing sales', () async {
    final dir = await Directory.systemTemp.createTemp('pos-migration-');
    final file = File('${dir.path}/phase4.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute(
        'CREATE TABLE sales (id TEXT PRIMARY KEY, cashier_id TEXT NOT NULL, total_cents INTEGER NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL)');
    raw.execute("INSERT INTO sales VALUES ('s1', 'u1', 1200, 'completed', 0)");
    raw.execute('PRAGMA user_version = 5');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect((await db.select(db.sales).get()).single.totalCents, 1200);
      expect(await db.select(db.settings).get(), isEmpty);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
  test('v3 reversal migration marks existing restored stock', () async {
    final dir = await Directory.systemTemp.createTemp('pos-migration-');
    final file = File('${dir.path}/legacy.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('CREATE TABLE sale_reversals (id TEXT PRIMARY KEY, '
        'sale_id TEXT NOT NULL UNIQUE, actor_id TEXT NOT NULL, '
        'kind TEXT NOT NULL, amount_cents INTEGER NOT NULL, '
        'created_at INTEGER NOT NULL)');
    raw.execute(
        'CREATE TABLE products (id TEXT PRIMARY KEY, name TEXT NOT NULL)');
    raw.execute(
        'CREATE TABLE sale_items (id TEXT PRIMARY KEY, product_id TEXT NOT NULL)');
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
