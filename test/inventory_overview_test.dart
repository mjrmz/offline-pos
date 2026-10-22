import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/inventory/inventory_overview.dart';
import 'package:modern_offline_pos/features/inventory/inventory_workspace.dart';

void main() {
  Future<(AppDatabase, PosRepository, AuthService)> setup(WidgetTester tester,
      {Size size = const Size(1366, 768)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    return (db, PosRepository(db), auth);
  }

  testWidgets(
      'Overview shows live KPIs, attention, readable activity and links',
      (tester) async {
    final (db, repo, auth) = await setup(tester);
    final low = await repo.saveProduct(
        name: 'Soap',
        priceCents: 1000,
        costCents: 500,
        startingStock: 2,
        lowStockThreshold: 5);
    await repo.saveProduct(
        name: 'Empty', priceCents: 1000, costCents: 500, lowStockThreshold: 5);
    await repo.saveProduct(
        name: 'Healthy',
        priceCents: 1000,
        costCents: 500,
        startingStock: 10,
        lowStockThreshold: 5);
    await db.into(db.inventoryMovements).insert(
        InventoryMovementsCompanion.insert(
            productId: low,
            quantityDelta: -1,
            quantityDeltaMilli: const Value(-1000),
            reason: 'sale',
            createdAt: Value(DateTime.now())));
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: repo, auth: auth, user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Inventory overview'), findsNothing);
    expect(find.text('Products'), findsWidgets);
    expect(find.text('3'), findsWidgets);
    expect(find.text('Low stock'), findsOneWidget);
    expect(find.text('Out of stock'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('1 product out of stock'), findsOneWidget);
    expect(find.text('1 product low on stock'), findsOneWidget);
    expect(find.text('Opening stock ·', findRichText: true), findsNothing);
    expect(find.textContaining('Opening stock'), findsWidgets);
    expect(find.text('Sale'), findsOneWidget);
    expect(find.text('+2 pcs'), findsOneWidget);
    expect(find.text('-1 pc'), findsOneWidget);
    expect(find.textContaining('initial_stock'), findsNothing);
    await tester.tap(find.text('View all movements'));
    await tester.pumpAndSettle();
    expect(find.text('Inventory movements'), findsOneWidget);
    expect(find.text('Sale'), findsWidgets);
    expect(find.text('-1 pc'), findsOneWidget);
    expect(find.text('View all movements'), findsNothing);
  });

  testWidgets('Overview KPI filters open existing Products filters',
      (tester) async {
    final (_, repo, auth) = await setup(tester);
    await repo.saveProduct(name: 'Empty', priceCents: 1000, costCents: 500);
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: repo, auth: auth, user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Out of stock').first);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Out of stock'))
            .selected,
        isTrue);
    expect(find.text('Empty'), findsOneWidget);
  });

  testWidgets('Overview empty activity and narrow layout stay usable',
      (tester) async {
    final (_, repo, auth) = await setup(tester, size: const Size(390, 844));
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: repo, auth: auth, user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.text('Inventory looks healthy.'), findsOneWidget);
    expect(find.textContaining('No inventory activity yet.'), findsOneWidget);
    expect(find.text('Receive stock'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Recent activity is limited to eight movements', (tester) async {
    final (db, repo, auth) = await setup(tester);
    final id =
        await repo.saveProduct(name: 'Soap', priceCents: 1000, costCents: 500);
    for (var i = 0; i < 12; i++) {
      await db.into(db.inventoryMovements).insert(
          InventoryMovementsCompanion.insert(
              productId: id,
              quantityDelta: -1,
              quantityDeltaMilli: const Value(-1000),
              reason: 'sale',
              createdAt: Value(DateTime.now().subtract(Duration(minutes: i)))));
    }
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: repo, auth: auth, user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.byType(InventoryMovementRow), findsNWidgets(8));
  });

  testWidgets('Movements ledger filters and stacks at narrow width',
      (tester) async {
    final (_, repo, auth) = await setup(tester, size: const Size(390, 844));
    await repo.saveProduct(
        name: 'Opening device',
        priceCents: 1000,
        costCents: 500,
        startingStock: 1);
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: repo,
            auth: auth,
            user: auth.current!,
            initialView: 4)));
    await tester.pumpAndSettle();
    expect(find.text('Inventory movements'), findsOneWidget);
    expect(find.text('Opening device'), findsOneWidget);
    expect(find.text('+1 pc'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Sale'));
    await tester.pumpAndSettle();
    expect(find.text('No inventory movements yet'), findsOneWidget);
  });

  testWidgets('Movements show supplier reference without exposing UUID',
      (tester) async {
    final (db, repo, auth) = await setup(tester);
    final id = await repo.saveProduct(
        name: 'Delivered item', priceCents: 1000, costCents: 500);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    await StockReceivingRepository(db).receive(
        auth.current!, supplier.id, [ReceivingLineRequest(id, 1000, 500)],
        externalReference: 'DEL-42');
    await tester.pumpWidget(MaterialApp(
        home: InventoryWorkspace(
            repository: repo,
            auth: auth,
            user: auth.current!,
            initialView: 4)));
    await tester.pumpAndSettle();
    expect(find.text('DEL-42'), findsOneWidget);
    expect(find.text('Stock received'), findsOneWidget);
  });

  testWidgets('Movement labels and local dates use readable fallbacks',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: Text('Ready'))));
    final context = tester.element(find.text('Ready'));
    expect(inventoryMovementLabel('initial_stock'), 'Opening stock');
    expect(inventoryMovementLabel('sale'), 'Sale');
    expect(inventoryMovementLabel('item_refund'), 'Refund restock');
    expect(inventoryMovementLabel('unknown_event'), 'Unknown Event');
    final now = DateTime(2026, 10, 4, 12);
    expect(inventoryMovementWhen(context, DateTime(2026, 10, 4, 10), now: now),
        startsWith('Today ·'));
    expect(inventoryMovementWhen(context, DateTime(2026, 10, 3, 20), now: now),
        startsWith('Yesterday ·'));
    expect(inventoryMovementWhen(context, DateTime(2025, 10, 2, 11), now: now),
        contains('2025'));
  });
}
