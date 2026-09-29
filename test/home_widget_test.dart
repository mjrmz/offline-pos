import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/dashboard/home_screen.dart';

void main() {
  testWidgets('cashier and manager do not get recovery tools', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final cashierId =
        await auth.createUser('Cashier', UserRole.cashier, '1234');
    final managerId = await auth.createUser(
        'Manager', UserRole.manager, 'managerPassword123');
    await auth.logout();
    for (final (id, credential) in [
      (cashierId, '1234'),
      (managerId, 'managerPassword123'),
    ]) {
      await auth.login(id, credential);
      await tester.pumpWidget(MaterialApp(
          home: HomeScreen(
              auth: auth,
              pos: PosRepository(db),
              salesRepository: SalesRepository(db),
              recoveryScreen: const Text('Recovery probe'),
              onChanged: () {})));
      await tester.pumpAndSettle();
      expect(find.text('Recovery'), findsNothing);
      expect(find.text('Recovery probe'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.logout();
    }
  });

  testWidgets('recovery scan widget mounts only when owner opens its tab',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    var recoveryBuilds = 0;
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            recoveryScreen: Builder(builder: (_) {
              recoveryBuilds++;
              return const Text('Recovery probe');
            }),
            onChanged: () {})));
    await tester.pumpAndSettle();
    expect(recoveryBuilds, 0);
    await tester.tap(find.text('Recovery'));
    await tester.pumpAndSettle();
    expect(recoveryBuilds, greaterThan(0));
    expect(find.text('Recovery probe'), findsOneWidget);
  });

  testWidgets('sale appears when history and reports tabs open',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final pos = PosRepository(db);
    await pos.saveProduct(
        name: 'Coke', priceCents: 4000, costCents: 1000, startingStock: 3);
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: pos,
            salesRepository: SalesRepository(db),
            onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump();
    expect(find.text('Total: ₱40.00'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Cash received'), '40');
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Complete sale'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Complete sale'))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('Complete sale'));
    await tester.pumpAndSettle();
    expect(find.textContaining('complete. Change:'), findsOneWidget);
    final sale = (await db.select(db.sales).get()).single;
    expect(sale.cashierId, ownerId);
    await tester.tap(find.text('Sales history'));
    await tester.pumpAndSettle();
    expect(find.textContaining(sale.id), findsWidgets);
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();
    expect(find.text('Gross sales: ₱40.00'), findsOneWidget);
    expect(find.text('Net sales: ₱40.00'), findsOneWidget);
  });
}
