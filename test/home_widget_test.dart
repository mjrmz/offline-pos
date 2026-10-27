import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/dashboard/home_screen.dart';
import 'package:modern_offline_pos/features/inventory/stock_receiving_screen.dart';
import 'package:modern_offline_pos/features/inventory/expiry_monitor_screen.dart';

void main() {
  void useDesktopSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final (width, height) in <(double, double)>[
    (1366, 768),
    (1600, 900),
    (1920, 1080),
  ]) {
    testWidgets('Home with sidebar fits $width x $height', (tester) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final ownerId = await auth.bootstrap(
          'Owner', 'ownerPassword123', 'Question?', 'answer');
      await auth.login(ownerId, 'ownerPassword123');
      await tester.pumpWidget(MaterialApp(
          home: HomeScreen(
              auth: auth,
              pos: PosRepository(db),
              salesRepository: SalesRepository(db),
              onChanged: () {})));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('full-height-sidebar')), findsOneWidget);
      expect(find.text('Quick actions'), findsOneWidget);
    });
  }

  testWidgets('Home receive stock action opens Receiving', (tester) async {
    useDesktopSize(tester);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Receive stock'));
    await tester.pumpAndSettle();
    expect(find.byType(StockReceivingScreen), findsOneWidget);
  });

  testWidgets('Home near expiry alert opens Expiry Monitor', (tester) async {
    useDesktopSize(tester);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final now = DateTime.now();
    final expiry =
        DateTime(now.year, now.month, now.day + 3).millisecondsSinceEpoch ~/
            1000;
    final received = now.millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO products(id,name,price_cents,created_at) VALUES ('milk','Milk',100,?)",
        [received]);
    await db.customStatement('''INSERT INTO inventory_layers
      (id,product_id,quantity_received_milli,quantity_remaining_milli,
       unit_cost_cents,batch_number,expiry_date,received_at)
       VALUES ('batch','milk',1000,1000,50,'B1',?,?)''', [expiry, received]);
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('1 batch near expiry'));
    await tester.tap(find.text('1 batch near expiry'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpiryMonitorScreen), findsOneWidget);
  });

  testWidgets('popup dialog cancel survives an application root rebuild',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    var refreshCount = 0;
    late StateSetter rebuildRoot;
    await tester.pumpWidget(StatefulBuilder(builder: (context, update) {
      rebuildRoot = update;
      return MaterialApp(
          home: HomeScreen(
        auth: auth,
        pos: PosRepository(db),
        salesRepository: SalesRepository(db),
        onChanged: () => update(() {}),
        refreshLicense: (_) async {
          refreshCount++;
          update(() {});
        },
      ));
    }));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh license'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    rebuildRoot(() {});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(refreshCount, 0);
    expect(auth.current?.id, id);
  });

  testWidgets('refresh license cancel keeps owner signed in', (tester) async {
    useDesktopSize(tester);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    var refreshes = 0;
    var changes = 0;
    String? refreshedKey;
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            refreshLicense: (key) async {
              refreshes++;
              refreshedKey = key;
            },
            onChanged: () {
              changes++;
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(refreshes, 0);
    expect(changes, 0);
    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh license'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'sample-key');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(refreshes, 0);
    expect(changes, 0);
    expect(auth.current?.id, ownerId);
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh license'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'another-key');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(refreshes, 0);
    expect(changes, 0);

    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh license'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(refreshes, 0);

    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh license'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 350));
    await tester.pumpAndSettle();
    expect(refreshes, 0);
    expect(changes, 0);

    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh license'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'valid-key');
    await tester.tap(find.text('Refresh').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(refreshes, 1);
    expect(refreshedKey, 'valid-key');
    expect(auth.current?.id, ownerId);
  });
  testWidgets('cashier and manager do not get recovery tools', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final cashierId =
        await auth.createUser('Cashier', UserRole.cashier, '1234');
    final managerId = await auth.createUser(
        'Manager', UserRole.manager, 'managerPassword123');
    await auth.logout();
    for (final (id, credential) in [
      (cashierId, '1234'),
      (managerId, 'managerPassword123'),
    ]) {
      await auth.login(id, credential);
      await tester.pumpWidget(MaterialApp(
          home: HomeScreen(
              auth: auth,
              pos: PosRepository(db),
              salesRepository: SalesRepository(db),
              recoveryScreen: const Text('Recovery probe'),
              onChanged: () {})));
      await tester.pumpAndSettle();
      expect(find.text('Recovery'), findsNothing);
      expect(find.text('Settings'), findsNothing);
      expect(find.text('Recovery probe'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await auth.logout();
    }
  });

  testWidgets('owner opens Settings then Business Features', (tester) async {
    useDesktopSize(tester);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byTooltip('Settings'), 150,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const Key('pos-shift-status')), findsNothing);
    await tester.tap(find.descendant(
        of: find.byKey(const Key('settings-navigation')),
        matching: find.text('Inventory')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Product capabilities'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Choose any combination'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('recovery scan widget mounts only when owner opens its tab',
      (tester) async {
    useDesktopSize(tester);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    var recoveryBuilds = 0;
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            recoveryScreen: Builder(builder: (_) {
              recoveryBuilds++;
              return const Text('Recovery probe');
            }),
            onChanged: () {})));
    await tester.pumpAndSettle();
    expect(recoveryBuilds, 0);
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byKey(const Key('settings-navigation')),
        matching: find.text('System')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup & Recovery'));
    await tester.pumpAndSettle();
    expect(recoveryBuilds, greaterThan(0));
    expect(find.text('Recovery probe'), findsOneWidget);
  });

  testWidgets('sale appears when history and reports tabs open',
      (tester) async {
    useDesktopSize(tester);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final pos = PosRepository(db);
    await pos.saveProduct(
        name: 'Coke', priceCents: 4000, costCents: 1000, startingStock: 3);
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: pos,
            salesRepository: SalesRepository(db),
            onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('POS'));
    await tester.pumpAndSettle();
    expect(find.text('Open your cashier shift'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('pos-opening-cash')), '0');
    await tester.pump();
    await tester.tap(find.byKey(const Key('pos-open-shift')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Coke'));
    await tester.pump();
    expect(find.text('TOTAL'), findsOneWidget);
    expect(find.text('₱40.00'), findsWidgets);
    await tester.enterText(
        find.widgetWithText(TextField, 'Cash tendered'), '40');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('pay-button')));
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('pay-button')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const Key('pay-button')));
    await tester.pumpAndSettle();
    expect(find.text('SALE COMPLETE'), findsOneWidget);
    expect(find.textContaining(RegExp(r'Shift open.*40\.00')), findsOneWidget);
    await tester.scrollUntilVisible(find.byTooltip('Cash session'), 150,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Cash session'));
    await tester.pumpAndSettle();
    expect(find.text('CURRENT SHIFT'), findsOneWidget);
    expect(find.textContaining('40.00'), findsWidgets);
    expect(find.byKey(const Key('pos-shift-status')), findsNothing);
    final sale = (await db.select(db.sales).get()).single;
    expect(sale.cashierId, ownerId);
    await tester.scrollUntilVisible(find.byTooltip('Sales History'), -150,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Sales History'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Receipt #POS-'), findsWidgets);
    expect(find.textContaining(sale.id), findsNothing);
    await tester.scrollUntilVisible(find.byTooltip('Reports'), 150,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Reports'));
    await tester.pumpAndSettle();
    expect(find.text('Net sales'), findsWidgets);
    await tester.tap(find.text('Sales').last);
    await tester.pumpAndSettle();
    expect(find.text('Gross sales'), findsWidgets);
  });
}
