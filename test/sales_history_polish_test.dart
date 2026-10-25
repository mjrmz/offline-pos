import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/sales_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/sales_history/sales_history_screen.dart';

void main() {
  testWidgets('history keeps structure at wide and narrow sizes in both themes',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final cashierId = await auth.bootstrap('MJ', 'password123', 'Q?', 'answer');
    await auth.login(cashierId, 'password123');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO sales (id, receipt_number, cashier_id, total_cents, created_at) VALUES ('sale', 'POS-000126', ?, 5000, ?)",
        [cashierId, now]);
    await db.customStatement(
        "INSERT INTO payments (id, sale_id, method, amount_cents) VALUES ('payment', 'sale', 'cash', 5000)");
    for (final width in [1600.0, 1920.0, 520.0]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        tester.view.physicalSize = Size(width, width == 520 ? 850 : 900);
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: SalesHistoryScreen(
                sales: SalesService(SalesRepository(db), auth),
                user: auth.current!)));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('sale-row-sale')), findsOneWidget);
        if (width == 1920) {
          expect(
              tester.getSize(find.byKey(const ValueKey('sale-row-sale'))).width,
              lessThanOrEqualTo(width - 64));
        }
        expect(find.text('Receipt #POS-000126'), findsOneWidget);
        expect(find.text('₱50'), findsWidgets);
        expect(find.byKey(const Key('sales-transaction-workspace')),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('1366 history shows five rows and polished drawer',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final cashierId = await auth.bootstrap('MJ', 'password123', 'Q?', 'answer');
    await auth.login(cashierId, 'password123');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('product', 'Motherboard', 350000, ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('customer', 'A very long customer name for a narrow transaction column', ?)",
        [now]);
    for (var i = 0; i < 20; i++) {
      await db.customStatement(
          "INSERT INTO sales (id, receipt_number, cashier_id, customer_id, total_cents, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            'sale-$i',
            i == 0 ? null : 'POS-${i.toString().padLeft(6, '0')}',
            cashierId,
            i == 0 ? 'customer' : null,
            350000,
            i == 1
                ? 'refunded'
                : i == 2
                    ? 'voided'
                    : 'completed',
            now
          ]);
      await db.customStatement(
          "INSERT INTO payments (id, sale_id, method, amount_cents) VALUES (?, ?, 'cash', 350000)",
          ['payment-$i', 'sale-$i']);
      await db.customStatement(
          "INSERT INTO sale_items (id, sale_id, product_id, product_name, quantity, quantity_milli, unit_price_cents, line_total_cents) VALUES (?, ?, 'product', 'Motherboard', 1, 1000, 350000, 350000)",
          ['item-$i', 'sale-$i']);
    }
    await tester.pumpWidget(MaterialApp(
        home: SalesHistoryScreen(
            sales: SalesService(SalesRepository(db), auth),
            user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sales-kpi-strip')), findsOneWidget);
    expect(
        find.byKey(const Key('sales-transaction-workspace')), findsOneWidget);
    expect(find.text('20 results'), findsOneWidget);
    expect(find.text('Status: All'), findsOneWidget);
    expect(find.text('Payment: All'), findsOneWidget);
    expect(find.text('Cashier: All'), findsOneWidget);
    expect(find.text('Compliance: All'), findsOneWidget);
    await tester.tap(find.text('Cashier: All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cashier: MJ').last);
    await tester.pumpAndSettle();
    expect(find.text('Cashier: MJ'), findsWidgets);
    expect(find.text('Legacy sale'), findsOneWidget);
    expect(find.textContaining('A very long customer name'), findsWidgets);
    expect(find.text('Receipt #Legacy sale'), findsNothing);
    expect(find.text('Completed'), findsWidgets);
    expect(find.text('Refunded'), findsWidgets);
    expect(find.text('Voided'), findsWidgets);
    expect(find.text('Non-BIR'), findsWidgets);
    expect(
        tester.getBottomRight(find.byKey(const ValueKey('sale-row-sale-4'))).dy,
        lessThanOrEqualTo(768));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('sale-row-sale-3')));
    await tester.pumpAndSettle();
    expect(find.text('Receipt #POS-000003'), findsWidgets);
    expect(find.text('SALE DETAILS'), findsOneWidget);
    expect(find.text('LIFECYCLE SUMMARY'), findsOneWidget);
    expect(find.text('Net retained sale value'), findsOneWidget);
    expect(find.text('ITEMS'), findsOneWidget);
    expect(find.text('Create RMA / Warranty'), findsOneWidget);
    expect(find.text('Reprint receipt'), findsOneWidget);
    expect(find.textContaining('Sale ID:'), findsNothing);
    await tester.tap(find.text('Reprint receipt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Receipt could not be printed'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss error'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Receipt could not be printed'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sale-row-sale-0')));
    await tester.pumpAndSettle();
    expect(find.text('Legacy sale'), findsWidgets);
    expect(find.text('No historical receipt reference'), findsWidgets);
    expect(find.text('Receipt #Legacy sale'), findsNothing);
  });

  testWidgets('receipt opened from customer history uses sales detail',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('MJ', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO sales (id, receipt_number, cashier_id, total_cents, created_at) VALUES ('linked-sale', 'POS-000200', ?, 5000, ?)",
        [userId, now]);
    await tester.pumpWidget(MaterialApp(
        home: SalesHistoryScreen(
      sales: SalesService(SalesRepository(db), auth),
      user: auth.current!,
      initialSaleId: 'linked-sale',
    )));
    await tester.pumpAndSettle();
    expect(find.text('LIFECYCLE SUMMARY'), findsOneWidget);
    expect(find.text('Net retained sale value'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sale-row-linked-sale')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
