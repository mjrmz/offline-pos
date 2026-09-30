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

void main() {
  test(
      'in-place cutover and old-backup reconciliation preserve issued counters and Z history',
      () async {
    final dir = await Directory.systemTemp.createTemp('pos-phase7-');
    final live = File('${dir.path}/live.sqlite');
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    AppDatabase db = AppDatabase.forTesting(NativeDatabase(live));
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
      await auth.login(ownerId, 'password123');
      final user = auth.current!;
      final product = await PosRepository(db).saveProduct(
          name: 'Item', priceCents: 125, costCents: 0, startingStock: 20);
      Future<int?> sell(bool bir) async =>
          (await PosRepository(db, birReady: bir, protection: protection)
                  .completeCashSale(
                      [SaleLineRequest(product, 1)], 125, ownerId))
              .birInvoiceNumber;
      expect(await sell(false), isNull);
      expect(await sell(false), isNull);
      expect(await db.select(db.birComplianceState).get(), isEmpty);
      await CashSessionRepository(db, birReady: true, protection: protection)
          .open(user, 0);
      expect(await sell(true), 1);
      expect(await sell(true), 2);
      final backup = await BackupService(db, Directory('${dir.path}/backups'))
          .create(BackupKind.manual);
      expect(await sell(true), 3);
      expect(await sell(true), 4);
      await CashSessionRepository(db, birReady: true, protection: protection)
          .close(user, 500);
      expect((await db.select(db.zReadings).get()).single.grandTotalCents, 500);
      await db.close();
      await backup.file.copy(live.path);
      db = AppDatabase.forTesting(NativeDatabase(live));
      await protection.reconcile(db, actorId: ownerId);
      final state = (await db.select(db.birComplianceState).get()).single;
      expect(state.highestInvoiceNumber, 4);
      expect(state.grandTotalCents, 500);
      expect(
          (await db.select(db.zReadings).get()).single.endingInvoiceNumber, 4);
      expect(
          (await db.select(db.cashSessions).get()).single.closedAt, isNotNull);
      await CashSessionRepository(db, birReady: true, protection: protection)
          .open(user, 0);
      expect(await sell(true), 5);
      expect((await db.select(db.zReadings).get()).single.grandTotalCents, 500);
      await expectLater(
          db.customStatement('DELETE FROM z_readings'), throwsA(anything));
      expect(
          (await db.select(db.birComplianceState).get()).single.grandTotalCents,
          625);
      expect(
          (await db.select(db.sales).get())
              .where((s) => s.birInvoiceNumber == null)
              .length,
          2);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('BIR payment failure leaves invoice and total unchanged', () async {
    final dir = await Directory.systemTemp.createTemp('pos-phase7-failure-');
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
      final product = await PosRepository(db).saveProduct(
          name: 'Item', priceCents: 125, costCents: 0, startingStock: 2);
      await auth.login(ownerId, 'password123');
      await CashSessionRepository(db, birReady: true).open(auth.current!, 0);
      await db.customStatement(
          'CREATE TRIGGER fail_payment BEFORE INSERT ON payments BEGIN SELECT RAISE(FAIL, \'failed\'); END');
      await expectLater(
          PosRepository(db, birReady: true, protection: protection)
              .completeCashSale([SaleLineRequest(product, 1)], 125, ownerId),
          throwsA(anything));
      expect(await db.select(db.sales).get(), isEmpty);
      expect(await db.select(db.birComplianceState).get(), isEmpty);
      expect(await PosRepository(db).stock(product), 2);
      await db.customStatement('DROP TRIGGER fail_payment');
      final resumed =
          await PosRepository(db, birReady: true, protection: protection)
              .completeCashSale([SaleLineRequest(product, 1)], 125, ownerId);
      expect(resumed.birInvoiceNumber, 1);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('concurrent BIR checkouts receive distinct sequential invoices',
      () async {
    final dir = await Directory.systemTemp.createTemp('pos-phase7-concurrent-');
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
      await auth.login(ownerId, 'password123');
      await CashSessionRepository(db, birReady: true).open(auth.current!, 0);
      final product = await PosRepository(db).saveProduct(
          name: 'Item', priceCents: 125, costCents: 0, startingStock: 2);
      final repository =
          PosRepository(db, birReady: true, protection: protection);
      final results = await Future.wait([
        repository
            .completeCashSale([SaleLineRequest(product, 1)], 125, ownerId),
        repository
            .completeCashSale([SaleLineRequest(product, 1)], 125, ownerId),
      ]);
      expect(results.map((r) => r.birInvoiceNumber).toSet(), {1, 2});
      expect(
          (await db.select(db.birComplianceState).get()).single.grandTotalCents,
          250);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
