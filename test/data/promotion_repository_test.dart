import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/promotion_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('version 40 upgrades add promotion tables without changing products', () async {
    final dir = await Directory.systemTemp.createTemp('promotion-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement("INSERT INTO categories (id, name) VALUES ('c1', 'Food')");
    await seed.customStatement("INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 12500, 0)");
    await seed.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP INDEX sale_promotion_applications_sale');
    raw.execute('DROP TABLE sale_promotion_applications');
    raw.execute('ALTER TABLE sale_items DROP COLUMN promotion_discount_cents');
    raw.execute('ALTER TABLE sales DROP COLUMN discount_source');
    raw.execute('DROP TABLE promotion_product_targets');
    raw.execute('DROP TABLE promotion_category_targets');
    raw.execute('DROP TABLE promotions');
    raw.execute('PRAGMA user_version = 40');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    expect((await db.select(db.products).get()).single.priceCents, 12500);
    expect((await db.select(db.categories).get()).single.name, 'Food');
    expect(await db.select(db.promotions).get(), isEmpty);
    expect(await db.select(db.promotionProductTargets).get(), isEmpty);
    expect(await db.select(db.promotionCategoryTargets).get(), isEmpty);
    await db.close();
  });

  test('create, update, targets, filters, lifecycle, audit and paging', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap('Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement("INSERT INTO categories (id, name) VALUES ('c1', 'Food')");
    await db.customStatement("INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 12500, 0)");
    final repo = PromotionRepository(db);
    final created = await repo.createPromotion(owner, const PromotionInput(name: 'Weekend', type: 'percentage', rewardKind: 'percentage', rewardValue: 1000,
      targetMode: 'products', productIds: ['p1'], active: true));
    expect(created.reference, 'PROMO-000001');
    expect(repo.status(created), 'active');
    final scheduled = await repo.createPromotion(owner, PromotionInput(name: 'Future', type: 'percentage', rewardKind: 'percentage', rewardValue: 100,
      active: true, startsAt: DateTime.now().add(const Duration(days: 2))));
    expect(repo.status(scheduled), 'scheduled');
    final expired = await repo.createPromotion(owner, PromotionInput(name: 'Past', type: 'percentage', rewardKind: 'percentage', rewardValue: 100,
      active: true, endsAt: DateTime.now().subtract(const Duration(days: 1))));
    expect(repo.status(expired), 'expired');
    final draft = await repo.createPromotion(owner, const PromotionInput(name: 'Draft', type: 'percentage', rewardKind: 'percentage', rewardValue: 100, draft: true));
    expect(repo.status(draft), 'draft');
    expect(await repo.productTargets(owner, created.id), ['p1']);
    expect(await repo.countPromotions(owner, search: 'week', statusFilter: 'active'), 1);
    final updated = await repo.updatePromotion(owner, created.id, const PromotionInput(name: 'Weekend Plus', type: 'fixed', rewardKind: 'fixed', rewardValue: 500,
      targetMode: 'categories', categoryIds: ['c1']));
    expect(repo.status(updated), 'inactive');
    expect(await repo.productTargets(owner, created.id), isEmpty);
    expect(await repo.categoryTargets(owner, created.id), ['c1']);
    expect(await repo.countPromotions(owner, type: 'fixed'), 1);
    expect((await repo.auditHistory(owner, created.id)).length, greaterThanOrEqualTo(2));
    await repo.setActive(owner, created.id, true);
    expect(repo.status((await repo.getPromotion(owner, created.id))!), 'active');
    expect(() => repo.createPromotion(owner, const PromotionInput(name: '', type: 'percentage', rewardKind: 'percentage', rewardValue: 100)), throwsA(isA<ArgumentError>()));
    for (var i = 0; i < 50; i++) {
      await repo.createPromotion(owner, PromotionInput(name: 'Rule $i', type: 'percentage', rewardKind: 'percentage', rewardValue: 100));
    }
    expect(await repo.countPromotions(owner), 54);
    expect(await repo.listPromotions(owner), hasLength(50));
    expect(await repo.listPromotions(owner, page: 1), hasLength(4));
  });

  test('candidate query excludes inactive dates and batch loads beyond 50', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap('Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final repo = PromotionRepository(db);
    await db.customStatement("INSERT INTO categories (id, name) VALUES ('c1', 'Food')");
    await db.customStatement("INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 12500, 0)");
    final now = DateTime(2026, 10, 24, 12);
    await repo.createPromotion(owner, PromotionInput(name: 'Later', type: 'fixed', rewardKind: 'fixed', rewardValue: 100,
      active: true, startsAt: now.add(const Duration(seconds: 1))));
    await repo.createPromotion(owner, PromotionInput(name: 'Ended', type: 'fixed', rewardKind: 'fixed', rewardValue: 100,
      active: true, endsAt: now));
    await repo.createPromotion(owner, const PromotionInput(name: 'Disabled', type: 'fixed', rewardKind: 'fixed', rewardValue: 100));
    await repo.createPromotion(owner, const PromotionInput(name: 'Draft', type: 'fixed', rewardKind: 'fixed', rewardValue: 100, draft: true));
    for (var i = 0; i < 51; i++) {
      await repo.createPromotion(owner, PromotionInput(name: 'Eligible $i', type: 'percentage', rewardKind: 'percentage', rewardValue: 1000,
        targetMode: i.isEven ? 'products' : 'categories',
        productIds: i.isEven ? ['p1'] : [], categoryIds: i.isOdd ? ['c1'] : [], active: true));
    }
    final candidates = await repo.getPromotionCandidates(owner, now);
    expect(candidates, hasLength(51));
    expect(candidates.where((p) => p.targetMode == 'products').every((p) => p.productIds.contains('p1')), isTrue);
    expect(candidates.where((p) => p.targetMode == 'categories').every((p) => p.categoryIds.contains('c1')), isTrue);
  });
}
