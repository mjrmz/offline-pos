import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/role_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';
import 'package:modern_offline_pos/data/daos/held_sale_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;
  late String ownerId;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(AuthRepository(db));
    ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Recovery place?', 'Baguio');
    await auth.login(ownerId, 'ownerPassword123');
  });
  tearDown(() => db.close());

  test('built-in roles retain fixed baseline and are protected', () async {
    final roles = await auth.roles.all();
    expect(roles.where((r) => r.isSystem).map((r) => r.code).toSet(),
        {'owner', 'manager', 'cashier'});
    expect(roles.firstWhere((r) => r.code == 'owner').permissions,
        containsAll(PosPermission.values));
    await expectLater(auth.deleteRole('owner'), throwsStateError);
    final managerId = await auth.createUser(
        'Manager', UserRole.manager, 'managerPassword123');
    final cashierId =
        await auth.createUser('Cashier', UserRole.cashier, '1234');
    expect(
        (await auth.repository.requireActive(managerId))
            .can(PosPermission.reverseSale),
        isTrue);
    expect(
        (await auth.repository.requireActive(cashierId))
            .can(PosPermission.reverseSale),
        isFalse);
    expect(
        (await auth.repository.requireActive(cashierId))
            .can(PosPermission.sell),
        isTrue);
  });

  test('custom role permissions persist and enforce after assignment',
      () async {
    final code = await auth.createRole('Inventory Staff', 'Receives stock',
        {PosPermission.stockReceiving, PosPermission.stockCount});
    final userId =
        await auth.createUserWithRole('Staff', code, 'staffPassword123');
    final active = await auth.repository.requireActive(userId);
    expect(active.role, UserRole.custom);
    expect(active.can(PosPermission.stockReceiving), isTrue);
    expect(active.can(PosPermission.sell), isFalse);
    expect(() => active.require(PosPermission.reverseSale), throwsStateError);
    await expectLater(SalesRepository(db).history(active), throwsStateError);
    await expectLater(
        StockCountRepository(db).finalize(active, 'missing'), throwsStateError);
    await auth.updateRole(
        code, 'Inventory Staff', 'Counts stock', {PosPermission.stockCount});
    final updated = await auth.repository.requireActive(userId);
    expect(updated.can(PosPermission.stockReceiving), isFalse);
    expect(updated.can(PosPermission.stockCount), isTrue);
    await expectLater(auth.deleteRole(code), throwsStateError);
    final logs = await auth.repository.securityActivity();
    expect(logs.any((e) => e.action == 'role_created'), isTrue);
    expect(
        logs.any((e) =>
            e.action == 'role_updated' &&
            e.details!.contains('removed=stockReceiving')),
        isTrue);
  });

  test('names, dependencies, duplication, and deletion are guarded', () async {
    final code = await auth
        .createRole('Senior Cashier', '', {PosPermission.reverseSale});
    final role = await auth.roles.requireRole(code);
    expect(
        role.permissions,
        containsAll({
          PosPermission.reverseSale,
          PosPermission.viewAllSales,
          PosPermission.viewOwnSales
        }));
    await expectLater(auth.createRole(' manager ', '', {}), throwsStateError);
    await expectLater(
        auth.createRole(' SENIOR CASHIER ', '', {}), throwsStateError);
    await expectLater(
        auth.createRole('Unsafe', '', {PosPermission.manageRecovery}),
        throwsStateError);
    final duplicate = await auth.createRole(
        'Senior Cashier copy', '', role.permissions,
        duplicatedFrom: code);
    expect((await auth.roles.requireRole(duplicate)).assignedUsers, 0);
    await auth.deleteRole(duplicate);
    await auth.deleteRole(code);
    expect(
        (await auth.repository.securityActivity())
            .any((e) => e.action == 'role_deleted'),
        isTrue);
  });

  test('POS sale grant alone does not allow held sale operations', () async {
    final code = await auth.createRole('POS Only', '', {PosPermission.sell});
    final id =
        await auth.createUserWithRole('POS Staff', code, 'staffPassword123');
    final actor = await auth.repository.requireActive(id);
    expect(actor.can(PosPermission.sell), isTrue);
    expect(actor.can(PosPermission.holdSale), isFalse);
    expect(actor.can(PosPermission.resumeSale), isFalse);
    await expectLater(
        HeldSaleRepository(db).hold(actor, Cart()), throwsStateError);
    await expectLater(HeldSaleRepository(db).all(actor), throwsStateError);
  });

  test('role change updates future login and keeps last Owner', () async {
    final code =
        await auth.createRole('Reports Staff', '', {PosPermission.reports});
    final cashier = await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.changeRoleTo(cashier, code, 'staffPassword123');
    expect(
        (await auth.repository.requireActive(cashier))
            .can(PosPermission.reports),
        isTrue);
    expect((await auth.repository.user(cashier))!.pinHash, isNull);
    await expectLater(
        auth.repository.changeRoleTo(ownerId, ownerId, code, 'unusedHash'),
        throwsStateError);
  });

  test('v39 upgrade preserves users and credentials while seeding roles',
      () async {
    final dir = await Directory.systemTemp.createTemp('rbac-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    final priorAuth = AuthService(AuthRepository(old));
    final priorOwner = await priorAuth.bootstrap(
        'Prior Owner', 'ownerPassword123', 'Place?', 'Baguio');
    await priorAuth.login(priorOwner, 'ownerPassword123');
    final manager = await priorAuth.createUser(
        'Manager', UserRole.manager, 'managerPassword123');
    final cashier =
        await priorAuth.createUser('Cashier', UserRole.cashier, '1234');
    final hashes = <String, String?>{
      for (final id in [priorOwner, manager, cashier])
        id: (await priorAuth.repository.user(id))!.passwordHash ??
            (await priorAuth.repository.user(id))!.pinHash,
    };
    await old.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TRIGGER users_valid_role_insert');
    raw.execute('DROP TRIGGER users_valid_role_update');
    raw.execute('DROP TABLE role_permissions');
    raw.execute('DROP TABLE roles');
    raw.execute('PRAGMA user_version = 39');
    raw.dispose();
    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(upgraded.close);
    final rows = await AuthRepository(upgraded).managedUsers();
    expect(rows.length, 3);
    expect(rows.map((u) => u.role).toSet(), {'owner', 'manager', 'cashier'});
    for (final row in rows) {
      expect(row.passwordHash ?? row.pinHash, hashes[row.id]);
    }
    expect((await RoleRepository(upgraded).all()).length, 3);
  });

  test(
      'backup preserves custom roles and rejects missing Owner or unknown keys',
      () async {
    final dir = await Directory.systemTemp.createTemp('rbac-backup-');
    addTearDown(() => dir.delete(recursive: true));
    final code = await auth
        .createRole('Stock Staff', '', {PosPermission.stockReceiving});
    await auth.createUserWithRole('Staff', code, 'staffPassword123');
    final backup = await BackupService(db, dir).create(BackupKind.manual);
    expect(BackupService.verify(backup.file), 46);
    final raw = sqlite.sqlite3.open(backup.file.path);
    expect(
        raw.select(
            'SELECT role FROM users WHERE name = ?', ['Staff']).single['role'],
        code);
    expect(
        raw.select(
            'SELECT permission_key FROM role_permissions '
            'WHERE role_code = ?',
            [code]).single['permission_key'],
        PosPermission.stockReceiving.name);
    raw.execute('UPDATE users SET is_active = 0 WHERE role = ?', ['owner']);
    raw.dispose();
    expect(() => BackupService.verify(backup.file), throwsStateError);
    final unknown = sqlite.sqlite3.open(backup.file.path);
    unknown.execute('UPDATE users SET is_active = 1 WHERE role = ?', ['owner']);
    unknown.execute(
        'INSERT INTO role_permissions (role_code, permission_key) '
        'VALUES (?, ?)',
        [code, 'futureCapability']);
    unknown.dispose();
    expect(() => BackupService.verify(backup.file), throwsStateError);
  });
}
