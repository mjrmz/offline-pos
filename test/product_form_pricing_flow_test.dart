import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

Future<PosRepository> openProductForm(WidgetTester tester,
    {bool batch = false,
    bool weight = false,
    void Function(String)? onReceiveStock}) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final auth = AuthService(AuthRepository(db));
  final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'Answer');
  await auth.login(owner, 'password123');
  if (batch) {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, auth.current!);
  }
  if (weight) {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, auth.current!);
  }
  final repo = PosRepository(db);
  await tester.pumpWidget(MaterialApp(
      home: ProductScreen(
          repository: repo,
          auth: auth,
          onReceiveStock: onReceiveStock ?? (_) {})));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Add product').first);
  await tester.pumpAndSettle();
  return repo;
}

Future<void> showInForm(WidgetTester tester, Finder finder,
    {double delta = 240}) async {
  final scrollable = find
      .descendant(
          of: find.byType(Dialog).last, matching: find.byType(Scrollable))
      .first;
  await tester.scrollUntilVisible(finder, delta, scrollable: scrollable);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> selectLayerPricing(WidgetTester tester) async {
  await showInForm(tester, find.text('PRICING'));
  await tester.tap(find.text('Use one product price'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Price each stock layer separately').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('zero and supplier paths show only their required prices',
      (tester) async {
    await openProductForm(tester);
    await showInForm(tester, find.text('PRICING'));
    expect(find.widgetWithText(TextField, 'Selling price *'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Opening quantity *'), findsNothing);
    await selectLayerPricing(tester);
    expect(find.widgetWithText(TextField, 'Selling price *'), findsNothing);
    expect(find.widgetWithText(TextField, 'Opening quantity *'), findsNothing);

    await showInForm(tester, find.text('Receive from supplier'), delta: -240);
    await tester.tap(find.text('Receive from supplier'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('PRICING'));
    expect(find.widgetWithText(TextField, 'Selling price *'), findsNothing);
    expect(find.widgetWithText(TextField, 'Opening quantity *'), findsNothing);
    await tester.tap(find.text('Price each stock layer separately'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use one product price').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Selling price *'), findsOneWidget);
  });

  testWidgets(
      'product-priced opening stock has one sale price and blank required quantity',
      (tester) async {
    final repo = await openProductForm(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Opening item');
    await showInForm(tester, find.text('I already have stock'));
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('PRICING'));
    await showInForm(
        tester, find.widgetWithText(TextField, 'Opening quantity *'));
    final quantity = find.widgetWithText(TextField, 'Opening quantity *');
    expect(tester.widget<TextField>(quantity).controller!.text, isEmpty);
    expect(find.widgetWithText(TextField, 'Selling price *'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '15');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    expect(find.text('Opening quantity is required.'), findsOneWidget);
    for (final invalid in ['0', '-1', 'abc']) {
      await tester.enterText(quantity, invalid);
      await tester.tap(find.text('Create product').last);
      await tester.pumpAndSettle();
      expect(find.text('Quantity must be greater than zero.'), findsOneWidget);
    }
    await tester.enterText(quantity, '3');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    expect(find.text('Opening cost is required.'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost per unit *'), '9');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    final layer = (await repo.layersForProduct(product.id)).single;
    expect(product.priceCents, 1500);
    expect(layer.unitCostCents, 900);
    expect(layer.unitSellingPriceCents, isNull);
    expect(layer.quantityRemainingMilli, 3000);
  });

  testWidgets(
      'layer-priced opening stock saves its one sale price on the layer',
      (tester) async {
    final repo = await openProductForm(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Layer opening');
    await showInForm(tester, find.text('I already have stock'));
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await selectLayerPricing(tester);
    await showInForm(
        tester, find.widgetWithText(TextField, 'Opening quantity *'));
    expect(find.widgetWithText(TextField, 'Selling price *'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Opening quantity *'), '2');
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost per unit *'), '10');
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '18');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    final layer = (await repo.layersForProduct(product.id)).single;
    expect(product.pricingPolicy, 'layer');
    expect(product.priceCents, 0);
    expect(layer.unitCostCents, 1000);
    expect(layer.unitSellingPriceCents, 1800);
    expect(layer.quantityRemainingMilli, 2000);
  });

  testWidgets('batch opening derives quantity and uses one product price',
      (tester) async {
    final repo = await openProductForm(tester, batch: true);
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Batch opening');
    await showInForm(tester, find.text('Batch / expiry'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Batch / expiry'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('I already have stock'));
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('PRICING'));
    expect(find.byKey(const ValueKey('product-selling-price')), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '15');
    await showInForm(tester, find.text('OPENING BATCHES'));
    expect(find.widgetWithText(TextField, 'Opening quantity *'), findsNothing);
    expect(find.widgetWithText(TextField, 'Selling *'), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextField, 'Batch / lot *').first, 'A');
    await tester.enterText(find.widgetWithText(TextField, 'Qty *').first, '2');
    await tester.enterText(find.widgetWithText(TextField, 'Cost *').first, '9');
    await tester.tap(find.text('Add batch'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Batch / lot *').last, 'B');
    await tester.enterText(find.widgetWithText(TextField, 'Qty *').last, '3');
    await tester.enterText(find.widgetWithText(TextField, 'Cost *').last, '10');
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('Total opening quantity: 5 pcs'));
    expect(find.text('Total opening quantity: 5 pcs'), findsOneWidget);
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    final layers = await repo.layersForProduct(product.id);
    expect(product.priceCents, 1500);
    expect(layers.length, 2);
    expect(
        layers.fold<int>(0, (sum, l) => sum + l.quantityRemainingMilli), 5000);
    expect(layers.every((l) => l.unitSellingPriceCents == null), isTrue);
  });

  testWidgets('serial opening derives quantity without a second sale price',
      (tester) async {
    final repo = await openProductForm(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Serialized item');
    await showInForm(tester, find.text('Serial numbers'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Serial numbers'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('I already have stock'));
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('PRICING'));
    expect(find.byKey(const ValueKey('product-selling-price')), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '100');
    await showInForm(tester, find.widgetWithText(TextField, 'Cost per unit *'));
    expect(find.byKey(const ValueKey('opening-selling-price')), findsNothing);
    expect(find.widgetWithText(TextField, 'Opening quantity *'), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost per unit *'), '60');
    await showInForm(
        tester, find.widgetWithText(TextField, 'Scan or enter serial number'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Scan or enter serial number'), 'SN-1');
    await tester.tap(find.text('Add serial'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    expect(product.priceCents, 10000);
    expect(
        (await repo.layersForProduct(product.id)).single.quantityRemainingMilli,
        1000);
    expect((await repo.availableSerials(product.id)).length, 1);
  });

  testWidgets('weighted opening quantity accepts fixed-point kg',
      (tester) async {
    final repo = await openProductForm(tester, weight: true);
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Rice');
    await showInForm(tester, find.text('Sold by weight'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Sold by weight'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('I already have stock'));
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await showInForm(tester, find.text('PRICING'));
    await showInForm(
        tester, find.widgetWithText(TextField, 'Opening quantity *'));
    expect(
        tester
            .widget<TextField>(
                find.widgetWithText(TextField, 'Opening quantity *'))
            .decoration!
            .suffixText,
        'kg');
    await tester.enterText(
        find.widgetWithText(TextField, 'Opening quantity *'), '100.250');
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost per unit *'), '42');
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '50');
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    expect(product.business.unit.label, 'kg');
    expect(
        (await repo.layersForProduct(product.id)).single.quantityRemainingMilli,
        100250);
  });

  for (final layerPricing in [false, true]) {
    testWidgets(
        'supplier path creates zero stock with ${layerPricing ? 'layer' : 'product'} pricing',
        (tester) async {
      String? receivingProductId;
      final repo = await openProductForm(tester,
          onReceiveStock: (id) => receivingProductId = id);
      await tester.enterText(find.widgetWithText(TextField, 'Product name *'),
          layerPricing ? 'Layer supplier item' : 'Product supplier item');
      await showInForm(tester, find.text('Receive from supplier'));
      await tester.tap(find.text('Receive from supplier'));
      await tester.pumpAndSettle();
      if (layerPricing) {
        await selectLayerPricing(tester);
        expect(find.widgetWithText(TextField, 'Selling price *'), findsNothing);
      } else {
        await showInForm(tester, find.text('PRICING'));
        await tester.enterText(
            find.widgetWithText(TextField, 'Selling price *'), '24');
      }
      expect(
          find.widgetWithText(TextField, 'Opening quantity *'), findsNothing);
      await tester.tap(find.text('Create & Continue to Receiving').last);
      await tester.pumpAndSettle();
      final product = (await repo.products()).single;
      expect(receivingProductId, product.id);
      expect(product.priceCents, layerPricing ? 0 : 2400);
      expect(await repo.stockMilli(product.id), 0);
      expect(await repo.layersForProduct(product.id), isEmpty);
    });
  }
}
