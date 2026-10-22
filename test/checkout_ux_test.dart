import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  Future<(AppDatabase, PosRepository)> mount(
      WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(owner, 'ownerPassword123');
    final pos = PosRepository(db);
    final food = await pos.addCategory('Food');
    await pos.saveProduct(
        name: 'Jasmine Rice',
        sku: 'RICE-1',
        barcode: 'RICE',
        categoryId: food,
        priceCents: 5000,
        costCents: 2000,
        startingStock: 200);
    await pos.saveProduct(
        name: 'Low Stock Soap',
        sku: 'SOAP',
        priceCents: 500,
        costCents: 100,
        startingStock: 1,
        lowStockThreshold: 2);
    await pos.saveProduct(
        name: 'Empty Shelf', priceCents: 500, costCents: 100, startingStock: 0);
    await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Alex Buyer');
    await tester.pumpWidget(MaterialApp(
        home:
            CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    return (db, pos);
  }

  testWidgets(
      'desktop shows separate search, categories, stock states and empty sale',
      (tester) async {
    await mount(tester, const Size(1280, 900));
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
    expect(find.byKey(const Key('product-search')), findsOneWidget);
    expect(find.byKey(const Key('barcode-serial-input')), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('Low stock'), findsOneWidget);
    expect(find.text('Out of stock'), findsOneWidget);
    expect(find.text('Out of stock'), findsOneWidget);
    expect(find.text('No items added'), findsOneWidget);
    expect(find.byKey(const Key('cash-tendered')), findsNothing);
    expect(find.text('Add an item to continue'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('product-search')), 'RICE-1');
    await tester.pump();
    expect(find.text('Jasmine Rice'), findsOneWidget);
    expect(find.text('Low Stock Soap'), findsNothing);
    await tester.enterText(find.byKey(const Key('product-search')), 'missing');
    await tester.pump();
    expect(find.text('No products found'), findsOneWidget);
  });

  testWidgets('customer and payment split stay in current sale',
      (tester) async {
    await mount(tester, const Size(1280, 900));
    await tester.tap(find.text('Jasmine Rice'));
    await tester.pumpAndSettle();
    expect(find.text('TOTAL'), findsOneWidget);
    expect(find.text('Pay ₱50.00'), findsOneWidget);
    expect(find.byKey(const Key('cash-tendered')), findsOneWidget);
    expect(find.text('Select a customer before using credit.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('customer-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alex Buyer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Credit / Utang'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cash-tendered')), '20');
    await tester.pump();
    expect(find.text('Cash'), findsWidgets);
    expect(find.text('Credit'), findsOneWidget);
    expect(find.text('₱30.00'), findsOneWidget);
    expect(find.text('Complete payment · ₱50.00'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(
                find.widgetWithText(TextButton, '+ Add discount'))
            .onPressed,
        isNotNull);
  });

  testWidgets('direct quantity and quick cash update totals and change',
      (tester) async {
    await mount(tester, const Size(1280, 900));
    await tester.tap(find.text('Jasmine Rice'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Pay ₱150.00'), findsOneWidget);
    await tester.tap(find.text('₱500'));
    await tester.pump();
    expect(find.text('₱350.00'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pay-button')))
            .onPressed,
        isNotNull);
  });

  testWidgets('ordinary card adds and direct quantity accepts 100',
      (tester) async {
    await mount(tester, const Size(1366, 768));
    expect(find.widgetWithText(TextButton, 'Add'), findsNothing);
    await tester.tap(find.text('Jasmine Rice'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '100');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
        tester
            .state<CheckoutScreenState>(find.byType(CheckoutScreen))
            .cart
            .lines
            .single
            .quantity,
        100);
    expect(find.byKey(const Key('pay-button')), findsOneWidget);
  });

  testWidgets('quantity above stock rolls back safely', (tester) async {
    await mount(tester, const Size(1280, 900));
    await tester.tap(find.text('Low Stock Soap'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
        tester
            .state<CheckoutScreenState>(find.byType(CheckoutScreen))
            .cart
            .lines
            .single
            .quantity,
        1);
    expect(find.textContaining('Only 1'), findsOneWidget);
  });

  testWidgets('quantity controls disable at limits and sale warning expires',
      (tester) async {
    await mount(tester, const Size(1280, 900));
    await tester.tap(find.text('Low Stock Soap'));
    await tester.pumpAndSettle();
    final minus =
        find.byTooltip('Minimum quantity or serial selection reached');
    final plus = find.byTooltip('Maximum quantity or serial selection reached');
    expect(
        tester
            .widget<IconButton>(
                find.ancestor(of: minus, matching: find.byType(IconButton)))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(
                find.ancestor(of: plus, matching: find.byType(IconButton)))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextFormField).first, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byKey(const Key('current-sale-notice')), findsOneWidget);
    expect(find.textContaining('Only 1'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('current-sale-notice')), findsNothing);
  });

  testWidgets('tablet and mobile expose cart without shrinking two panes',
      (tester) async {
    await mount(tester, const Size(820, 740));
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsNothing);
    expect(find.byKey(const Key('mobile-cart-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mobile-cart-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('No items added'), findsOneWidget);
    expect(find.byTooltip('Browse products'), findsOneWidget);
  });

  for (final size in [
    const Size(1366, 768),
    const Size(1600, 900),
    const Size(1920, 1080),
  ]) {
    testWidgets('desktop checkout fits ${size.width}x${size.height}',
        (tester) async {
      await mount(tester, size);
      expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
      expect(find.byKey(const Key('product-catalog-grid')), findsOneWidget);
      expect(find.byKey(const Key('pay-button')), findsOneWidget);
      await tester.tap(find.text('Jasmine Rice'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cash-tendered')), findsOneWidget);
      expect(find.byKey(const Key('pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
