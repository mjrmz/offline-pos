import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/features/inventory/inventory_workspace.dart';
import 'package:modern_offline_pos/features/inventory/purchase_orders_screen.dart';

void main() {
  testWidgets('partial and closed orders show factual progress and permissions',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final directory = DirectoryRepository(db);
    final supplier =
        await directory.saveSupplier(auth.current!, name: 'Supplier A');
    final productId = await pos.saveProduct(
        name: 'Product A',
        priceCents: 10000,
        costCents: 5000,
        startingStock: 0);
    final po = PurchaseOrderRepository(db);
    final partial = await po.create(auth.current!, supplier.id, DateTime.now(),
        [PurchaseOrderLineInput(productId, 2000, 5000)],
        markSent: true);
    final partialLine = (await po.detail(partial.id)).lines.single;
    final partialReceipt = await StockReceivingRepository(db).receive(
        auth.current!,
        supplier.id,
        [
          ReceivingLineRequest(productId, 1000, 6000,
              purchaseOrderLineId: partialLine.id)
        ],
        purchaseOrderId: partial.id);
    final closed = await po.create(auth.current!, supplier.id, DateTime.now(),
        [PurchaseOrderLineInput(productId, 1000, 5000)],
        markSent: true);
    final closedLine = (await po.detail(closed.id)).lines.single;
    await StockReceivingRepository(db).receive(
        auth.current!,
        supplier.id,
        [
          ReceivingLineRequest(productId, 1000, 5000,
              purchaseOrderLineId: closedLine.id)
        ],
        purchaseOrderId: closed.id);
    await po.close(auth.current!, closed.id);
    String? openedReceipt;
    await tester.pumpWidget(MaterialApp(
        home: PurchaseOrdersScreen(
            repository: po,
            directory: directory,
            products: pos,
            user: auth.current!,
            onReceive: (_) {},
            onOpenReceiving: (id) => openedReceipt = id)));
    await tester.pumpAndSettle();

    await tester.tap(
        find.textContaining(PurchaseOrderRepository.number(partial)).first);
    await tester.pumpAndSettle();
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Received cost variance'), findsOneWidget);
    final receive = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Receive stock'));
    expect(receive.onPressed, isNotNull);
    await tester.ensureVisible(
        find.text(StockReceivingRepository.number(partialReceipt)));
    await tester
        .tap(find.text(StockReceivingRepository.number(partialReceipt)));
    await tester.pumpAndSettle();
    expect(openedReceipt, partialReceipt.id);

    await tester
        .tap(find.textContaining(PurchaseOrderRepository.number(closed)).first);
    await tester.pumpAndSettle();
    expect(find.text('Closed'), findsWidgets);
    expect(find.text('100%'), findsOneWidget);
    final disabledReceive = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Receive stock'));
    expect(disabledReceive.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'missing expected cost hides comparison; many serials stay compact',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier A');
    final productId = await pos.saveProduct(
        name: 'Serialized product',
        priceCents: 10000,
        costCents: 0,
        startingStock: 0,
        serialTracking: true);
    final po = PurchaseOrderRepository(db);
    final order = await po.create(auth.current!, supplier.id, DateTime.now(),
        [PurchaseOrderLineInput(productId, 12000, 0)],
        markSent: true);
    final line = (await po.detail(order.id)).lines.single;
    final receipt = await StockReceivingRepository(db).receive(
        auth.current!,
        supplier.id,
        [
          ReceivingLineRequest(productId, 12000, 1000,
              purchaseOrderLineId: line.id,
              serialNumbers: [
                for (var n = 1; n <= 12; n++)
                  n == 12
                      ? 'SERIAL-12-VERY-LONG-IDENTIFIER-THAT-MUST-ELLIPSIZE-WITHIN-THE-DRAWER'
                      : 'SERIAL-$n'
              ])
        ],
        purchaseOrderId: order.id);
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: pos, auth: auth, user: auth.current!, initialView: 3)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(StockReceivingRepository.number(receipt)).first);
    await tester.pumpAndSettle();
    expect(find.text('Linked PO cost comparison'), findsNothing);
    expect(find.text('Serial numbers (12)'), findsOneWidget);
    await tester.ensureVisible(find.text('Serial numbers (12)'));
    await tester.tap(find.text('Serial numbers (12)'));
    await tester.pumpAndSettle();
    expect(find.text('SERIAL-1'), findsOneWidget);
    await tester.ensureVisible(find.text('SERIAL-1'));
    final serialList = find
        .ancestor(of: find.text('SERIAL-1'), matching: find.byType(ListView))
        .first;
    await tester.drag(serialList, const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(find.textContaining('SERIAL-12-VERY-LONG'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
