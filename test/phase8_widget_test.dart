import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/auth/auth_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';
import 'package:modern_offline_pos/features/settings/business_features_screen.dart';

Future<void> openProductSection(WidgetTester tester, String section) async {
  section = switch (section) {
    'Selling method' => 'SELLING METHOD',
    'Tracking options' => 'TRACKING',
    'Special selling options' => 'SPECIAL SELLING',
    _ => section,
  };
  await tester.scrollUntilVisible(find.text(section), 250,
      scrollable: find
          .descendant(
              of: find.byKey(const ValueKey('product-editor-right')),
              matching: find.byType(Scrollable))
          .first);
  await tester.ensureVisible(find.text(section));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first-run choices allow multiple local features',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    await tester.pumpWidget(
        MaterialApp(home: AuthScreen(auth: auth, onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Owner name'), 'Owner');
    await tester.enterText(
        find.widgetWithText(TextField, 'Owner password (8+ characters)'),
        'password123');
    await tester.enterText(
        find.widgetWithText(TextField, 'Offline recovery question'),
        'Favorite place?');
    await tester.enterText(
        find.widgetWithText(TextField, 'Recovery answer'), 'Baguio');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    for (final feature in [
      BusinessFeature.weightBasedPricing,
      BusinessFeature.tankDepositExchange
    ]) {
      final tile = find.widgetWithText(CheckboxListTile, feature.displayName);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pump();
    }
    await tester.tap(find.text('Create owner'));
    await tester.pumpAndSettle();
    final flags = await BusinessFeatureRepository(db).availability();
    expect(flags[BusinessFeature.weightBasedPricing], true);
    expect(flags[BusinessFeature.tankDepositExchange], true);
    expect(flags.values.where((v) => v).length, 2);
  });

  testWidgets('Settings toggles persist and product fields follow availability',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'password123', 'Recovery question?', 'Secret answer');
    await auth.login(id, 'password123');
    final features = BusinessFeatureRepository(db);
    await tester.pumpWidget(MaterialApp(
        home:
            BusinessFeaturesScreen(repository: features, user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.text('Settings → Business Features'), findsOneWidget);
    await tester.tap(find.widgetWithText(
        SwitchListTile, BusinessFeature.weightBasedPricing.displayName));
    await tester.pumpAndSettle();
    expect((await features.availability())[BusinessFeature.weightBasedPricing],
        true);
    await tester.pumpWidget(MaterialApp(
        home: ProductScreen(repository: PosRepository(db), auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await openProductSection(tester, 'Selling method');
    expect(find.text('Sold by weight'), findsOneWidget);
    expect(find.text('Refill / container'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await features.setEnabled(
        BusinessFeature.weightBasedPricing, false, auth.current!);
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await openProductSection(tester, 'Selling method');
    expect(find.text('Sold by weight'), findsNothing);
  });

  final featureCases = <BusinessFeature, (BusinessProduct, String)>{
    BusinessFeature.weightBasedPricing: (
      const BusinessProduct(unit: SaleUnit.kilogram, weight: true),
      'Sold by weight'
    ),
    BusinessFeature.containerRefillPricing: (
      const BusinessProduct(
          unit: SaleUnit.bottle, refill: true, containerPriceCents: 1000),
      'Refill / container'
    ),
    BusinessFeature.tankDepositExchange: (
      const BusinessProduct(tank: true, depositCents: 50000),
      'LPG tank exchange / deposit'
    ),
    BusinessFeature.expiryBatchTracking: (
      const BusinessProduct(batch: true),
      'Batch / expiry'
    ),
    BusinessFeature.unitOfMeasureVariety: (
      const BusinessProduct(unit: SaleUnit.meter),
      'Unit'
    ),
    BusinessFeature.madeToOrderTracking: (
      const BusinessProduct(madeToOrder: true),
      'Made to order'
    ),
  };
  for (final entry in featureCases.entries) {
    testWidgets(
        '${entry.key.name} edit fields hide and restore without data loss',
        (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap(
          'Owner', 'password123', 'Recovery question?', 'Secret answer');
      await auth.login(id, 'password123');
      final features = BusinessFeatureRepository(db);
      await features.setEnabled(entry.key, true, auth.current!);
      final repo = PosRepository(db);
      final productId = await repo.saveProduct(
          name: 'Special',
          priceCents: 5000,
          costCents: 0,
          business: entry.value.$1);
      final before = await features.productConfiguration(productId, entry.key);
      await tester.pumpWidget(
          MaterialApp(home: ProductScreen(repository: repo, auth: auth)));
      await tester.pumpAndSettle();
      Future<void> openEdit() async {
        await tester.tap(find.text('Special').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit product'));
        await tester.pumpAndSettle();
        final section = switch (entry.key) {
          BusinessFeature.weightBasedPricing ||
          BusinessFeature.unitOfMeasureVariety ||
          BusinessFeature.madeToOrderTracking =>
            'Selling method',
          BusinessFeature.expiryBatchTracking => 'Tracking options',
          _ => 'Special selling options',
        };
        await openProductSection(tester, section);
      }

      Future<void> closeEdit() async {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }

      await openEdit();
      expect(find.text(entry.value.$2), findsOneWidget);
      await closeEdit();
      await features.setEnabled(entry.key, false, auth.current!);
      await openEdit();
      expect(
          find.text(entry.value.$2),
          entry.key == BusinessFeature.unitOfMeasureVariety
              ? findsOneWidget
              : findsNothing);
      await closeEdit();
      expect(await features.productConfiguration(productId, entry.key), before);
      await features.setEnabled(entry.key, true, auth.current!);
      await openEdit();
      expect(find.text(entry.value.$2), findsOneWidget);
      expect(await features.productConfiguration(productId, entry.key), before);
    });
  }

  testWidgets('adaptive Add and Edit save weighted stock and price',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'password123', 'Recovery question?', 'Secret answer');
    await auth.login(id, 'password123');
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, auth.current!);
    final repo = PosRepository(db);
    await tester.pumpWidget(
        MaterialApp(home: ProductScreen(repository: repo, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Product name *'), 'Rice');
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '50');
    await tester.tap(find.text('No stock yet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('I already have stock').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Opening quantity *'), '10.000');
    await tester.enterText(
        find.widgetWithText(TextField, 'Cost per unit *'), '20');
    await openProductSection(tester, 'Selling method');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Sold by weight'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create product').last);
    await tester.pumpAndSettle();
    final product = (await repo.products()).single;
    expect(product.business.weight, true);
    expect(product.business.unit, SaleUnit.kilogram);
    expect(await repo.stockMilli(product.id), 10000);
    await tester.tap(find.text('Rice').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit product'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Selling price *'), '55');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect((await repo.products()).single.priceCents, 5500);
    expect((await repo.products()).single.business.weight, true);
    expect(await repo.stockMilli(product.id), 10000);
  });
}
