import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cycle_count_schedule_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late AppDatabase db;
  late AuthService auth;
  late CycleCountScheduleRepository schedules;
  late String ownerId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(AuthRepository(db));
    ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    schedules = CycleCountScheduleRepository(db);
  });
  tearDown(() async => db.close());

  Future<String> product(String name) async =>
      (await PosRepository(db).saveProduct(
          name: name, priceCents: 1000, costCents: 500, startingStock: 5));

  Future<CycleCountSchedule> create(List<String> refs,
          {String scope = 'products', DateTime? scheduled, DateTime? due}) =>
      schedules.create(auth.current!,
          title: 'Weekly shelf check',
          scopeType: scope,
          scopeRefs: refs,
          assigneeId: ownerId,
          scheduledDate: scheduled ?? DateTime(2026, 10, 24),
          dueDate: due ?? DateTime(2026, 10, 25));

  test('product schedule starts once and freezes linked lines', () async {
    final a = await product('A');
    final row = await create([a]);
    expect((await db.select(db.stockCounts).get()), isEmpty);
    final first = await schedules.start(auth.current!, row.id);
    final second = await schedules.start(auth.current!, row.id);
    expect(first.id, second.id);
    expect((await db.select(db.stockCounts).get()).length, 1);
    expect(
        (await StockCountRepository(db).lines(first.id)).single.productId, a);
    expect((await schedules.get(row.id)).status, 'in_progress');
    expect(
        CycleCountScheduleRepository.overdue(
            await schedules.get(row.id), DateTime(2026, 10, 26)),
        isTrue);
    await product('Later');
    expect((await StockCountRepository(db).lines(first.id)).length, 1);
  });

  test('due date uses local calendar boundary', () async {
    final id = await product('A');
    final row = await create([id]);
    expect(
        CycleCountScheduleRepository.overdue(
            row, DateTime(2026, 10, 25, 23, 59)),
        false);
    expect(CycleCountScheduleRepository.overdue(row, DateTime(2026, 10, 26)),
        true);
    await expectLater(
        create([id], due: DateTime(2026, 10, 23)), throwsStateError);
  });

  test('category scope resolves once at start', () async {
    final id = await product('A');
    final category = await db
        .into(db.categories)
        .insertReturning(CategoriesCompanion.insert(name: 'Shelf'));
    await (db.update(db.products)..where((p) => p.id.equals(id)))
        .write(ProductsCompanion(categoryId: Value(category.id)));
    final row = await create([category.id], scope: 'categories');
    final count = await schedules.start(auth.current!, row.id);
    expect(
        (await StockCountRepository(db).lines(count.id)).single.productId, id);
  });

  test('started schedule cannot be edited or directly cancelled', () async {
    final id = await product('A');
    final row = await create([id]);
    await schedules.start(auth.current!, row.id);
    await expectLater(
        schedules.cancel(auth.current!, row.id), throwsStateError);
    await expectLater(
        schedules.edit(auth.current!, row.id,
            title: 'Changed',
            scopeType: 'products',
            scopeRefs: [id],
            assigneeId: ownerId,
            scheduledDate: DateTime(2026),
            dueDate: DateTime(2026)),
        throwsStateError);
  });

  test('duplicate scope and unauthorized schedule creation are rejected',
      () async {
    final id = await product('A');
    await expectLater(create([id, id]), throwsStateError);
    final cashier = await db.into(db.users).insertReturning(
        UsersCompanion.insert(name: 'Cashier', role: 'cashier'));
    final actor = ActiveUser(cashier.id, cashier.name, UserRole.cashier);
    await expectLater(
        schedules.create(actor,
            title: 'Unauthorized',
            scopeType: 'products',
            scopeRefs: [id],
            assigneeId: cashier.id,
            scheduledDate: DateTime(2026),
            dueDate: DateTime(2026)),
        throwsStateError);
  });

  test('finalization completes schedule and records one completion audit',
      () async {
    final id = await product('A');
    final row = await create([id]);
    final counts = StockCountRepository(db);
    final count = await schedules.start(auth.current!, row.id);
    final line = (await counts.lines(count.id)).single;
    await counts.setCount(auth.current!, line.id, line.expectedMilli);
    await counts.finalize(auth.current!, count.id);
    final done = await schedules.get(row.id);
    expect(done.status, 'completed');
    expect(CycleCountScheduleRepository.overdue(done, DateTime(2030)), false);
    final audit = await db
        .customSelect(
            "SELECT COUNT(*) AS n FROM audit_logs WHERE action = 'cycle_count.completed'")
        .getSingle();
    expect(audit.read<int>('n'), 1);
    await expectLater(
        counts.finalize(auth.current!, count.id), throwsStateError);
  });

  test('linked draft cancellation synchronizes schedule', () async {
    final id = await product('A');
    final row = await create([id]);
    final count = await schedules.start(auth.current!, row.id);
    await StockCountRepository(db).cancel(auth.current!, count.id);
    expect((await schedules.get(row.id)).status, 'cancelled');
    expect(
        CycleCountScheduleRepository.overdue(
            await schedules.get(row.id), DateTime(2030)),
        false);
  });

  test('inactive assignee remains visible but cannot be newly assigned',
      () async {
    final id = await product('A');
    final employee = await db.into(db.users).insertReturning(
        UsersCompanion.insert(name: 'Employee', role: 'cashier'));
    final row = await schedules.create(auth.current!,
        title: 'Check',
        scopeType: 'products',
        scopeRefs: [id],
        assigneeId: employee.id,
        scheduledDate: DateTime(2026, 10, 25),
        dueDate: DateTime(2026, 10, 25));
    await (db.update(db.users)..where((u) => u.id.equals(employee.id)))
        .write(const UsersCompanion(isActive: Value(false)));
    expect((await schedules.get(row.id)).assigneeId, employee.id);
    await expectLater(
        schedules.create(auth.current!,
            title: 'Second',
            scopeType: 'products',
            scopeRefs: [id],
            assigneeId: employee.id,
            scheduledDate: DateTime(2026, 10, 25),
            dueDate: DateTime(2026, 10, 25)),
        throwsStateError);
  });

  test('manual counts stay separate', () async {
    await product('A');
    final count = await StockCountRepository(db).createCount(auth.current!);
    expect((await db.select(db.cycleCountSchedules).get()), isEmpty);
    expect(count.status, 'draft');
  });

  test('schema 50 upgrade adds schedules and retains inventory', () async {
    final dir = await Directory.systemTemp.createTemp('cycle-count-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final original = AppDatabase.forTesting(NativeDatabase(file));
    await original.select(original.products).get();
    await original
        .into(original.products)
        .insert(ProductsCompanion.insert(name: 'Keep me', priceCents: 100));
    await original.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE cycle_count_schedules');
    raw.execute('DROP TABLE cash_shift_handover_denominations');
    raw.execute('DROP TABLE cash_shift_handovers');
    raw.execute('PRAGMA user_version = 50');
    raw.dispose();
    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(upgraded.close);
    expect(upgraded.schemaVersion, 55);
    expect((await upgraded.select(upgraded.products).get()).single.name,
        'Keep me');
    expect(await upgraded.select(upgraded.cycleCountSchedules).get(), isEmpty);
  });
}
