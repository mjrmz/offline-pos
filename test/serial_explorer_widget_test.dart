import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/serial_lifecycle_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/inventory/serial_explorer.dart';
import 'package:modern_offline_pos/features/inventory/inventory_workspace.dart';

void main() {
  testWidgets('product serial pages and drawer fit common sizes in both themes',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final product = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(name: 'Drive', priceCents: 100));
    final other = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(name: 'Other', priceCents: 100));
    for (var i = 0; i < 51; i++) {
      await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
          productId: product.id, serialNumber: 'SN-${i.toString().padLeft(3, '0')}'));
    }
    await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
        productId: other.id, serialNumber: 'OTHER-SN'));
    for (final size in [const Size(1366, 768), const Size(1600, 900),
      const Size(1920, 1080)]) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(MaterialApp(theme: ThemeData(
            brightness: brightness), home: SerialExplorer(
              key: ValueKey('$size-$brightness'),
              repository: SerialLifecycleRepository(db),
              user: const ActiveUser('owner', 'Owner', UserRole.owner),
              productId: product.id)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('OTHER-SN'), findsNothing);
        expect(find.text('SN-000'), findsOneWidget);
        await tester.tap(find.text('SN-000'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Lifecycle timeline'), findsOneWidget);
        expect(tester.getSize(find.byType(Drawer)).width, lessThanOrEqualTo(620));
        if (size.width == 1366 && brightness == Brightness.light) {
          await tester.tap(find.byIcon(Icons.close));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Next'));
          await tester.pumpAndSettle();
          expect(find.text('SN-050'), findsOneWidget);
          expect(find.text('OTHER-SN'), findsNothing);
        }
      }
    }
  });

  testWidgets('Inventory Tools opens the embedded explorer', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: InventoryWorkspace(
        repository: PosRepository(db), auth: auth, user: auth.current!,
        initialView: 8))));
    await tester.pumpAndSettle();
    final card = find.ancestor(of: find.text('Serial Explorer'),
        matching: find.byType(Card)).first;
    await tester.ensureVisible(card);
    await tester.tap(find.descendant(of: card, matching: find.text('Open')));
    await tester.pumpAndSettle();
    expect(find.byType(SerialExplorer), findsOneWidget);
    expect(find.text('Search serial number'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
