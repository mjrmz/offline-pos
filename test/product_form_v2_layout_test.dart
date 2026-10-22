import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  testWidgets('batch stock fields appear only for opening inventory',
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
    await tester.pumpWidget(MaterialApp(
      home: ProductScreen(
          repository: PosRepository(db), auth: auth, onReceiveStock: (_) {}),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    final left = find
        .descendant(
            of: find.byKey(const ValueKey('product-editor-left')),
            matching: find.byType(Scrollable))
        .first;
    final right = find
        .descendant(
            of: find.byKey(const ValueKey('product-editor-right')),
            matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('Batch / expiry'), 250,
        scrollable: right);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Batch / expiry'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Batch / lot *'), findsNothing);
    await tester.scrollUntilVisible(find.text('Receive from supplier'), 250,
        scrollable: left);
    await tester.tap(find.text('Receive from supplier'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Batch / lot *'), findsNothing);
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('OPENING BATCHES'), 250,
        scrollable: left);
    expect(find.widgetWithText(TextField, 'Batch / lot *'), findsOneWidget);
  });

  testWidgets('serial entry appears only for opening inventory',
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
    await tester.pumpWidget(MaterialApp(
      home: ProductScreen(
          repository: PosRepository(db), auth: auth, onReceiveStock: (_) {}),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add product').first);
    await tester.pumpAndSettle();
    final left = find
        .descendant(
            of: find.byKey(const ValueKey('product-editor-left')),
            matching: find.byType(Scrollable))
        .first;
    final right = find
        .descendant(
            of: find.byKey(const ValueKey('product-editor-right')),
            matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('Serial numbers'), 250,
        scrollable: right);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Serial numbers'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Scan or enter serial number'),
        findsNothing);
    await tester.scrollUntilVisible(find.text('Receive from supplier'), 250,
        scrollable: left);
    await tester.tap(find.text('Receive from supplier'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Scan or enter serial number'),
        findsNothing);
    await tester.tap(find.text('I already have stock'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('OPENING SERIALS · 0 units'), 250,
        scrollable: left);
    expect(find.widgetWithText(TextField, 'Scan or enter serial number'),
        findsOneWidget);
  });
  for (final size in [
    const Size(1366, 768),
    const Size(1600, 900),
    const Size(1920, 1080),
  ]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('Product form fits $size in $mode', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final auth = AuthService(AuthRepository(db));
        final owner =
            await auth.bootstrap('Owner', 'password123', 'Q?', 'Answer');
        await auth.login(owner, 'password123');
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: mode,
          home: ProductScreen(repository: PosRepository(db), auth: auth),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add product').first);
        await tester.pumpAndSettle();
        expect(find.text('PRODUCT'), findsOneWidget);
        expect(find.text('PRODUCT BEHAVIOR'), findsOneWidget);
        expect(
            find.byKey(const ValueKey('product-editor-left')), findsOneWidget);
        expect(
            find.byKey(const ValueKey('product-editor-right')), findsOneWidget);
        final productRect = tester.getRect(find.text('PRODUCT'));
        final behaviorRect = tester.getRect(find.text('PRODUCT BEHAVIOR'));
        expect(productRect.left, lessThan(behaviorRect.left));
        expect(find.text('STARTING INVENTORY'), findsOneWidget);
        expect(find.text('Cancel'), findsWidgets);
        expect(tester.takeException(), isNull);
        final left = find
            .descendant(
                of: find.byKey(const ValueKey('product-editor-left')),
                matching: find.byType(Scrollable))
            .first;
        final right = find
            .descendant(
                of: find.byKey(const ValueKey('product-editor-right')),
                matching: find.byType(Scrollable))
            .first;
        await tester.scrollUntilVisible(find.text('PRICING'), 240,
            scrollable: left);
        expect(find.text('PRICING'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('ADVANCED'), 240,
            scrollable: right);
        await tester.pumpAndSettle();
        expect(find.text('Low-stock alert threshold'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
