import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/printer_settings_repository.dart';
import 'package:modern_offline_pos/core/services/sales_service.dart';
import 'package:modern_offline_pos/core/models/printer_settings.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_printer.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_service.dart';
import 'package:modern_offline_pos/hardware/cash_drawer/cash_drawer.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/pos_layout_preference.dart';

class _RetryPrinter implements ReceiptPrinter {
  bool fails = true;
  int attempts = 0;
  @override
  Future<void> print(ReceiptDocument document, PrinterSettings settings) async {
    attempts++;
    if (fails) throw const HardwareException('offline');
  }

  @override
  Future<void> test(PrinterSettings settings) async {}
}

class _NoDrawer implements CashDrawer {
  @override
  Future<void> open(PrinterSettings settings) async {}
}

void main() {
  testWidgets(
      'visual checkout holds walk-in and authorized discount, then resumes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await pos.saveProduct(
        name: 'Mouse',
        barcode: '12345',
        priceCents: 10000,
        costCents: 5000,
        startingStock: 2);
    await tester.pumpWidget(MaterialApp(
        home:
            CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();

    final barcode = find.byKey(const Key('barcode-serial-input'));
    await tester.enterText(barcode, '99999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Barcode not found: 99999'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mouse').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('customer-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Walk-in details'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('quick-customer-name')), 'Juan');
    await tester.enterText(
        find.byKey(const Key('quick-customer-contact')), '0917 123 4567');
    await tester.tap(find.text('Use walk-in'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('+ Add discount'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixed amount').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Percentage').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('manual-discount-value')), '10');
    await tester.enterText(
        find.byKey(const Key('manual-discount-password')), 'password123');
    await tester.tap(find.text('Authorize'));
    await tester.pumpAndSettle();
    expect(find.text('Manual discount'), findsOneWidget);

    await tester.tap(find.text('Hold sale · F6'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hold sale').last);
    await tester.pumpAndSettle();
    expect(await db.select(db.heldSales).get(), hasLength(1));
    expect(await db.select(db.sales).get(), isEmpty);
    await tester.tap(find.text('Held sales · F7'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(await db.select(db.heldSales).get(), isEmpty);
    expect(find.textContaining('Juan'), findsWidgets);

    await tester.enterText(find.byKey(const Key('cash-tendered')), '100');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('pay-button')));
    await tester.tap(find.byKey(const Key('pay-button')));
    await tester.pumpAndSettle();
    expect(find.text('SALE COMPLETE'), findsOneWidget);
    expect(find.text('Juan\n0917 123 4567'), findsOneWidget);
    expect((await db.select(db.sales).get()).single.totalCents, 9000);
    await tester.tap(find.text('New sale'));
    await tester.pumpAndSettle();
    expect(find.text('No items added'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('held sale stays held when stock is no longer available',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 5000, startingStock: 1);
    await tester.pumpWidget(MaterialApp(
        home:
            CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mouse').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hold sale · F6'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hold sale').last);
    await tester.pumpAndSettle();
    await StockCountRepository(db)
        .adjust(auth.current!, AdjustmentRequest(id, -1000, 'Lost'));
    await tester.tap(find.text('Held sales · F7'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(find.text('Some items are no longer available'), findsOneWidget);
    expect(await db.select(db.heldSales).get(), hasLength(1));
    expect(await db.select(db.sales).get(), isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown barcode product creation prefills scanned code',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    await tester.pumpWidget(MaterialApp(
        home: CheckoutScreen(
            repository: PosRepository(db), user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('barcode-serial-input')), '9999999999999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product'));
    await tester.pumpAndSettle();
    final barcode =
        tester.widget<TextField>(find.widgetWithText(TextField, 'Barcode'));
    expect(barcode.controller!.text, '9999999999999');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'cashier can create a named customer but cannot create an unknown product',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final cashier = await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.login(cashier, '1234');
    await tester.pumpWidget(MaterialApp(
        home: CheckoutScreen(
            repository: PosRepository(db), user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('barcode-serial-input')), '99999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Create product'), findsNothing);
    await tester.tap(find.byKey(const Key('customer-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ New Customer'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Create customer'))
            .onPressed,
        isNull);
    await tester.enterText(
        find.byKey(const Key('quick-customer-name')), 'Moira');
    await tester.pump();
    await tester.tap(find.text('Create customer'));
    await tester.pumpAndSettle();
    expect((await db.select(db.customers).get()).single.name, 'Moira');
    expect((await db.select(db.customers).get()).single.phone, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resume explains a price change and uses current pricing',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 5000, startingStock: 1);
    await tester.pumpWidget(MaterialApp(
        home:
            CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mouse').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hold sale · F6'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hold sale').last);
    await tester.pumpAndSettle();
    await pos.saveProduct(
        id: id, name: 'Mouse', priceCents: 12000, costCents: 5000);
    await tester.tap(find.text('Held sales · F7'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Prices changed while held'), findsWidgets);
    expect(find.text('Pay ₱120.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('print failure keeps committed success screen and retry works',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await pos.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 5000, startingStock: 1);
    final settings = PrinterSettingsStore(db);
    await settings
        .save(const PrinterSettings(enabled: true, host: 'example.local'));
    final printer = _RetryPrinter();
    final receipts = ReceiptService(SalesService(SalesRepository(db), auth),
        settings, printer, _NoDrawer());
    await tester.pumpWidget(MaterialApp(
        home: CheckoutScreen(
            repository: pos,
            user: auth.current!,
            auth: auth,
            receipts: receipts)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mouse').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cash-tendered')), '100');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('pay-button')));
    await tester.tap(find.byKey(const Key('pay-button')));
    await tester.pumpAndSettle();
    expect(find.text('SALE COMPLETE'), findsOneWidget);
    expect(
        find.text('Sale completed. Receipt printing failed.'), findsOneWidget);
    expect(await db.select(db.sales).get(), hasLength(1));
    printer.fails = false;
    await tester.tap(find.text('Retry print'));
    await tester.pumpAndSettle();
    expect(find.text('Sale completed. Receipt printing failed.'), findsNothing);
    expect(printer.attempts, 2);
    expect(await db.select(db.sales).get(), hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
