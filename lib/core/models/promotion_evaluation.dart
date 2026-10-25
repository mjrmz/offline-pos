import 'quantity.dart';

/// A sale line snapshot for a calculation. [subtotalCents] is the current
/// pre-promotion line total, including any existing special pricing.
class PromotionCartLine {
  final String id;
  final String productId;
  final String? categoryId;
  final int quantityMilli;
  final int unitPriceCents;
  final int subtotalCents;
  final bool merchandise;

  PromotionCartLine(
      {required this.id,
      required this.productId,
      required this.categoryId,
      required this.quantityMilli,
      required this.unitPriceCents,
      int? subtotalCents,
      this.merchandise = true})
      : subtotalCents =
            subtotalCents ?? Quantity.lineCents(unitPriceCents, quantityMilli) {
    if (id.isEmpty ||
        productId.isEmpty ||
        quantityMilli <= 0 ||
        unitPriceCents < 0 ||
        this.subtotalCents < 0) {
      throw ArgumentError('Invalid promotion cart line');
    }
  }
}

class PromotionEvaluationContext {
  final DateTime at;
  final List<PromotionCartLine> lines;
  final int subtotalCents;

  PromotionEvaluationContext(
      {required this.at,
      required List<PromotionCartLine> lines,
      required this.subtotalCents})
      : lines = List.unmodifiable(lines) {
    if (subtotalCents < 0 ||
        lines.fold<int>(0, (sum, line) => sum + line.subtotalCents) !=
            subtotalCents ||
        lines.map((line) => line.id).toSet().length != lines.length) {
      throw ArgumentError('Cart subtotal or line IDs are inconsistent');
    }
  }
}

/// Pure rule snapshot. Target IDs are immutable and loaded in batches by the
/// repository. No database or Flutter dependency is needed for evaluation.
class PromotionRule {
  final String id, reference, name, type, rewardKind, targetMode, stackingMode;
  final int rewardValue, priority;
  final int? minimumSubtotalCents;
  final DateTime? startsAt, endsAt;
  final bool isActive, isDraft;
  final Set<String> productIds, categoryIds;

  PromotionRule(
      {required this.id,
      required this.reference,
      required this.name,
      required this.type,
      required this.rewardKind,
      required this.rewardValue,
      required this.targetMode,
      required this.stackingMode,
      required this.priority,
      this.minimumSubtotalCents,
      this.startsAt,
      this.endsAt,
      required this.isActive,
      required this.isDraft,
      Set<String> productIds = const {},
      Set<String> categoryIds = const {}})
      : productIds = Set.unmodifiable(productIds),
        categoryIds = Set.unmodifiable(categoryIds);
}

enum PromotionIneligibility {
  draft,
  inactive,
  notStarted,
  expired,
  unsupportedRule,
  invalidConfiguration,
  noTargetedProducts,
  noTargetedCategories,
  emptyEligibleSubtotal,
  minimumSpendNotMet,
}

class PromotionApplication {
  final String promotionId, reference, name, type, stackingMode;
  final int discountCents, eligibleSubtotalCents, priority;
  final List<String> affectedLineIds;
  final Map<String, int> lineDiscountCents;
  final String explanation;

  PromotionApplication(
      {required this.promotionId,
      required this.reference,
      required this.name,
      required this.type,
      required this.stackingMode,
      required this.discountCents,
      required this.eligibleSubtotalCents,
      required this.priority,
      required List<String> affectedLineIds,
      required Map<String, int> lineDiscountCents,
      required this.explanation})
      : affectedLineIds = List.unmodifiable(affectedLineIds),
        lineDiscountCents = Map.unmodifiable(lineDiscountCents);
}

class PromotionDecision {
  final PromotionRule rule;
  final PromotionApplication? application;
  final PromotionIneligibility? reason;
  const PromotionDecision(this.rule, {this.application, this.reason});
  bool get eligible => application != null;
}

class PromotionEvaluationResult {
  final List<PromotionDecision> decisions;
  final List<PromotionApplication> recommendedApplications;
  final int originalSubtotalCents, totalDiscountCents;
  int get discountedSubtotalCents => originalSubtotalCents - totalDiscountCents;
  List<PromotionApplication> get eligiblePromotions => List.unmodifiable(
      decisions.where((d) => d.eligible).map((d) => d.application!));
  List<PromotionDecision> get ineligiblePromotions =>
      List.unmodifiable(decisions.where((d) => !d.eligible));

  PromotionEvaluationResult(
      {required List<PromotionDecision> decisions,
      required List<PromotionApplication> recommendedApplications,
      required this.originalSubtotalCents,
      required this.totalDiscountCents})
      : decisions = List.unmodifiable(decisions),
        recommendedApplications = List.unmodifiable(recommendedApplications) {
    if (totalDiscountCents < 0 || totalDiscountCents > originalSubtotalCents) {
      throw ArgumentError('Invalid promotion total');
    }
  }
}
