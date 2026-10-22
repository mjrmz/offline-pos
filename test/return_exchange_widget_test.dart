import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sale_return_repository.dart';
import 'package:modern_offline_pos/features/sales_history/return_exchange_dialog.dart';

void main() {
  for (final width in [1366.0, 1600.0, 1920.0]) {
    for (final dark in [false, true]) {
      testWidgets('return editor cancels and reopens at $width dark=$dark',
          (tester) async {
        tester.view.physicalSize = Size(width, width == 1366 ? 768 : 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final auth = AuthService(AuthRepository(db));
        final owner =
            await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
        await auth.login(owner, 'password123');
        await CashSessionRepository(db).open(auth.current!, 10000);
        final pos = PosRepository(db);
        final product = await pos.saveProduct(
            name: 'Cable', priceCents: 1000, costCents: 500, startingStock: 5);
        final sale = await pos
            .completeCashSale([SaleLineRequest(product, 2)], 2000, owner);
        final repository = SaleReturnRepository(db);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: Scaffold(
              body: Builder(
                  builder: (context) => Center(
                      child: FilledButton(
                          onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => ReturnExchangeDialog(
                                  repository: repository,
                                  actor: auth.current!,
                                  saleId: sale.saleId,
                                  receipt: 'POS-000001',
                                  pos: pos)),
                          child: const Text('Open'))))),
        ));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Return / Exchange'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await repository.history(sale.saleId), isEmpty);
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Return / Exchange'), findsNothing);
        expect(await repository.history(sale.saleId), isEmpty);
        expect(await pos.stock(product), 3);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('partial non-sellable return finalizes from the editor',
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
    await CashSessionRepository(db).open(auth.current!, 10000);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Cable', priceCents: 1000, costCents: 500, startingStock: 5);
    final sale =
        await pos.completeCashSale([SaleLineRequest(product, 2)], 2000, owner);
    final repository = SaleReturnRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ReturnExchangeDialog(
                repository: repository,
                actor: auth.current!,
                saleId: sale.saleId,
                receipt: 'POS-000001',
                pos: pos))));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Return now'), '1');
    await tester.pumpAndSettle();
    expect(find.text('Items selected: 1'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<bool>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Do not return to sellable stock').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wrong item').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finalize cash refund'));
    await tester.pumpAndSettle();
    expect(
        (await repository.history(sale.saleId)).single.refundValueCents, 1000);
    expect(await pos.stock(product), 3);
  });
}
