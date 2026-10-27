import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import '../support/historical_fixture.dart';

void main() {
  test('version 41 sale migrates to 43 without changing historical totals',
      () async {
    final dir = await Directory.systemTemp.createTemp('promotion-v41-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO users (id, name, role) VALUES ('u1', 'Owner', 'owner')");
    await seed.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 10000, 0)");
    await seed.customStatement(
        "INSERT INTO sales (id, cashier_id, total_cents, created_at) VALUES ('s1', 'u1', 10000, 0)");
    await seed.customStatement(
        "INSERT INTO sale_items (id, sale_id, product_id, quantity, unit_price_cents, line_total_cents) VALUES ('i1', 's1', 'p1', 1, 10000, 10000)");
    await seed.close();
    await rebuildAsHistoricalFixture(file, 41);
    final db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await db.select(db.sales).get()).single.totalCents, 10000);
    expect((await db.select(db.sales).get()).single.discountSource, 'none');
    expect((await db.select(db.saleItems).get()).single.lineTotalCents, 10000);
    expect(
        (await db.select(db.saleItems).get()).single.promotionDiscountCents, 0);
    expect(await db.select(db.salePromotionApplications).get(), isEmpty);
    await db.close();
    expect(BackupService.verify(file), 55);
  });

  test('version 42 adds promotion analytics index without changing sales',
      () async {
    final dir = await Directory.systemTemp.createTemp('promotion-v42-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO users (id, name, role) VALUES ('u1', 'Owner', 'owner')");
    await seed.customStatement(
        "INSERT INTO sales (id, cashier_id, total_cents, created_at) VALUES ('s1', 'u1', 10000, 0)");
    await seed.close();
    await rebuildAsHistoricalFixture(file, 42);
    final db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await db.select(db.sales).get()).single.totalCents, 10000);
    final index = await db
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type='index' AND name='sale_promotion_applications_promotion'")
        .get();
    expect(index, hasLength(1));
    await db.close();
  });
}
