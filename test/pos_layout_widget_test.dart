import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/pos_layout_preference.dart';
import 'package:modern_offline_pos/features/settings/pos_layout_settings_screen.dart';

void main() {
  test('legacy shortcut preference migrates without changing business data',
      () async {
    SharedPreferences.setMockInitialValues(
        {'pos.workspace.showShortcutBar': false});
    final preference = PosLayoutPreference.instance;
    await preference.load(force: true);
    expect(preference.showVisualCatalogShortcutBar, isFalse);
    expect(preference.showScanFirstShortcutBar, isFalse);
    await preference.setWorkspaceOption('showScanFirstShortcutBar', true);
    await preference.load(force: true);
    expect(preference.showVisualCatalogShortcutBar, isFalse);
    expect(preference.showScanFirstShortcutBar, isTrue);
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      await preference.load(force: true);
    });
  });

  testWidgets(
      'workspace settings persist and shortcut strip reflects sale state',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preference = PosLayoutPreference.instance;
    await preference.load(force: true);
    expect(preference.showVisualCatalogShortcutBar, isFalse);
    expect(preference.showScanFirstShortcutBar, isTrue);
    await preference.setLayout(PosLayoutType.scanFirst);
    await preference.setWorkspaceOption('startFocused', false);
    addTearDown(() async {
      await preference.setLayout(PosLayoutType.visualCatalog);
      await preference.setWorkspaceOption('startFocused', false);
      await preference.setWorkspaceOption(
          'showVisualCatalogShortcutBar', false);
      await preference.setWorkspaceOption('showScanFirstShortcutBar', true);
    });
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: PosLayoutSettingsScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pos-start-focused-setting')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const Key('pos-visual-shortcut-bar-setting')), 300);
    await tester.tap(find.byKey(const Key('pos-visual-shortcut-bar-setting')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pos.workspace.startFocused'), isTrue);
    expect(
        prefs.getBool('pos.workspace.visualCatalog.showShortcutBar'), isTrue);
    expect(preference.showScanFirstShortcutBar, isTrue);
    expect(find.byKey(const Key('pos-visual-shortcut-bar-setting')),
        findsOneWidget);
    expect(
        find.byKey(const Key('pos-scan-shortcut-bar-setting')), findsOneWidget);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Place?', 'City');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: CheckoutScreen(
            repository: pos,
            user: auth.current!,
            auth: auth,
            focusMode: true,
            onToggleFocus: () {})));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pos-shortcut-bar')), findsOneWidget);
    expect(find.text('Exit focus'), findsWidgets);
    expect(
        find.descendant(
            of: find.byKey(const Key('pos-shortcut-bar')),
            matching: find.text('Del')),
        findsNothing);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Qty'))
            .onPressed,
        isNull);
    expect(find.text('F6'), findsOneWidget);
    expect(find.text('F7'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Pay'))
            .onPressed,
        isNull);
    await preference.setWorkspaceOption('showScanFirstShortcutBar', false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pos-shortcut-bar')), findsNothing);
    expect(prefs.getBool('pos.workspace.scanFirst.showShortcutBar'), isFalse);
  });

  testWidgets(
      'layout switch preserves cart and scan-first repeats and reports unknown codes',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preference = PosLayoutPreference.instance;
    await preference.load(force: true);
    await preference.setLayout(PosLayoutType.visualCatalog);
    addTearDown(() => preference.setLayout(PosLayoutType.visualCatalog));
    tester.view.physicalSize = const Size(1366, 768);
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
        name: 'Soap',
        barcode: '12345',
        sku: 'SOAP',
        priceCents: 500,
        costCents: 100,
        startingStock: 5);
    var focusToggles = 0;
    await tester.pumpWidget(MaterialApp(
        home: CheckoutScreen(
            repository: pos,
            user: auth.current!,
            auth: auth,
            onToggleFocus: () => focusToggles++)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('product-search')), findsOneWidget);
    expect(find.byKey(const Key('pos-shortcut-bar')), findsNothing);
    final fullWorkspaceHeight =
        tester.getSize(find.byKey(const Key('desktop-pos-two-pane'))).height;
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('CART'), findsNothing);
    expect(find.text('Product lookup'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await preference.setWorkspaceOption('showVisualCatalogShortcutBar', true);
    await tester.pumpAndSettle();
    final visualBar = find.byKey(const Key('pos-shortcut-bar'));
    expect(visualBar, findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('desktop-pos-two-pane'))).height,
        lessThan(fullWorkspaceHeight));
    for (final key in ['F4', 'F5', 'Del', '+/-', '\u2191\u2193']) {
      expect(find.descendant(of: visualBar, matching: find.text(key)),
          findsNothing);
    }
    await preference.setWorkspaceOption('showVisualCatalogShortcutBar', false);
    await tester.pumpAndSettle();
    expect(visualBar, findsNothing);
    expect(tester.getSize(find.byKey(const Key('desktop-pos-two-pane'))).height,
        fullWorkspaceHeight);
    await tester.enterText(
        find.byKey(const Key('barcode-serial-input')), '12345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Pay ₱5.00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('customer-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Walk-in details'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('quick-customer-name')), 'Juan');
    await tester.tap(find.text('Use walk-in'));
    await tester.pumpAndSettle();
    await preference.setLayout(PosLayoutType.scanFirst);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scan-first-input')), findsOneWidget);
    expect(find.textContaining('Juan'), findsWidgets);
    final scanBar = find.byKey(const Key('pos-shortcut-bar'));
    expect(scanBar, findsOneWidget);
    for (final key in ['F4', 'F5', 'Del', '+/-', '\u2191\u2193']) {
      expect(find.descendant(of: scanBar, matching: find.text(key)),
          findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(focusToggles, 1);
    expect(find.text('Pay ₱5.00  F8'), findsOneWidget);
    final input = find.byKey(const Key('scan-first-input'));
    await tester.enterText(input, 'SOAP');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Pay ₱10.00  F8'), findsOneWidget);
    expect(find.byKey(const Key('scan-checkout-footer')), findsOneWidget);
    expect(find.text('Hold  F6'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('scan-checkout-footer')),
            matching: find.text('TOTAL')),
        findsOneWidget);
    expect(find.byTooltip('Increase quantity'), findsOneWidget);
    expect(find.byTooltip('Decrease quantity'), findsOneWidget);
    expect(find.byTooltip('Remove item'), findsOneWidget);
    expect(find.byKey(const Key('last-scanned-card')), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    await tester.enterText(input, 'missing');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unknown-barcode-panel')), findsOneWidget);
    expect(find.text('Search products'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unknown-barcode-panel')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('CART'), findsOneWidget);
    expect(find.text('Product lookup'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scan-payment-cash')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(find.text('Quantity: Soap'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f4);
    await tester.pumpAndSettle();
    expect(find.text('Product lookup'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(find.text('Walk-in details'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f3);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    await tester.enterText(input, '');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: scanBar, matching: find.text('Del')), findsNothing);
    expect(find.text('Ready to scan'), findsOneWidget);
    expect(find.text('Scan a barcode or press F4 to search products.'),
        findsOneWidget);
  });

  testWidgets(
      'settings preview does not apply and scan-first fits desktop widths',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    SharedPreferences.setMockInitialValues({});
    final preference = PosLayoutPreference.instance;
    await preference.setLayout(PosLayoutType.visualCatalog);
    addTearDown(() => preference.setLayout(PosLayoutType.visualCatalog));
    await tester.pumpWidget(const MaterialApp(home: PosLayoutSettingsScreen()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(TextButton, 'Preview').last);
    await tester.tap(find.widgetWithText(TextButton, 'Preview').last);
    await tester.pumpAndSettle();
    expect(preference.layout, PosLayoutType.visualCatalog);
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Apply'));
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(preference.layout, PosLayoutType.scanFirst);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pos.checkoutLayout'), 'scanFirst');

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Place?', 'Baguio');
    await auth.login(owner, 'ownerPassword123');
    final pos = PosRepository(db);
    for (final size in [
      const Size(1366, 768),
      const Size(1600, 900),
      const Size(1920, 1080)
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
          home: CheckoutScreen(
              repository: pos, user: auth.current!, auth: auth)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-first-input')), findsOneWidget);
      expect(find.byKey(const Key('pay-button')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
