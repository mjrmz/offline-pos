import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

class _Fixture {
  final Directory dir;
  final File live;
  final File journal;
  AppDatabase db;
  final String owner;
  final String product;
  _Fixture(
      this.dir, this.live, this.journal, this.db, this.owner, this.product);
  ComplianceProtection protection(
          {Future<void> Function(ComplianceStep)? hook}) =>
      ComplianceProtection(journal, failureHook: hook);
  Future<CommittedSale> sell(ComplianceProtection guard) =>
      PosRepository(db, birReady: true, protection: guard)
          .completeCashSale([SaleLineRequest(product, 1)], 125, owner);
  Future<void> dispose() async {
    await db.close();
    await dir.delete(recursive: true);
  }
}

Future<_Fixture> _fixture() async {
  final dir = await Directory.systemTemp.createTemp('pos-phase7-durable-');
  final live = File('${dir.path}/live.sqlite');
  final db = AppDatabase.forTesting(NativeDatabase(live));
  final owner = await AuthService(AuthRepository(db))
      .bootstrap('Owner', 'password123', 'Question?', 'answer');
  final product = await PosRepository(db).saveProduct(
      name: 'Item', priceCents: 125, costCents: 0, startingStock: 20);
  final actor = await AuthRepository(db).requireActive(owner);
  await CashSessionRepository(db).open(actor, 0);
  return _Fixture(
      dir, live, File('${dir.path}/compliance.json'), db, owner, product);
}

void main() {
  test('failure before reservation leaves no issued invoice', () async {
    final f = await _fixture();
    try {
      final guard = f.protection(hook: (step) async {
        if (step == ComplianceStep.beforeReservation) throw StateError('stop');
      });
      await expectLater(f.sell(guard), throwsStateError);
      expect(await f.db.select(f.db.sales).get(), isEmpty);
      expect(await f.db.select(f.db.birComplianceState).get(), isEmpty);
      await f.protection().reconcile(f.db);
      expect((await f.sell(f.protection())).birInvoiceNumber, 1);
    } finally {
      await f.dispose();
    }
  });

  test(
      'power loss after reservation before SQLite commit leaves an auditable unresolved intent',
      () async {
    final f = await _fixture();
    try {
      final guard = f.protection(hook: (step) async {
        if (step == ComplianceStep.afterReservation) {
          throw SimulatedComplianceCrash();
        }
      });
      await expectLater(
          f.sell(guard), throwsA(isA<SimulatedComplianceCrash>()));
      expect(await f.db.select(f.db.sales).get(), isEmpty);
      expect(await f.db.select(f.db.birComplianceState).get(), isEmpty);
      await expectLater(f.protection().reconcile(f.db), throwsStateError);
      await expectLater(f.sell(f.protection()), throwsStateError);
      final text = await File('${f.journal.path}.journal-a').readAsString();
      expect(text, contains('reserve_sale'));
    } finally {
      await f.dispose();
    }
  });

  test('SQLite commit before finalize recovers invoice and total after restart',
      () async {
    final f = await _fixture();
    try {
      final guard = f.protection(hook: (step) async {
        if (step == ComplianceStep.beforeFinalize) throw StateError('stop');
      });
      final first = await f.sell(guard);
      expect(first.protectionWarning, true);
      expect(first.birInvoiceNumber, 1);
      await f.db.close();
      f.db = AppDatabase.forTesting(NativeDatabase(f.live));
      final restarted = f.protection();
      await restarted.reconcile(f.db);
      expect(
          (await f.db.select(f.db.birComplianceState).get())
              .single
              .grandTotalCents,
          125);
      expect((await f.sell(restarted)).birInvoiceNumber, 2);
    } finally {
      await f.dispose();
    }
  });

  test('partial finalize repairs the shorter journal copy', () async {
    final f = await _fixture();
    try {
      final guard = f.protection(hook: (step) async {
        if (step == ComplianceStep.duringFinalize) throw StateError('stop');
      });
      expect((await f.sell(guard)).protectionWarning, true);
      final restarted = f.protection();
      await restarted.reconcile(f.db);
      expect(await File('${f.journal.path}.journal-a').readAsString(),
          await File('${f.journal.path}.journal-b').readAsString());
      expect((await f.sell(restarted)).birInvoiceNumber, 2);
    } finally {
      await f.dispose();
    }
  });

  test('old backup after uncertain committed sale cannot reissue its number',
      () async {
    final f = await _fixture();
    try {
      final backup =
          await BackupService(f.db, Directory('${f.dir.path}/backups'))
              .create(BackupKind.manual);
      final guard = f.protection(hook: (step) async {
        if (step == ComplianceStep.beforeFinalize) throw StateError('stop');
      });
      expect((await f.sell(guard)).birInvoiceNumber, 1);
      await f.db.close();
      await backup.file.copy(f.live.path);
      f.db = AppDatabase.forTesting(NativeDatabase(f.live));
      await expectLater(f.protection().reconcile(f.db), throwsStateError);
      await expectLater(f.sell(f.protection()), throwsStateError);
      expect(await f.db.select(f.db.sales).get(), isEmpty);
    } finally {
      await f.dispose();
    }
  });

  test('missing or corrupt journal copies do not silently reset counters',
      () async {
    final f = await _fixture();
    try {
      expect((await f.sell(f.protection())).birInvoiceNumber, 1);
      final a = File('${f.journal.path}.journal-a');
      final b = File('${f.journal.path}.journal-b');
      await a.writeAsString('broken', flush: true);
      await f.protection().reconcile(f.db); // Valid second copy repairs first.
      expect(await a.readAsString(), await b.readAsString());
      await b.delete();
      await f.protection().reconcile(f.db); // Valid first copy repairs second.
      await a.writeAsString('broken', flush: true);
      await b.writeAsString('broken', flush: true);
      await expectLater(f.protection().reconcile(f.db), throwsStateError);
      await a.delete();
      await b.delete();
      await expectLater(f.protection().reconcile(f.db), throwsStateError);
    } finally {
      await f.dispose();
    }
  });

  test(
      'two journals truncated to a valid old prefix are rejected by the durable head',
      () async {
    final f = await _fixture();
    try {
      await f.sell(f.protection());
      final a = File('${f.journal.path}.journal-a');
      final b = File('${f.journal.path}.journal-b');
      final original = await a.readAsString();
      final genesis = '${original.split('\n').first}\n';
      await a.writeAsString(genesis, flush: true);
      await b.writeAsString(genesis, flush: true);
      await expectLater(f.protection().reconcile(f.db), throwsStateError);
      await a.writeAsString(original, flush: true);
      await b.writeAsString(original, flush: true);
      await f.protection().reconcile(f.db);
      await File('${f.journal.path}.journal-head').delete();
      await File('${f.journal.path}.journal-head.previous').delete();
      await expectLater(f.protection().reconcile(f.db), throwsStateError);
    } finally {
      await f.dispose();
    }
  });

  test(
      'Z-reading commit before finalize is recovered without changing its snapshot',
      () async {
    final f = await _fixture();
    try {
      final good = f.protection();
      await f.sell(good);
      final actor = await AuthRepository(f.db).requireActive(f.owner);
      final interrupted = f.protection(hook: (step) async {
        if (step == ComplianceStep.beforeFinalize) throw StateError('stop');
      });
      final closed = await CashSessionRepository(f.db,
              birReady: true, protection: interrupted)
          .close(actor, 125);
      expect(closed.protectionWarning, true);
      final restarted = f.protection();
      await restarted.reconcile(f.db);
      final snapshot = (await f.db.select(f.db.zReadings).get()).single;
      expect(snapshot.number, 1);
      expect(snapshot.grandTotalCents, 125);
      await expectLater(
          f.db.customStatement('DELETE FROM z_readings'), throwsA(anything));
    } finally {
      await f.dispose();
    }
  });

  test('old backup with an unresolved committed Z-reading cannot discard it',
      () async {
    final f = await _fixture();
    try {
      final good = f.protection();
      await f.sell(good);
      final backup =
          await BackupService(f.db, Directory('${f.dir.path}/backups'))
              .create(BackupKind.manual);
      final actor = await AuthRepository(f.db).requireActive(f.owner);
      final interrupted = f.protection(hook: (step) async {
        if (step == ComplianceStep.beforeFinalize) throw StateError('stop');
      });
      final result = await CashSessionRepository(f.db,
              birReady: true, protection: interrupted)
          .close(actor, 125);
      expect(result.protectionWarning, true);
      await f.db.close();
      await backup.file.copy(f.live.path);
      f.db = AppDatabase.forTesting(NativeDatabase(f.live));
      await expectLater(f.protection().reconcile(f.db), throwsStateError);
      expect(await f.db.select(f.db.zReadings).get(), isEmpty);
    } finally {
      await f.dispose();
    }
  });

  test(
      'failed Z insert rolls back and the next close reuses its unissued number',
      () async {
    final f = await _fixture();
    try {
      final guard = f.protection();
      await f.sell(guard);
      final actor = await AuthRepository(f.db).requireActive(f.owner);
      await f.db.customStatement(
          "CREATE TRIGGER fail_z BEFORE INSERT ON z_readings BEGIN SELECT RAISE(FAIL, 'failed'); END");
      await expectLater(
          CashSessionRepository(f.db, birReady: true, protection: guard)
              .close(actor, 125),
          throwsA(anything));
      expect(await f.db.select(f.db.zReadings).get(), isEmpty);
      expect(
          (await f.db.select(f.db.cashSessions).get()).single.closedAt, isNull);
      await f.db.customStatement('DROP TRIGGER fail_z');
      await CashSessionRepository(f.db, birReady: true, protection: guard)
          .close(actor, 125);
      expect((await f.db.select(f.db.zReadings).get()).single.number, 1);
    } finally {
      await f.dispose();
    }
  });

  test('recovery failure injection leaves SQLite state unchanged', () async {
    final f = await _fixture();
    try {
      await f.sell(f.protection());
      final guard = f.protection(hook: (step) async {
        if (step == ComplianceStep.duringReconcile) throw StateError('stop');
      });
      await expectLater(guard.reconcile(f.db), throwsStateError);
      expect(
          (await f.db.select(f.db.birComplianceState).get())
              .single
              .highestInvoiceNumber,
          1);
    } finally {
      await f.dispose();
    }
  });
}
