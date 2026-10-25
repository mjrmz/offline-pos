import 'package:bcrypt/bcrypt.dart';
import '../models/active_user.dart';
import '../../data/daos/auth_repository.dart';
import '../../data/daos/role_repository.dart';
import '../../data/daos/product_margin_repository.dart';

final class BelowCostApproval {
  final String cashierId;
  final String approverId;
  final String approverName;
  final String reason;
  final String fingerprint;
  final DateTime authorizedAt;
  bool _used = false;
  bool _claimed = false;
  BelowCostApproval._(this.cashierId, this.approverId, this.approverName,
      this.reason, this.fingerprint, this.authorizedAt);
  bool matches(String cashier, BelowCostQuote quote) => !_used && !_claimed &&
      cashierId == cashier && fingerprint == quote.fingerprint &&
      reason.trim().isNotEmpty;
  bool claim(String cashier, BelowCostQuote quote) {
    if (!matches(cashier, quote)) return false;
    _claimed = true;
    return true;
  }
  void release() => _claimed = false;
  void consume() { _used = true; _claimed = false; }
  void invalidate() { _used = true; _claimed = false; }
}

class AuthService {
  static const maxAttempts = 5;
  static const lockDuration = Duration(minutes: 2);
  final AuthRepository repository;
  final DateTime Function() now;
  ActiveUser? _current;
  ActiveUser? get current => _current;
  AuthService(this.repository, {DateTime Function()? clock})
      : now = clock ?? DateTime.now;
  RoleRepository get roles => RoleRepository(repository.db);
  Future<void> refreshCurrent() async {
    if (_current != null) {
      _current = await repository.requireActive(_current!.id);
    }
  }

  ActiveUser requireSession(PosPermission permission) {
    final user = _current;
    if (user == null) throw StateError('Please log in');
    if (PermissionRegistry.byKey[permission.name]?.ownerOnly == true &&
        user.role != UserRole.owner) {
      throw StateError('Owner access required');
    }
    user.require(permission);
    return user;
  }

  Future<ActiveUser> authorizeDiscount(String userId, String password) async {
    requireSession(PosPermission.sell);
    final row = await repository.user(userId);
    if (row == null ||
        !row.isActive ||
        !(await repository.requireActive(row.id))
            .can(PosPermission.approveDiscount) ||
        (row.lockedUntil != null && now().isBefore(row.lockedUntil!))) {
      await repository.audit(
          current?.id, 'manual_discount.authorization_failed');
      throw StateError('Manager authorization failed');
    }
    if (!_matches(password, row.passwordHash)) {
      final attempts = row.failedAttempts + 1;
      await repository.failed(row.id, attempts,
          attempts >= maxAttempts ? now().add(lockDuration) : null);
      await repository.audit(
          current?.id, 'manual_discount.authorization_failed');
      throw StateError('Manager authorization failed');
    }
    await repository.discountCredentialSucceeded(userId);
    return repository.requireActive(userId);
  }

  Future<BelowCostApproval> authorizeBelowCost(
      BelowCostQuote quote, String reason,
      {String? approverId, String? credential}) async {
    final cashier = requireSession(PosPermission.sell);
    if (!quote.isBelowCost || reason.trim().isEmpty) {
      throw StateError('A below-cost reason is required');
    }
    final id = approverId ?? cashier.id;
    final row = await repository.user(id);
    if (row == null || !row.isActive ||
        !(await repository.requireActive(id))
            .can(PosPermission.authorizeBelowCost) ||
        (row.lockedUntil != null && now().isBefore(row.lockedUntil!))) {
      await repository.audit(cashier.id, 'below_cost.authorization_failed');
      throw StateError('Below-cost authorization failed');
    }
    if (id != cashier.id || credential != null) {
      if (credential == null || !_matches(credential, row.passwordHash)) {
        final attempts = row.failedAttempts + 1;
        await repository.failed(id, attempts,
            attempts >= maxAttempts ? now().add(lockDuration) : null);
        await repository.audit(cashier.id, 'below_cost.authorization_failed');
        throw StateError('Below-cost authorization failed');
      }
      await repository.belowCostCredentialSucceeded(id);
    }
    return BelowCostApproval._(cashier.id, id, row.name, reason.trim(),
        quote.fingerprint, now());
  }

  String _hash(String value) =>
      BCrypt.hashpw(value, BCrypt.gensalt(logRounds: 10));
  bool _matches(String value, String? hash) =>
      hash != null && BCrypt.checkpw(value, hash);
  String _answer(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  void _password(String value) {
    if (value.length < 8) {
      throw StateError('Password must be at least 8 characters');
    }
  }

  void _pin(String value) {
    if (!RegExp(r'^\d{4,6}$').hasMatch(value)) {
      throw StateError('PIN must be 4–6 digits');
    }
  }

  Future<String> bootstrap(
      String name, String password, String question, String answer) async {
    if (name.trim().isEmpty ||
        question.trim().isEmpty ||
        _answer(answer).length < 4) {
      throw StateError('Enter name, recovery question, and answer');
    }
    _password(password);
    return repository.bootstrap(
        name: name.trim(),
        hash: _hash(password),
        question: question.trim(),
        answerHash: _hash(_answer(answer)));
  }

  Future<ActiveUser> login(String userId, String credential) async {
    final row = await repository.user(userId);
    if (row == null || row.id == 'phase2-local-cashier') {
      await repository.failed(null, 0, null);
      throw StateError('Invalid credentials');
    }
    if (!row.isActive) {
      await repository.audit(row.id, 'login_failed');
      throw StateError('Account is inactive');
    }
    if (row.lockedUntil != null && now().isBefore(row.lockedUntil!)) {
      await repository.audit(row.id, 'login_failed');
      throw StateError('Account temporarily locked');
    }
    final correct = _matches(
        credential, row.role == 'cashier' ? row.pinHash : row.passwordHash);
    if (!correct) {
      final attempts = row.failedAttempts + 1;
      await repository.failed(row.id, attempts,
          attempts >= maxAttempts ? now().add(lockDuration) : null);
      throw StateError(attempts >= maxAttempts
          ? 'Account temporarily locked'
          : 'Invalid credentials');
    }
    await repository.succeeded(row.id);
    _current = await repository.requireActive(row.id);
    return _current!;
  }

  Future<void> logout() async {
    final user = _current;
    try {
      if (user != null) await repository.audit(user.id, 'logout');
    } finally {
      _current = null;
    }
  }

  Future<void> lock() async {
    final user = _current;
    try {
      if (user != null) await repository.audit(user.id, 'register_locked');
    } finally {
      _current = null;
    }
  }

  Future<void> recover(
      String ownerId, String answer, String newPassword) async {
    _password(newPassword);
    final row = await repository.user(ownerId);
    if (row == null ||
        row.role != 'owner' ||
        !row.isActive ||
        row.recoveryAnswerHash == null) {
      await repository.audit(null, 'recovery_failed');
      throw StateError('Recovery failed');
    }
    if (row.lockedUntil != null && now().isBefore(row.lockedUntil!)) {
      await repository.audit(row.id, 'recovery_failed');
      throw StateError('Account temporarily locked');
    }
    if (!_matches(_answer(answer), row.recoveryAnswerHash)) {
      final attempts = row.failedAttempts + 1;
      await repository.recoveryFailed(ownerId, attempts,
          attempts >= maxAttempts ? now().add(lockDuration) : null);
      throw StateError('Recovery failed');
    }
    await repository.setRecoveryPassword(ownerId, _hash(newPassword));
  }

  Future<String> createUser(
      String name, UserRole role, String credential) async {
    requireSession(PosPermission.manageUsers);
    if (name.trim().isEmpty) throw StateError('Enter a name');
    if (role == UserRole.cashier) {
      _pin(credential);
    } else {
      _password(credential);
    }
    (await repository.requireActive(current!.id))
        .require(PosPermission.manageUsers);
    return repository.createUser(
        actorId: current!.id,
        name: name.trim(),
        role: role,
        hash: _hash(credential));
  }

  Future<String> createUserWithRole(
      String name, String roleCode, String password) async {
    requireSession(PosPermission.manageUsers);
    if (name.trim().isEmpty) throw StateError('Enter a name');
    _password(password);
    (await repository.requireActive(current!.id))
        .require(PosPermission.manageUsers);
    return repository.createUserWithRole(
        actorId: current!.id,
        name: name.trim(),
        roleCode: roleCode,
        hash: _hash(password));
  }

  Future<void> changeRoleTo(
      String userId, String roleCode, String password) async {
    requireSession(PosPermission.manageUsers);
    if (userId == current?.id) throw StateError('Cannot change your own role');
    if (userId == 'phase2-local-cashier') {
      throw StateError('Historical account cannot be changed');
    }
    _password(password);
    (await repository.requireActive(current!.id))
        .require(PosPermission.manageUsers);
    await repository.changeRoleTo(
        current!.id, userId, roleCode, _hash(password));
  }

  Future<String> createRole(
      String name, String description, Set<PosPermission> permissions,
      {String? duplicatedFrom}) async {
    requireSession(PosPermission.manageRoles);
    if (current!.role != UserRole.owner) {
      throw StateError('Only an Owner can manage roles');
    }
    return roles.create(current!.id, name, description, permissions,
        duplicatedFrom: duplicatedFrom);
  }

  Future<void> updateRole(String code, String name, String description,
      Set<PosPermission> permissions) async {
    requireSession(PosPermission.manageRoles);
    if (current!.role != UserRole.owner) {
      throw StateError('Only an Owner can manage roles');
    }
    await roles.update(current!.id, code, name, description, permissions);
    await refreshCurrent();
  }

  Future<void> deleteRole(String code) async {
    requireSession(PosPermission.manageRoles);
    if (current!.role != UserRole.owner) {
      throw StateError('Only an Owner can manage roles');
    }
    await roles.delete(current!.id, code);
  }

  Future<void> setActive(String userId, bool active) async {
    requireSession(PosPermission.manageUsers);
    if (userId == current?.id && !active) {
      throw StateError('Cannot deactivate your own account');
    }
    if (userId == 'phase2-local-cashier') {
      throw StateError('Historical account cannot be changed');
    }
    (await repository.requireActive(current!.id))
        .require(PosPermission.manageUsers);
    await repository.setActive(current!.id, userId, active);
  }

  Future<void> editUser(String userId, String name) async {
    requireSession(PosPermission.manageUsers);
    if (name.trim().isEmpty) throw StateError('Name is required');
    (await repository.requireActive(current!.id))
        .require(PosPermission.manageUsers);
    final target = await repository.user(userId);
    if (target == null) throw StateError('User not found');
    await repository.editUser(current!.id, userId,
        name: name, roleCode: target.role);
  }

  Future<void> changeRole(
      String userId, UserRole role, String credential) async {
    requireSession(PosPermission.manageUsers);
    if (userId == current?.id) throw StateError('Cannot change your own role');
    if (userId == 'phase2-local-cashier') {
      throw StateError('Historical account cannot be changed');
    }
    if (role == UserRole.cashier) {
      _pin(credential);
    } else {
      _password(credential);
    }
    (await repository.requireActive(current!.id))
        .require(PosPermission.manageUsers);
    await repository.changeRole(current!.id, userId, role, _hash(credential));
  }

  Future<void> resetCredential(String userId, String credential) async {
    requireSession(PosPermission.manageUsers);
    final row = await repository.user(userId);
    if (row == null || row.id == 'phase2-local-cashier') {
      throw StateError('User not found');
    }
    final role = UserRole.values.where((r) => r.name == row.role).firstOrNull ??
        UserRole.custom;
    if (role == UserRole.cashier) {
      _pin(credential);
    } else {
      _password(credential);
    }
    (await repository.requireActive(current!.id))
        .require(PosPermission.manageUsers);
    await repository.setCredential(
        current!.id, userId, role, _hash(credential));
  }
}
