import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/operational_summary_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/reports/operational_summary_screen.dart';
import 'package:modern_offline_pos/shared/theme/app_theme.dart';
import 'package:modern_offline_pos/shared/widgets/app_workspace.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
        'Operations has four aligned KPI tiles and drill-downs in ${mode.name}',
        (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final pos = PosRepository(db);
      await pos.saveProduct(name: 'Empty item', priceCents: 100, costCents: 0);
      await pos.saveProduct(
          name: 'Low item',
          priceCents: 100,
          costCents: 0,
          startingStock: 2,
          lowStockThreshold: 3);
      String? filter;
      var rmaOpened = false;
      var expiryOpened = false;
      var layawayOpened = false;
      var customersOpened = false;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: OperationalSummaryScreen(
          repository: OperationalSummaryRepository(db),
          user: const ActiveUser('owner', 'Owner', UserRole.owner),
          onInventory: (value) => filter = value,
          onRma: () => rmaOpened = true,
          onExpiry: () => expiryOpened = true,
          onLayaway: () => layawayOpened = true,
          onCustomers: () => customersOpened = true,
        ),
      ));
      await tester.pumpAndSettle();
      final keys = [
        'operations-kpi-out-of-stock',
        'operations-kpi-low-stock',
        'operations-kpi-expiring-soon',
        'operations-kpi-open-rma',
      ];
      final rects =
          keys.map((key) => tester.getRect(find.byKey(Key(key)))).toList();
      expect(rects.map((rect) => rect.top).toSet().length, 1);
      expect(rects.last.right, lessThanOrEqualTo(1366));
      expect(find.byType(AppMetricTile), findsNWidgets(4));
      expect(find.text('Inventory attention'), findsOneWidget);
      expect(find.text('Operational workload'), findsOneWidget);
      expect(
          find.byKey(const Key('operations-bar-out-of-stock')), findsOneWidget);
      expect(find.byKey(const Key('operations-bar-credit-customers')),
          findsOneWidget);
      final outBar = find.byKey(const Key('operations-bar-out-of-stock'));
      expect(find.descendant(of: outBar, matching: find.text('1')),
          findsOneWidget);
      await tester.tap(find.byKey(const Key('operations-bar-active-layaways')));
      expect(layawayOpened, isTrue);
      await tester
          .tap(find.byKey(const Key('operations-bar-credit-customers')));
      expect(customersOpened, isTrue);
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('Financial & customer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('operations-kpi-out-of-stock')));
      expect(filter, 'Out of stock');
      await tester.tap(find.byKey(const Key('operations-kpi-low-stock')));
      expect(filter, 'Low stock');
      await tester.tap(find.byKey(const Key('operations-kpi-open-rma')));
      expect(rmaOpened, isTrue);
      await tester.tap(find.byKey(const Key('operations-kpi-expiring-soon')));
      expect(expiryOpened, isTrue);
      await tester.scrollUntilVisible(find.text('Expiry'), 250,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Expiry'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('RMA / service'), 250,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('RMA / service'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Operations shows compact alerts, healthy expiry and drill-down',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final pos = PosRepository(db);
    await pos.saveProduct(name: 'Empty item', priceCents: 100, costCents: 0);
    await pos.saveProduct(
        name: 'Low item',
        priceCents: 100,
        costCents: 0,
        startingStock: 2,
        lowStockThreshold: 3);
    String? filter;
    await tester.pumpWidget(MaterialApp(
        home: OperationalSummaryScreen(
      repository: OperationalSummaryRepository(db),
      user: const ActiveUser('owner', 'Owner', UserRole.owner),
      onInventory: (value) => filter = value,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Operations Dashboard'), findsNothing);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Financial & customer'), findsOneWidget);
    expect(find.text('Inventory attention'), findsOneWidget);
    expect(find.text('Empty item'), findsOneWidget);
    expect(find.text('0 pcs available'), findsOneWidget);
    expect(find.textContaining('physical'), findsNothing);
    expect(find.textContaining('2 pcs available'), findsOneWidget);
    await tester.tap(find.text('Empty item'));
    expect(filter, 'Out of stock');
    await tester.scrollUntilVisible(find.text('Expiry'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('No expiry issues'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh dashboard'));
    await tester.pumpAndSettle();
    expect(find.text('Needs attention'), findsOneWidget);
  });

  testWidgets('Operations stacks panels on narrow screens', (tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
        home: OperationalSummaryScreen(
      repository: OperationalSummaryRepository(db),
      user: const ActiveUser('owner', 'Owner', UserRole.owner),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Operations are clear'), findsOneWidget);
    final first =
        tester.getRect(find.byKey(const Key('operations-kpi-out-of-stock')));
    final second =
        tester.getRect(find.byKey(const Key('operations-kpi-low-stock')));
    final third =
        tester.getRect(find.byKey(const Key('operations-kpi-expiring-soon')));
    expect(first.top, second.top);
    expect(third.top, greaterThan(first.top));
    expect(second.right, lessThanOrEqualTo(400));
    await tester.scrollUntilVisible(find.text('Needs attention'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(1600, 900), const Size(1920, 1080)]) {
    testWidgets('Operations charts fit ${size.width}x${size.height}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await tester.pumpWidget(MaterialApp(
          home: OperationalSummaryScreen(
        repository: OperationalSummaryRepository(db),
        user: const ActiveUser('owner', 'Owner', UserRole.owner),
      )));
      await tester.pumpAndSettle();
      final left = tester.getRect(find.text('Inventory attention'));
      final right = tester.getRect(find.text('Operational workload'));
      expect(left.top, right.top);
      expect(right.right, lessThan(size.width));
      expect(tester.takeException(), isNull);
    });
  }
}
