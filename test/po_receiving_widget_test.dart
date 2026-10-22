import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/features/inventory/stock_receiving_screen.dart';

void main() {
  testWidgets('PO lines preload, partially receive, then receive remainder',
      (tester) async {
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
    final directory = DirectoryRepository(db);
    final supplier =
        await directory.saveSupplier(auth.current!, name: 'Supplier A');
    final product = await pos.saveProduct(
        name: 'Product A', priceCents: 70000, costCents: 50000);
    final orders = PurchaseOrderRepository(db);
    final order = await orders.create(auth.current!, supplier.id,
        DateTime.now(), [PurchaseOrderLineInput(product, 10000, 50000)],
        markSent: true);
    final poLine = (await orders.detail(order.id)).lines.single;
    final receiving = StockReceivingRepository(db);

    Future<void> open() async {
      await tester.pumpWidget(MaterialApp(
          home: StockReceivingScreen(
              key: UniqueKey(),
              repository: receiving,
              directory: directory,
              products: pos,
              user: auth.current!,
              purchaseOrderId: order.id)));
      await tester.pumpAndSettle();
    }

    Future<void> finalize() async {
      await tester.tap(find.text('Finalize Receiving').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finalize Receiving').last);
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.text('Receive now'), findsNothing);
    expect(find.text('Add unplanned item'), findsOneWidget);
    expect(find.text('Product A'), findsOneWidget);
    expect(find.textContaining('Expected cost'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('po-qty-${poLine.id}')))
            .controller!
            .text,
        '10');
    expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('po-cost-${poLine.id}')))
            .controller!
            .text,
        '500.00');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Discard receiving draft?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(await pos.stockMilli(product), 0);
    expect((await orders.detail(order.id)).remaining(poLine), 10000);
    await open();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard receiving draft?'), findsOneWidget);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(await pos.stockMilli(product), 0);
    await open();
    await tester.enterText(find.byKey(ValueKey('po-qty-${poLine.id}')), '11');
    await tester.tap(find.text('Finalize Receiving').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot exceed the remaining'), findsOneWidget);
    expect(await pos.stockMilli(product), 0);
    await tester.enterText(find.byKey(ValueKey('po-qty-${poLine.id}')), '4');
    await tester.enterText(find.byKey(ValueKey('po-cost-${poLine.id}')), '520');
    await finalize();
    expect(await pos.stockMilli(product), 4000);
    expect((await orders.detail(order.id)).status, 'partially_received');
    expect((await orders.detail(order.id)).remaining(poLine), 6000);
    await open();
    expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('po-qty-${poLine.id}')))
            .controller!
            .text,
        '6');
    expect(find.textContaining('Prev. recv.'), findsOneWidget);
    await tester.enterText(find.byKey(ValueKey('po-cost-${poLine.id}')), '515');
    await finalize();
    expect(await pos.stockMilli(product), 10000);
    expect((await orders.detail(order.id)).status, 'fully_received');
    expect(
        (await db.select(db.inventoryLayers).get()).map((l) => l.unitCostCents),
        containsAll([52000, 51500]));
  });

  testWidgets(
      'zero PO line and unplanned item receive without changing PO quantity',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final directory = DirectoryRepository(db);
    final supplier =
        await directory.saveSupplier(auth.current!, name: 'Supplier B');
    final a = await pos.saveProduct(
        name: 'Product A', priceCents: 10000, costCents: 5000);
    final b = await pos.saveProduct(
        name: 'Product B', priceCents: 10000, costCents: 5000);
    final c = await pos.saveProduct(
        name: 'Product C', priceCents: 10000, costCents: 5000);
    final orders = PurchaseOrderRepository(db);
    final order = await orders.create(
        auth.current!,
        supplier.id,
        DateTime.now(),
        [
          PurchaseOrderLineInput(a, 5000, 5000),
          PurchaseOrderLineInput(b, 3000, 5000),
        ],
        markSent: true);
    final progress = await orders.detail(order.id);
    final bLine = progress.lines.firstWhere((line) => line.productId == b);
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
            repository: StockReceivingRepository(db),
            directory: directory,
            products: pos,
            user: auth.current!,
            purchaseOrderId: order.id)));
    await tester.pumpAndSettle();
    expect(find.text('Product A'), findsOneWidget);
    expect(find.text('Product B'), findsOneWidget);
    await tester.enterText(find.byKey(ValueKey('po-qty-${bLine.id}')), '0');
    await tester.tap(find.text('Add unplanned item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search/select product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Product C').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Quantity (pcs)'), '2');
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost / pcs *'), '60');
    await tester.tap(find.text('Add to delivery'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unplanned item'), findsOneWidget);
    await tester.tap(find.text('Finalize Receiving').first);
    await tester.pumpAndSettle();
    expect(find.text('Finalize this receiving?'), findsOneWidget);
    await tester.tap(find.text('Finalize Receiving').last);
    await tester.pumpAndSettle();
    expect(await pos.stockMilli(a), 5000);
    expect(await pos.stockMilli(b), 0);
    expect(await pos.stockMilli(c), 2000);
    final after = await orders.detail(order.id);
    expect(after.remaining(bLine), 3000);
    expect(
        after.lines.firstWhere((line) => line.productId == b).orderedQtyMilli,
        3000);
  });

  testWidgets('PO receiving fits desktop sizes in light and dark',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final directory = DirectoryRepository(db);
    final supplier =
        await directory.saveSupplier(auth.current!, name: 'Supplier C');
    final product = await pos.saveProduct(
        name: 'Product A', priceCents: 10000, costCents: 5000);
    final order = await PurchaseOrderRepository(db).create(
        auth.current!,
        supplier.id,
        DateTime.now(),
        [PurchaseOrderLineInput(product, 1000, 5000)],
        markSent: true);
    for (final size in [
      const Size(1366, 768),
      const Size(1600, 900),
      const Size(1920, 1080)
    ]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(MaterialApp(
            themeMode: mode,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            home: StockReceivingScreen(
                key: UniqueKey(),
                repository: StockReceivingRepository(db),
                directory: directory,
                products: pos,
                user: auth.current!,
                purchaseOrderId: order.id)));
        await tester.pumpAndSettle();
        expect(find.text('Items received'), findsOneWidget);
        expect(find.text('Finalize Receiving'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  });

  testWidgets('serialized PO line requires details in Receiving',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final directory = DirectoryRepository(db);
    final supplier =
        await directory.saveSupplier(auth.current!, name: 'Supplier D');
    final product = await pos.saveProduct(
        name: 'Serial product',
        priceCents: 10000,
        costCents: 5000,
        serialTracking: true);
    final order = await PurchaseOrderRepository(db).create(
        auth.current!,
        supplier.id,
        DateTime.now(),
        [PurchaseOrderLineInput(product, 2000, 5000)],
        markSent: true);
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
            repository: StockReceivingRepository(db),
            directory: directory,
            products: pos,
            user: auth.current!,
            purchaseOrderId: order.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finalize Receiving'));
    await tester.pumpAndSettle();
    expect(find.textContaining('one serial number per received unit'),
        findsOneWidget);
    expect(await pos.stockMilli(product), 0);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Serial 1'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Serial 2'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Serial 1'), 'SN001');
    await tester.enterText(find.widgetWithText(TextField, 'Serial 2'), 'SN002');
    await tester.tap(find.text('Save delivery item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finalize Receiving').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finalize Receiving').last);
    await tester.pumpAndSettle();
    expect(await pos.stockMilli(product), 2000);
  });
}
