import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/layaway_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/layaway_screen.dart';
import 'package:modern_offline_pos/features/contacts/quotation_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';
import 'package:modern_offline_pos/shared/widgets/app_workspace.dart';

void main() {
  testWidgets('multiple quotation shortages can prefill one PO',
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
    final first = await pos.saveProduct(
        name: 'Bulk first',
        priceCents: 10000,
        costCents: 5000,
        startingStock: 0);
    final second = await pos.saveProduct(
        name: 'Bulk second',
        priceCents: 20000,
        costCents: 8000,
        startingStock: 0);
    final repo = QuotationRepository(db, pos);
    final quote = await repo.create(auth.current!,
        [QuoteLineRequest(first, 2000), QuoteLineRequest(second, 3000)]);
    List<({String productId, int quantityMilli})>? selected;
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: repo,
            directory: DirectoryRepository(db),
            products: pos,
            user: auth.current!,
            onCreatePurchaseOrderForLines: (lines, _, __) => selected = lines,
            onCreatePurchaseOrder: (_, __, ___, ____) {})));
    await tester.pumpAndSettle();
    await tester.tap(find.text(quote.reference));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review sourcing'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    await tester.tap(find.text('Create Purchase Order for selected'));
    await tester.pumpAndSettle();
    expect(selected, isNotNull);
    expect(selected!.map((line) => line.productId).toSet(), {first, second});
    expect(selected!.map((line) => line.quantityMilli).toList(), [2000, 3000]);
    expect(await pos.stockMilli(first), 0);
    expect(await pos.stockMilli(second), 0);
  });

  testWidgets(
      'quotation shows Draft PO incoming separately and suggests only uncovered shortage',
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
    final productId = await pos.saveProduct(
        name: 'Quotation PO Product',
        priceCents: 10000,
        costCents: 5000,
        startingStock: 0);
    final repo = QuotationRepository(db, pos);
    final quote =
        await repo.create(auth.current!, [QuoteLineRequest(productId, 5000)]);
    final supplier =
        await DirectoryRepository(db).saveSupplier(auth.current!, name: 'ABC');
    final po = PurchaseOrderRepository(db);
    final draft = await po.create(auth.current!, supplier.id,
        DateTime(2026, 10, 15), [PurchaseOrderLineInput(productId, 3000, 5000)],
        notes: 'For quotation ${quote.reference}',
        sourceQuotationReference: quote.reference,
        sourceQuantitiesMilli: {productId: 3000});
    int? proposedQuantity;
    String? selectedOrderId;
    int? addedQuantity;
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
      repository: repo,
      directory: DirectoryRepository(db),
      products: pos,
      user: auth.current!,
      onCreatePurchaseOrder: (_, __, quantity, ___) =>
          proposedQuantity = quantity,
      onAddToPurchaseOrder: (orderId, _, quantity, __) {
        selectedOrderId = orderId;
        addedQuantity = quantity;
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text(quote.reference));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review sourcing'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Incoming: 3'), findsOneWidget);
    expect(find.textContaining('Still needed to order: 2'), findsOneWidget);
    expect(find.text('Create Purchase Order'), findsOneWidget);
    expect(find.text('Add to existing PO'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Continue to checkout'))
            .onPressed,
        isNull);
    await tester.tap(find.text('Add to existing PO'));
    await tester.pumpAndSettle();
    expect(find.text('PO-000001'), findsOneWidget);
    await tester.tap(find.text('PO-000001'));
    await tester.pumpAndSettle();
    expect(selectedOrderId, draft.id);
    expect(addedQuantity, 2000);
    await tester.tap(find.text(quote.reference));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review sourcing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create Purchase Order'));
    await tester.pumpAndSettle();
    expect(proposedQuantity, 2000);
    expect(await pos.stockMilli(productId), 0);
  });

  testWidgets('POS loads a saved quote and retains its price', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Cable', priceCents: 50000, costCents: 10000, startingStock: 2);
    final quote = await QuotationRepository(db, pos)
        .create(auth.current!, [QuoteLineRequest(product, 1000)]);
    await pos.saveProduct(
        id: product, name: 'Cable', priceCents: 60000, costCents: 10000);
    await tester.pumpWidget(MaterialApp(
        home: CheckoutScreen(
            repository: pos,
            user: auth.current!,
            auth: auth,
            quotationId: quote.id,
            quotationReference: quote.reference)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Converting quotation'), findsOneWidget);
    expect(find.textContaining('Quoted price retained'), findsOneWidget);
    expect(find.textContaining('Cable'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quotation editor fits common desktop and narrow sizes',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    tester.view.physicalSize = const Size(1366, 768);
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: QuotationRepository(db, PosRepository(db)),
            directory: DirectoryRepository(db),
            products: PosRepository(db),
            user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.text('Quotations'), findsNWidgets(2));
    await tester.tap(find.text('New quotation').first);
    await tester.pumpAndSettle();
    expect(find.text('Quotation summary'), findsOneWidget);
    expect(find.text('Quotations'), findsNWidgets(2));
    for (final size in [
      const Size(1366, 768),
      const Size(1600, 900),
      const Size(1920, 1080),
      const Size(390, 844)
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Layout at $size');
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Quotation summary'), findsNothing);
  });

  testWidgets('zero-stock active product is searchable and can be quoted',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Order-only mouse',
        priceCents: 45000,
        costCents: 20000,
        startingStock: 0);
    final repo = QuotationRepository(db, pos);
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: repo,
            directory: DirectoryRepository(db),
            products: pos,
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New quotation').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search product, SKU, or barcode'),
        'Order-only');
    await tester.pumpAndSettle();
    expect(find.textContaining('Available by order'), findsOneWidget);
    await tester.tap(find.text('Order-only mouse').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Source on order'), findsOneWidget);
    await tester.tap(find.text('Save quotation'));
    await tester.pumpAndSettle();
    expect((await repo.history()).length, 1);
    expect(await pos.stockMilli(product), 0);
  });

  testWidgets('unknown search can add a quotation-only custom item',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final repo = QuotationRepository(db, pos);
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: repo,
            directory: DirectoryRepository(db),
            products: pos,
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New quotation').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search product, SKU, or barcode'),
        'ASUS TUF B850-PLUS WIFI');
    await tester.pumpAndSettle();
    expect(find.textContaining('No products found for'), findsOneWidget);
    expect(find.text('Create new product'), findsOneWidget);
    expect(find.text('Add custom quotation item'), findsOneWidget);
    expect(await db.select(db.products).get(), isEmpty);
    await tester.tap(find.text('Add custom quotation item'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Description *'), findsOneWidget);
    expect(find.text('ASUS TUF B850-PLUS WIFI'), findsWidgets);
    await tester.enterText(
        find.widgetWithText(TextField, 'Unit price *'), '12500');
    await tester.enterText(
        find.widgetWithText(TextField, 'Notes / specification (optional)'),
        'Special order · 3–5 days');
    await tester.tap(find.text('Add to quotation'));
    await tester.pumpAndSettle();
    expect(find.text('Custom item'), findsOneWidget);
    expect(find.textContaining('Special order'), findsOneWidget);
    await tester.tap(find.text('Save quotation'));
    await tester.pumpAndSettle();
    final quote = (await repo.history()).single;
    expect((await repo.items(quote.id)).single.productId, isNull);
    expect((await repo.items(quote.id)).single.lineTotalCents, 1250000);
    expect(await db.select(db.products).get(), isEmpty);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
  });

  testWidgets(
      'unknown search creates a zero-stock Product in the quotation draft',
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
    final repo = QuotationRepository(db, pos);
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Juan Dela Cruz');
    final cableId = await pos.saveProduct(
        name: 'Existing cable',
        priceCents: 50000,
        costCents: 20000,
        startingStock: 1);
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: repo,
            directory: DirectoryRepository(db),
            products: pos,
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New quotation').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Juan Dela Cruz'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search product, SKU, or barcode'),
        'Existing cable');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Existing cable').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search product, SKU, or barcode'),
        'ASUS TUF B850-PLUS WIFI');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create new product'));
    await tester.pumpAndSettle();
    expect(find.text('ASUS TUF B850-PLUS WIFI'), findsWidgets);
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '12500');
    await tester.tap(find.text('Create & add to quotation'));
    await tester.pumpAndSettle();
    final product = (await pos.products())
        .firstWhere((product) => product.name == 'ASUS TUF B850-PLUS WIFI');
    expect(product.name, 'ASUS TUF B850-PLUS WIFI');
    expect(await pos.stockMilli(product.id), 0);
    expect(
        (await db.select(db.inventoryLayers).get())
            .where((layer) => layer.productId == product.id),
        isEmpty);
    expect(
        (await db.select(db.inventoryMovements).get())
            .where((movement) => movement.productId == product.id),
        isEmpty);
    expect(find.textContaining('Source on order'), findsOneWidget);
    await tester.tap(find.text('Save quotation'));
    await tester.pumpAndSettle();
    final quote = (await repo.history()).single;
    expect(quote.customerId, customer.id);
    expect((await repo.items(quote.id)).map((item) => item.productId),
        containsAll([product.id, cableId]));
  });

  testWidgets('custom conversion offers product linking and keeps quoted price',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final repo = QuotationRepository(db, pos);
    final quote = await repo.create(auth.current!, [
      const QuoteLineRequest.custom('ASUS TUF B850-PLUS WIFI', 1000,
          unit: 'pcs', unitPriceCents: 1250000)
    ]);
    final productId = await pos.saveProduct(
        name: 'ASUS TUF GAMING B850-PLUS WIFI',
        priceCents: 1290000,
        costCents: 900000,
        startingStock: 0);
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: repo,
            directory: DirectoryRepository(db),
            products: pos,
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(quote.reference));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Convert to sale').last);
    await tester.tap(find.text('Convert to sale').last);
    await tester.pumpAndSettle();
    expect(find.text('Needs product link'), findsOneWidget);
    expect(find.text('Recommended next step'), findsOneWidget);
    expect(find.text('1 of 1 items ready'), findsNothing);
    expect(find.textContaining('1 require action'), findsOneWidget);
    expect(find.text('Create product'), findsOneWidget);
    expect(find.text('Link existing product'), findsOneWidget);
    expect(find.text('More actions'), findsOneWidget);
    await tester.tap(find.text('Link existing product'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search product, SKU, or barcode'),
        'ASUS TUF');
    await tester.pumpAndSettle();
    expect(find.textContaining('Current price'), findsOneWidget);
    await tester.tap(find.text('ASUS TUF GAMING B850-PLUS WIFI'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Link product'));
    await tester.pumpAndSettle();
    expect(find.text('✓ Product linked'), findsOneWidget);
    expect(find.text('Source from supplier'), findsOneWidget);
    expect(find.textContaining('Current stock: 0'), findsOneWidget);
    final linked = (await repo.items(quote.id)).single;
    expect(linked.productId, productId);
    expect(linked.unitPriceCents, 1250000);
    expect(await pos.stockMilli(productId), 0);
    expect(await db.select(db.sales).get(), isEmpty);
    await tester.tap(find.text('Source from supplier'));
    await tester.pumpAndSettle();
    expect(find.text('Source from supplier'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String?>), findsOneWidget);
    await tester.tap(find.text('Create sourcing requirement'));
    await tester.pumpAndSettle();
    expect(find.text('✓ Sourcing requirement created'), findsOneWidget);
    expect(find.textContaining('Stock remains unchanged'), findsOneWidget);
    expect(find.textContaining('Create a Purchase Order'), findsOneWidget);
  });

  testWidgets(
      'quotation cards keep next step and status visible at desktop sizes',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final repo = QuotationRepository(db, pos);
    final productId = await pos.saveProduct(
        name:
            'A very long motherboard product name for a compact quotation card',
        priceCents: 1500000,
        costCents: 1000000,
        startingStock: 0);
    final quote =
        await repo.create(auth.current!, [QuoteLineRequest(productId, 1000)]);
    await repo.requestSourcing(auth.current!, quote.id, productId);
    for (final size in const [
      Size(1366, 768),
      Size(1600, 900),
      Size(1920, 1080)
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        await tester.pumpWidget(MaterialApp(
          themeMode: mode,
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          home: QuotationScreen(
              repository: repo,
              directory: DirectoryRepository(db),
              products: pos,
              user: auth.current!),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Next: Order'), findsOneWidget);
        expect(find.textContaining('Awaiting stock'), findsWidgets);
        expect(find.byType(AppSemanticStatusBadge), findsOneWidget);
        await tester.tap(find.text(quote.reference).first);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('NEXT STEP'), findsOneWidget);
        expect(find.text('Customer'), findsOneWidget);
        expect(find.text('Items'), findsOneWidget);
        expect(find.text('Total'), findsOneWidget);
        expect(find.text('Edit quotation'), findsOneWidget);
        expect(find.text('Convert to sale'), findsOneWidget);
        expect(tester.takeException(), isNull,
            reason: 'Detail at $size in $mode');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      }
    }
    await tester.pumpWidget(MaterialApp(
      home: QuotationScreen(
        key: const ValueKey('return-from-receiving'),
        repository: repo,
        directory: DirectoryRepository(db),
        products: pos,
        user: auth.current!,
        initialQuotationReference: quote.reference,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text(quote.reference), findsWidgets);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('ready quotation detail shows checkout without next step',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Ready item',
        priceCents: 15000,
        costCents: 8000,
        startingStock: 2);
    final repo = QuotationRepository(db, pos);
    final quote =
        await repo.create(auth.current!, [QuoteLineRequest(productId, 1000)]);
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: repo,
            directory: DirectoryRepository(db),
            products: pos,
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(quote.reference));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('NEXT STEP'), findsNothing);
    expect(find.text('Ready for checkout'), findsWidgets);
    expect(find.text('Convert to sale'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'custom conversion creates a real zero-stock product before sourcing',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(id, 'password123');
    final pos = PosRepository(db);
    final repo = QuotationRepository(db, pos);
    final quote = await repo.create(auth.current!, [
      const QuoteLineRequest.custom('ASUS TUF B850-PLUS WIFI', 1000,
          unit: 'pcs', unitPriceCents: 1250000)
    ]);
    await tester.pumpWidget(MaterialApp(
        home: QuotationScreen(
            repository: repo,
            directory: DirectoryRepository(db),
            products: pos,
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(quote.reference));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Convert to sale'));
    await tester.tap(find.text('Convert to sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product'));
    await tester.pumpAndSettle();
    expect(find.text('ASUS TUF B850-PLUS WIFI'), findsWidgets);
    expect(find.widgetWithText(TextField, 'Product name *'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'SKU'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Barcode'), findsOneWidget);
    expect(find.widgetWithText(DropdownButtonFormField<String?>, 'Category'),
        findsOneWidget);
    expect(find.text('Serial tracking'), findsNothing);
    expect(
        tester
            .widget<TextField>(
                find.widgetWithText(TextField, 'Selling price *'))
            .controller!
            .text,
        '12500.00');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    expect(find.text('✓ Product created'), findsOneWidget);
    expect(find.text('Source from supplier'), findsOneWidget);
    final product = (await pos.products()).single;
    expect(product.name, 'ASUS TUF B850-PLUS WIFI');
    expect(await pos.stockMilli(product.id), 0);
    expect((await repo.items(quote.id)).single.productId, product.id);
    expect((await repo.items(quote.id)).single.unitPriceCents, 1250000);
    expect(await db.select(db.inventoryLayers).get(), isEmpty);
    expect(await db.select(db.sales).get(), isEmpty);
    await tester.tap(find.text('Back to quotation'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text(quote.reference), findsWidgets);
    await tester.ensureVisible(find.text('Convert to sale').last);
    await tester.tap(find.text('Convert to sale').last);
    await tester.pumpAndSettle();
    expect(find.text('Needs sourcing'), findsOneWidget);
  });

  for (final mobile in [false, true]) {
    testWidgets(
        'quotation workspace is structured on ${mobile ? 'mobile' : 'desktop'}',
        (tester) async {
      tester.view.physicalSize =
          mobile ? const Size(390, 844) : const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
      await auth.login(id, 'password123');
      await tester.pumpWidget(MaterialApp(
          home: QuotationScreen(
              repository: QuotationRepository(db, PosRepository(db)),
              directory: DirectoryRepository(db),
              products: PosRepository(db),
              user: auth.current!)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New quotation').first);
      await tester.pumpAndSettle();
      expect(find.text('Customer'), findsWidgets);
      expect(find.text('Walk-in customer'), findsWidgets);
      expect(find.text('Items'), findsWidgets);
      expect(find.text('Save quotation'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Save quotation'))
              .onPressed,
          isNull);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      expect(find.text('Select customer'), findsOneWidget);
      expect(find.text('Add new customer'), findsOneWidget);
      await tester.tap(find.text('Add new customer'));
      await tester.pumpAndSettle();
      expect(find.text('Add customer'), findsOneWidget);
      await tester.enterText(
          find
              .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(TextField))
              .first,
          'Quote customer');
      await tester.tap(find.text('Create & select'));
      await tester.pumpAndSettle();
      expect(find.text('Quote customer'), findsWidgets);
    });

    testWidgets(
        'layaway requires customer and items on ${mobile ? 'mobile' : 'desktop'}',
        (tester) async {
      tester.view.physicalSize =
          mobile ? const Size(390, 844) : const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
      await auth.login(id, 'password123');
      await tester.pumpWidget(MaterialApp(
          home: LayawayScreen(
              repository: LayawayRepository(db, PosRepository(db)),
              directory: DirectoryRepository(db),
              products: PosRepository(db),
              user: auth.current!)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New layaway'));
      await tester.pumpAndSettle();
      expect(find.text('Reserved items'), findsOneWidget);
      expect(find.text('Walk-in'), findsNothing);
      expect(find.text('Create layaway'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Create layaway'))
              .onPressed,
          isNull);
    });
  }
}
