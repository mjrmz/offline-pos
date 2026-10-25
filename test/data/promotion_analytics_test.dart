import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/promotion_analytics_repository.dart';
import 'package:modern_offline_pos/data/daos/promotion_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  late AppDatabase db;
  late ActiveUser owner;
  late PromotionRepository promotions;
  late PromotionAnalyticsRepository analytics;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final id = await AuthService(AuthRepository(db))
        .bootstrap('Owner', 'password123', 'Q?', 'answer');
    owner = ActiveUser(id, 'Owner', UserRole.owner);
    promotions = PromotionRepository(db);
    analytics = PromotionAnalyticsRepository(db);
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 10000, 0)");
  });
  tearDown(() => db.close());

  Future<void> seedSale(
      String id, String promoId, String reference, DateTime at,
      {int gross = 10000, int discount = 1000}) async {
    await db.into(db.sales).insert(SalesCompanion.insert(
        id: Value(id),
        cashierId: owner.id,
        totalCents: gross - discount,
        receiptNumber: Value(id),
        discountSource: const Value('promotion'),
        createdAt: Value(at)));
    await db.into(db.saleItems).insert(SaleItemsCompanion.insert(
        saleId: id,
        productId: 'p1',
        quantity: 1,
        unitPriceCents: gross,
        productName: const Value('Bread'),
        quantityMilli: const Value(1000),
        lineTotalCents: Value(gross - discount),
        promotionDiscountCents: Value(discount)));
    await db.into(db.salePromotionApplications).insert(
        SalePromotionApplicationsCompanion.insert(
            saleId: id,
            promotionId: Value(promoId),
            promotionReference: reference,
            promotionName: 'Original',
            promotionType: 'fixed',
            stackingMode: 'exclusive',
            priority: 100,
            eligibleSubtotalCents: gross,
            discountCents: discount,
            createdAt: Value(at)));
  }

  test('snapshot analytics, period, paging, products and edited rule',
      () async {
    final promo = await promotions.createPromotion(
        owner,
        const PromotionInput(
            name: 'Original',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 1000,
            targetMode: 'products',
            productIds: ['p1'],
            active: true));
    final at = DateTime(2026, 10, 24, 12);
    await db.transaction(() async {
      for (var i = 0; i < 52; i++) {
        await seedSale('R-$i', promo.id, promo.reference, at);
      }
    });
    final period =
        PromotionPeriod.custom(DateTime(2026, 10, 1), DateTime(2026, 10, 31));
    final metrics = await analytics.metrics(owner, promo.id, period);
    expect(metrics.sales, 52);
    expect(metrics.grossCents, 520000);
    expect(metrics.discountCents, 52000);
    expect(metrics.netCents, 468000);
    expect(metrics.averageDiscountCents, 1000);
    expect(metrics.firstUse, isNotNull);
    expect((await analytics.sales(owner, promo.id, period)), hasLength(50));
    expect((await analytics.sales(owner, promo.id, period, page: 1)),
        hasLength(2));
    final products = await analytics.topProducts(owner, promo.id, period);
    expect(products.single.quantityMilli, 52000);
    expect(products.single.discountCents, 52000);
    await promotions.updatePromotion(
        owner,
        promo.id,
        const PromotionInput(
            name: 'Edited',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 2000));
    await promotions.setActive(owner, promo.id, true);
    await promotions.setActive(owner, promo.id, false);
    expect((await analytics.metrics(owner, promo.id, period)).discountCents,
        52000);
    expect((await analytics.sales(owner, promo.id, period)).first.receipt,
        isNotEmpty);
    final activity = await analytics.activity(owner, promo.id);
    expect(
        activity.map((e) => e.action),
        containsAll([
          'promotion_created',
          'promotion_edited',
          'promotion_activated',
          'promotion_deactivated'
        ]));
    final empty = await analytics.metrics(owner, promo.id,
        PromotionPeriod.custom(DateTime(2026, 9, 1), DateTime(2026, 9, 30)));
    expect(empty.sales, 0);
    expect(empty.discountCents, 0);
  });

  test('duplicate is a fresh draft with targets and no usage', () async {
    final original = await promotions.createPromotion(
        owner,
        const PromotionInput(
            name: 'Original',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 1000,
            targetMode: 'products',
            productIds: ['p1'],
            active: true));
    await seedSale(
        'R-1', original.id, original.reference, DateTime(2026, 10, 24));
    final copy = await promotions.duplicatePromotion(owner, original.id);
    expect(copy.reference, isNot(original.reference));
    expect(copy.isDraft, isTrue);
    expect(copy.isActive, isFalse);
    expect(await promotions.productTargets(owner, copy.id), ['p1']);
    expect(
        (await analytics.metrics(
                owner,
                copy.id,
                PromotionPeriod.custom(
                    DateTime(2026, 10, 1), DateTime(2026, 10, 31))))
            .sales,
        0);
    expect((await analytics.activity(owner, copy.id)).map((e) => e.action),
        contains('promotion_duplicated'));
  });

  test('period report separates promotion and manual discount', () async {
    final promo = await promotions.createPromotion(
        owner,
        const PromotionInput(
            name: 'Original',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 1000));
    final at = DateTime(2026, 10, 24);
    await seedSale('P-1', promo.id, promo.reference, at);
    await db.into(db.sales).insert(SalesCompanion.insert(
        id: const Value('M-1'),
        cashierId: owner.id,
        totalCents: 9500,
        discountSource: const Value('manual'),
        createdAt: Value(at)));
    await db.into(db.saleManualDiscounts).insert(
        SaleManualDiscountsCompanion.insert(
            saleId: 'M-1',
            scope: 'order',
            kind: 'fixed',
            value: 500,
            effectCents: 500,
            reason: 'Approved',
            requestedBy: owner.id,
            authorizedBy: owner.id,
            authorizedAt: at));
    final summary = await analytics.discountSummary(owner,
        PromotionPeriod.custom(DateTime(2026, 10, 1), DateTime(2026, 10, 31)));
    expect(summary.promotedSales, 1);
    expect(summary.promotionCents, 1000);
    expect(summary.manualCents, 500);
    expect(summary.totalCents, 1500);
    expect(summary.topPromotion, 'Original');
  });
}
