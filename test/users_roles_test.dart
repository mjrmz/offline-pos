import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  test('last active Owner cannot be disabled or downgraded', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Place?', 'Baguio');
    await auth.login(id, 'ownerPassword123');
    await expectLater(auth.setActive(id, false), throwsStateError);
    await expectLater(
        auth.changeRole(id, UserRole.manager, 'managerPassword123'),
        throwsStateError);
    expect((await auth.repository.user(id))!.isActive, isTrue);
  });
  test('role changes require a new credential for the destination role',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Place?', 'Baguio');
    await auth.login(id, 'ownerPassword123');
    final cashier = await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.changeRole(cashier, UserRole.manager, 'managerPassword123');
    final row = (await auth.repository.user(cashier))!;
    expect(row.role, 'manager');
    expect(row.pinHash, isNull);
    expect(row.passwordHash, isNotNull);
    expect(
        (await auth.repository.securityActivity())
            .any((e) => e.action == 'user_role_changed'),
        isTrue);
  });
}
