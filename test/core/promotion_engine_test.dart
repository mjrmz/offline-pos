import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/promotion_evaluation.dart';
import 'package:modern_offline_pos/core/models/promotion_lifecycle.dart';
import 'package:modern_offline_pos/core/services/promotion_engine.dart';

final at = DateTime(2026, 10, 24, 12);
const engine = PromotionEngine();

PromotionCartLine line(String id, int cents,
        {String? category,
        int quantityMilli = 1000,
        int? unitPriceCents,
        bool merchandise = true}) =>
    PromotionCartLine(
        id: id,
        productId: id,
        categoryId: category,
        quantityMilli: quantityMilli,
        unitPriceCents: unitPriceCents ?? cents,
        subtotalCents: cents,
        merchandise: merchandise);

PromotionEvaluationContext cart(List<PromotionCartLine> lines) =>
    PromotionEvaluationContext(
        at: at,
        lines: lines,
        subtotalCents: lines.fold(0, (sum, line) => sum + line.subtotalCents));

PromotionRule rule(String id,
        {String type = 'percentage',
        String? rewardKind,
        int value = 1000,
        String target = 'all',
        Set<String> products = const {},
        Set<String> categories = const {},
        int? minimum,
        int priority = 100,
        String stacking = 'exclusive',
        bool active = true,
        bool draft = false,
        DateTime? start,
        DateTime? end,
        String? reference}) =>
    PromotionRule(
        id: id,
        reference: reference ?? id,
        name: id,
        type: type,
        rewardKind: rewardKind ?? type,
        rewardValue: value,
        targetMode: target,
        stackingMode: stacking,
        priority: priority,
        minimumSubtotalCents: minimum,
        isActive: active,
        isDraft: draft,
        startsAt: start,
        endsAt: end,
        productIds: products,
        categoryIds: categories);

void main() {
  test('percentage all products uses basis points and half-up cents', () {
    final result = engine.evaluate(cart([line('a', 9999)]), [rule('p')]);
    expect(result.totalDiscountCents, 1000);
    expect(result.discountedSubtotalCents, 8999);
    expect(result.eligiblePromotions.single.eligibleSubtotalCents, 9999);
    expect(PromotionEngine.percentCents(5, 1000), 1);
    expect(PromotionEngine.percentCents(4, 1000), 0);
  });

  test('product and category targets use only matching merchandise lines', () {
    final context = cart([
      line('a', 10000, category: 'food'),
      line('b', 20000, category: 'food'),
      line('c', 7000, category: 'other'),
      line('fee', 4000, category: 'food', merchandise: false)
    ]);
    final result = engine.evaluate(context, [
      rule('product', target: 'products', products: {'a', 'c'}),
      rule('category', target: 'categories', categories: {'food'}),
    ]);
    expect(result.eligiblePromotions.map((a) => a.eligibleSubtotalCents),
        [30000, 17000]);
    expect(result.eligiblePromotions.first.affectedLineIds, ['a', 'b']);
    expect(result.eligiblePromotions.last.affectedLineIds, ['a', 'c']);
  });

  test('fractional quantity uses actual pre-promotion line cents', () {
    final context =
        cart([line('weight', 7499, quantityMilli: 750, unitPriceCents: 9999)]);
    expect(engine.evaluate(context, [rule('p')]).totalDiscountCents, 750);
  });

  test('fixed discount applies once and caps at eligible subtotal', () {
    final context = cart([line('a', 7000), line('b', 9000)]);
    final result = engine.evaluate(context, [
      rule('f',
          type: 'fixed', value: 10000, target: 'products', products: {'a'})
    ]);
    expect(result.totalDiscountCents, 7000);
    expect(result.discountedSubtotalCents, 9000);
    expect(result.eligiblePromotions.single.lineDiscountCents, {'a': 7000});
  });

  test('minimum spend threshold uses targeted original subtotal', () {
    final context = cart([line('a', 9999), line('b', 10000)]);
    final below = engine.evaluate(context, [
      rule('min',
          type: 'minimum_spend',
          rewardKind: 'percentage',
          value: 1000,
          minimum: 10000,
          target: 'products',
          products: {'a'})
    ]);
    expect(below.ineligiblePromotions.single.reason,
        PromotionIneligibility.minimumSpendNotMet);
    final exact = engine.evaluate(context, [
      rule('min',
          type: 'minimum_spend',
          rewardKind: 'percentage',
          value: 1000,
          minimum: 10000,
          target: 'products',
          products: {'b'})
    ]);
    expect(exact.totalDiscountCents, 1000);
    final above = engine.evaluate(context, [
      rule('min',
          type: 'minimum_spend',
          rewardKind: 'fixed',
          value: 2500,
          minimum: 10000)
    ]);
    expect(above.totalDiscountCents, 2500);
  });

  test('lifecycle shares A1 status boundaries', () {
    final context = cart([line('a', 10000)]);
    final decisions = engine.evaluate(context, [
      rule('draft', draft: true),
      rule('inactive', active: false),
      rule('future', start: at.add(const Duration(seconds: 1))),
      rule('expired', end: at),
      rule('start', start: at),
      rule('open', end: null),
    ]).decisions;
    expect(decisions.map((d) => d.reason), [
      PromotionIneligibility.draft,
      PromotionIneligibility.expired,
      PromotionIneligibility.notStarted,
      PromotionIneligibility.inactive,
      null,
      null
    ]);
    expect(
        PromotionLifecycle.status(
            isDraft: false, isActive: true, at: at, startsAt: at),
        PromotionStatus.active);
  });

  test('empty cart, no rules, and missing targets are safe', () {
    expect(engine.evaluate(cart([]), [rule('p')]).totalDiscountCents, 0);
    expect(engine.evaluate(cart([line('a', 100)]), []).totalDiscountCents, 0);
    final result = engine.evaluate(cart([line('a', 100)]), [
      rule('p', target: 'products', products: {'missing'}),
      rule('c', target: 'categories', categories: {'missing'}),
    ]);
    expect(result.ineligiblePromotions.map((d) => d.reason), [
      PromotionIneligibility.noTargetedCategories,
      PromotionIneligibility.noTargetedProducts
    ]);
  });

  test('priority desc and reference tie order are deterministic', () {
    final result = engine.evaluate(cart([line('a', 10000)]), [
      rule('z', priority: 10),
      rule('b', priority: 20),
      rule('a', priority: 20)
    ]);
    expect(result.decisions.map((d) => d.rule.id), ['a', 'b', 'z']);
  });

  test('stackable overlap caps each line and cannot make subtotal negative',
      () {
    final result = engine.evaluate(cart([line('a', 10000)]), [
      rule('one',
          type: 'fixed', value: 8000, stacking: 'stackable', priority: 20),
      rule('two',
          type: 'fixed', value: 5000, stacking: 'stackable', priority: 10),
    ]);
    expect(result.eligiblePromotions.map((a) => a.discountCents), [8000, 5000]);
    expect(result.recommendedApplications.map((a) => a.discountCents),
        [8000, 2000]);
    expect(result.totalDiscountCents, 10000);
    expect(result.discountedSubtotalCents, 0);
  });

  test('exclusive recommendation beats stackable combination when larger', () {
    final result = engine.evaluate(cart([line('a', 10000)]), [
      rule('exclusive', type: 'fixed', value: 7000),
      rule('stack', type: 'fixed', value: 5000, stacking: 'stackable'),
    ]);
    expect(result.recommendedApplications.single.reference, 'exclusive');
    expect(result.totalDiscountCents, 7000);
  });

  test('overlap across different targets respects line cap', () {
    final result = engine.evaluate(
        cart([
          line('a', 5000, category: 'food'),
          line('b', 5000, category: 'food')
        ]),
        [
          rule('cat',
              type: 'fixed',
              value: 8000,
              target: 'categories',
              categories: {'food'},
              stacking: 'stackable',
              priority: 20),
          rule('prod',
              type: 'fixed',
              value: 5000,
              target: 'products',
              products: {'a'},
              stacking: 'stackable',
              priority: 10),
        ]);
    expect(result.totalDiscountCents, 9000);
    expect(result.recommendedApplications.last.discountCents, 1000);
    expect(result.discountedSubtotalCents, 1000);
  });

  test('stacking redistributes remaining discount to another targeted line',
      () {
    final result = engine.evaluate(cart([line('a', 10000), line('b', 10000)]), [
      rule('onlyA',
          type: 'fixed',
          value: 10000,
          target: 'products',
          products: {'a'},
          stacking: 'stackable',
          priority: 20),
      rule('all',
          type: 'fixed', value: 10000, stacking: 'stackable', priority: 10),
    ]);
    expect(result.totalDiscountCents, 20000);
    expect(result.recommendedApplications.last.lineDiscountCents['b'], 10000);
  });

  test('tiny line allocation never discounts a line below zero', () {
    final result = engine.evaluate(
        cart([line('a', 1), line('b', 1), line('c', 1)]),
        [rule('fixed', type: 'fixed', value: 2)]);
    final amounts = result.recommendedApplications.single.lineDiscountCents;
    expect(amounts.values.fold<int>(0, (sum, value) => sum + value), 2);
    expect(amounts.values.every((value) => value <= 1), isTrue);
  });

  test('unsupported and invalid rules return reasons', () {
    final result = engine.evaluate(cart([line('a', 10000)]), [
      rule('bundle', type: 'bundle', rewardKind: 'fixed'),
      rule('buy', type: 'buy_x_get_y', rewardKind: 'fixed'),
      rule('invalid', value: 10001),
    ]);
    expect(result.ineligiblePromotions.map((d) => d.reason), [
      PromotionIneligibility.unsupportedRule,
      PromotionIneligibility.unsupportedRule,
      PromotionIneligibility.invalidConfiguration
    ]);
  });
}
