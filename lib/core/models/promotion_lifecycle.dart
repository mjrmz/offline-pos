enum PromotionStatus { draft, inactive, scheduled, active, expired }

abstract final class PromotionLifecycle {
  static PromotionStatus status(
      {required bool isDraft,
      required bool isActive,
      required DateTime at,
      DateTime? startsAt,
      DateTime? endsAt}) {
    if (isDraft) return PromotionStatus.draft;
    if (!isActive) return PromotionStatus.inactive;
    if (endsAt != null && !endsAt.isAfter(at)) return PromotionStatus.expired;
    if (startsAt != null && startsAt.isAfter(at)) {
      return PromotionStatus.scheduled;
    }
    return PromotionStatus.active;
  }
}
