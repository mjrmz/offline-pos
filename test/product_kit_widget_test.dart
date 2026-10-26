import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  testWidgets('product form creates an inactive kit without stock',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: ProductScreen(
            repository: pos, auth: auth, onReceiveStock: (_) {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Starter Kit');
    await tester.tap(find.text('Standard').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kit').last);
    await tester.pumpAndSettle();
    expect(find.text('I already have stock'), findsNothing);
    await tester
        .ensureVisible(find.widgetWithText(TextField, 'Selling price *'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '12.99');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final kit = (await pos.products()).single;
    expect(kit.productType, 'kit');
    expect(kit.isActive, isFalse);
    expect(await pos.stockMilli(kit.id), 0);
    expect(await db.select(db.inventory).get(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('kit detail shows derived availability and editor in $mode',
        (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final owner =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(owner, 'password123');
      final pos = PosRepository(db);
      await pos.saveProduct(
          name: 'Keyboard', priceCents: 1000, costCents: 400, startingStock: 6);
      await pos.saveProduct(
          name: 'Gaming Bundle',
          priceCents: 1299,
          costCents: 0,
          productType: 'kit',
          isActive: false);
      await tester.pumpWidget(MaterialApp(
          themeMode: mode,
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          home: ProductScreen(repository: pos, auth: auth)));
      await tester.pumpAndSettle();
      expect(find.text('Available: 0 kits'), findsOneWidget);
      await tester.tap(find.text('Gaming Bundle').first);
      await tester.pumpAndSettle();
      expect(find.text('Kit summary'), findsOneWidget);
      expect(find.text('Add component'), findsOneWidget);
      expect(find.text('Stock snapshot'), findsNothing);
      await tester.ensureVisible(find.text('Add component'));
      await tester.tap(find.text('Add component'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Component').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keyboard').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(find.text('Keyboard'), findsWidgets);
      expect(find.text('6'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
