import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_activity_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';

void main() {
  test('cash funds, reimbursement, replenishment and reversal remain distinct',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final actor = auth.current!;
    final sessions = CashSessionRepository(db);
    final session = await sessions.open(actor, 100000);
    final repo = CashActivityRepository(db);
    final category = (await repo.categories()).first;
    final drawer = await repo.expense(actor,
        amountCents: 10000,
        source: 'drawer',
        categoryId: category.id,
        payee: 'Grab',
        reference: 'OR-123',
        note: 'Delivery');
    expect(drawer.recordedByUserId, actor.id);
    expect(drawer.reference, 'OR-123');
    expect(drawer.payee, 'Grab');
    expect(drawer.cashSessionId, session.id);
    await expectLater(
        db.customStatement(
            'UPDATE business_cash_movements SET amount_cents = 1 WHERE id = ?',
            [drawer.id]),
        throwsA(isA<Exception>()));
    await expectLater(
        db.customStatement(
            'DELETE FROM business_cash_movements WHERE id = ?', [drawer.id]),
        throwsA(isA<Exception>()));
    expect(await sessions.expected(session.id), 90000);
    expect((await db.select(db.cashMovements).get()).length, 1);
    await expectLater(
        repo.expense(actor,
            amountCents: 100, source: 'petty', categoryId: category.id),
        throwsStateError);
    await repo.addOpeningCash(actor,
        fund: 'company', amountCents: 50000, note: 'Opening count');
    await expectLater(
        repo.addOpeningCash(actor,
            fund: 'company', amountCents: 10000, note: 'Second opening'),
        throwsStateError);
    expect(await repo.balance('company'), 50000);
    await repo.replenish(actor, amountCents: 20000, destination: 'petty');
    expect(await repo.balance('petty'), 20000);
    expect(await repo.balance('company'), 30000);
    final petty = await repo.expense(actor,
        amountCents: 5000, source: 'petty', categoryId: category.id);
    await repo.expense(actor,
        amountCents: 3000, source: 'company', categoryId: category.id);
    await repo.expense(actor,
        amountCents: 850,
        source: 'personal',
        categoryId: category.id,
        personallyPaidBy: 'MJ');
    expect(await repo.balance('petty'), 15000);
    expect(await repo.balance('company'), 27000);
    expect(await repo.reimbursementDue(), 850);
    expect(await sessions.expected(session.id), 90000);
    await repo.reverse(actor, petty.id, 'Wrong amount');
    expect(await repo.balance('petty'), 20000);
    await repo.reverse(actor, drawer.id, 'Wrong amount');
    expect(await sessions.expected(session.id), 100000);
    await expectLater(
        repo.reverse(actor, drawer.id, 'Duplicate'), throwsStateError);
    expect(
        (await repo.history()).firstWhere((m) => m.id == drawer.id).amountCents,
        10000);
    final closed = await sessions.close(actor, 100000);
    expect(closed.expectedCents, 100000);
  });

  test('inactive categories preserve snapshots and reject new expenses',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final actor = auth.current!;
    final repo = CashActivityRepository(db);
    final category = (await repo.categories()).first;
    final expense = await repo.expense(actor,
        amountCents: 100,
        source: 'personal',
        categoryId: category.id,
        personallyPaidBy: 'MJ');
    await repo.saveCategory(actor,
        id: category.id, name: 'Renamed', active: false);
    expect(
        (await repo.history())
            .firstWhere((m) => m.id == expense.id)
            .categoryName,
        category.name);
    await expectLater(
        repo.expense(actor,
            amountCents: 100,
            source: 'personal',
            categoryId: category.id,
            personallyPaidBy: 'MJ'),
        throwsStateError);
    await expectLater(
        repo.expense(actor,
            amountCents: 0,
            source: 'personal',
            categoryId: category.id,
            personallyPaidBy: 'MJ'),
        throwsArgumentError);
  });

  test('backup preserves new movements and categories', () async {
    final dir = await Directory.systemTemp.createTemp('cash-activity-backup-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final id =
          await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
      await auth.login(id, 'ownerPassword123');
      final repo = CashActivityRepository(db);
      final category = (await repo.categories()).first;
      await repo.expense(auth.current!,
          amountCents: 825,
          source: 'personal',
          categoryId: category.id,
          personallyPaidBy: 'MJ');
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect(
            (await restored.select(restored.businessCashMovements).get())
                .single
                .amountCents,
            825);
        expect(
            (await restored.select(restored.cashExpenseCategories).get())
                .isNotEmpty,
            true);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
