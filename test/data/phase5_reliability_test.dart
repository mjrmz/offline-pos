import 'dart:io';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/backup/restore_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;
  late Directory directory;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(AuthRepository(db));
    directory = await Directory.systemTemp.createTemp('pos-phase5-');
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(id, 'password123');
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
      'cash session derives expected from committed cash movements and keeps history',
      () async {
    final sessions = CashSessionRepository(db);
    final user = auth.current!;
    await expectLater(sessions.open(user, -1), throwsArgumentError);
    await sessions.open(user, 1000);
    await expectLater(sessions.open(user, 1000), throwsStateError);
    final product = await PosRepository(db).saveProduct(
        name: 'Item', priceCents: 350, costCents: 0, startingStock: 2);
    await PosRepository(db)
        .completeCashSale([SaleLineRequest(product, 1)], 500, user.id);
    expect(await sessions.expected((await sessions.active())!.id), 1350);
    await expectLater(sessions.close(user, -1), throwsArgumentError);
    final closed = await sessions.close(user, 1300);
    expect(closed.varianceCents, -50);
    expect(closed.session.expectedCashCents, 1350);
    expect(await sessions.active(), isNull);
    await expectLater(sessions.close(user, 1000), throwsStateError);
    expect((await sessions.history()).length, 1);
    expect((await db.select(db.auditLogs).get()).map((e) => e.action),
        containsAll(['cash_session.open', 'cash_session.close']));
  });

  test('cash close rolls back when audit insert fails', () async {
    final sessions = CashSessionRepository(db);
    await sessions.open(auth.current!, 500);
    await db.customStatement(
        "CREATE TRIGGER block_close BEFORE INSERT ON audit_logs "
        "WHEN NEW.action = 'cash_session.close' BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    await expectLater(sessions.close(auth.current!, 500), throwsA(anything));
    expect((await sessions.active())?.actualCashCents, isNull);
    expect((await sessions.active())?.closedAt, isNull);
  });

  test('sale rolls back when payment write fails', () async {
    final product = await PosRepository(db).saveProduct(
        name: 'Item', priceCents: 300, costCents: 0, startingStock: 2);
    await db.customStatement(
        "CREATE TRIGGER block_payment BEFORE INSERT ON payments "
        "BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    await expectLater(
        PosRepository(db).completeCashSale(
            [SaleLineRequest(product, 1)], 300, auth.current!.id),
        throwsA(anything));
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.saleItems).get(), isEmpty);
    expect(await db.select(db.payments).get(), isEmpty);
    expect(await PosRepository(db).stock(product), 2);
  });

  test('sale rolls back when cash movement write fails', () async {
    await CashSessionRepository(db).open(auth.current!, 100);
    final product = await PosRepository(db).saveProduct(
        name: 'Item', priceCents: 300, costCents: 0, startingStock: 2);
    await db.customStatement(
        "CREATE TRIGGER block_movement BEFORE INSERT ON cash_movements "
        "BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    await expectLater(
        PosRepository(db).completeCashSale(
            [SaleLineRequest(product, 1)], 300, auth.current!.id),
        throwsA(anything));
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.payments).get(), isEmpty);
    expect(await db.select(db.cashMovements).get(), isEmpty);
    expect(await PosRepository(db).stock(product), 2);
  });

  test('SQLite snapshot verifies, has metadata, and source sale remains',
      () async {
    final user = auth.current!;
    final product = await PosRepository(db).saveProduct(
        name: 'Item', priceCents: 200, costCents: 0, startingStock: 2);
    await PosRepository(db)
        .completeCashSale([SaleLineRequest(product, 1)], 200, user.id);
    final before = await db.select(db.sales).get();
    final service = BackupService(db, directory);
    final record = await service.create(BackupKind.manual);
    expect(record.schemaVersion, 7);
    expect(record.integrity, 'ok');
    expect(record.bytes, greaterThan(0));
    expect(record.appVersion, '0.1.0');
    expect(BackupService.inspect(record.file).bytes, record.bytes);
    expect((await db.select(db.sales).get()).length, before.length);
    expect((await service.listValid()).length, 1);
    await record.file.writeAsBytes([1, 2, 3]);
    expect(() => BackupService.inspect(record.file), throwsStateError);
    expect(await service.listValid(), isEmpty);
  });

  test('backup write failure leaves source usable', () async {
    final occupied = File('${directory.path}/occupied');
    await occupied.writeAsString('x');
    final service = BackupService(db, Directory(occupied.path));
    await expectLater(service.create(BackupKind.manual), throwsStateError);
    expect((await db.select(db.users).get()).length, 1);
  });

  test('backup retention keeps five manual generations', () async {
    var instant = DateTime.utc(2026, 1, 1);
    final service = BackupService(db, directory, clock: () => instant);
    for (var i = 0; i < 7; i++) {
      instant = instant.add(const Duration(seconds: 1));
      await service.create(BackupKind.manual);
    }
    final list = await service.listValid();
    expect(list.length, BackupService.manualRetention);
    expect(list.every((e) => e.integrity == 'ok'), isTrue);
  });

  test('automatic backups create daily and weekly generations only when due',
      () async {
    var instant = DateTime.utc(2026, 1, 1);
    final service = BackupService(db, directory, clock: () => instant);
    await service.createDue();
    expect((await service.listValid()).map((e) => e.kind),
        containsAll([BackupKind.daily, BackupKind.weekly]));
    await service.createDue();
    expect((await service.listValid()).length, 2);
    instant = instant.add(const Duration(days: 1, seconds: 1));
    await service.createDue();
    expect((await service.listValid()).length, 3);
  });

  test('corrupt backup fails SQLite integrity verification', () async {
    final record = await BackupService(db, directory).create(BackupKind.manual);
    final bytes = await record.file.readAsBytes();
    await record.file.writeAsBytes(bytes.sublist(0, 100));
    expect(() => BackupService.verify(record.file), throwsA(anything));
    expect(await BackupService(db, directory).listValid(), isEmpty);
  });

  test(
      'verified restore reopens prior state and failed validation preserves live data',
      () async {
    await db.close();
    final liveFile = File('${directory.path}/live.sqlite');
    var live = AppDatabase.forTesting(NativeDatabase(liveFile));
    final liveAuth = AuthService(AuthRepository(live));
    await liveAuth.bootstrap(
        'Restore owner', 'password123', 'Question?', 'answer');
    await PosRepository(live).addCategory('Before');
    final backup =
        await BackupService(live, Directory('${directory.path}/backups'))
            .create(BackupKind.manual);
    await PosRepository(live).addCategory('After');
    final restorer =
        RestoreService(liveFile, Directory('${directory.path}/backups'),
            closeDatabase: () async => live.close(),
            openDatabase: () async {
              live = AppDatabase.forTesting(NativeDatabase(liveFile));
              await live.select(live.categories).get();
              return live;
            });
    final invalid = File('${directory.path}/invalid.sqlite');
    await invalid.writeAsBytes([1, 2, 3]);
    await expectLater(
        restorer.restore(BackupRecord(
            invalid, BackupKind.manual, DateTime.now(), 7, '0.1.0', 3, 'ok')),
        throwsStateError);
    final corrupt = File('${backup.file.parent.path}/corrupt.sqlite');
    await backup.file.copy(corrupt.path);
    final damaged = await corrupt.readAsBytes();
    damaged[0] = 0;
    await corrupt.writeAsBytes(damaged);
    final corruptRecord = BackupRecord(corrupt, BackupKind.manual,
        DateTime.now(), 7, '0.1.0', damaged.length, 'ok');
    await File('${corrupt.path}.json')
        .writeAsString(jsonEncode(corruptRecord.toJson()));
    await expectLater(restorer.restore(corruptRecord), throwsStateError);
    expect((await live.select(live.categories).get()).length, 2);
    live = await restorer.restore(backup);
    expect((await live.select(live.categories).get()).map((e) => e.name),
        ['Before']);
    expect(
        (await live.customSelect('PRAGMA integrity_check').get())
            .single
            .read<String>('integrity_check'),
        'ok');
    await PosRepository(live).addCategory('Later');
    final failing = RestoreService(
        liveFile, Directory('${directory.path}/backups'),
        closeDatabase: () async => live.close(),
        openDatabase: () async {
          live = AppDatabase.forTesting(NativeDatabase(liveFile));
          return live;
        },
        afterVerify: (_) async =>
            throw StateError('Injected post-open failure'));
    await expectLater(failing.restore(backup), throwsStateError);
    live = AppDatabase.forTesting(NativeDatabase(liveFile));
    expect((await live.select(live.categories).get()).map((e) => e.name),
        containsAll(['Before', 'Later']));
    await live.close();
  });
}
