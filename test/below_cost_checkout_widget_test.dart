import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/pos_layout_preference.dart';
import 'package:modern_offline_pos/data/daos/product_margin_repository.dart';

class _LongErrorAuth extends AuthService {
  _LongErrorAuth(super.repository);
  @override
  Future<BelowCostApproval> authorizeBelowCost(BelowCostQuote quote,
      String reason, {String? approverId, String? credential}) async {
    throw StateError('Authorization failed: ${List.filled(12,
        'Please check the approver credentials and try again. ').join()}');
  }
}

void main() {
  testWidgets('owner confirms below-cost Sale with required reason',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    await PosLayoutPreference.instance.setLayout(PosLayoutType.visualCatalog);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await pos.saveProduct(name: 'Below cost item', priceCents: 10000,
        costCents: 12000, startingStock: 1, openingCostCents: 12000);
    await tester.pumpWidget(MaterialApp(home: CheckoutScreen(
        repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Below cost item').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Manager authorization required'), findsOneWidget);
    final pay = find.byKey(const Key('pay-button'));
    await tester.enterText(find.byKey(const Key('cash-tendered')), '100');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(pay).onPressed, isNotNull);
    await tester.tap(pay);
    await tester.pumpAndSettle();
    expect(find.text('Below-Cost Sale Authorization'), findsOneWidget);
    await tester.tap(find.text('Authorize & Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('reason is required'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Reason *'), 'Clearance');
    await tester.tap(find.text('Authorize & Continue'));
    await tester.pumpAndSettle();
    expect((await db.select(db.sales).get()), hasLength(1));
    expect((await db.select(db.auditLogs).get())
        .where((row) => row.action == 'below_cost.sale_authorized'), hasLength(1));
  });

  testWidgets('dark 1366x768 dialog keeps long validation accessible',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await PosLayoutPreference.instance.load(force: true);
    await PosLayoutPreference.instance.setLayout(PosLayoutType.visualCatalog);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = _LongErrorAuth(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    await pos.saveProduct(name: 'Loss item', priceCents: 10000,
        costCents: 12000, startingStock: 1, openingCostCents: 12000);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home:
        CheckoutScreen(repository: pos, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Loss item').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cash-tendered')), '100');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay-button')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Reason *'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Reason *'), 'Clearance');
    await tester.tap(find.text('Authorize & Continue'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Authorization failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(await db.select(db.sales).get(), isEmpty);
  });
}
