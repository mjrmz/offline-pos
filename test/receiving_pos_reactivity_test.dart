import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  testWidgets('mounted POS shows new received product without navigation',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    await tester.pumpWidget(MaterialApp(
        home:
            CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    expect(find.text('RC'), findsNothing);

    final id = await pos.saveProduct(
        name: 'RC',
        sku: 'RC-1',
        barcode: '480000000101',
        priceCents: 5000,
        costCents: 3000);
    await StockReceivingRepository(db).receive(
        auth.current!, supplier.id, [ReceivingLineRequest(id, 100000, 3000)]);
    await tester.pumpAndSettle();
    expect(find.text('RC'), findsOneWidget);
    expect(find.text('100 available'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Add'), findsNothing);
    await tester.tap(find.text('RC'));
    await tester.pumpAndSettle();
    expect(find.text('TOTAL'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
