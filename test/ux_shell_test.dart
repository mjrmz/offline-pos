import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/dashboard/home_screen.dart';
import 'package:modern_offline_pos/shared/theme/app_theme.dart';

void main() {
  Future<void> mount(WidgetTester tester, Size size,
      {ThemeMode themeMode = ThemeMode.light, bool openShift = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(owner, 'ownerPassword123');
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            onChanged: () {})));
    await tester.pumpAndSettle();
    if (openShift) {
      await tester.enterText(find.byKey(const Key('pos-opening-cash')), '0');
      await tester.pump();
      await tester.tap(find.byKey(const Key('pos-open-shift')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('desktop groups destinations and keeps cart beside catalog',
      (tester) async {
    await mount(tester, const Size(1280, 900), openShift: true);
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    expect(find.byTooltip('Inventory'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pos-sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('SELL'), findsOneWidget);
    expect(find.text('INVENTORY'), findsOneWidget);
    expect(find.text('ADMIN & SETTINGS'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
    expect(find.text('Point of Sale'), findsOneWidget);
    expect(find.textContaining('Vertex POS  /'), findsNothing);
    await tester.tap(find.byKey(const Key('pos-sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('SELL'), findsNothing);
    expect(find.byTooltip('Inventory'), findsOneWidget);
  });

  testWidgets('mobile keeps five primary destinations and exposes More',
      (tester) async {
    await mount(tester, const Size(390, 844));
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 5);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Stock Receiving'), findsNothing);
    expect(find.text('Inventory'), findsWidgets);
    expect(find.text('Backup & Recovery'), findsNothing);
  });

  testWidgets('global shift status keeps cashier in POS when closed',
      (tester) async {
    await mount(tester, const Size(1280, 900));
    await tester.tap(find.byKey(const Key('global-shift-status')));
    await tester.pumpAndSettle();
    expect(find.text('Open your cashier shift'), findsOneWidget);
    expect(find.byKey(const Key('pos-opening-cash')), findsOneWidget);
  });

  testWidgets('POS restores only a genuinely open session across app mounts',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(owner, 'ownerPassword123');
    final cash = CashSessionRepository(db);
    Future<void> mountApp() async {
      await tester.pumpWidget(MaterialApp(
          home: HomeScreen(
              auth: auth,
              pos: PosRepository(db),
              salesRepository: SalesRepository(db),
              onChanged: () {})));
      await tester.pumpAndSettle();
    }

    await mountApp();
    expect(find.byKey(const Key('pos-opening-cash')), findsOneWidget);
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsNothing);
    await tester.enterText(find.byKey(const Key('pos-opening-cash')), '1000');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pos-open-shift')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const Key('pos-open-shift')));
    await tester.pumpAndSettle();
    expect((await cash.active())?.startingCashCents, 100000);
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
    expect(find.textContaining('Shift open'), findsOneWidget);
    await tester.tap(find.byTooltip('Cash session'));
    await tester.pumpAndSettle();
    expect(find.text('CURRENT SHIFT'), findsOneWidget);
    expect(find.text('₱1,000.00'), findsWidgets);
    expect(find.text('Shift open · Expected ₱1,000.00'), findsOneWidget);
    await tester.tap(find.byTooltip('POS'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await mountApp();
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
    final cashier = await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.logout();
    await auth.login(cashier, '1234');
    await tester.pumpWidget(const SizedBox.shrink());
    await mountApp();
    expect(find.text('Another cashier has an open shift'), findsOneWidget);
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsNothing);
    await auth.logout();
    await auth.login(owner, 'ownerPassword123');
    await tester.pumpWidget(const SizedBox.shrink());
    await mountApp();
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
    await cash.close(auth.current!, 100000);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pos-opening-cash')), findsOneWidget);
    expect(find.textContaining('Shift open'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await mountApp();
    expect(find.byKey(const Key('pos-opening-cash')), findsOneWidget);
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsNothing);
    expect(find.textContaining('Shift open'), findsNothing);
  });

  testWidgets('Inventory is one destination with four internal views',
      (tester) async {
    await mount(tester, const Size(1280, 900));
    await tester.tap(find.byTooltip('Inventory'));
    await tester.pumpAndSettle();
    expect(find.text('Inventory overview'), findsNothing);
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Products'), findsWidgets);
    expect(find.text('Receiving'), findsWidgets);
    expect(find.text('Movements'), findsWidgets);
    await tester.tap(find.text('Products').first);
    await tester.pumpAndSettle();
    expect(find.text('Add product'), findsWidgets);
    await tester.tap(find.text('Receiving').first);
    await tester.pumpAndSettle();
    expect(find.text('Recent receiving'), findsOneWidget);
    await tester.tap(find.text('New receiving'));
    await tester.pumpAndSettle();
    expect(find.text('Delivery details'), findsWidgets);
    await tester.tap(find.text('Movements').first);
    await tester.pumpAndSettle();
    expect(find.text('No inventory movements yet'), findsOneWidget);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
        'desktop shell, POS, Inventory and cash session render in ${mode.name}',
        (tester) async {
      await mount(tester, const Size(1366, 768),
          themeMode: mode, openShift: true);
      expect(Theme.of(tester.element(find.byType(HomeScreen))).brightness,
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light);
      expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pos-sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('SELL'), findsOneWidget);
      await tester.tap(find.byTooltip('Inventory'));
      await tester.pumpAndSettle();
      expect(find.text('Products'), findsWidgets);
      await tester.tap(find.byKey(const Key('global-shift-status')));
      await tester.pumpAndSettle();
      expect(find.text('CURRENT SHIFT'), findsOneWidget);
      await tester.tap(find.text('View details'));
      await tester.pumpAndSettle();
      expect(find.text('Cash Session'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow shell renders in ${mode.name}', (tester) async {
      await mount(tester, const Size(390, 844), themeMode: mode);
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('Inventory'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
