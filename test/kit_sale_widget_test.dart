import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/product_kit_repository.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/pos_layout_preference.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('POS kit badge, derived availability, cart merge and cap in $mode',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await PosLayoutPreference.instance.load(force: true);
      await PosLayoutPreference.instance.setLayout(PosLayoutType.visualCatalog);
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      final owner = await auth.login(ownerId, 'password123');
      final pos = PosRepository(db);
      final component = await pos.saveProduct(name: 'Widget component',
        priceCents: 100, costCents: 20, startingStock: 2);
      final kit = await pos.saveProduct(name: 'Widget kit', priceCents: 500,
        costCents: 0, productType: 'kit', isActive: false);
      await ProductKitRepository(db).addComponent(owner, kit, component, 1000);
      await pos.saveProduct(id: kit, name: 'Widget kit', priceCents: 500,
        costCents: 0, productType: 'kit', isActive: true);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.light(),
        darkTheme: ThemeData.dark(), themeMode: mode,
        home: CheckoutScreen(repository: pos, user: owner, auth: auth)));
      await tester.pumpAndSettle();
      expect(find.text('Kit'), findsWidgets);
      expect(find.text('Available: 2 kits'), findsOneWidget);
      await tester.tap(find.text('Widget kit').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Widget kit').first);
      await tester.pumpAndSettle();
      expect(find.text('2'), findsWidgets);
      await tester.tap(find.text('Widget kit').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Not enough Widget component'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
