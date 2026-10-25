import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/import_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/inventory/import_wizard.dart';
import 'package:modern_offline_pos/features/inventory/inventory_workspace.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('wizard shows supported types and stock notice in $brightness',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: ImportWizard(
            repository: ImportRepository(db),
            user: const ActiveUser('owner', 'Owner', UserRole.owner),
          ),
        ),
      ));
      expect(find.text('Import Data'), findsOneWidget);
      expect(find.text('Select CSV'), findsOneWidget);
      expect(find.textContaining('Opening stock'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<ImportKind>));
      await tester.pumpAndSettle();
      expect(find.text('Customers'), findsWidgets);
      expect(find.text('Suppliers'), findsWidgets);
      await tester.tap(find.text('Opening Inventory').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('before using this POS'), findsOneWidget);
      expect(find.text('Download template'), findsOneWidget);
    });
  }
  testWidgets('Inventory Tools opens Import Data with a Material surface',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    await tester.pumpWidget(MaterialApp(home: InventoryWorkspace(
      repository: PosRepository(db), auth: auth, user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Tools').first);
    await tester.tap(find.text('Tools').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Open').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Import Data'), findsWidgets);
    expect(find.byType(Chip), findsNWidgets(5));
    expect(find.ancestor(of: find.byType(Chip).first,
        matching: find.byType(Material)), findsWidgets);
  });
}
