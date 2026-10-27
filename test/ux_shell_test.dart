import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:modern_offline_pos/features/pos_checkout/pos_layout_preference.dart';
import 'package:modern_offline_pos/shared/theme/app_theme.dart';
import 'package:modern_offline_pos/shared/theme/theme_mode_controller.dart';
import 'package:modern_offline_pos/shared/widgets/app_workspace.dart';

void main() {
  Future<void> mount(WidgetTester tester, Size size,
      {ThemeMode themeMode = ThemeMode.light,
      bool openShift = false,
      SidebarColorPreset? sidebarColor}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(owner, 'ownerPassword123');
    final appearance = ThemeModeController();
    if (sidebarColor != null) await appearance.setSidebarColor(sidebarColor);
    await tester.pumpWidget(AppThemeController(
        controller: appearance,
        child: MaterialApp(
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: themeMode,
            home: HomeScreen(
                auth: auth,
                pos: PosRepository(db),
                salesRepository: SalesRepository(db),
                onChanged: () {}))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('POS'));
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
    await tester.scrollUntilVisible(find.text('ADMIN & SETTINGS'), 200,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    expect(find.text('ADMIN & SETTINGS'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
    expect(find.text('Point of Sale'), findsOneWidget);
    expect(find.byKey(const Key('sidebar-business-name')), findsOneWidget);
    expect(find.byKey(const Key('pos-shift-status')), findsOneWidget);
    expect(find.byKey(const Key('sidebar-account')), findsOneWidget);
    expect(find.textContaining('Vertex POS  /'), findsNothing);
    await tester.tap(find.byKey(const Key('pos-sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('SELL'), findsNothing);
    expect(find.byKey(const Key('sidebar-business-name')), findsNothing);
    expect(find.byKey(const Key('sidebar-brand-logo')), findsOneWidget);
    expect(find.byTooltip('Inventory'), findsOneWidget);
  });

  testWidgets('sidebar fills workspace and account menu stays at bottom',
      (tester) async {
    await mount(tester, const Size(1366, 768), openShift: true);
    final sidebar = find.byKey(const Key('full-height-sidebar'));
    final account = find.byKey(const Key('sidebar-account'));
    expect(tester.getTopLeft(sidebar).dy, 0);
    expect(tester.getSize(sidebar).height, 768);
    expect(tester.getBottomLeft(account).dy, 768);
    expect(find.byKey(const Key('sidebar-navigation')), findsOneWidget);
    expect(
        find.descendant(
            of: account, matching: find.byIcon(Icons.account_circle_outlined)),
        findsOneWidget);
    expect(find.text('Owner'), findsNothing);
    await tester.tap(account);
    await tester.pumpAndSettle();
    expect(find.text('Lock / Switch user'), findsOneWidget);
    expect(find.text('Logout'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Logout'), findsNothing);
    await tester.tap(find.byTooltip('Sales History'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pos-shift-status')), findsNothing);
    expect(tester.getTopLeft(sidebar).dy, 0);
    expect(tester.getBottomLeft(account).dy, 768);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light sidebar keeps account footer readable', (tester) async {
    await mount(tester, const Size(1366, 768),
        sidebarColor: SidebarColorPreset.light);
    final sidebar =
        tester.widget<Material>(find.byKey(const Key('full-height-sidebar')));
    expect(sidebar.color, SidebarColorPreset.light.color);
    final icon = tester.widget<Icon>(find.descendant(
        of: find.byKey(const Key('sidebar-account')),
        matching: find.byIcon(Icons.account_circle_outlined)));
    expect(icon.color, SidebarColorPreset.light.foreground);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'F11 and visible control toggle POS focus without replacing checkout',
      (tester) async {
    await mount(tester, const Size(1366, 768), openShift: true);
    expect(find.byTooltip('Inventory'), findsOneWidget);
    expect(find.byKey(const Key('pos-shortcut-bar')), findsNothing);
    final checkout = find.byKey(const Key('desktop-pos-two-pane'));
    expect(checkout, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Inventory'), findsNothing);
    expect(checkout, findsOneWidget);
    expect(find.text('Exit focus mode · F11'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Inventory'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pos-focus-toggle')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Inventory'), findsNothing);
    for (final size in [const Size(1600, 900), const Size(1920, 1080)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pos-shortcut-bar')), findsNothing);
      expect(find.byKey(const Key('desktop-pos-two-pane')), findsOneWidget);
      expect(find.byTooltip('Inventory'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('quotation editor keeps the desktop application shell',
      (tester) async {
    await mount(tester, const Size(1600, 900));
    await tester.tap(find.byTooltip('Quotations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New quotation').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pos-sidebar-toggle')), findsOneWidget);
    expect(find.byKey(const Key('pos-shift-status')), findsNothing);
    expect(find.byKey(const Key('sidebar-account')), findsOneWidget);
    expect(find.text('Build a customer price offer before checkout.'),
        findsOneWidget);
    expect(find.text('Quotation summary'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile keeps five primary destinations and exposes More',
      (tester) async {
    await mount(tester, const Size(390, 844));
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 6);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Stock Receiving'), findsNothing);
    expect(find.text('Inventory'), findsWidgets);
    expect(find.text('Backup & Recovery'), findsNothing);
  });

  testWidgets('Settings keeps inventory health and product features inline',
      (tester) async {
    await mount(tester, const Size(1366, 768));
    await tester.scrollUntilVisible(find.byTooltip('Settings'), 200,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(
        find.text('Manage your application, business, and device preferences.'),
        findsOneWidget);
    expect(find.text('Business identity'), findsOneWidget);
    expect(find.text('Sidebar preview'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byKey(const Key('settings-navigation')),
        matching: find.text('Inventory')));
    await tester.pumpAndSettle();
    expect(find.text('Stock health'), findsWidgets);
    expect(find.text('Slow moving after (days)'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.text('Product capabilities'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Choose any combination'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings embeds team and receipt hardware screens',
      (tester) async {
    await mount(tester, const Size(1600, 900));
    await tester.scrollUntilVisible(find.byTooltip('Settings'), 200,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Team & Access'));
    await tester.pumpAndSettle();
    expect(find.text('Roles & Permissions'), findsOneWidget);
    expect(find.text('Add user'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tester.tap(find.text('Receipt & Hardware'));
    await tester.pumpAndSettle();
    expect(find.text('RECEIPT PREVIEW'), findsOneWidget);
    await tester.tap(find.text('Printer'));
    await tester.pumpAndSettle();
    expect(find.text('Enable printer'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('global shift status keeps cashier in POS when closed',
      (tester) async {
    await mount(tester, const Size(1280, 900));
    await tester.tap(find.byKey(const Key('pos-shift-status')));
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
      await tester.tap(find.byTooltip('POS'));
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
    await tester.scrollUntilVisible(find.byTooltip('Cash session'), 200,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Cash session'));
    await tester.pumpAndSettle();
    expect(find.text('CURRENT SHIFT'), findsOneWidget);
    expect(find.text('₱1,000.00'), findsWidgets);
    expect(find.byKey(const Key('pos-shift-status')), findsNothing);
    await tester.scrollUntilVisible(find.byTooltip('POS'), -200,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
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
    await tester.scrollUntilVisible(find.text('Movements'), 300,
        scrollable: find.descendant(
            of: find.byType(AppWorkspaceTabs),
            matching: find.byType(Scrollable)));
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
      expect(find.byKey(const Key('pos-shift-status')), findsNothing);
      await tester.tap(find.byTooltip('POS'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pos-shift-status')));
      await tester.pumpAndSettle();
      expect(find.text('CURRENT SHIFT'), findsOneWidget);
      await tester.tap(find.text('View details'));
      await tester.pumpAndSettle();
      expect(find.text('Cash Session'), findsOneWidget);
      expect(
          find.ancestor(
              of: find.text('Cash Session'), matching: find.byType(AppBar)),
          findsNothing);
      expect(find.text('Expected cash'), findsWidgets);
      expect(find.byKey(const Key('pos-shift-status')), findsNothing);
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
