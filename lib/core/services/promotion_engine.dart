import '../models/promotion_evaluation.dart';
import '../models/promotion_lifecycle.dart';

/// Calculates promotion suggestions from immutable snapshots. It never writes,
/// mutates the cart, or combines promotions with a manual discount.
class PromotionEngine {
  const PromotionEngine();

  /// Nonnegative half-up rounding, matching Quantity.lineCents and the
  /// existing manual percentage discount policy.
  static int percentCents(int basisCents, int basisPoints) =>
      (basisCents * basisPoints + 5000) ~/ 10000;

  PromotionEvaluationResult evaluate(
      PromotionEvaluationContext context, Iterable<PromotionRule> promotions) {
    final rules = promotions.toList()
      ..sort((a, b) {
        final priority = b.priority.compareTo(a.priority);
        if (priority != 0) return priority;
        final reference = a.reference.compareTo(b.reference);
        return reference != 0 ? reference : a.id.compareTo(b.id);
      });
    final decisions = [for (final rule in rules) _evaluateOne(context, rule)];
    final eligible =
        decisions.where((d) => d.eligible).map((d) => d.application!).toList();

    // Each rule is calculated against the original eligible line subtotal.
    // Recommendation applies stackable rules in priority order and caps each
    // line at its original subtotal. An exclusive rule stands alone. Choose
    // whichever option yields the larger discount; stable ordering breaks ties.
    final remaining = {
      for (final line in context.lines) line.id: line.subtotalCents
    };
    final stacked = <PromotionApplication>[];
    var stackedTotal = 0;
    for (final application
        in eligible.where((a) => a.stackingMode == 'stackable')) {
      final actual = <String, int>{};
      for (final lineId in application.affectedLineIds) {
        final wanted = application.lineDiscountCents[lineId] ?? 0;
        final allowed = remaining[lineId] ?? 0;
        final applied = wanted < allowed ? wanted : allowed;
        if (applied > 0) {
          actual[lineId] = applied;
          remaining[lineId] = allowed - applied;
        }
      }
      // If an earlier rule saturated one line, move the still available
      // discount to other targeted lines with remaining value.
      var unallocated = application.discountCents -
          actual.values.fold<int>(0, (sum, value) => sum + value);
      for (final lineId in application.affectedLineIds) {
        if (unallocated == 0) break;
        final spare = remaining[lineId] ?? 0;
        final extra = spare < unallocated ? spare : unallocated;
        if (extra > 0) {
          actual[lineId] = (actual[lineId] ?? 0) + extra;
          remaining[lineId] = spare - extra;
          unallocated -= extra;
        }
      }
      final discount = actual.values.fold<int>(0, (sum, value) => sum + value);
      if (discount == 0) continue;
      stackedTotal += discount;
      stacked.add(PromotionApplication(
        promotionId: application.promotionId,
        reference: application.reference,
        name: application.name,
        type: application.type,
        stackingMode: application.stackingMode,
        priority: application.priority,
        eligibleSubtotalCents: application.eligibleSubtotalCents,
        discountCents: discount,
        affectedLineIds: actual.keys.toList(),
        lineDiscountCents: actual,
        explanation:
            'Stacked against original values; capped by remaining line value.',
      ));
    }
    final exclusive = eligible
        .where((a) => a.stackingMode == 'exclusive')
        .toList()
      ..sort((a, b) {
        final amount = b.discountCents.compareTo(a.discountCents);
        if (amount != 0) return amount;
        final priority = b.priority.compareTo(a.priority);
        return priority != 0 ? priority : a.reference.compareTo(b.reference);
      });
    final bestExclusive = exclusive.isEmpty ? null : exclusive.first;
    final useExclusive =
        bestExclusive != null && bestExclusive.discountCents >= stackedTotal;
    final recommended = useExclusive ? [bestExclusive] : stacked;
    final total = useExclusive ? bestExclusive.discountCents : stackedTotal;
    return PromotionEvaluationResult(
        decisions: decisions,
        recommendedApplications: recommended,
        originalSubtotalCents: context.subtotalCents,
        totalDiscountCents: total);
  }

  PromotionDecision _evaluateOne(
      PromotionEvaluationContext context, PromotionRule rule) {
    final status = PromotionLifecycle.status(
        isDraft: rule.isDraft,
        isActive: rule.isActive,
        at: context.at,
        startsAt: rule.startsAt,
        endsAt: rule.endsAt);
    final reason = switch (status) {
      PromotionStatus.draft => PromotionIneligibility.draft,
      PromotionStatus.inactive => PromotionIneligibility.inactive,
      PromotionStatus.scheduled => PromotionIneligibility.notStarted,
      PromotionStatus.expired => PromotionIneligibility.expired,
      PromotionStatus.active => null,
    };
    if (reason != null) return PromotionDecision(rule, reason: reason);
    if (!{'percentage', 'fixed', 'minimum_spend'}.contains(rule.type)) {
      return PromotionDecision(rule,
          reason: PromotionIneligibility.unsupportedRule);
    }
    if (!{'percentage', 'fixed'}.contains(rule.rewardKind) ||
        (rule.type != 'minimum_spend' && rule.type != rule.rewardKind) ||
        rule.rewardValue <= 0 ||
        (rule.rewardKind == 'percentage' && rule.rewardValue > 10000) ||
        (rule.type == 'minimum_spend' &&
            (rule.minimumSubtotalCents == null ||
                rule.minimumSubtotalCents! <= 0)) ||
        !{'all', 'products', 'categories'}.contains(rule.targetMode) ||
        !{'exclusive', 'stackable'}.contains(rule.stackingMode)) {
      return PromotionDecision(rule,
          reason: PromotionIneligibility.invalidConfiguration);
    }
    final matches = context.lines
        .where((line) =>
            line.merchandise &&
            (rule.targetMode == 'all' ||
                (rule.targetMode == 'products' &&
                    rule.productIds.contains(line.productId)) ||
                (rule.targetMode == 'categories' &&
                    rule.categoryIds.contains(line.categoryId))))
        .toList();
    if (matches.isEmpty) {
      return PromotionDecision(rule,
          reason: switch (rule.targetMode) {
            'products' => PromotionIneligibility.noTargetedProducts,
            'categories' => PromotionIneligibility.noTargetedCategories,
            _ => PromotionIneligibility.emptyEligibleSubtotal,
          });
    }
    final basis = matches.fold<int>(0, (sum, line) => sum + line.subtotalCents);
    if (basis == 0) {
      return PromotionDecision(rule,
          reason: PromotionIneligibility.emptyEligibleSubtotal);
    }
    if (rule.type == 'minimum_spend' && basis < rule.minimumSubtotalCents!) {
      return PromotionDecision(rule,
          reason: PromotionIneligibility.minimumSpendNotMet);
    }
    final raw = rule.rewardKind == 'percentage'
        ? percentCents(basis, rule.rewardValue)
        : rule.rewardValue; // fixed amount once per transaction
    final discount = raw < basis ? raw : basis;
    if (discount == 0) {
      return PromotionDecision(rule,
          reason: PromotionIneligibility.emptyEligibleSubtotal);
    }

    // Proportional integer allocation, then distribute remainder to lines
    // with spare value. This also covers tiny one-cent lines safely.
    final lineAmounts = <String, int>{};
    final positive = matches.where((line) => line.subtotalCents > 0).toList();
    var remaining = discount;
    for (final line in positive) {
      final amount = discount * line.subtotalCents ~/ basis;
      lineAmounts[line.id] = amount;
      remaining -= amount;
    }
    for (final line in positive) {
      if (remaining == 0) break;
      final spare = line.subtotalCents - lineAmounts[line.id]!;
      final extra = spare < remaining ? spare : remaining;
      lineAmounts[line.id] = lineAmounts[line.id]! + extra;
      remaining -= extra;
    }
    return PromotionDecision(rule,
        application: PromotionApplication(
          promotionId: rule.id,
          reference: rule.reference,
          name: rule.name,
          type: rule.type,
          stackingMode: rule.stackingMode,
          discountCents: discount,
          eligibleSubtotalCents: basis,
          affectedLineIds: matches.map((line) => line.id).toList(),
          lineDiscountCents: lineAmounts,
          priority: rule.priority,
          explanation: rule.type == 'minimum_spend'
              ? 'Threshold met on targeted subtotal.'
              : 'Calculated on targeted subtotal.',
        ));
  }
}
