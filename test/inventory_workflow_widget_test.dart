import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/inventory/stock_receiving_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

Future<void> revealProductField(WidgetTester tester, Finder target,
    {double delta = 250, bool right = false}) async {
  final vertical = find
      .descendant(
          of: find.byKey(
              ValueKey(right ? 'product-editor-right' : 'product-editor-left')),
          matching: find.byType(Scrollable))
      .first;
  await tester.scrollUntilVisible(target, delta, scrollable: vertical);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening batch table derives quantity and stores layer prices',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'Answer');
    await auth.login(owner, 'password123');
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, auth.current!);
    final repo = PosRepository(db);
    await tester.pumpWidget(
        MaterialApp(home: ProductScreen(repository: repo, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    final vertical = find
        .descendant(
            of: find.byKey(const ValueKey('product-editor-left')),
            matching: find.byType(Scrollable))
        .first;
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Batch item');
    await revealProductField(tester, find.text('Batch / expiry'), right: true);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Batch / expiry'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('I already have stock'), 250,
        scrollable: vertical);
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await revealProductField(tester, find.text('PRICING'));
    await tester.tap(find.text('Use one product price'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Price each stock layer separately').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('OPENING BATCHES'), 250,
        scrollable: vertical);
    await tester.enterText(
        find.widgetWithText(TextField, 'Batch / lot *').first, 'LOT-A');
    await tester.enterText(find.widgetWithText(TextField, 'Qty *').first, '2');
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost *').first, '10');
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling *').first, '15');
    await tester.tap(find.text('Add batch'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Batch / lot *').last, 'LOT-B');
    await tester.enterText(find.widgetWithText(TextField, 'Qty *').last, '3');
    await tester.enterText(find.widgetWithText(TextField, 'Cost *').last, '11');
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling *').last, '17');
    await tester.pumpAndSettle();
    expect(find.text('Total opening quantity: 5 pcs'), findsOneWidget);
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    final layers = await repo.layersForProduct(product.id);
    expect(layers.map((l) => l.batchNumber).toSet(), {'LOT-A', 'LOT-B'});
    expect(layers.map((l) => l.unitCostCents).toSet(), {1000, 1100});
    expect(layers.map((l) => l.unitSellingPriceCents).toSet(), {1500, 1700});
    await tester.tap(find.text('Batch item').first);
    await tester.pumpAndSettle();
    expect(find.text('Stock layers'), findsOneWidget);
    await tester.ensureVisible(find.text('Stock layers'));
    await tester.tap(find.text('Stock layers'));
    await tester.pumpAndSettle();
    expect(find.byType(DataTable), findsWidgets);
    expect(find.text('LOT-A'), findsOneWidget);
    expect(find.text('LOT-B'), findsOneWidget);
  });

  testWidgets(
      'received-stock pricing creates zero stock without a product price',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    await tester.pumpWidget(
        MaterialApp(home: ProductScreen(repository: repo, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    expect(find.text('Low-stock alert threshold'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Layer item');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    expect(find.text('Selling price is required.'), findsOneWidget);
    await revealProductField(tester, find.text('PRICING'));
    await tester.tap(find.text('Use one product price'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Price each stock layer separately').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Selling price *'), findsNothing);
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    expect(product.pricingPolicy, 'layer');
    expect(product.priceCents, 0);
    expect(await repo.layersForProduct(product.id), isEmpty);
  });

  testWidgets('serialized opening stock requires exact scanned serials',
      (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    await tester.pumpWidget(
        MaterialApp(home: ProductScreen(repository: repo, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Opening board');
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '3500');
    await revealProductField(tester, find.text('Serial numbers'), right: true);
    await tester.tap(find.text('Serial numbers'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('I already have stock').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('I already have stock').last);
    await tester.pumpAndSettle();
    expect(find.text('Existing inventory'), findsOneWidget);
    expect(find.text('Serialized'), findsWidgets);
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost per unit *'), '2000');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, 700));
    await tester.pumpAndSettle();
    expect(
        find.text('Enter at least one opening serial number.'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Scan or enter serial number'), 'SN-1');
    await tester.drag(find.byType(ListView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add serial'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Scan or enter serial number'), 'SN-2');
    await tester.drag(find.byType(ListView).last, const Offset(0, -120));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add serial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    expect(await repo.stockMilli(product.id), 2000);
    expect((await repo.availableSerials(product.id)).length, 2);
    await tester.tap(find.text('Opening board').first);
    await tester.pumpAndSettle();
    expect(find.text('AVAILABLE SERIALS (2)'), findsOneWidget);
    await tester.ensureVisible(find.text('AVAILABLE SERIALS (2)'));
    await tester.tap(find.text('AVAILABLE SERIALS (2)'));
    await tester.pumpAndSettle();
    expect(find.text('SN-1'), findsOneWidget);
    expect(find.text('SN-2'), findsOneWidget);
  });
  testWidgets('Product stock setup preserves opening and receive paths',
      (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    String? requestedReceiving;
    await tester.pumpWidget(MaterialApp(
        home: ProductScreen(
            repository: repo,
            auth: auth,
            onReceiveStock: (id) => requestedReceiving = id)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Opening item');
    await revealProductField(tester, find.text('I already have stock'));
    await tester.tap(find.text('I already have stock').last);
    await tester.pumpAndSettle();
    await revealProductField(tester, find.text('PRICING'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '10');
    await revealProductField(
        tester, find.widgetWithText(TextField, 'Opening quantity *'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Opening quantity *'), '3');
    await tester.scrollUntilVisible(
        find.widgetWithText(TextField, 'Cost per unit *'), 250,
        scrollable: find
            .descendant(
                of: find.byType(Dialog), matching: find.byType(Scrollable))
            .first);
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost per unit *'), '5');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    final opening = (await repo.products()).single;
    expect(await repo.stockMilli(opening.id), 3000);
    expect((await repo.layersForProduct(opening.id)).single.source, 'opening');
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Receive item');
    await revealProductField(tester, find.text('Receive from supplier'));
    await tester.tap(find.text('Receive from supplier').last);
    await tester.pumpAndSettle();
    await revealProductField(tester, find.text('PRICING'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '20');
    await tester.tap(find.text('Create & Continue to Receiving').last);
    await tester.pumpAndSettle();
    expect(requestedReceiving, isNotNull);
    expect(await repo.stockMilli(requestedReceiving!), 0);
    expect(await repo.layersForProduct(requestedReceiving!), isEmpty);
  });
  testWidgets('Existing category can be selected after duplicate warning',
      (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    final categoryId = await repo.addCategory('Food');
    await tester.pumpWidget(
        MaterialApp(home: ProductScreen(repository: repo, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create new category'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name *'), ' food ');
    await tester.tap(find.text('Create & select'));
    await tester.pumpAndSettle();
    expect(
        find.text('A category with this name already exists.'), findsOneWidget);
    await tester.tap(find.text('Use existing category'));
    await tester.pumpAndSettle();
    expect(find.text('Food'), findsOneWidget);
    expect((await repo.categories()).single.id, categoryId);
  });
  testWidgets('Product form creates and selects category without losing fields',
      (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    await tester.pumpWidget(
        MaterialApp(home: ProductScreen(repository: repo, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Jasmine rice');
    await tester.tap(find.text('Create new category'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name *'), 'Food');
    await tester.tap(find.text('Create & select'));
    await tester.pumpAndSettle();
    expect(find.text('Jasmine rice'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    await revealProductField(tester, find.text('PRICING'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '50');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    expect((await repo.products()).single.name, 'Jasmine rice');
    expect((await repo.categories()).single.id,
        (await repo.products()).single.categoryId);
  });
  testWidgets('Products search, detail, and receive shortcut', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    final laptop = await repo.saveProduct(
        name: 'Laptop',
        sku: 'LOQ-15',
        priceCents: 4500000,
        costCents: 3000000,
        serialTracking: true);
    await repo.saveProduct(name: 'Rice', priceCents: 5000, costCents: 3000);
    String? shortcut;
    await tester.pumpWidget(MaterialApp(
        home: ProductScreen(
            repository: repo,
            auth: auth,
            onReceiveStock: (id) => shortcut = id)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search name, SKU, or barcode'),
        'LOQ-15');
    await tester.pumpAndSettle();
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.text('Rice'), findsNothing);
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-details-drawer')), findsOneWidget);
    expect(find.text('Rice'), findsNothing);
    expect(find.text('No physical stock on hand.'), findsOneWidget);
    expect(find.text('AVAILABLE SERIALS (0)'), findsOneWidget);
    await tester.ensureVisible(find.text('AVAILABLE SERIALS (0)'));
    await tester.tap(find.text('AVAILABLE SERIALS (0)'));
    await tester.pumpAndSettle();
    expect(find.text('No available serials.'), findsOneWidget);
    await tester.tap(find.text('Receive stock'));
    expect(shortcut, laptop);
  });

  testWidgets('Receiving quick add supplier preserves delivery reference',
      (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    final productId = await repo.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 5000);
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
      repository: StockReceivingRepository(db),
      directory: DirectoryRepository(db),
      products: repo,
      user: auth.current!,
      initialProductId: productId,
    )));
    await tester.pumpAndSettle();
    expect(find.text('New Receiving'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Quantity (pcs)'), findsNothing);
    await tester.tap(find.text('Add item').first);
    await tester.pumpAndSettle();
    expect(find.text('Add item'), findsWidgets);
    expect(find.text('Mouse'), findsOneWidget);
    await tester.tap(find.byTooltip('Close item editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(
            TextField, 'Supplier invoice / reference (optional)'),
        'DR-123');
    await tester.tap(find.text('Search/select supplier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quick add supplier'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Supplier name *'), 'Acme Supply');
    await tester.tap(find.text('Create & select'));
    await tester.pumpAndSettle();
    expect(find.text('Acme Supply'), findsWidgets);
    expect(find.text('DR-123'), findsWidgets);
    expect(
        (await DirectoryRepository(db).suppliers()).single.name, 'Acme Supply');
  });
  testWidgets('Receiving quick add product selects it without losing supplier',
      (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Acme Supply');
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
      repository: StockReceivingRepository(db),
      directory: DirectoryRepository(db),
      products: repo,
      user: auth.current!,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Recent receiving'), findsOneWidget);
    expect(find.text('Receiving history'), findsNothing);
    await tester.tap(find.text('New receiving'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search/select supplier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(supplier.name).last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(
            TextField, 'Supplier invoice / reference (optional)'),
        'DR-456');
    await tester.tap(find.text('Add item').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search/select product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quick add product'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name *'), 'Mouse');
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '800');
    await tester.tap(find.text('Create & select'));
    await tester.pumpAndSettle();
    expect(find.text('Mouse'), findsOneWidget);
    expect(find.text('Acme Supply'), findsWidgets);
    expect(find.text('DR-456'), findsWidgets);
    expect((await repo.products()).single.name, 'Mouse');
    await tester.enterText(
        find.widgetWithText(TextField, 'Quantity (pcs)'), '2');
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost / pcs *'), '500');
    await tester.tap(find.text('Add to delivery'));
    await tester.pumpAndSettle();
    expect(find.text('Items in this delivery'), findsOneWidget);
    expect(find.text('Review & Finalize'), findsOneWidget);
    await tester.tap(find.byTooltip('Edit item'));
    await tester.pumpAndSettle();
    expect(find.text('Edit delivery item'), findsOneWidget);
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('Items in this delivery'), findsOneWidget);
  });

  testWidgets('Receiving uses shared Product editor and keeps draft details',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
            repository: StockReceivingRepository(db),
            directory: DirectoryRepository(db),
            products: repo,
            user: auth.current!,
            auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New receiving'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(
            TextField, 'Supplier invoice / reference (optional)'),
        'DR-789');
    await tester.tap(find.text('Add item').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search/select product'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quick add product'));
    await tester.pumpAndSettle();
    expect(find.text('PRODUCT'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'New mouse');
    await revealProductField(tester, find.text('PRICING'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '800');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    expect((await repo.products()).single.name, 'New mouse');
    expect(find.text('DR-789'), findsWidgets);
    expect(find.text('New mouse'), findsOneWidget);
    expect(await repo.stockMilli((await repo.products()).single.id), 0);
  });

  testWidgets('Receiving back confirms only a meaningful draft',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
            repository: StockReceivingRepository(db),
            directory: DirectoryRepository(db),
            products: repo,
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New receiving'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to receiving'));
    await tester.pumpAndSettle();
    expect(find.text('Discard receiving draft?'), findsNothing);
    await tester.tap(find.text('New receiving'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(
            TextField, 'Supplier invoice / reference (optional)'),
        'DR-001');
    await tester.tap(find.byTooltip('Back to receiving'));
    await tester.pumpAndSettle();
    expect(find.text('Discard receiving draft?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('DR-001'), findsWidgets);
  });

  testWidgets('Receiving draft changes stock only after finalization',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    final productId = await repo.saveProduct(
        name: 'Draft mouse', priceCents: 80000, costCents: 50000);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Acme Supply');
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
      repository: StockReceivingRepository(db),
      directory: DirectoryRepository(db),
      products: repo,
      user: auth.current!,
      initialProductId: productId,
    )));
    await tester.pumpAndSettle();
    expect(
        find.text('Stock is updated only after finalization.'), findsNothing);
    expect(find.textContaining('Stock is updated only after finalization.'),
        findsOneWidget);
    expect(find.text('Delivery details'), findsOneWidget);
    expect(find.text('Items in this delivery'), findsOneWidget);
    expect(find.text('Review & Finalize'), findsOneWidget);
    expect(find.text('Select a supplier to continue.'), findsOneWidget);
    await tester.tap(find.text('Search/select supplier'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(supplier.name).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add item').first);
    await tester.pumpAndSettle();
    expect(find.text('Add item'), findsWidgets);
    expect(find.textContaining('Stock changes only after finalization.'),
        findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Quantity (pcs)'), '2');
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost / pcs *'), '500');
    await tester.tap(find.text('Add to delivery'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Added to this delivery.'), findsOneWidget);
    expect(await repo.stockMilli(productId), 0);
    await tester.scrollUntilVisible(find.text('Finalize Receiving'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finalize Receiving'));
    await tester.pumpAndSettle();
    expect(find.text('Finalize this receiving?'), findsOneWidget);
    expect(
        find.text(
            'Finalizing this receiving will add these quantities to inventory.'),
        findsOneWidget);
    expect(await repo.stockMilli(productId), 0);
    await tester.tap(find.text('Finalize Receiving').last);
    await tester.pumpAndSettle();
    expect(find.text('Receiving finalized'), findsOneWidget);
    expect(await repo.stockMilli(productId), 2000);
  });

  testWidgets('Receiving draft sections fit a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    final repo = PosRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: StockReceivingScreen(
      repository: StockReceivingRepository(db),
      directory: DirectoryRepository(db),
      products: repo,
      user: auth.current!,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New receiving'));
    await tester.pumpAndSettle();
    expect(find.text('Delivery details'), findsOneWidget);
    expect(find.text('Items in this delivery'), findsOneWidget);
    expect(find.text('Review & Finalize'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Finalize Receiving'), 250,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Add at least one item to continue.'), findsNothing);
    expect(find.text('Select a supplier to continue.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
