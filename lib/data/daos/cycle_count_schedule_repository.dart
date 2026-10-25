import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'stock_count_repository.dart';

/// Schedules select products at start. The linked Stock Count lines then freeze
/// the product set and expected quantities for the existing reconciliation flow.
class CycleCountScheduleRepository {
  final AppDatabase db;
  CycleCountScheduleRepository(this.db);

  Future<List<CycleCountSchedule>> all() => (db.select(db.cycleCountSchedules)
        ..orderBy([(t) => OrderingTerm(expression: t.dueDate)]))
      .get();

  Future<CycleCountSchedule> get(String id) =>
      (db.select(db.cycleCountSchedules)..where((t) => t.id.equals(id)))
          .getSingle();

  Future<List<AuditLog>> activity(String id) => (db.select(db.auditLogs)
        ..where((a) =>
            a.action.like('cycle_count.%') &
            (a.details.equals(id) | a.details.like('$id:%')))
        ..orderBy([
          (a) => OrderingTerm(expression: a.createdAt, mode: OrderingMode.desc)
        ]))
      .get();

  static DateTime businessDate(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static bool overdue(CycleCountSchedule schedule, DateTime now) =>
      schedule.status != 'completed' &&
      schedule.status != 'cancelled' &&
      businessDate(schedule.dueDate).isBefore(businessDate(now));

  Future<ActiveUser> _manager(ActiveUser actor) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.stockCount);
    if (live.role != UserRole.owner && live.role != UserRole.manager) {
      throw StateError('Only an owner or manager may manage schedules');
    }
    return live;
  }

  Future<void> _validate(String title, String scopeType, List<String> refs,
      String assigneeId, DateTime scheduled, DateTime due) async {
    if (title.trim().isEmpty ||
        refs.isEmpty ||
        !{'products', 'categories'}.contains(scopeType)) {
      throw StateError('Enter a title and select a scope');
    }
    if (businessDate(due).isBefore(businessDate(scheduled))) {
      throw StateError('Due date cannot precede scheduled date');
    }
    final assignee = await (db.select(db.users)
          ..where((u) => u.id.equals(assigneeId) & u.isActive.equals(true)))
        .getSingleOrNull();
    if (assignee == null) throw StateError('Select an active employee');
    final unique = refs.toSet();
    if (unique.length != refs.length || unique.contains('')) {
      throw StateError('Scope contains duplicate or empty references');
    }
    if (scopeType == 'products') {
      final products = await (db.select(db.products)
            ..where((p) => p.id.isIn(refs) & p.isActive.equals(true)))
          .get();
      if (products.length != refs.length) {
        throw StateError('A product is unavailable');
      }
    } else {
      final categories =
          await (db.select(db.categories)..where((c) => c.id.isIn(refs))).get();
      if (categories.length != refs.length) {
        throw StateError('A category is unavailable');
      }
    }
  }

  Future<CycleCountSchedule> create(
    ActiveUser actor, {
    required String title,
    required String scopeType,
    required List<String> scopeRefs,
    required String assigneeId,
    required DateTime scheduledDate,
    required DateTime dueDate,
    String? notes,
  }) =>
      db.transaction(() async {
        final live = await _manager(actor);
        await _validate(
            title, scopeType, scopeRefs, assigneeId, scheduledDate, dueDate);
        final row = await db
            .into(db.cycleCountSchedules)
            .insertReturning(CycleCountSchedulesCompanion.insert(
              title: title.trim(),
              scopeType: scopeType,
              scopeRefs: jsonEncode(scopeRefs),
              assigneeId: assigneeId,
              scheduledDate: businessDate(scheduledDate),
              dueDate: businessDate(dueDate),
              createdBy: live.id,
              notes: Value(notes?.trim()),
            ));
        await AuthRepository(db).audit(live.id, 'cycle_count.created', row.id);
        await AuthRepository(db)
            .audit(live.id, 'cycle_count.assigned', '${row.id}:$assigneeId');
        return row;
      });

  Future<void> edit(
    ActiveUser actor,
    String id, {
    required String title,
    required String scopeType,
    required List<String> scopeRefs,
    required String assigneeId,
    required DateTime scheduledDate,
    required DateTime dueDate,
    String? notes,
  }) =>
      db.transaction(() async {
        final live = await _manager(actor);
        final old = await get(id);
        if (old.status != 'scheduled' || old.stockCountId != null) {
          throw StateError('Started schedules cannot be edited');
        }
        await _validate(
            title, scopeType, scopeRefs, assigneeId, scheduledDate, dueDate);
        final unchanged = old.title == title.trim() &&
            old.scopeType == scopeType &&
            (jsonDecode(old.scopeRefs) as List)
                .cast<String>()
                .toSet()
                .containsAll(scopeRefs) &&
            (jsonDecode(old.scopeRefs) as List).length == scopeRefs.length &&
            old.assigneeId == assigneeId &&
            businessDate(old.scheduledDate) == businessDate(scheduledDate) &&
            businessDate(old.dueDate) == businessDate(dueDate) &&
            (old.notes ?? '') == (notes?.trim() ?? '');
        if (unchanged) return;
        final changed = await (db.update(db.cycleCountSchedules)
              ..where((s) =>
                  s.id.equals(id) &
                  s.status.equals('scheduled') &
                  s.stockCountId.isNull()))
            .write(CycleCountSchedulesCompanion(
                title: Value(title.trim()),
                scopeType: Value(scopeType),
                scopeRefs: Value(jsonEncode(scopeRefs)),
                assigneeId: Value(assigneeId),
                scheduledDate: Value(businessDate(scheduledDate)),
                dueDate: Value(businessDate(dueDate)),
                notes: Value(notes?.trim()),
                updatedAt: Value(DateTime.now())));
        if (changed != 1) throw StateError('Schedule was already started');
        final audit = AuthRepository(db);
        await audit.audit(live.id, 'cycle_count.updated', id);
        if (old.assigneeId != assigneeId) {
          await audit.audit(live.id, 'cycle_count.assigned', '$id:$assigneeId');
        }
      });

  Future<StockCount> start(ActiveUser actor, String id) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await _startOnce(actor, id);
      } on sqlite.SqliteException catch (error) {
        if (error.resultCode != 5 || attempt == 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
      }
    }
    throw StateError('Could not start schedule');
  }

  Future<StockCount> _startOnce(ActiveUser actor, String id) =>
      db.transaction(() async {
        // Take SQLite's write reservation before reading the link. Competing
        // connections then observe the committed link instead of both making
        // a snapshot from the same unstarted schedule.
        final claimed = await db.customUpdate(
            'UPDATE cycle_count_schedules SET updated_at = updated_at WHERE id = ?',
            variables: [Variable.withString(id)]);
        if (claimed != 1) throw StateError('Schedule is unavailable');
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockCount);
        final schedule = await get(id);
        if (live.id != schedule.assigneeId &&
            live.role != UserRole.owner &&
            live.role != UserRole.manager) {
          throw StateError('Count is assigned to another employee');
        }
        if (schedule.stockCountId != null) {
          final count = await (db.select(db.stockCounts)
                ..where((c) => c.id.equals(schedule.stockCountId!)))
              .getSingle();
          if (count.status == 'cancelled') {
            throw StateError('Linked count was cancelled');
          }
          return count;
        }
        if (schedule.status != 'scheduled') {
          throw StateError('Schedule is closed');
        }
        final refs = (jsonDecode(schedule.scopeRefs) as List).cast<String>();
        final products = await (db.select(db.products)
              ..where((p) => p.isActive.equals(true)))
            .get();
        final configurations =
            await BusinessFeatureRepository(db).allProductConfigurations();
        final ids = products
            .where((p) =>
                !(configurations[p.id]?.madeToOrder ?? false) &&
                (schedule.scopeType == 'products'
                    ? refs.contains(p.id)
                    : refs.contains(p.categoryId)))
            .map((p) => p.id)
            .toList();
        if (ids.isEmpty) {
          throw StateError('No eligible active products in scope');
        }
        final count = await StockCountRepository(db)
            .createCount(live, productIds: ids, notes: schedule.notes);
        final linked = await (db.update(db.cycleCountSchedules)
              ..where((s) => s.id.equals(id) & s.stockCountId.isNull()))
            .write(CycleCountSchedulesCompanion(
                stockCountId: Value(count.id),
                status: const Value('in_progress'),
                updatedAt: Value(DateTime.now())));
        if (linked != 1) throw StateError('Schedule was already started');
        await AuthRepository(db)
            .audit(live.id, 'cycle_count.started', '$id:${count.id}');
        return count;
      });

  Future<void> cancel(ActiveUser actor, String id) => db.transaction(() async {
        final live = await _manager(actor);
        final schedule = await get(id);
        if (schedule.status != 'scheduled' || schedule.stockCountId != null) {
          throw StateError('Only unstarted schedules can be cancelled');
        }
        final changed = await (db.update(db.cycleCountSchedules)
              ..where((s) =>
                  s.id.equals(id) &
                  s.status.equals('scheduled') &
                  s.stockCountId.isNull()))
            .write(CycleCountSchedulesCompanion(
                status: const Value('cancelled'),
                updatedAt: Value(DateTime.now())));
        if (changed != 1) throw StateError('Schedule was already started');
        await AuthRepository(db).audit(live.id, 'cycle_count.cancelled', id);
      });
}
