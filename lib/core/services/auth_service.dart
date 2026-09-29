import 'package:bcrypt/bcrypt.dart';
import '../models/active_user.dart';
import '../../data/daos/auth_repository.dart';

class AuthService {
  static const maxAttempts = 5;
  static const lockDuration = Duration(minutes: 2);
  final AuthRepository repository;
  final DateTime Function() now;
  ActiveUser? _current;
  ActiveUser? get current => _current;
  AuthService(this.repository, {DateTime Function()? clock})
      : now = clock ?? DateTime.now;
  ActiveUser requireSession(PosPermission permission) {
    final user = _current;
    if (user == null) throw StateError('Please log in');
    user.require(permission);
    return user;
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
    await repository.requireActive(current!.id);
    return repository.createUser(
        actorId: current!.id,
        name: name.trim(),
        role: role,
        hash: _hash(credential));
  }

  Future<void> setActive(String userId, bool active) async {
    requireSession(PosPermission.manageUsers);
    if (userId == current?.id && !active) {
      throw StateError('Cannot deactivate your own account');
    }
    if (userId == 'phase2-local-cashier') {
      throw StateError('Historical account cannot be changed');
    }
    await repository.requireActive(current!.id);
    await repository.setActive(current!.id, userId, active);
  }

  Future<void> resetCredential(String userId, String credential) async {
    requireSession(PosPermission.manageUsers);
    final row = await repository.user(userId);
    if (row == null || row.id == 'phase2-local-cashier') {
      throw StateError('User not found');
    }
    final role = UserRole.values.byName(row.role);
    if (role == UserRole.cashier) {
      _pin(credential);
    } else {
      _password(credential);
    }
    await repository.requireActive(current!.id);
    await repository.setCredential(
        current!.id, userId, role, _hash(credential));
  }
}
