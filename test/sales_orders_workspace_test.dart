import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_order_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/sales_orders_screen.dart';

void main() {
  testWidgets('Orders filters method and physical status without losing rows',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('c1', 'Ana', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 1000, 0)");
    final orders = SalesOrderRepository(db);
    final pickup = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 1000)],
        fulfillmentMethod: 'pickup');
    final delivery = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 1000)],
        fulfillmentMethod: 'delivery');
    await db.customStatement("UPDATE sales_orders SET physical_status='scheduled' WHERE id=?", [delivery.id]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: orders,
        directory: DirectoryRepository(db), products: PosRepository(db),
        user: owner))));
    await tester.pumpAndSettle();
    expect(find.text(pickup.reference), findsOneWidget);
    expect(find.text(delivery.reference), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('method-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pickup').last);
    await tester.pumpAndSettle();
    expect(find.text(pickup.reference), findsOneWidget);
    expect(find.text(delivery.reference), findsNothing);
    await tester.tap(find.byKey(const ValueKey('physical-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scheduled').last);
    await tester.pumpAndSettle();
    expect(find.text(pickup.reference), findsNothing);
  });

  testWidgets('pickup setup hides delivery address and fee', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, address, created_at) VALUES ('c1', 'Ana', 'Main Street', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 1000, 0)");
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 1000)],
        fulfillmentMethod: 'pickup');
    await orders.transition(owner, order.id, 'confirmed');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: orders,
        directory: DirectoryRepository(db), products: PosRepository(db),
        user: owner))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Edit contact and method'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit contact and method'));
    await tester.pumpAndSettle();
    expect(find.text('Pickup contact'), findsOneWidget);
    expect(find.text('Delivery address'), findsNothing);
    expect(find.text('Delivery fee'), findsNothing);
    expect(find.text('Instructions'), findsOneWidget);
  });

  testWidgets('pickup completion asks for released-to name', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana', phone: '09170000000');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget', priceCents: 1000,
        costCents: 500, startingStock: 1);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 1000, 1000)],
        fulfillmentMethod: 'pickup');
    await orders.transition(owner, order.id, 'confirmed');
    final line = (await orders.lines(order.id)).single;
    await pos.completeCashSale([SaleLineRequest(product, 1, lineKey: line.id)],
        1000, id, customerId: customer.id, salesOrderId: order.id);
    await orders.transitionPhysical(owner, order.id, 'scheduled',
        scheduledAt: DateTime.now());
    await orders.transitionPhysical(owner, order.id, 'ready');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: orders,
        directory: DirectoryRepository(db), products: pos, user: owner))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    expect(find.text('Delivery address'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Picked Up'));
    await tester.pumpAndSettle();
    expect(find.text('Released to *'), findsOneWidget);
    await tester.enterText(find.byWidgetPredicate((widget) =>
      widget is TextField && widget.decoration?.labelText == 'Released to *'),
      'Ana');
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Picked Up'));
    await tester.pumpAndSettle();
    expect(find.text('Ana'), findsWidgets);
    expect(find.text('Mark Picked Up'), findsNothing);
  });

  testWidgets('delivery actions show context, failure retry, and recipient',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana', address: 'Main Street', phone: '09170000000');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget', priceCents: 1000,
        costCents: 500, startingStock: 1);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 1000, 1000)],
        fulfillmentMethod: 'delivery');
    await orders.configurePhysical(owner, order.id, method: 'delivery',
        contactName: 'Ana', contactPhone: '09170000000',
        address: 'Main Street');
    await orders.transition(owner, order.id, 'confirmed');
    final line = (await orders.lines(order.id)).single;
    await pos.completeCashSale([SaleLineRequest(product, 1, lineKey: line.id)],
        1000, id, customerId: customer.id, salesOrderId: order.id);
    await orders.transitionPhysical(owner, order.id, 'scheduled',
        scheduledAt: DateTime.now());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: orders,
        directory: DirectoryRepository(db), products: pos, user: owner))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Ready'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ready for handoff'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Ready'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Out for Delivery'));
    await tester.pumpAndSettle();
    expect(find.text('Main Street'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Out for Delivery'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record Failed Delivery'));
    await tester.pumpAndSettle();
    expect(find.text('Failure reason *'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Customer unavailable');
    await tester.tap(find.widgetWithText(FilledButton, 'Record Failed Delivery'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Reschedule'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Reschedule'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Choose a date and time'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Reschedule'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Ready'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Ready'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Out for Delivery'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Out for Delivery'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Delivered'));
    await tester.pumpAndSettle();
    expect(find.text('Recipient name *'), findsOneWidget);
    await tester.enterText(find.byWidgetPredicate((widget) =>
      widget is TextField && widget.decoration?.labelText == 'Recipient name *'),
      'Juan');
    await tester.tap(find.widgetWithText(FilledButton, 'Mark Delivered'));
    await tester.pumpAndSettle();
    expect(find.text('Juan'), findsOneWidget);
    expect(find.text('Mark Delivered'), findsNothing);
  });

  testWidgets('desktop sizes and both themes keep queue and long address usable',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final user = ActiveUser(id, 'Owner', UserRole.owner);
    const address = '123 Long Avenue, Barangay Riverside, City of San Pedro, '
        'Province of Laguna, near the municipal hall entrance';
    await db.customStatement(
        "INSERT INTO customers (id, name, address, created_at) VALUES ('c1', 'Ana', ?, 0)",
        [address]);
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 1000, 0)");
    final orders = SalesOrderRepository(db);
    final order = await orders.create(user, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 1000)],
        fulfillmentMethod: 'delivery');
    await orders.transition(user, order.id, 'confirmed');
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      for (final size in [const Size(1366, 768), const Size(1600, 900),
        const Size(1920, 1080)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(themeMode: mode,
        theme: ThemeData.light(), darkTheme: ThemeData.dark(), home: Scaffold(body:
          SalesOrdersScreen(key: UniqueKey(), repository: orders,
            directory: DirectoryRepository(db), products: PosRepository(db),
            user: user))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Open Orders'), findsOneWidget);
      await tester.tap(find.text('Fulfillment Queue'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(order.reference));
      await tester.pumpAndSettle();
      expect(find.text(address), findsOneWidget);
      expect(find.byKey(const Key('record-details-drawer')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close details'));
      await tester.pumpAndSettle();
      }
    }
    addTearDown(() { tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio(); });
  });

  testWidgets('physical actions respect partial, terminal, and permission states',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('c1', 'Ana', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 1000, 0)");
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 1000)],
        fulfillmentMethod: 'delivery');
    await orders.transition(owner, order.id, 'confirmed');
    await db.customStatement("UPDATE sales_orders SET physical_status='scheduled' WHERE id=?", [order.id]);
    Future<void> openAs(ActiveUser user) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        SalesOrdersScreen(key: UniqueKey(), repository: orders,
          directory: DirectoryRepository(db), products: PosRepository(db),
          user: user))));
      await tester.pumpAndSettle();
      await tester.tap(find.text(order.reference));
      await tester.pumpAndSettle();
    }
    await openAs(owner);
    final ready = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Mark Ready'));
    expect(ready.onPressed, isNull);
    expect(find.textContaining('Complete inventory fulfillment'), findsOneWidget);
    await tester.tap(find.byTooltip('Close details'));
    await tester.pumpAndSettle();
    await db.customStatement("UPDATE sales_orders SET physical_status='delivered' WHERE id=?", [order.id]);
    await openAs(owner);
    expect(find.text('Mark Ready'), findsNothing);
    expect(find.text('Mark Delivered'), findsNothing);
    await tester.tap(find.byTooltip('Close details'));
    await tester.pumpAndSettle();
    await db.customStatement("UPDATE sales_orders SET physical_status='scheduled' WHERE id=?", [order.id]);
    await openAs(ActiveUser(id, 'Viewer', UserRole.custom,
      true, null, {PosPermission.viewSalesOrders}));
    expect(find.text('Mark Ready'), findsNothing);
    expect(find.text('Edit contact and method'), findsNothing);
  });
  testWidgets('Fulfillment Queue opens order and focused schedule action',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final user = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, address, created_at) VALUES ('c1', 'Ana', 'Old address', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 1000, 0)");
    final orders = SalesOrderRepository(db);
    final order = await orders.create(user, 'c1',
        [const SalesOrderLineRequest('p1', 1000, 1000)],
        fulfillmentMethod: 'delivery');
    await orders.transition(user, order.id, 'confirmed');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
          SalesOrdersScreen(key: UniqueKey(), repository: orders,
        directory: DirectoryRepository(db), products: PosRepository(db),
        user: user))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fulfillment Queue'));
    await tester.pumpAndSettle();
    expect(find.text(order.reference), findsOneWidget);
    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(find.text(order.reference), findsNothing);
    await tester.tap(find.text('All Active'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pickup'));
    await tester.pumpAndSettle();
    expect(find.text(order.reference), findsNothing);
    await tester.tap(find.text('All Active'));
    await tester.pumpAndSettle();
    expect(find.text(order.reference), findsOneWidget);
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    expect(find.text('Delivery / Pickup'), findsOneWidget);
    expect(find.textContaining('Old address'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Choose date'), findsOneWidget);
    expect(find.text('Choose time'), findsOneWidget);
    expect(find.textContaining('Edit contact and address'), findsOneWidget);
  });
  testWidgets('Sales Orders workspace opens draft editor', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final user = ActiveUser(id, 'Owner', UserRole.owner);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: SalesOrderRepository(db),
        directory: DirectoryRepository(db), products: PosRepository(db),
        user: user))));
    await tester.pumpAndSettle();
    expect(find.text('Sales Orders'), findsOneWidget);
    await tester.tap(find.text('New Sales Order'));
    await tester.pumpAndSettle();
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Fulfillment intent'), findsOneWidget);
    expect(find.text('Save draft'), findsOneWidget);
  });
  testWidgets('confirmed order shows explicit reservation controls',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final user = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('c1', 'Ana', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 1000, 0)");
    await db.customStatement(
        "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p1', 10, 10000)");
    final orders = SalesOrderRepository(db);
    final order = await orders.create(user, 'c1',
        [const SalesOrderLineRequest('p1', 4000, 1000)]);
    await orders.transition(user, order.id, 'confirmed');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: orders,
        directory: DirectoryRepository(db), products: PosRepository(db),
        user: user, auth: auth))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    expect(find.text('Reserve stock'), findsOneWidget);
    expect(find.textContaining('Reserved 0'), findsOneWidget);
    await tester.ensureVisible(find.text('Reserve stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reserve stock'));
    await tester.pumpAndSettle();
    expect(find.text('Requested: 4'), findsOneWidget);
    expect(find.text('Available: 10'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    expect(find.text('Fulfill Order'), findsOneWidget);
    await tester.ensureVisible(find.text('Fulfill Order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fulfill Order'));
    await tester.pumpAndSettle();
    expect(find.textContaining('remaining 4'), findsOneWidget);
    expect(find.text('Open checkout'), findsOneWidget);
    await tester.tap(find.text('Open checkout'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fulfilling Sales Order'), findsOneWidget);
  });
}
