import 'dart:ui' show PointerDeviceKind;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/sales_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';
import 'package:modern_offline_pos/features/reports/reports_screen.dart';
import 'package:modern_offline_pos/features/reports/report_widgets.dart';
import 'package:modern_offline_pos/features/reports/overview_charts.dart';

void main() {
  testWidgets(
      'Overview top products fit five rows without fixed-height overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 600,
                child: OverviewBars(values: {
                  for (var i = 0; i < 12; i++) 'Product $i': 120000 - i * 1000
                }, emptyMessage: 'Empty')))));
    expect(find.text('Product 0'), findsOneWidget);
    expect(find.text('Product 4'), findsOneWidget);
    expect(find.text('Product 5'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(1366, 768),
    const Size(1600, 900),
    const Size(1920, 1080)
  ]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets(
          'Reports tabs and period fit ${size.width}x${size.height} $mode',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final auth = AuthService(AuthRepository(db));
        final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
        await auth.login(id, 'password123');
        final supplier = await DirectoryRepository(db)
            .saveSupplier(auth.current!, name: 'Supplier');
        final pos = PosRepository(db);
        final productId = await pos.saveProduct(
            name: 'Mouse', priceCents: 10000, costCents: 6000);
        await StockReceivingRepository(db).receive(auth.current!, supplier.id,
            [ReceivingLineRequest(productId, 1000, 6000)]);
        await pos.completeCashSale([SaleLineRequest(productId, 1)], 10000, id);
        await StockCountRepository(db).adjust(
            auth.current!,
            AdjustmentRequest(productId, 1000, 'Stock found',
                unitCostCents: 6000));
        await tester.pumpWidget(MaterialApp(
            themeMode: mode,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            home:
                ReportsScreen(sales: SalesService(SalesRepository(db), auth))));
        await tester.pumpAndSettle();
        expect(
            find.widgetWithText(ReportMetricTile, 'Net sales'), findsOneWidget);
        expect(find.byType(ReportMetricTile), findsNWidgets(6));
        expect(find.text('Business performance'), findsOneWidget);
        expect(find.byType(OverviewPerformanceChart), findsOneWidget);
        expect(find.text('Payment method mix'), findsOneWidget);
        expect(find.text('Top products by net sales'), findsOneWidget);
        expect(find.text('Expense mix'), findsOneWidget);
        expect(find.text('Sales by category'), findsOneWidget);
        expect(find.text('Business highlights'), findsOneWidget);
        expect(find.text('DAILY NET SALES'), findsNothing);
        expect(find.text('EXPENSE BY CATEGORY'), findsNothing);
        expect(find.text('Inventory adjustments'), findsOneWidget);
        expect(find.text('LOW STOCK'), findsNothing);
        await tester.ensureVisible(find.byType(OverviewPerformanceChart));
        final chart = find.byType(OverviewPerformanceChart);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(chart));
        await mouse.moveTo(tester.getCenter(chart));
        await tester.pump();
        expect(find.byType(OverviewTooltip), findsOneWidget);
        expect(find.text('Gross sales'), findsWidgets);
        expect(find.text('Net sales'), findsWidgets);
        expect(find.text('Refunds'), findsWidgets);
        expect(find.text('Expenses'), findsWidgets);
        expect(find.text('₱100.00'), findsWidgets);
        await mouse.removePointer();
        await tester.ensureVisible(find.text('View daily details'));
        await tester.tap(find.text('View daily details'));
        await tester.pumpAndSettle();
        expect(find.text('Daily sales details'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView).first, const Offset(0, 1200));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sales').last);
        await tester.pumpAndSettle();
        expect(find.text('SALES TREND'), findsOneWidget);
        expect(find.byType(ReportTrendChart), findsOneWidget);
        expect(find.text('SALES BY PRODUCT'), findsOneWidget);
        await tester.tap(find.text('Profit & Loss'));
        await tester.pumpAndSettle();
        expect(find.text('Management Profit & Loss'), findsOneWidget);
        expect(find.text('INVENTORY ADJUSTMENTS'), findsOneWidget);
        expect(find.text('Stock found'), findsOneWidget);
        expect(find.text('PRODUCT PROFITABILITY'), findsOneWidget);
        await tester.tap(find.text('Expenses'));
        await tester.pumpAndSettle();
        expect(find.text('EXPENSE RECORDS'), findsOneWidget);
        await tester.tap(find.text('Inventory'));
        await tester.pumpAndSettle();
        expect(find.text('LOW STOCK'), findsOneWidget);
        expect(find.text('INVENTORY ADJUSTMENT IMPACT'), findsWidgets);
        expect(find.text('CURRENT INVENTORY HEALTH'), findsOneWidget);
        expect(find.text('CURRENT INVENTORY AGING'), findsWidgets);
        expect(find.text('TOP INVENTORY VALUE'), findsWidgets);
        expect(find.text('INVENTORY VALUE BY CATEGORY'), findsWidgets);
        expect(find.textContaining('selected report period does not change'),
            findsOneWidget);
        await tester.tap(find.byTooltip('Report period'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Yesterday').last);
        await tester.pumpAndSettle();
        expect(find.text('Yesterday'), findsOneWidget);
        expect(find.text('No inventory adjustments in this period.'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
