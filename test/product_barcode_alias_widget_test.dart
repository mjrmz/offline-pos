import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  testWidgets('product detail can add and disable an alias', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await pos.saveProduct(name: 'Alias Item', priceCents: 100,
      costCents: 0, barcode: 'MAIN');
    await tester.pumpWidget(MaterialApp(home: ProductScreen(
      repository: pos, auth: auth, onReceiveStock: (_) {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alias Item').first);
    await tester.pumpAndSettle();
    expect(find.text('Barcode aliases'), findsOneWidget);
    expect(find.text('No barcode aliases.'), findsOneWidget);
    await tester.ensureVisible(find.text('Add barcode'));
    await tester.tap(find.text('Add barcode'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Barcode').last, 'ALT');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(find.text('ALT'), findsOneWidget);
    await tester.tap(find.byTooltip('Disable alias'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Inactive'), findsWidgets);
    expect(await pos.barcode('ALT'), isNull);
  });
}
