import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';

class AuthRepository {
  final AppDatabase db;
  AuthRepository(this.db);
  ActiveUser _active(User user) => ActiveUser(
      user.id, user.name, UserRole.values.byName(user.role), user.isActive);

  Future<bool> hasOwner() async => (await (db.select(db.users)
            ..where((u) => u.role.equals('owner') & u.passwordHash.isNotNull()))
          .get())
      .isNotEmpty;
  Future<List<ActiveUser>> loginUsers() async => (await (db.select(db.users)
            ..where((u) =>
                u.isActive.equals(true) &
                u.id.equals('phase2-local-cashier').not())
            ..orderBy([(u) => OrderingTerm(expression: u.name)]))
          .get())
      .map(_active)
      .toList();
  Future<List<ActiveUser>> allUsers() async => (await db.select(db.users).get())
      .where((u) => u.id != 'phase2-local-cashier')
      .map(_active)
      .toList();
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
        final row = await db.into(db.users).insertReturning(
            UsersCompanion.insert(
                name: name,
                role: role.name,
                pinHash: Value(role == UserRole.cashier ? hash : null),
                passwordHash: Value(role == UserRole.cashier ? null : hash)));
        await audit(actorId, 'user_created', row.id);
        return row.id;
      });
  Future<void> setActive(String actorId, String userId, bool active) =>
      db.transaction(() async {
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
  Future<void> audit(String? userId, String action, [String? details]) async {
    await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
        userId: Value(userId), action: action, details: Value(details)));
  }
}
