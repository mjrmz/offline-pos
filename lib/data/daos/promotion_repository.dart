import 'dart:convert';
import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../../core/models/promotion_lifecycle.dart';
import '../../core/models/promotion_evaluation.dart';
import '../database.dart';
import 'auth_repository.dart';

class PromotionInput {
  final String name, description, type, rewardKind, targetMode, stackingMode;
  final int rewardValue, priority;
  final int? minimumSubtotalCents;
  final DateTime? startsAt, endsAt;
  final bool active, draft;
  final List<String> productIds, categoryIds;
  const PromotionInput(
      {required this.name,
      this.description = '',
      required this.type,
      required this.rewardKind,
      required this.rewardValue,
      this.minimumSubtotalCents,
      this.targetMode = 'all',
      this.stackingMode = 'exclusive',
      this.priority = 100,
      this.startsAt,
      this.endsAt,
      this.active = false,
      this.draft = false,
      this.productIds = const [],
      this.categoryIds = const []});
}

class PromotionRepository {
  final AppDatabase db;
  final AuthRepository auth;
  PromotionRepository(this.db) : auth = AuthRepository(db);

  Future<ActiveUser> _authorized(
      ActiveUser actor, PosPermission permission) async {
    final live = await auth.requireActive(actor.id);
    live.require(permission);
    return live;
  }

  void _validate(PromotionInput input) {
    if (input.name.trim().isEmpty) throw ArgumentError('Name is required');
    if (!{'percentage', 'fixed', 'minimum_spend'}.contains(input.type)) {
      throw ArgumentError('Unsupported promotion type');
    }
    if (!{'percentage', 'fixed'}.contains(input.rewardKind)) {
      throw ArgumentError('Invalid reward type');
    }
    if (input.type != 'minimum_spend' && input.rewardKind != input.type) {
      throw ArgumentError('Reward type does not match promotion type');
    }
    if (input.rewardValue <= 0 ||
        (input.rewardKind == 'percentage' && input.rewardValue > 10000)) {
      throw ArgumentError('Invalid discount value');
    }
    if (input.type == 'minimum_spend' &&
        (input.minimumSubtotalCents == null ||
            input.minimumSubtotalCents! <= 0)) {
      throw ArgumentError('Minimum spend is required');
    }
    if (input.startsAt != null &&
        input.endsAt != null &&
        !input.endsAt!.isAfter(input.startsAt!)) {
      throw ArgumentError('End must follow start');
    }
    if (!{'all', 'products', 'categories'}.contains(input.targetMode)) {
      throw ArgumentError('Invalid target mode');
    }
    if (input.targetMode == 'products' && input.productIds.isEmpty) {
      throw ArgumentError('Select a product');
    }
    if (input.targetMode == 'categories' && input.categoryIds.isEmpty) {
      throw ArgumentError('Select a category');
    }
    if (!{'exclusive', 'stackable'}.contains(input.stackingMode)) {
      throw ArgumentError('Invalid stacking mode');
    }
  }

  String status(Promotion row, [DateTime? now]) {
    return PromotionLifecycle.status(
            isDraft: row.isDraft,
            isActive: row.isActive,
            at: now ?? DateTime.now(),
            startsAt: row.startsAt,
            endsAt: row.endsAt)
        .name;
  }

  Future<void> _audit(ActiveUser actor, String action, Promotion row) async {
    await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
        userId: Value(actor.id),
        action: action,
        details: Value(
            jsonEncode({'reference': row.reference, 'promotionId': row.id}))));
  }

  Future<void> _targets(String id, PromotionInput input) async {
    await (db.delete(db.promotionProductTargets)
          ..where((t) => t.promotionId.equals(id)))
        .go();
    await (db.delete(db.promotionCategoryTargets)
          ..where((t) => t.promotionId.equals(id)))
        .go();
    if (input.targetMode == 'products') {
      for (final productId in input.productIds.toSet()) {
        final product = await (db.select(db.products)
              ..where((t) => t.id.equals(productId)))
            .getSingleOrNull();
        if (product == null) throw ArgumentError('Unknown product');
        await db.into(db.promotionProductTargets).insert(
            PromotionProductTargetsCompanion.insert(
                promotionId: id, productId: productId));
      }
    } else if (input.targetMode == 'categories') {
      for (final categoryId in input.categoryIds.toSet()) {
        final category = await (db.select(db.categories)
              ..where((t) => t.id.equals(categoryId)))
            .getSingleOrNull();
        if (category == null) throw ArgumentError('Unknown category');
        await db.into(db.promotionCategoryTargets).insert(
            PromotionCategoryTargetsCompanion.insert(
                promotionId: id, categoryId: categoryId));
      }
    }
  }

  Future<Promotion> createPromotion(
      ActiveUser actor, PromotionInput input) async {
    final live = await _authorized(actor, PosPermission.managePromotions);
    _validate(input);
    return db.transaction(() async {
      final next = await db
          .customSelect(
              "SELECT COALESCE(MAX(CAST(SUBSTR(reference, 7) AS INTEGER)), 0) + 1 AS n FROM promotions")
          .getSingle();
      final reference =
          'PROMO-${next.read<int>('n').toString().padLeft(6, '0')}';
      final id = await db.into(db.promotions).insertReturning(
          PromotionsCompanion.insert(
              reference: reference,
              name: input.name.trim(),
              description: Value(input.description.trim()),
              type: input.type,
              rewardKind: input.rewardKind,
              rewardValue: input.rewardValue,
              minimumSubtotalCents: Value(input.minimumSubtotalCents),
              targetMode: input.targetMode,
              priority: Value(input.priority),
              stackingMode: Value(input.stackingMode),
              startsAt: Value(input.startsAt),
              endsAt: Value(input.endsAt),
              isActive: Value(input.active),
              isDraft: Value(input.draft),
              createdBy: live.id,
              updatedBy: live.id));
      await _targets(id.id, input);
      await _audit(live, 'promotion_created', id);
      return id;
    });
  }

  Future<Promotion> duplicatePromotion(ActiveUser actor, String id) async {
    final live = await _authorized(actor, PosPermission.managePromotions);
    return db.transaction(() async {
      final source = await getPromotion(live, id);
      if (source == null) throw StateError('Promotion not found');
      final products = await productTargets(live, id);
      final categories = await categoryTargets(live, id);
      final now = DateTime.now();
      final expired = source.endsAt != null && !source.endsAt!.isAfter(now);
      final copy = await createPromotion(
          live,
          PromotionInput(
              name: '${source.name} Copy',
              description: source.description,
              type: source.type,
              rewardKind: source.rewardKind,
              rewardValue: source.rewardValue,
              minimumSubtotalCents: source.minimumSubtotalCents,
              targetMode: source.targetMode,
              stackingMode: source.stackingMode,
              priority: source.priority,
              startsAt: expired ? null : source.startsAt,
              endsAt: expired ? null : source.endsAt,
              draft: true,
              active: false,
              productIds: products,
              categoryIds: categories));
      await _audit(live, 'promotion_duplicated', copy);
      return copy;
    });
  }

  Future<Promotion> updatePromotion(
      ActiveUser actor, String id, PromotionInput input) async {
    final live = await _authorized(actor, PosPermission.managePromotions);
    _validate(input);
    return db.transaction(() async {
      final before = await getPromotion(actor, id);
      if (before == null) throw StateError('Promotion not found');
      await (db.update(db.promotions)..where((t) => t.id.equals(id))).write(
          PromotionsCompanion(
              name: Value(input.name.trim()),
              description: Value(input.description.trim()),
              type: Value(input.type),
              rewardKind: Value(input.rewardKind),
              rewardValue: Value(input.rewardValue),
              minimumSubtotalCents: Value(input.minimumSubtotalCents),
              targetMode: Value(input.targetMode),
              priority: Value(input.priority),
              stackingMode: Value(input.stackingMode),
              startsAt: Value(input.startsAt),
              endsAt: Value(input.endsAt),
              isActive: Value(input.active),
              isDraft: Value(input.draft),
              updatedAt: Value(DateTime.now()),
              updatedBy: Value(live.id)));
      await _targets(id, input);
      final after = (await getPromotion(actor, id))!;
      await _audit(live, 'promotion_edited', after);
      if (before.isActive != after.isActive) {
        await _audit(
            live,
            after.isActive ? 'promotion_activated' : 'promotion_deactivated',
            after);
      }
      return after;
    });
  }

  Future<void> setActive(ActiveUser actor, String id, bool active) async {
    final live = await _authorized(actor, PosPermission.managePromotions);
    await db.transaction(() async {
      final row = await getPromotion(actor, id);
      if (row == null) throw StateError('Promotion not found');
      if (row.isActive == active) return;
      await (db.update(db.promotions)..where((t) => t.id.equals(id))).write(
          PromotionsCompanion(
              isActive: Value(active),
              isDraft: active ? const Value(false) : const Value.absent(),
              updatedAt: Value(DateTime.now()),
              updatedBy: Value(live.id)));
      await _audit(
          live, active ? 'promotion_activated' : 'promotion_deactivated', row);
    });
  }

  Future<Promotion?> getPromotion(ActiveUser actor, String id) async {
    await _authorized(actor, PosPermission.viewPromotions);
    return (db.select(db.promotions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<List<String>> productTargets(ActiveUser actor, String id) async {
    await _authorized(actor, PosPermission.viewPromotions);
    return (await (db.select(db.promotionProductTargets)
              ..where((t) => t.promotionId.equals(id)))
            .get())
        .map((e) => e.productId)
        .toList();
  }

  Future<List<String>> categoryTargets(ActiveUser actor, String id) async {
    await _authorized(actor, PosPermission.viewPromotions);
    return (await (db.select(db.promotionCategoryTargets)
              ..where((t) => t.promotionId.equals(id)))
            .get())
        .map((e) => e.categoryId)
        .toList();
  }

  Future<List<String>> productTargetNames(ActiveUser actor, String id) async {
    final ids = await productTargets(actor, id);
    if (ids.isEmpty) return [];
    final rows = await (db.select(db.products)
          ..where((t) => t.id.isIn(ids))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
    return rows.map((row) => row.name).toList();
  }

  Future<List<String>> categoryTargetNames(ActiveUser actor, String id) async {
    final ids = await categoryTargets(actor, id);
    if (ids.isEmpty) return [];
    final rows = await (db.select(db.categories)
          ..where((t) => t.id.isIn(ids))
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
    return rows.map((row) => row.name).toList();
  }

  Future<List<AuditLog>> auditHistory(ActiveUser actor, String id) async {
    await _authorized(actor, PosPermission.viewPromotions);
    return (db.select(db.auditLogs)
          ..where((t) => t.details.like('%"promotionId":"$id"%'))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
  }

  Expression<bool> _filter(Promotions t, String search, String? type,
      String? statusFilter, DateTime now) {
    Expression<bool> where = const Constant(true);
    if (search.trim().isNotEmpty) {
      final q =
          '%${search.trim().replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      where = where & (t.name.like(q) | t.reference.like(q));
    }
    if (type != null && type != 'all') where = where & t.type.equals(type);
    if (statusFilter != null && statusFilter != 'all') {
      switch (statusFilter) {
        case 'draft':
          where = where & t.isDraft.equals(true);
        case 'inactive':
          where = where & t.isDraft.equals(false) & t.isActive.equals(false);
        case 'expired':
          where = where &
              t.isDraft.equals(false) &
              t.isActive.equals(true) &
              t.endsAt.isSmallerOrEqualValue(now);
        case 'scheduled':
          where = where &
              t.isDraft.equals(false) &
              t.isActive.equals(true) &
              t.startsAt.isBiggerThanValue(now) &
              (t.endsAt.isNull() | t.endsAt.isBiggerThanValue(now));
        case 'active':
          where = where &
              t.isDraft.equals(false) &
              t.isActive.equals(true) &
              (t.startsAt.isNull() | t.startsAt.isSmallerOrEqualValue(now)) &
              (t.endsAt.isNull() | t.endsAt.isBiggerThanValue(now));
      }
    }
    return where;
  }

  Future<List<Promotion>> listPromotions(ActiveUser actor,
      {int page = 0,
      String search = '',
      String? type,
      String? statusFilter}) async {
    await _authorized(actor, PosPermission.viewPromotions);
    final q = db.select(db.promotions)
      ..where((t) => _filter(t, search, type, statusFilter, DateTime.now()))
      ..orderBy([
        (t) => OrderingTerm.desc(t.updatedAt),
        (t) => OrderingTerm.desc(t.id)
      ])
      ..limit(50, offset: page * 50);
    return q.get();
  }

  Future<int> countPromotions(ActiveUser actor,
      {String search = '', String? type, String? statusFilter}) async {
    await _authorized(actor, PosPermission.viewPromotions);
    final count = db.promotions.id.count();
    final row = await (db.selectOnly(db.promotions)
          ..addColumns([count])
          ..where(_filter(
              db.promotions, search, type, statusFilter, DateTime.now())))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<Map<String, int>> statusCounts(ActiveUser actor) async {
    await _authorized(actor, PosPermission.viewPromotions);
    final result = <String, int>{};
    for (final status in [
      'active',
      'scheduled',
      'draft',
      'expired',
      'inactive'
    ]) {
      result[status] = await countPromotions(actor, statusFilter: status);
    }
    return result;
  }

  Future<List<Product>> searchProducts(ActiveUser actor, String query) async {
    await _authorized(actor, PosPermission.viewPromotions);
    return (db.select(db.products)
          ..where(
              (t) => t.isActive.equals(true) & t.name.like('%${query.trim()}%'))
          ..orderBy([(t) => OrderingTerm.asc(t.name)])
          ..limit(20))
        .get();
  }

  Future<List<Category>> categories(ActiveUser actor) async {
    await _authorized(actor, PosPermission.viewPromotions);
    return (db.select(db.categories)
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
  }

  /// Runtime candidate loading is independent of the 50-row admin list.
  /// It uses one header query and two batch target queries for any cart size.
  Future<List<PromotionRule>> getPromotionCandidates(
      ActiveUser actor, DateTime at) async {
    await _authorized(actor, PosPermission.sell);
    final rows = await (db.select(db.promotions)
          ..where((t) =>
              t.isActive.equals(true) &
              t.isDraft.equals(false) &
              (t.startsAt.isNull() | t.startsAt.isSmallerOrEqualValue(at)) &
              (t.endsAt.isNull() | t.endsAt.isBiggerThanValue(at)) &
              t.type.isIn(const ['percentage', 'fixed', 'minimum_spend']) &
              t.rewardValue.isBiggerThanValue(0))
          ..orderBy([
            (t) => OrderingTerm.desc(t.priority),
            (t) => OrderingTerm.asc(t.reference),
            (t) => OrderingTerm.asc(t.id)
          ]))
        .get();
    if (rows.isEmpty) return [];
    final ids = rows.map((row) => row.id).toList();
    final products = await (db.select(db.promotionProductTargets)
          ..where((t) => t.promotionId.isIn(ids)))
        .get();
    final categories = await (db.select(db.promotionCategoryTargets)
          ..where((t) => t.promotionId.isIn(ids)))
        .get();
    final productsByPromotion = <String, Set<String>>{};
    for (final target in products) {
      productsByPromotion
          .putIfAbsent(target.promotionId, () => {})
          .add(target.productId);
    }
    final categoriesByPromotion = <String, Set<String>>{};
    for (final target in categories) {
      categoriesByPromotion
          .putIfAbsent(target.promotionId, () => {})
          .add(target.categoryId);
    }
    return [
      for (final row in rows)
        PromotionRule(
          id: row.id,
          reference: row.reference,
          name: row.name,
          type: row.type,
          rewardKind: row.rewardKind,
          rewardValue: row.rewardValue,
          targetMode: row.targetMode,
          stackingMode: row.stackingMode,
          priority: row.priority,
          minimumSubtotalCents: row.minimumSubtotalCents,
          startsAt: row.startsAt,
          endsAt: row.endsAt,
          isActive: row.isActive,
          isDraft: row.isDraft,
          productIds: productsByPromotion[row.id] ?? {},
          categoryIds: categoriesByPromotion[row.id] ?? {},
        )
    ];
  }
}
