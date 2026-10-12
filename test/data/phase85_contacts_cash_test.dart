import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/petty_cash_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';

void main() {
  test('customers and suppliers edit and deactivate without losing records',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final actor = auth.current!;
    final repo = DirectoryRepository(db);
    final customer =
        await repo.saveCustomer(actor, name: 'Juan', phone: '0917');
    await repo.saveCustomer(actor,
        id: customer.id, name: 'Juan Dela Cruz', active: false);
    final supplier = await repo.saveSupplier(actor, name: 'Supplier A');
    await repo.saveSupplier(actor,
        id: supplier.id, name: 'Supplier A', active: false);
    expect((await repo.customers()).single.name, 'Juan Dela Cruz');
    expect((await repo.customers()).single.isActive, false);
    expect((await repo.suppliers()).single.isActive, false);
  });

  test('petty cash reduces expected drawer and remains auditable', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final actor = auth.current!;
    final cash = CashSessionRepository(db);
    final session = await cash.open(actor, 100000);
    final entry = await PettyCashRepository(db)
        .record(actor, amountCents: 10000, category: 'Transport');
    expect(entry.amountCents, 10000);
    expect(await cash.expected(session.id), 90000);
    expect((await PettyCashRepository(db).history()).single.id, entry.id);
    expect(
        (await db.select(db.auditLogs).get())
            .any((a) => a.action == 'petty_cash.record'),
        true);
  });

  test('petty cash audit failure rolls back expense and drawer movement',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final actor = auth.current!;
    final cash = CashSessionRepository(db);
    final session = await cash.open(actor, 100000);
    await db.customStatement(
        "CREATE TRIGGER reject_petty_audit BEFORE INSERT ON audit_logs "
        "WHEN NEW.action = 'petty_cash.record' BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END");
    await expectLater(
        PettyCashRepository(db)
            .record(actor, amountCents: 10000, category: 'Transport'),
        throwsA(isA<Exception>()));
    expect(await db.select(db.pettyCashEntries).get(), isEmpty);
    expect(await cash.expected(session.id), 100000);
  });

  test('price and cost changes append history with actor', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Rice', priceCents: 5500, costCents: 4000, actorId: ownerId);
    await pos.saveProduct(
        id: id,
        name: 'Rice',
        priceCents: 6000,
        costCents: 4200,
        actorId: ownerId);
    final record = (await db.select(db.priceHistory).get()).single;
    expect(record.oldPriceCents, 5500);
    expect(record.newPriceCents, 6000);
    expect(record.userId, ownerId);
  });

  test('schema 11 contacts and petty cash survive SQLite backup', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-backup-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
      await auth.login(ownerId, 'ownerPassword123');
      final actor = auth.current!;
      await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
      await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier A');
      await CashSessionRepository(db).open(actor, 100000);
      await PettyCashRepository(db)
          .record(actor, amountCents: 10000, category: 'Transport');
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect((await restored.select(restored.customers).get()).single.name,
            'Juan');
        expect((await restored.select(restored.suppliers).get()).single.name,
            'Supplier A');
        expect(
            (await restored.select(restored.pettyCashEntries).get())
                .single
                .amountCents,
            10000);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
