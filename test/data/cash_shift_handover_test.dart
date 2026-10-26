import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_shift_handover_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('schema 51 upgrades additively with no fabricated handovers', () async {
    final dir = await Directory.systemTemp.createTemp('handover-migrate-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    final owner = await auth.login(ownerId, 'ownerPassword123');
    final session = await CashSessionRepository(db).open(owner, 12345);
    await db.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE cash_shift_handover_denominations');
    raw.execute('DROP TABLE cash_shift_handovers');
    raw.execute('PRAGMA user_version = 51');
    raw.dispose();
    db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect((await CashSessionRepository(db).active())!.id, session.id);
      expect(await CashSessionRepository(db).expected(session.id), 12345);
      expect(await CashShiftHandoverRepository(db).history(owner), isEmpty);
      expect(BackupService.verify(file), 55);
    } finally {
      await db.close();
    }
  });

  Future<(AppDatabase, ActiveUser, ActiveUser, ActiveUser, String)>
      setup() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    final owner = await auth.login(ownerId, 'ownerPassword123');
    final firstId = await auth.createUser('First', UserRole.cashier, '1234');
    final secondId = await auth.createUser('Second', UserRole.cashier, '5678');
    final first = await AuthRepository(db).requireActive(firstId);
    final second = await AuthRepository(db).requireActive(secondId);
    final session = await CashSessionRepository(db).open(first, 100000);
    return (db, owner, first, second, session.id);
  }

  test('schema 52 adds empty handover tables and accepts a single active draft',
      () async {
    final (db, _, first, _, sessionId) = await setup();
    expect(db.schemaVersion, 55);
    final repo = CashShiftHandoverRepository(db);
    expect(
        await repo.history(await AuthRepository(db).requireActive(
            (await db.select(db.users).get())
                .firstWhere((u) => u.role == 'owner')
                .id)),
        isEmpty);
    final draft = await repo.start(first, sessionId);
    expect(draft.reference, 'HOV-000001');
    await expectLater(repo.start(first, sessionId), throwsA(isA<StateError>()));
    expect((await db.select(db.cashMovements).get()), isEmpty);
  });

  test(
      'balanced count completes with manager credentials and remains immutable',
      () async {
    final (db, owner, first, second, sessionId) = await setup();
    final repo = CashShiftHandoverRepository(db);
    final draft = await repo.start(first, sessionId);
    final submitted =
        await repo.submit(first, draft.id, second.id, {100000: 1}, '');
    expect(submitted.variance, 0);
    await expectLater(
        repo.complete(first, draft.id, owner.id, credential: 'wrongPassword'),
        throwsA(isA<StateError>()));
    final completed = await repo.complete(first, draft.id, owner.id,
        credential: 'ownerPassword123');
    expect(completed.status, 'completed');
    expect(completed.managerId, owner.id);
    expect(
        (await CashSessionRepository(db).active())!.openedByUserId, first.id);
    expect((await CashSessionRepository(db).currentFor(second.id)), isNull);
    expect((await db.select(db.cashMovements).get()), isEmpty);
    await expectLater(repo.cancel(first, draft.id), throwsA(isA<StateError>()));
    await expectLater(
        db.customStatement(
            "UPDATE cash_shift_handovers SET notes = 'changed' WHERE id = ?",
            [draft.id]),
        throwsA(isA<Exception>()));
  });

  test('short and over counts require notes; stale cash requires recount',
      () async {
    final (db, owner, first, second, sessionId) = await setup();
    final repo = CashShiftHandoverRepository(db);
    final draft = await repo.start(first, sessionId);
    await expectLater(repo.submit(first, draft.id, second.id, {50000: 1}, ''),
        throwsA(isA<StateError>()));
    final short =
        await repo.submit(first, draft.id, second.id, {50000: 1}, 'Recounted');
    expect(short.variance, -50000);
    await expectLater(CashSessionRepository(db).close(first, 50000),
        throwsA(isA<StateError>()));
    await db.customStatement(
        "INSERT INTO cash_movements (id, session_id, amount_cents, kind, created_at) VALUES ('test-movement', ?, 10000, 'cash_sale', strftime('%s','now'))",
        [sessionId]);
    await expectLater(
        repo.complete(first, draft.id, owner.id,
            credential: 'ownerPassword123'),
        throwsA(isA<StateError>()));
    final recounted = await repo.recount(first, draft.id);
    expect(recounted.expected, 110000);
    final over = await repo.submit(first, draft.id, second.id,
        {100000: 1, 20000: 1}, 'Extra cash counted');
    expect(over.variance, 10000);
    await repo.cancel(first, draft.id);
    expect((await repo.detail(first, draft.id)).status, 'cancelled');
  });

  test('cashier cannot acknowledge and a closed session cannot complete',
      () async {
    final (db, owner, first, second, sessionId) = await setup();
    final repo = CashShiftHandoverRepository(db);
    final draft = await repo.start(first, sessionId);
    await repo.submit(first, draft.id, second.id, {100000: 1}, '');
    await expectLater(
        repo.complete(first, draft.id, second.id, credential: '5678'),
        throwsA(isA<StateError>()));
    await db.customStatement(
        "UPDATE cash_sessions SET closed_at = strftime('%s','now') WHERE id = ?",
        [sessionId]);
    await expectLater(
        repo.complete(first, draft.id, owner.id,
            credential: 'ownerPassword123'),
        throwsA(isA<StateError>()));
    expect((await db.select(db.cashMovements).get()), isEmpty);
  });

  test('simultaneous acknowledgments complete only once', () async {
    final (db, owner, first, second, sessionId) = await setup();
    final repo = CashShiftHandoverRepository(db);
    final draft = await repo.start(first, sessionId);
    await repo.submit(first, draft.id, second.id, {100000: 1}, '');
    final attempts = await Future.wait([
      repo.complete(first, draft.id, owner.id, credential: 'ownerPassword123')
          .then((_) => true).catchError((_) => false),
      repo.complete(first, draft.id, owner.id, credential: 'ownerPassword123')
          .then((_) => true).catchError((_) => false),
    ]);
    expect(attempts.where((ok) => ok).length, 1);
    expect((await repo.detail(owner, draft.id)).status, 'completed');
    expect((await db.select(db.cashMovements).get()), isEmpty);
  });
}

