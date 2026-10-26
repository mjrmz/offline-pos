import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/inventory/serial_explorer.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  testWidgets('Product Serials uses the bounded explorer list', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final product = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(name: 'Drive', priceCents: 100,
            serialTracking: const Value(true)));
    for (var i = 0; i < 51; i++) {
      await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
          productId: product.id, serialNumber: 'PD-${i.toString().padLeft(3, '0')}'));
    }
    await tester.pumpWidget(MaterialApp(home: ProductScreen(
        repository: PosRepository(db), auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drive').last);
    await tester.pumpAndSettle();
    expect(find.text('AVAILABLE SERIALS'), findsNothing);
    await tester.ensureVisible(find.text('Serials').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Serials').last);
    await tester.pumpAndSettle();
    expect(find.byType(SerialExplorer), findsOneWidget);
    expect(find.text('PD-000'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('PD-050'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
