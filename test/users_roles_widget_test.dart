import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/auth/users_screen.dart';

void main() {
  for (final size in const [
    Size(1366, 768),
    Size(1600, 900),
    Size(1920, 1080)
  ]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('Users workspace fits $size in $mode', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final auth = AuthService(AuthRepository(db));
        final owner =
            await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
        await auth.login(owner, 'ownerPassword123');
        await auth.createUser('tiya', UserRole.cashier, '1234');
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: UsersScreen(auth: auth)));
        await tester.pumpAndSettle();
        expect(find.text('Users & Roles'), findsOneWidget);
        expect(find.text('tiya'), findsOneWidget);
        expect(find.text('Current user'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Roles & Permissions'));
        await tester.pumpAndSettle();
        expect(find.text('Capability'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Owner can open grouped custom role editor', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
    await auth.login(owner, 'ownerPassword123');
    await tester.pumpWidget(MaterialApp(home: UsersScreen(auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Roles & Permissions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create role').first);
    await tester.pumpAndSettle();
    expect(find.text('POS & Sales'), findsWidgets);
    expect(find.text('Inventory'), findsWidgets);
    expect(find.text('Sensitive'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
