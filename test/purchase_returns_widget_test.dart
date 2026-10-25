import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_return_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/features/inventory/purchase_returns_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('purchase return editor reviews and finalizes source stock',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final owner = auth.current!;
    final product = await PosRepository(db).saveProduct(
        name: 'Widget', priceCents: 900, costCents: 500, startingStock: 0);
    final supplier =
        await DirectoryRepository(db).saveSupplier(owner, name: 'Supplier A');
    final receipt = await StockReceivingRepository(db).receive(
        owner, supplier.id, [ReceivingLineRequest(product, 10000, 500)]);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PurchaseReturnsScreen(
                repository: PurchaseReturnRepository(db),
                user: owner,
                initialReceivingId: receipt.id))));
    await tester.pumpAndSettle();
    expect(find.text('New purchase return'), findsOneWidget);
    expect(find.text('Widget'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '2');
    await tester.ensureVisible(find.text('Review and finalize'));
    await tester.tap(find.text('Review and finalize'));
    await tester.pumpAndSettle();
    expect(find.text('Review purchase return'), findsOneWidget);
    await tester.tap(find.text('Continue to finalization'));
    await tester.pumpAndSettle();
    expect(find.text('Finalize purchase return?'), findsOneWidget);
    await tester.tap(find.text('Finalize return'));
    await tester.pumpAndSettle();
    expect(await PosRepository(db).stockMilli(product), 8000);
    expect(find.textContaining('PRT-000001'), findsWidgets);
  });
}
