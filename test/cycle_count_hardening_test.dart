import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cycle_count_schedule_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/role_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';

void main() {
  test('concurrent starts across database connections link one count',
      () async {
    final dir = await Directory.systemTemp.createTemp('cycle-concurrent-');
    final file = File('${dir.path}/pos.sqlite');
    final first = AppDatabase.forTesting(NativeDatabase(file));
    AppDatabase? second;
    try {
      final auth = AuthService(AuthRepository(first));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(ownerId, 'password123');
      final productId = await PosRepository(first).saveProduct(
          name: 'A', priceCents: 100, costCents: 50, startingStock: 2);
      final schedules = CycleCountScheduleRepository(first);
      final row = await schedules.create(auth.current!,
          title: 'Count',
          scopeType: 'products',
          scopeRefs: [productId],
          assigneeId: ownerId,
          scheduledDate: DateTime(2026, 10, 25),
          dueDate: DateTime(2026, 10, 26));
      second = AppDatabase.forTesting(NativeDatabase(file));
      await second.select(second.cycleCountSchedules).get();
      final results = await Future.wait([
        schedules.start(auth.current!, row.id),
        CycleCountScheduleRepository(second).start(auth.current!, row.id),
        schedules.start(auth.current!, row.id),
      ]);
      expect(results.map((c) => c.id).toSet().length, 1);
      expect((await first.select(first.stockCounts).get()).length, 1);
      expect((await schedules.get(row.id)).stockCountId, results.first.id);
      final starts = await first
          .customSelect(
              "SELECT COUNT(*) AS n FROM audit_logs WHERE action = 'cycle_count.started'")
          .getSingle();
      expect(starts.read<int>('n'), 1);
    } finally {
      await second?.close();
      await first.close();
      await dir.delete(recursive: true);
    }
  });

  test('restart preserves link, frozen category scope, and overdue boundary',
      () async {
    final dir = await Directory.systemTemp.createTemp('cycle-restart-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(ownerId, 'password123');
      final category = await db
          .into(db.categories)
          .insertReturning(CategoriesCompanion.insert(name: 'Shelf'));
      final a = await PosRepository(db).saveProduct(
          name: 'A',
          categoryId: category.id,
          priceCents: 100,
          costCents: 50,
          startingStock: 2);
      final schedule = await CycleCountScheduleRepository(db).create(
          auth.current!,
          title: 'Shelf',
          scopeType: 'categories',
          scopeRefs: [category.id],
          assigneeId: ownerId,
          scheduledDate: DateTime(2026, 10, 25),
          dueDate: DateTime(2026, 10, 26));
      final count = await CycleCountScheduleRepository(db)
          .start(auth.current!, schedule.id);
      await (db.update(db.products)..where((p) => p.id.equals(a)))
          .write(const ProductsCompanion(categoryId: Value(null)));
      await PosRepository(db).saveProduct(
          name: 'B',
          categoryId: category.id,
          priceCents: 100,
          costCents: 50,
          startingStock: 1);
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      final repo = CycleCountScheduleRepository(db);
      final persisted = await repo.get(schedule.id);
      expect(
          CycleCountScheduleRepository.overdue(
              persisted, DateTime(2026, 10, 26, 23, 59)),
          false);
      expect(
          CycleCountScheduleRepository.overdue(
              persisted, DateTime(2026, 10, 27, 0, 0)),
          true);
      final resumed = await repo.start(auth.current!, schedule.id);
      expect(resumed.id, count.id);
      expect(
          (await StockCountRepository(db).lines(count.id))
              .map((l) => l.productId),
          [a]);
      expect((await db.select(db.stockCounts).get()).length, 1);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('direct repository calls enforce management and linked assignee',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final id = await PosRepository(db).saveProduct(
        name: 'A', priceCents: 100, costCents: 50, startingStock: 1);
    final roleCode = await RoleRepository(db)
        .create(ownerId, 'Counter', '', {PosPermission.stockCount});
    final assigned = await db.into(db.users).insertReturning(
        UsersCompanion.insert(name: 'Assigned', role: roleCode));
    final other = await db
        .into(db.users)
        .insertReturning(UsersCompanion.insert(name: 'Other', role: roleCode));
    final assignedActor = await AuthRepository(db).requireActive(assigned.id);
    final otherActor = await AuthRepository(db).requireActive(other.id);
    final repo = CycleCountScheduleRepository(db);
    final row = await repo.create(auth.current!,
        title: 'Scoped',
        scopeType: 'products',
        scopeRefs: [id],
        assigneeId: assigned.id,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 26));
    Future<void> edit(ActiveUser actor) => repo.edit(actor, row.id,
        title: 'Changed',
        scopeType: 'products',
        scopeRefs: [id],
        assigneeId: other.id,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 26));
    await expectLater(
        repo.create(assignedActor,
            title: 'Denied',
            scopeType: 'products',
            scopeRefs: [id],
            assigneeId: assigned.id,
            scheduledDate: DateTime(2026),
            dueDate: DateTime(2026)),
        throwsStateError);
    await expectLater(edit(assignedActor), throwsStateError);
    await expectLater(repo.cancel(assignedActor, row.id), throwsStateError);
    await expectLater(repo.start(otherActor, row.id), throwsStateError);
    final count = await repo.start(assignedActor, row.id);
    final line = (await StockCountRepository(db).lines(count.id)).single;
    await expectLater(
        StockCountRepository(db).setCount(otherActor, line.id, 1000),
        throwsStateError);
    await expectLater(StockCountRepository(db).refreshLine(otherActor, line.id),
        throwsStateError);
    await expectLater(StockCountRepository(db).cancel(otherActor, count.id),
        throwsStateError);
    expect((await repo.get(row.id)).assigneeId, assigned.id);
    expect((await StockCountRepository(db).lines(count.id)).single.countedMilli,
        isNull);
  });

  test('no-op edit adds no audit; assignment changes add one event', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final id = await PosRepository(db).saveProduct(
        name: 'A', priceCents: 100, costCents: 50, startingStock: 1);
    final employee = await db.into(db.users).insertReturning(
        UsersCompanion.insert(name: 'Employee', role: 'cashier'));
    final repo = CycleCountScheduleRepository(db);
    final row = await repo.create(auth.current!,
        title: 'One',
        scopeType: 'products',
        scopeRefs: [id],
        assigneeId: ownerId,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 26));
    Future<void> edit(String assignee) => repo.edit(auth.current!, row.id,
        title: 'One',
        scopeType: 'products',
        scopeRefs: [id],
        assigneeId: assignee,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 26));
    await edit(ownerId);
    await edit(employee.id);
    final entries = await repo.activity(row.id);
    expect(entries.where((e) => e.action == 'cycle_count.created').length, 1);
    expect(entries.where((e) => e.action == 'cycle_count.updated').length, 1);
    expect(entries.where((e) => e.action == 'cycle_count.assigned').length, 2);
  });

  test('audit activity matches exact schedule ID and its event suffix',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final productId = await PosRepository(db).saveProduct(
        name: 'A', priceCents: 100, costCents: 50, startingStock: 1);
    final repo = CycleCountScheduleRepository(db);
    final row = await repo.create(auth.current!,
        title: 'Audit',
        scopeType: 'products',
        scopeRefs: [productId],
        assigneeId: ownerId,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 26));
    await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
        action: 'cycle_count.created', details: Value('${row.id}-other')));
    await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
        action: 'cycle_count.started', details: Value('${row.id}:linked')));
    final entries = await repo.activity(row.id);
    expect(entries.length, 3);
    expect(entries.any((e) => e.details == '${row.id}-other'), false);
    expect(entries.any((e) => e.details == '${row.id}:linked'), true);
  });

  test('stale edit and cancel cannot change a linked schedule or its audit',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final productId = await PosRepository(db).saveProduct(
        name: 'A', priceCents: 100, costCents: 50, startingStock: 1);
    final repo = CycleCountScheduleRepository(db);
    final stale = await repo.create(auth.current!,
        title: 'Original',
        scopeType: 'products',
        scopeRefs: [productId],
        assigneeId: ownerId,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 26));
    final count = await repo.start(auth.current!, stale.id);
    final priorAuditCount = (await repo.activity(stale.id)).length;
    await expectLater(
        repo.edit(auth.current!, stale.id,
            title: 'Stale edit',
            scopeType: stale.scopeType,
            scopeRefs: [productId],
            assigneeId: ownerId,
            scheduledDate: stale.scheduledDate,
            dueDate: stale.dueDate),
        throwsStateError);
    await expectLater(repo.cancel(auth.current!, stale.id), throwsStateError);
    final current = await repo.get(stale.id);
    expect(current.title, 'Original');
    expect(current.status, 'in_progress');
    expect(current.stockCountId, count.id);
    expect((await repo.activity(stale.id)).length, priorAuditCount);
  });

  test('failed finalization leaves count and schedule unfinished', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final productId = await PosRepository(db).saveProduct(
        name: 'A', priceCents: 100, costCents: 50, startingStock: 1);
    final repo = CycleCountScheduleRepository(db);
    final row = await repo.create(auth.current!,
        title: 'Count',
        scopeType: 'products',
        scopeRefs: [productId],
        assigneeId: ownerId,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 26));
    final counts = StockCountRepository(db);
    final count = await repo.start(auth.current!, row.id);
    final line = (await counts.lines(count.id)).single;
    await counts.setCount(auth.current!, line.id, line.expectedMilli + 1000);
    await expectLater(
        counts.finalize(auth.current!, count.id), throwsStateError);
    expect((await repo.get(row.id)).status, 'in_progress');
    expect((await counts.counts()).single.status, 'draft');
    expect(
        (await repo.activity(row.id))
            .where((e) => e.action == 'cycle_count.completed'),
        isEmpty);
  });
}
