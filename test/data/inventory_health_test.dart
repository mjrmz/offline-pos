import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/inventory_health_repository.dart';

int seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;

void main() {
  test('schema 36 upgrade adds defaults without touching products', () async {
    final dir = await Directory.systemTemp.createTemp('health-upgrade-');
    final file = File('${dir.path}/pos.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Preserved', 100, 1)");
    await db.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE inventory_health_settings');
    raw.execute('PRAGMA user_version = 36');
    raw.dispose();
    db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect((await db.select(db.products).get()).single.name, 'Preserved');
      expect(
          (await InventoryHealthRepository(db).settings()).slowMovingDays, 60);
      expect(db.schemaVersion, 40);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('health thresholds survive SQLite backup', () async {
    final dir = await Directory.systemTemp.createTemp('inventory-health-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    await InventoryHealthRepository(db)
        .saveSettings(const InventoryHealthSettings(45, 150, 14));
    final backup = await BackupService(db, dir).create(BackupKind.manual);
    expect(BackupService.verify(backup.file), db.schemaVersion);
    final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
    try {
      final settings = await InventoryHealthRepository(restored).settings();
      expect([
        settings.slowMovingDays,
        settings.deadStockDays,
        settings.nearExpiryDays
      ], [
        45,
        150,
        14
      ]);
    } finally {
      await restored.close();
    }
  });

  test('settings validate and never-sold stock uses only remaining layers',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = InventoryHealthRepository(db);
    final defaults = await repo.settings();
    expect([
      defaults.slowMovingDays,
      defaults.deadStockDays,
      defaults.nearExpiryDays
    ], [
      60,
      180,
      30
    ]);
    await expectLater(
        repo.saveSettings(const InventoryHealthSettings(20, 10, 5)),
        throwsArgumentError);
    await repo.saveSettings(const InventoryHealthSettings(10, 20, 5));
    expect((await repo.settings()).deadStockDays, 20);
    final now = DateTime(2026, 10, 18, 12);
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Never sold', 500, 1)");
    await db.customStatement(
        "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p', 10, 10000)");
    await db.customStatement('''INSERT INTO inventory_layers
      (id, product_id, source, quantity_received_milli, quantity_remaining_milli,
       unit_cost_cents, received_at, batch_number, expiry_date)
      VALUES ('old','p','opening',5000,0,100,${seconds(now.subtract(const Duration(days: 300)))},'OLD',${seconds(now.subtract(const Duration(days: 1)))})''');
    await db.customStatement('''INSERT INTO inventory_layers
      (id, product_id, source, quantity_received_milli, quantity_remaining_milli,
       unit_cost_cents, received_at, batch_number, expiry_date)
      VALUES ('new','p','opening',10000,10000,100,${seconds(now.subtract(const Duration(days: 25)))},'LIVE',${seconds(now.add(const Duration(days: 3)))})''');
    final snapshot = await repo.load(now: now);
    final health = snapshot.products['p']!;
    expect(health.neverSold, isTrue);
    expect(health.slowMoving, isTrue);
    expect(health.deadStock, isTrue);
    expect(health.costValueCents, 1000);
    expect(snapshot.aging[0].quantityMilli, 10000);
    expect(snapshot.aging[4].quantityMilli, 0);
    expect(snapshot.expiry.single.batchNumber, 'LIVE');
    expect(snapshot.expiry.single.quantityMilli, 10000);
    expect(snapshot.expiry.single.status, 'Expires within 7 days');
    expect(snapshot.expiredCount, 0);
    final later = await repo.load(now: now.add(const Duration(days: 5)));
    expect(later.expiredCount, 1);
    expect(later.expiry.single.quantityMilli, 10000);
    expect(later.expiry.single.status, 'Expired');
    expect((await db.select(db.inventory).getSingle()).quantityMilli, 10000);
  });

  test('completed sales and finalized returns drive velocity and cover',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 18, 12);
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Moving', 500, 1)");
    await db.customStatement(
        "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p', 15, 15000)");
    await db.customStatement(
        "INSERT INTO users (id, name, role) VALUES ('u', 'Owner', 'owner')");
    for (final (id, days, status) in [
      ('old', 40, 'completed'),
      ('recent', 10, 'completed'),
      ('void', 1, 'voided')
    ]) {
      await db.customStatement(
          "INSERT INTO sales (id, cashier_id, total_cents, status, created_at) VALUES ('$id', 'u', 15000, '$status', ${seconds(now.subtract(Duration(days: days)))})");
      await db.customStatement(
          "INSERT INTO sale_items (id, sale_id, product_id, quantity, quantity_milli, unit_price_cents, line_total_cents) VALUES ('i-$id', '$id', 'p', 30, 30000, 500, 15000)");
    }
    await db.customStatement(
        "INSERT INTO sale_returns (id, reference, original_sale_id, actor_id, kind, status, reason, refund_value_cents, created_at) VALUES ('r', 'RET-1', 'recent', 'u', 'refund', 'finalized', 'Customer return', 2500, ${seconds(now.subtract(const Duration(days: 5)))})");
    await db.customStatement(
        "INSERT INTO sale_return_lines (id, return_id, sale_item_id, quantity_milli, refund_cents, disposition) VALUES ('rl', 'r', 'i-recent', 5000, 2500, 'sellable')");
    final row =
        (await InventoryHealthRepository(db).load(now: now)).products['p']!;
    expect(row.netSold30Milli, 25000);
    expect(row.netSold90Milli, 55000);
    expect(row.lastSoldAt!.day, now.subtract(const Duration(days: 10)).day);
    expect(row.slowMoving, isFalse);
    expect(row.estimatedStockCoverDays, 18);
  });
}
