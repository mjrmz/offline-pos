import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/inventory/code128_preview.dart';
import 'package:modern_offline_pos/features/inventory/inventory_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('Inventory Tools label picker, quantity, removal and preview ($mode)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final repo = PosRepository(db);
      await repo.saveProduct(name: 'Medicine', sku: 'MED-1',
          barcode: 'ABC123', priceCents: 1250, costCents: 500, startingStock: 0);
      await repo.saveProduct(name: 'Water', sku: 'WAT-1',
          priceCents: 300, costCents: 100, startingStock: 0);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.light(),
        darkTheme: ThemeData.dark(), themeMode: mode,
        home: InventoryWorkspace(repository: repo, auth: auth,
          user: auth.current!, initialView: 7)));
      await tester.pumpAndSettle();
      expect(find.text('Label Printing'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Open').last);
      await tester.pumpAndSettle();
      expect(find.text('No labels selected'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField,
          'Add products by name, SKU, or barcode'), 'med-1');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Medicine'), findsOneWidget);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      expect(find.byType(Code128Preview), findsOneWidget);
      expect(find.text('ABC123'), findsWidgets);
      expect(find.text('Total: 1 labels'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField,
          'Add products by name, SKU, or barcode'), 'wat-1');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      expect(find.text('Total: 2 labels'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).last, '3');
      await tester.pumpAndSettle();
      expect(find.text('Total: 4 labels'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
      expect(find.text('Total: 3 labels'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove').first);
      await tester.pumpAndSettle();
      expect(find.text('No labels selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missing and invalid barcode previews are explicit', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Column(
      children: [Code128Preview(''), Code128Preview('bad\ncode')]))));
    expect(find.text('No barcode assigned'), findsOneWidget);
    expect(find.text('Unsupported CODE128 barcode value'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
