import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'role_repository.dart';

class AuthRepository {
  final AppDatabase db;
  AuthRepository(this.db);
  Future<ActiveUser> _active(User user) async {
    final role =
        UserRole.values.where((r) => r.name == user.role).firstOrNull ??
            UserRole.custom;
    if (role != UserRole.custom) {
      return ActiveUser(user.id, user.name, role, user.isActive, user.role);
    }
    final record = await RoleRepository(db).requireRole(user.role);
    return ActiveUser(user.id, user.name, role, user.isActive, record.code,
        record.permissions);
  }

  Future<bool> hasOwner() async => (await (db.select(db.users)
            ..where((u) => u.role.equals('owner') & u.passwordHash.isNotNull()))
          .get())
      .isNotEmpty;
  Future<List<ActiveUser>> loginUsers() async =>
      Future.wait((await (db.select(db.users)
                ..where((u) =>
                    u.isActive.equals(true) &
                    u.id.equals('phase2-local-cashier').not())
                ..orderBy([(u) => OrderingTerm(expression: u.name)]))
              .get())
          .map(_active));
  Future<List<ActiveUser>> allUsers() async =>
      Future.wait((await db.select(db.users).get())
          .where((u) => u.id != 'phase2-local-cashier')
          .map(_active));
  Future<List<User>> managedUsers() async => (await db.select(db.users).get())
      .where((u) => u.id != 'phase2-local-cashier')
      .toList();
  Future<List<AuditLog>> securityActivity({int limit = 50, int offset = 0}) =>
      (db.select(db.auditLogs)
            ..where((a) => a.action.isIn(const [
                  'owner_bootstrap',
                  'user_created',
                  'user_activated',
                  'user_deactivated',
                  'user_renamed',
                  'user_role_changed',
                  'role_created',
                  'role_duplicated',
                  'role_updated',
                  'role_deleted',
                  'credential_reset',
                  'password_recovered',
                  'recovery_failed',
                  'login_failed',
                  'login_success',
                  'logout',
                  'register_locked'
                ]))
            ..orderBy([
              (a) => OrderingTerm.desc(a.createdAt),
              (a) => OrderingTerm.desc(a.id),
            ])
            ..limit(limit, offset: offset))
          .get();
  Future<int> securityActivityCount() async {
    final count = db.auditLogs.id.count();
    final row = await (db.selectOnly(db.auditLogs)
          ..addColumns([count])
          ..where(db.auditLogs.action.isIn(const [
            'owner_bootstrap',
            'user_created',
            'user_activated',
            'user_deactivated',
            'user_renamed',
            'user_role_changed',
            'role_created',
            'role_duplicated',
            'role_updated',
            'role_deleted',
            'credential_reset',
            'password_recovered',
            'recovery_failed',
            'login_failed',
            'login_success',
            'logout',
            'register_locked'
          ])))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<void> editUser(String actorId, String userId,
          {required String name, required String roleCode}) =>
      db.transaction(() async {
        (await requireActive(actorId)).require(PosPermission.manageUsers);
        final target = await user(userId);
        if (target == null) throw StateError('User not found');
        if (target.role != roleCode) {
          final owners = await (db.select(db.users)
                ..where(
                    (u) => u.role.equals('owner') & u.isActive.equals(true)))
              .get();
          if (target.role == 'owner' && target.isActive && owners.length <= 1) {
            throw StateError('The last active Owner cannot change role');
          }
          // A role change changes the sign-in method; require a separate new credential.
          throw StateError('Reset the credential when changing sign-in role');
        }
        if (name.trim() != target.name) {
          await (db.update(db.users)..where((u) => u.id.equals(userId)))
              .write(UsersCompanion(name: Value(name.trim())));
          await audit(actorId, 'user_renamed', userId);
        }
      });
  Future<void> changeRole(
          String actorId, String userId, UserRole role, String hash) =>
      db.transaction(() async {
        (await requireActive(actorId)).require(PosPermission.manageUsers);
        if (actorId == userId) throw StateError('Cannot change your own role');
        final target = await user(userId);
        if (target == null) throw StateError('User not found');
        if (target.role == 'owner' &&
            target.isActive &&
            role != UserRole.owner) {
          final owners = await (db.select(db.users)
                ..where(
                    (u) => u.role.equals('owner') & u.isActive.equals(true)))
              .get();
          if (owners.length <= 1) {
            throw StateError('The last active Owner cannot change role');
          }
        }
        await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
            UsersCompanion(
                role: Value(role.name),
                pinHash: Value(role == UserRole.cashier ? hash : null),
                passwordHash: Value(role == UserRole.cashier ? null : hash),
                failedAttempts: const Value(0),
                lockedUntil: const Value(null)));
        await audit(actorId, 'user_role_changed',
            '$userId:${target.role}->${role.name}');
      });
  Future<User?> user(String id) =>
      (db.select(db.users)..where((u) => u.id.equals(id))).getSingleOrNull();
  Future<ActiveUser> requireActive(String id) async {
    final row = await user(id);
    if (row == null || !row.isActive || row.id == 'phase2-local-cashier') {
      throw StateError('Account is inactive or missing');
    }
    return _active(row);
  }

  Future<String> bootstrap(
          {required String name,
          required String hash,
          required String question,
          required String answerHash}) =>
      db.transaction(() async {
        if (await hasOwner()) throw StateError('Owner already exists');
        final row = await db.into(db.users).insertReturning(
            UsersCompanion.insert(
                name: name,
                role: 'owner',
                passwordHash: Value(hash),
                recoveryQuestion: Value(question),
                recoveryAnswerHash: Value(answerHash)));
        await audit(row.id, 'owner_bootstrap');
        return row.id;
      });
  Future<String> createUser(
          {required String actorId,
          required String name,
          required UserRole role,
          required String hash}) =>
      db.transaction(() async {
        (await requireActive(actorId)).require(PosPermission.manageUsers);
        final row = await db.into(db.users).insertReturning(
            UsersCompanion.insert(
                name: name,
                role: role.name,
                pinHash: Value(role == UserRole.cashier ? hash : null),
                passwordHash: Value(role == UserRole.cashier ? null : hash)));
        await audit(actorId, 'user_created', row.id);
        return row.id;
      });
  Future<String> createUserWithRole(
          {required String actorId,
          required String name,
          required String roleCode,
          required String hash}) =>
      db.transaction(() async {
        (await requireActive(actorId)).require(PosPermission.manageUsers);
        final role = await RoleRepository(db).requireRole(roleCode);
        if (role.isSystem) throw StateError('Use the built-in role flow');
        final row = await db.into(db.users).insertReturning(
            UsersCompanion.insert(
                name: name, role: roleCode, passwordHash: Value(hash)));
        await audit(actorId, 'user_created', row.id);
        return row.id;
      });

  Future<void> changeRoleTo(
          String actorId, String userId, String roleCode, String hash) =>
      db.transaction(() async {
        (await requireActive(actorId)).require(PosPermission.manageUsers);
        if (actorId == userId) throw StateError('Cannot change your own role');
        final target = await user(userId);
        if (target == null) throw StateError('User not found');
        final role = await RoleRepository(db).requireRole(roleCode);
        if (role.isSystem) throw StateError('Use the built-in role flow');
        if (target.role == 'owner' && target.isActive) {
          final owners = await (db.select(db.users)
                ..where(
                    (u) => u.role.equals('owner') & u.isActive.equals(true)))
              .get();
          if (owners.length <= 1) {
            throw StateError('The last active Owner cannot change role');
          }
        }
        await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
            UsersCompanion(
                role: Value(roleCode),
                pinHash: const Value(null),
                passwordHash: Value(hash),
                failedAttempts: const Value(0),
                lockedUntil: const Value(null)));
        await audit(
            actorId, 'user_role_changed', '$userId:${target.role}->$roleCode');
      });
  Future<void> setActive(String actorId, String userId, bool active) =>
      db.transaction(() async {
        (await requireActive(actorId)).require(PosPermission.manageUsers);
        if (actorId == userId && !active) {
          throw StateError('Cannot deactivate your own account');
        }
        final target = await user(userId);
        if (target == null) throw StateError('User not found');
        if (!active && target.role == 'owner' && target.isActive) {
          final owners = await (db.select(db.users)
                ..where(
                    (u) => u.role.equals('owner') & u.isActive.equals(true)))
              .get();
          if (owners.length <= 1) {
            throw StateError('The last active Owner cannot be disabled');
          }
        }
        final count = await (db.update(db.users)
              ..where((u) => u.id.equals(userId)))
            .write(UsersCompanion(isActive: Value(active)));
        if (count != 1) throw StateError('User not found');
        await audit(
            actorId, active ? 'user_activated' : 'user_deactivated', userId);
      });
  Future<void> setCredential(
          String actorId, String userId, UserRole role, String hash) =>
      db.transaction(() async {
        (await requireActive(actorId)).require(PosPermission.manageUsers);
        final count = await (db.update(db.users)
              ..where((u) => u.id.equals(userId)))
            .write(UsersCompanion(
                pinHash: Value(role == UserRole.cashier ? hash : null),
                passwordHash: Value(role == UserRole.cashier ? null : hash),
                failedAttempts: const Value(0),
                lockedUntil: const Value(null)));
        if (count != 1) throw StateError('User not found');
        await audit(actorId, 'credential_reset', userId);
      });
  Future<void> setRecoveryPassword(String userId, String hash) =>
      db.transaction(() async {
        await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
            UsersCompanion(
                passwordHash: Value(hash),
                failedAttempts: const Value(0),
                lockedUntil: const Value(null)));
        await audit(userId, 'password_recovered');
      });
  Future<void> failed(String? userId, int attempts, DateTime? lockedUntil) =>
      db.transaction(() async {
        if (userId != null) {
          await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
              UsersCompanion(
                  failedAttempts: Value(attempts),
                  lockedUntil: Value(lockedUntil)));
        }
        await audit(userId, 'login_failed');
      });
  Future<void> recoveryFailed(
          String userId, int attempts, DateTime? lockedUntil) =>
      db.transaction(() async {
        await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
            UsersCompanion(
                failedAttempts: Value(attempts),
                lockedUntil: Value(lockedUntil)));
        await audit(userId, 'recovery_failed');
      });
  Future<void> succeeded(String userId) => db.transaction(() async {
        await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
            const UsersCompanion(
                failedAttempts: Value(0), lockedUntil: Value(null)));
        await audit(userId, 'login_success');
      });
  Future<void> discountCredentialSucceeded(String userId) =>
      db.transaction(() async {
        await (db.update(db.users)..where((u) => u.id.equals(userId))).write(
            const UsersCompanion(
                failedAttempts: Value(0), lockedUntil: Value(null)));
        await audit(userId, 'manual_discount.credential_verified');
      });
  Future<void> audit(String? userId, String action, [String? details]) async {
    await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
        userId: Value(userId), action: action, details: Value(details)));
  }
}
