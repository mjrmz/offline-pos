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

void main() {
  testWidgets('PO opens its RCV detail and RCV opens its PO', (tester) async {
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
        name: 'Product A',
        priceCents: 80000,
        costCents: 50000,
        startingStock: 0);
    final poRepo = PurchaseOrderRepository(db);
    final order = await poRepo.create(auth.current!, supplier.id,
        DateTime.now(), [PurchaseOrderLineInput(productId, 1000, 50000)],
        markSent: true);
    final line = (await poRepo.detail(order.id)).lines.single;
    final receipt = await StockReceivingRepository(db).receive(
        auth.current!,
        supplier.id,
        [
          ReceivingLineRequest(productId, 1000, 51000,
              purchaseOrderLineId: line.id)
        ],
        purchaseOrderId: order.id);
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: pos,
            auth: auth,
            user: auth.current!,
            initialView: 2,
            initialPurchaseViewOrderId: order.id)));
    await tester.pumpAndSettle();
    expect(find.textContaining(PurchaseOrderRepository.number(order)),
        findsWidgets);
    await tester.tap(find.text(StockReceivingRepository.number(receipt)).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-details-drawer')), findsOneWidget);
    expect(find.text('Print GRN'), findsOneWidget);
    expect(find.text('Save GRN PDF'), findsOneWidget);
    expect(find.text('View Purchase Order'), findsOneWidget);
    await tester.tap(find.text('View Purchase Order'));
    await tester.pumpAndSettle();
    expect(find.textContaining(PurchaseOrderRepository.number(order)),
        findsWidgets);
    await tester.tap(find.text('Back to Purchase Orders').first);
    await tester.pumpAndSettle();
    await tester
        .tap(find.textContaining(PurchaseOrderRepository.number(order)).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-details-drawer')), findsOneWidget);
    expect(find.text('Open full details'), findsOneWidget);
    expect(find.text('Print PO'), findsOneWidget);
    expect(find.text('Save PDF'), findsOneWidget);
    expect(find.text('Duplicate PO'), findsOneWidget);
    expect(find.text('Receive stock'), findsOneWidget);
    await tester.tap(find.text('Open full details'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-details-drawer')), findsNothing);
    expect(find.text('Back to Purchase Orders'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Receiving history searches SKU and direct detail has no PO',
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
        name: 'Product A',
        sku: 'PART-A',
        priceCents: 80000,
        costCents: 50000,
        startingStock: 0);
    final receipt = await StockReceivingRepository(db).receive(auth.current!,
        supplier.id, [ReceivingLineRequest(productId, 1000, 51000)],
        externalReference: 'INV-55');
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: pos, auth: auth, user: auth.current!, initialView: 3)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View history'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'PART-A');
    await tester.pumpAndSettle();
    await tester.tap(find.text(StockReceivingRepository.number(receipt)).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-details-drawer')), findsOneWidget);
    expect(find.text('Direct receiving'), findsWidgets);
    expect(find.text('View Purchase Order'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
