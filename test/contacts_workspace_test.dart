import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/features/contacts/contacts_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('contact rows open wide profiles and supplier tab changes action',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final repo = DirectoryRepository(db);
    await repo.saveCustomer(auth.current!, name: 'Moira');
    await repo.saveSupplier(auth.current!, name: 'HC Play');
    await tester.pumpWidget(MaterialApp(
        home: ContactsScreen(repository: repo, user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.text('Add customer'), findsOneWidget);
    expect(find.text('Moira'), findsOneWidget);
    expect(find.text('Previous'), findsNothing);
    await tester.tap(find.text('Moira'));
    await tester.pumpAndSettle();
    expect(find.text('Rewards'), findsOneWidget);
    expect(find.text('Customers & Suppliers'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to customers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suppliers').first);
    await tester.pumpAndSettle();
    expect(find.text('Add supplier'), findsOneWidget);
    await tester.tap(find.text('HC Play'));
    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Customers & Suppliers'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('contact search pages in SQLite at 50 rows', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (var index = 0; index < 51; index++) {
      await db
          .into(db.customers)
          .insert(CustomersCompanion.insert(name: 'Paged customer $index'));
    }
    final repo = DirectoryRepository(db);
    expect(await repo.countCustomers('paged'), 51);
    expect((await repo.customerPage('paged', 0)).length, 50);
    expect((await repo.customerPage('paged', 1)).length, 1);
    expect(await repo.countCustomers('missing'), 0);
    expect(await repo.customerPage('missing', 0), isEmpty);
  });
}
