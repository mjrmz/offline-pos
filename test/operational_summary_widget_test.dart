import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/operational_summary_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/reports/operational_summary_screen.dart';
import 'package:modern_offline_pos/shared/theme/app_theme.dart';

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
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        home: OperationalSummaryScreen(
          repository: OperationalSummaryRepository(db),
          user: const ActiveUser('owner', 'Owner', UserRole.owner),
          onInventory: (value) => filter = value,
          onRma: () => rmaOpened = true,
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
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('Financial & customer'), findsOneWidget);
      expect(find.text('Expiry'), findsOneWidget);
      expect(find.text('RMA / service'), findsOneWidget);
      await tester.tap(find.byKey(const Key('operations-kpi-out-of-stock')));
      expect(filter, 'Out of stock');
      await tester.tap(find.byKey(const Key('operations-kpi-low-stock')));
      expect(filter, 'Low stock');
      await tester.tap(find.byKey(const Key('operations-kpi-open-rma')));
      expect(rmaOpened, isTrue);
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
    expect(find.text('RMA / service'), findsOneWidget);
    expect(find.text('No expiry issues'), findsNothing);
    expect(find.text('✓ No expiry issues'), findsOneWidget);
    expect(find.text('Empty item'), findsOneWidget);
    expect(find.text('0 pcs available'), findsOneWidget);
    expect(find.textContaining('physical'), findsNothing);
    expect(find.textContaining('2 pcs available'), findsOneWidget);
    await tester.tap(find.text('Empty item'));
    expect(filter, 'Out of stock');
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
}
