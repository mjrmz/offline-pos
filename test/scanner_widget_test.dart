import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  testWidgets(
      'keyboard scanner Enter uses product lookup and repeat adds quantity',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Place?', 'Baguio');
    await auth.login(owner, 'ownerPassword123');
    final pos = PosRepository(db);
    await pos.saveProduct(
        name: 'Item',
        barcode: '12345',
        priceCents: 500,
        costCents: 100,
        startingStock: 3);
    await tester.pumpWidget(MaterialApp(
        home:
            CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('barcode-serial-input'));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Barcode or serial number not found'), findsNothing);
    await tester.enterText(field, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('₱5.00'), findsWidgets);
    await tester.enterText(field, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('₱10.00'), findsWidgets);
    await tester.enterText(field, '99999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Barcode or serial number not found'), findsOneWidget);
    await tester.enterText(field, '12345');
    await tester.pumpAndSettle();
    expect(find.text('Barcode or serial number not found'), findsNothing);
  });
}
