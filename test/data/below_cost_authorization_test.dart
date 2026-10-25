import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/product_margin_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_order_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/data/daos/promotion_repository.dart';
import 'package:modern_offline_pos/core/services/promotion_checkout_service.dart';
import 'package:modern_offline_pos/core/models/manual_discount.dart';
import 'package:modern_offline_pos/core/services/sale_service.dart';
import 'package:modern_offline_pos/data/daos/loyalty_repository.dart';

void main() {
  test('only negative known cart margin needs authorization', () {
    BelowCostQuote quote(int? cost, int selling) =>
        ProductMarginRepository.quote([
          MarginSaleLine('a', 'a', 1000, selling, cost, 'ordinary', null, const [])
        ], selling);
    expect(quote(9000, 10000).isBelowCost, isFalse);
    expect(quote(10000, 10000).isBelowCost, isFalse);
    expect(quote(11000, 10000).isBelowCost, isTrue);
    expect(quote(null, 10000).isBelowCost, isFalse);
    expect(ProductMarginRepository.quote([
      const MarginSaleLine('a', 'a', 1000, 10000, 12000, 'ordinary', null, []),
      const MarginSaleLine('b', 'b', 1000, 10000, null, 'ordinary', null, []),
    ], 20000).isBelowCost, isFalse);
    expect(ProductMarginRepository.quote([
      const MarginSaleLine('a', 'a', 1000, 10000, 8000, 'ordinary', null, []),
      const MarginSaleLine('b', 'b', 1000, 10000, 11000, 'ordinary', null, []),
    ], 20000).isBelowCost, isFalse);
  });

  test('checkout fingerprint follows economics, not tender or payment', () {
    BelowCostQuote quote(int quantity, int price, int cost, int net) =>
        ProductMarginRepository.quote([
          MarginSaleLine('line', 'product', quantity, price, cost,
              'ordinary', null, const [])
        ], net);
    final original = quote(1000, 10000, 12000, 9000);
    expect(quote(1000, 10000, 12000, 9000).fingerprint,
        original.fingerprint);
    expect(quote(2000, 20000, 24000, 18000).fingerprint,
        isNot(original.fingerprint));
    expect(quote(1000, 11000, 12000, 9000).fingerprint,
        isNot(original.fingerprint));
    expect(quote(1000, 10000, 13000, 9000).fingerprint,
        isNot(original.fingerprint));
    expect(quote(1000, 10000, 12000, 8500).fingerprint,
        isNot(original.fingerprint));
    final added = ProductMarginRepository.quote([
      const MarginSaleLine('line', 'product', 1000, 10000, 12000,
          'ordinary', null, []),
      const MarginSaleLine('other', 'other', 1000, 1000, 1200,
          'ordinary', null, []),
    ], 10000);
    expect(added.fingerprint, isNot(original.fingerprint));
    final selectedBatch = ProductMarginRepository.quote([
      const MarginSaleLine('line', 'product', 1000, 10000, 12000,
          'ordinary', 'batch-1', []),
    ], 9000);
    expect(selectedBatch.fingerprint, isNot(original.fingerprint));
    final selectedSerial = ProductMarginRepository.quote([
      const MarginSaleLine('line', 'product', 1000, 10000, 12000,
          'ordinary', null, ['serial-1']),
    ], 9000);
    expect(selectedSerial.fingerprint, isNot(original.fingerprint));
  });

  test('existing Manager role gains below-cost capability on reopen', () async {
    final dir = await Directory.systemTemp.createTemp('below-cost-role-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/store.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final manager = await auth.createUser(
        'Manager', UserRole.manager, 'managerPassword123');
    await db.customStatement("DELETE FROM role_permissions WHERE role_code = 'manager' "
        "AND permission_key = 'authorizeBelowCost'");
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    expect((await AuthRepository(db).requireActive(manager))
        .can(PosPermission.authorizeBelowCost), isTrue);
  });

  test('invalid Manager credentials use the existing lockout', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final manager = await auth.createUser(
        'Manager', UserRole.manager, 'managerPassword123');
    final cashier = await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.login(cashier, '1234');
    final quote = ProductMarginRepository.quote([
      const MarginSaleLine('line', 'product', 1000, 10000, 12000,
          'ordinary', null, []),
    ], 10000);
    for (var i = 0; i < AuthService.maxAttempts; i++) {
      await expectLater(auth.authorizeBelowCost(quote, 'Clearance',
          approverId: manager, credential: 'wrong'), throwsStateError);
    }
    expect((await AuthRepository(db).user(manager))!.lockedUntil, isNotNull);
    await expectLater(auth.authorizeBelowCost(quote, 'Clearance',
        approverId: manager, credential: 'managerPassword123'),
        throwsStateError);
    expect((await db.select(db.auditLogs).get())
        .where((row) => row.action == 'below_cost.sale_authorized'), isEmpty);
  });

  test('cashier needs manager credential and exact one-time approval', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final manager = await auth.createUser('Manager', UserRole.manager, 'managerPassword123');
    final cashier = await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.login(cashier, '1234');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(name: 'Loss item', priceCents: 10000,
        costCents: 12000, startingStock: 2, openingCostCents: 12000);
    final cart = Cart()..add((await pos.products()).single);
    final quote = await ProductMarginRepository(db).quoteCart(cart, 10000);
    expect(quote.expectedCostCents, 12000);
    expect(quote.estimatedLossCents, 2000);
    final item = SaleLineRequest(id, 1, lineKey: cart.lines.single.id);
    await expectLater(pos.completeCashSale([item], 10000, cashier), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await pos.stockMilli(id), 2000);
    expect((await db.select(db.auditLogs).get())
        .where((a) => a.action == 'below_cost.sale_authorized'), isEmpty);
    await expectLater(auth.authorizeBelowCost(quote, 'Price match'),
        throwsStateError);
    await expectLater(auth.authorizeBelowCost(quote, ' ', approverId: manager,
        credential: 'managerPassword123'), throwsStateError);
    await expectLater(auth.authorizeBelowCost(quote, 'Price match',
        approverId: manager, credential: 'wrong'), throwsStateError);
    expect((await AuthRepository(db).user(manager))!.failedAttempts, 1);
    final approval = await auth.authorizeBelowCost(quote, 'Price match',
        approverId: manager, credential: 'managerPassword123');
    await expectLater(pos.completeCashSale([item], 1, cashier,
        belowCostApproval: approval), throwsStateError);
    expect(approval.matches(cashier, quote), isTrue);
    await expectLater(pos.completeCashSale(
        [SaleLineRequest(id, 2, lineKey: cart.lines.single.id)],
        20000, cashier, belowCostApproval: approval), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await pos.stockMilli(id), 2000);
    final changed = ProductMarginRepository.quote([
      const MarginSaleLine('changed', 'changed', 1000, 10000, 12000,
          'ordinary', null, []),
    ], 10000);
    expect(approval.matches(cashier, changed), isFalse);
    await db.customStatement('''CREATE TRIGGER reject_below_cost_audit
      BEFORE INSERT ON audit_logs
      WHEN NEW.action = 'below_cost.sale_authorized'
      BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END''');
    await expectLater(pos.completeCashSale([item], 10000, cashier,
        belowCostApproval: approval), throwsA(isA<Exception>()));
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await pos.stockMilli(id), 2000);
    expect(approval.matches(cashier, quote), isTrue);
    await db.customStatement('DROP TRIGGER reject_below_cost_audit');
    final sale = await pos.completeCashSale([item], 10000, cashier,
        belowCostApproval: approval);
    expect((await db.select(db.sales).get()).single.id, sale.saleId);
    expect(await pos.stockMilli(id), 1000);
    final audits = (await db.select(db.auditLogs).get())
        .where((a) => a.action == 'below_cost.sale_authorized').toList();
    expect(audits, hasLength(1));
    final details = jsonDecode(audits.single.details!) as Map<String, dynamic>;
    expect(details['saleId'], sale.saleId);
    expect(details['approverId'], manager);
    expect(details['reason'], 'Price match');
    expect(details['estimatedLossCents'], 2000);
    await expectLater(pos.completeCashSale([item], 10000, cashier,
        belowCostApproval: approval), throwsStateError);
    expect(await pos.stockMilli(id), 1000);
  });

  test('credit checkout keeps normal receivable after authorization', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Ana');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Clearance', priceCents: 8000,
        costCents: 9000, startingStock: 1, openingCostCents: 9000);
    final cart = Cart()..add((await pos.products()).single);
    final quote = await ProductMarginRepository(db).quoteCart(cart, 8000);
    final approval = await auth.authorizeBelowCost(quote, 'Clearance');
    final sale = await pos.completeCreditSale([
      SaleLineRequest(product, 1, lineKey: cart.lines.single.id)
    ], 0, customer.id, owner, belowCostApproval: approval);
    expect(sale.totalCents, 8000);
    expect((await db.select(db.customerCreditEntries).get())
        .single.amountCents, 8000);
  });

  test('one approval cannot authorize two concurrent Sale commits', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Loss', priceCents: 10000,
        costCents: 12000, startingStock: 2, openingCostCents: 12000);
    final cart = Cart()..add((await pos.products()).single);
    final quote = await ProductMarginRepository(db).quoteCart(cart, 10000);
    final approval = await auth.authorizeBelowCost(quote, 'Clearance');
    final item = SaleLineRequest(product, 1, lineKey: cart.lines.single.id);
    final outcomes = await Future.wait([
      for (var i = 0; i < 2; i++)
        pos.completeCashSale([item], 10000, owner,
            belowCostApproval: approval).then<Object>((sale) => sale,
            onError: (Object error) => error),
    ]);
    expect(outcomes.whereType<CommittedSale>(), hasLength(1));
    expect((await db.select(db.sales).get()), hasLength(1));
    expect((await db.select(db.auditLogs).get())
        .where((row) => row.action == 'below_cost.sale_authorized'),
        hasLength(1));
    expect(await pos.stockMilli(product), 1000);
  });

  test('Sales Order price stays agreed and delivery fee cannot hide loss',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final owner = auth.current!;
    final customer = await DirectoryRepository(db)
        .saveCustomer(owner, name: 'Ana');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Order item',
        priceCents: 10000, costCents: 12000, startingStock: 1,
        openingCostCents: 12000);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 1000, 10000, discountCents: 1000)]);
    await orders.transition(owner, order.id, 'confirmed');
    await orders.configurePhysical(owner, order.id,
        method: 'delivery', contactName: 'Ana', address: 'City',
        deliveryFeeCents: 5000);
    final line = (await orders.lines(order.id)).single;
    await pos.saveProduct(id: product, name: 'Order item',
        priceCents: 20000, costCents: 12000);
    final cart = Cart()..restoreLine(CartLine(
        (await pos.products()).single, 1000, id: line.id)..pricedTotalCents = 9000);
    final quote = await ProductMarginRepository(db).quoteCart(cart, 9000);
    expect(quote.estimatedLossCents, 3000);
    await expectLater(pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: line.id)
    ], 14000, ownerId, customerId: customer.id,
        salesOrderId: order.id), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    final approval = await auth.authorizeBelowCost(quote, 'Price honored');
    final sale = await pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: line.id)
    ], 14000, ownerId, customerId: customer.id,
        salesOrderId: order.id, belowCostApproval: approval);
    expect(sale.totalCents, 14000);
    expect((await orders.lines(order.id)).single.unitPriceCents, 10000);
    final audit = (await db.select(db.auditLogs).get())
        .singleWhere((row) => row.action == 'below_cost.sale_authorized');
    expect((jsonDecode(audit.details!) as Map<String, dynamic>)['saleValueCents'],
        9000);
  });

  test('failed BIR authorization allocates no invoice', () async {
    final dir = await Directory.systemTemp.createTemp('below-cost-bir-');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final protection = ComplianceProtection(File('${dir.path}/compliance.json'));
    await CashSessionRepository(db, birReady: true, protection: protection)
        .open(auth.current!, 0);
    final pos = PosRepository(db, birReady: true, protection: protection);
    final product = await pos.saveProduct(name: 'Loss', priceCents: 10000,
        costCents: 11000, startingStock: 1, openingCostCents: 11000);
    await expectLater(pos.completeCashSale([
      SaleLineRequest(product, 1)
    ], 10000, owner), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.birComplianceState).get(), isEmpty);
    expect(await pos.stockMilli(product), 1000);
    final cart = Cart()..add((await pos.products()).single);
    final quote = await ProductMarginRepository(db).quoteCart(cart, 10000);
    final approval = await auth.authorizeBelowCost(quote, 'Clearance');
    final sale = await pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: cart.lines.single.id)
    ], 10000, owner, belowCostApproval: approval);
    expect(sale.birInvoiceNumber, 1);
    expect((await db.select(db.birComplianceState).get())
        .single.highestInvoiceNumber, 1);
  });

  test('promotion net value triggers guard before Sale commit', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Promoted item',
        priceCents: 10000, costCents: 9500, startingStock: 1,
        openingCostCents: 9500);
    await PromotionRepository(db).createPromotion(auth.current!,
        const PromotionInput(name: 'Sale', type: 'fixed',
            rewardKind: 'fixed', rewardValue: 1000, active: true));
    final cart = Cart()..add((await pos.products()).single);
    final discount = (await PromotionCheckoutService(PromotionRepository(db))
        .evaluate(auth.current!, cart, DateTime.now())).totalDiscountCents;
    expect(discount, 1000);
    final quote = await ProductMarginRepository(db)
        .quoteCart(cart, cart.totalCents - discount);
    expect(quote.estimatedLossCents, 500);
    final item = SaleLineRequest(product, 1, lineKey: cart.lines.single.id);
    await expectLater(pos.completeCashSale([item], 9000, owner), throwsStateError);
    final approval = await auth.authorizeBelowCost(quote, 'Promotion clearance');
    final sale = await pos.completeCashSale([item], 9000, owner,
        belowCostApproval: approval);
    expect(sale.totalCents, 9000);
  });

  test('manual discount net value triggers guard', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Discounted item',
        priceCents: 10000, costCents: 9500, startingStock: 1,
        openingCostCents: 9500);
    final discount = ManualDiscount(scope: 'order', kind: 'fixed', value: 1000,
        reason: 'Price match', requestedBy: owner, authorizedBy: owner,
        authorizedAt: DateTime.now(), approvedBasisCents: 10000);
    final cart = Cart()..add((await pos.products()).single);
    final quote = await ProductMarginRepository(db).quoteCart(cart, 9000);
    final item = SaleLineRequest(product, 1, lineKey: cart.lines.single.id);
    await expectLater(pos.completeCashSale([item], 9000, owner,
        manualDiscount: discount), throwsStateError);
    final approval = await auth.authorizeBelowCost(quote, 'Manager decision');
    final sale = await pos.completeCashSale([item], 9000, owner,
        manualDiscount: discount, belowCostApproval: approval);
    expect(sale.totalCents, 9000);
    expect((await db.select(db.saleManualDiscounts).get()), hasLength(1));
  });

  test('actual rewards redemption uses committed net selling value', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Rewards customer');
    final loyalty = LoyaltyRepository(db);
    await loyalty.adjust(customer.id, owner, 100, 'Test balance');
    final pos = PosRepository(db);
    await pos.saveProduct(name: 'Rewards item', priceCents: 10000,
        costCents: 9500, startingStock: 1, openingCostCents: 9500);
    final cart = Cart()..add((await pos.products()).single);
    final quote = await ProductMarginRepository(db).quoteCart(cart, 9000);
    expect(quote.expectedCostCents, 9500);
    expect(quote.estimatedLossCents, 500);
    final sales = SaleService(pos, auth);
    await expectLater(sales.checkout(cart, 9000, customerId: customer.id,
        redeemPoints: 100, rewardDiscountCents: 1000), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await loyalty.balance(customer.id), 100);
    final approval = await auth.authorizeBelowCost(quote, 'Rewards clearance');
    final sale = await sales.checkout(cart, 9000, customerId: customer.id,
        redeemPoints: 100, rewardDiscountCents: 1000,
        belowCostApproval: approval);
    expect(sale.totalCents, 9000);
    final reward = await db.customSelect(
        'SELECT discount_cents FROM sale_loyalty WHERE sale_id = ?',
        variables: [Variable.withString(sale.saleId)]).getSingle();
    expect(reward.read<int>('discount_cents'), 1000);
    final audit = (await db.select(db.auditLogs).get())
        .singleWhere((row) => row.action == 'below_cost.sale_authorized');
    final details = jsonDecode(audit.details!) as Map<String, dynamic>;
    expect(details['saleValueCents'], 9000);
    expect(details['expectedCostCents'], 9500);
  });
}
