import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/promotion_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/pos_layout_preference.dart';

void main() {
  Future<(AppDatabase, AuthService, PosRepository)> mount(WidgetTester tester,
      {bool scanFirst = false,
      Size size = const Size(1366, 768),
      ThemeMode theme = ThemeMode.light,
      bool registerClose = true}) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    await PosLayoutPreference.instance.setLayout(
        scanFirst ? PosLayoutType.scanFirst : PosLayoutType.visualCatalog);
    addTearDown(() async {
      await PosLayoutPreference.instance.setLayout(PosLayoutType.visualCatalog);
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    if (registerClose) addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await pos.saveProduct(
        name: 'Bread',
        barcode: 'BREAD',
        priceCents: 10000,
        costCents: 1000,
        startingStock: 5);
    final promotions = PromotionRepository(db);
    await promotions.createPromotion(
        auth.current!,
        const PromotionInput(
            name: 'Weekend Sale',
            type: 'percentage',
            rewardKind: 'percentage',
            rewardValue: 1000,
            active: true));
    await promotions.createPromotion(
        auth.current!,
        const PromotionInput(
            name: 'Small Saving',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 500,
            active: true));
    await tester.pumpWidget(MaterialApp(
        themeMode: theme,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        home:
            CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    return (db, auth, pos);
  }

  testWidgets('visual totals, details and manual conflict choices',
      (tester) async {
    await mount(tester);
    await tester.tap(find.text('Bread').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('applied-promotion-row')), findsOneWidget);
    expect(find.textContaining('Pay ₱90.00'), findsOneWidget);
    expect(find.text('Estimated cart margin: ₱80.00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('applied-promotion-row')));
    await tester.pumpAndSettle();
    expect(find.text('Available promotions'), findsOneWidget);
    expect(find.text('Small Saving'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ Add discount'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('manual-discount-value')), '15');
    await tester.enterText(
        find.byKey(const Key('manual-discount-password')), 'password123');
    await tester.tap(find.text('Authorize'));
    await tester.pumpAndSettle();
    expect(find.text('Choose discount'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pay ₱90.00'), findsOneWidget);
    await tester.tap(find.text('+ Add discount'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('manual-discount-value')), '15');
    await tester.enterText(
        find.byKey(const Key('manual-discount-password')), 'password123');
    await tester.tap(find.text('Authorize'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep promotion'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pay ₱90.00'), findsOneWidget);
    await tester.tap(find.text('+ Add discount'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('manual-discount-value')), '15');
    await tester.enterText(
        find.byKey(const Key('manual-discount-password')), 'password123');
    await tester.tap(find.text('Authorize'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use manual discount'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pay ₱85.00'), findsOneWidget);
    expect(find.byKey(const Key('applied-promotion-row')), findsNothing);
    expect(find.text('Estimated cart margin: ₱75.00'), findsOneWidget);
    final state = tester.state<CheckoutScreenState>(find.byType(CheckoutScreen));
    state.rewardDiscountCents = 500;
    await tester.enterText(find.byKey(const Key('cash-tendered')), '0');
    await tester.pumpAndSettle();
    expect(find.text('Estimated cart margin: ₱70.00'), findsOneWidget);
  });

  testWidgets('cashier cannot see POS cost or estimated margin', (tester) async {
    final setup = await mount(tester);
    final cashier = await setup.$2.createUser('Cashier', UserRole.cashier, '1234');
    await setup.$2.login(cashier, '1234');
    await tester.pumpWidget(MaterialApp(home: CheckoutScreen(
        repository: setup.$3, user: setup.$2.current!, auth: setup.$2)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bread').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Estimated cart margin'), findsNothing);
    expect(find.textContaining('FIFO Cost'), findsNothing);
  });

  testWidgets('scan first shares discount and preserves scanner focus',
      (tester) async {
    await mount(tester, scanFirst: true);
    final scan = find.byKey(const Key('scan-first-input'));
    await tester.enterText(scan, 'BREAD');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('applied-promotion-row')), findsOneWidget);
    expect(find.textContaining('Pay ₱90.00'), findsOneWidget);
    final state =
        tester.state<CheckoutScreenState>(find.byType(CheckoutScreen));
    expect(state.barcodeFocus.hasFocus, isTrue);
  });

  testWidgets('resumed held sale re-evaluates current promotion validity',
      (tester) async {
    final setup = await mount(tester);
    await tester.tap(find.text('Bread').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('applied-promotion-row')), findsOneWidget);
    await tester.tap(find.textContaining('Hold sale').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hold sale').last);
    await tester.pumpAndSettle();
    final rule = (await setup.$1.select(setup.$1.promotions).get()).first;
    await PromotionRepository(setup.$1)
        .setActive(setup.$2.current!, rule.id, false);
    await tester.tap(find.textContaining('Held sales').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Promotion · Small Saving'), findsOneWidget);
    expect(find.textContaining('Pay ₱95.00'), findsOneWidget);
  });

  testWidgets('promotion totals fit desktop sizes in light and dark',
      (tester) async {
    for (final size in [
      const Size(1366, 768),
      const Size(1600, 900),
      const Size(1920, 1080)
    ]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        final setup =
            await mount(tester, size: size, theme: mode, registerClose: false);
        await tester.tap(find.text('Bread').first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('applied-promotion-row')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await setup.$1.close();
      }
    }
  });
}
