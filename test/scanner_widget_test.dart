import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  testWidgets('keyboard scanner Enter uses product lookup and repeat adds quantity', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'ownerPassword123', 'Place?', 'Baguio');
    await auth.login(owner, 'ownerPassword123');
    final pos = PosRepository(db);
    await pos.saveProduct(name: 'Item', barcode: '12345', priceCents: 500,
        costCents: 100, startingStock: 3);
    await tester.pumpWidget(MaterialApp(home: CheckoutScreen(
        repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Type barcode');
    await tester.enterText(field, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Total: ₱5.00'), findsOneWidget);
    await tester.enterText(field, '12345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Total: ₱10.00'), findsOneWidget);
    await tester.enterText(field, '99999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Barcode not found'), findsOneWidget);
  });
}
