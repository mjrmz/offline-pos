import 'package:drift/drift.dart' show Value;
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/models/manual_discount.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/promotion_checkout_service.dart';
import 'package:modern_offline_pos/core/services/sale_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/promotion_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/sale_return_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;
  late PosRepository pos;
  late PromotionRepository promotions;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(AuthRepository(db));
    final owner =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
    await auth.login(owner, 'password123');
    pos = PosRepository(db);
    promotions = PromotionRepository(db);
  });
  tearDown(() => db.close());

  test('cart changes recalculate preview; disabled rules stop applying',
      () async {
    final id = await pos.saveProduct(
        name: 'Bread', priceCents: 10000, costCents: 1000, startingStock: 5);
    final product = (await pos.products()).single;
    final cart = Cart()..add(product);
    final rule = await promotions.createPromotion(
        auth.current!,
        PromotionInput(
            name: 'Weekend',
            type: 'percentage',
            rewardKind: 'percentage',
            rewardValue: 1000,
            active: true,
            targetMode: 'products',
            productIds: [id]));
    final preview = PromotionCheckoutService(promotions);
    expect(
        (await preview.evaluate(auth.current!, cart, DateTime.now()))
            .totalDiscountCents,
        1000);
    cart.setQuantity(id, 2);
    expect(
        (await preview.evaluate(auth.current!, cart, DateTime.now()))
            .totalDiscountCents,
        2000);
    cart.remove(id);
    expect(
        (await preview.evaluate(auth.current!, cart, DateTime.now()))
            .totalDiscountCents,
        0);
    cart.add(product);
    await promotions.setActive(auth.current!, rule.id, false);
    expect(
        (await preview.evaluate(auth.current!, cart, DateTime.now()))
            .totalDiscountCents,
        0);
  });

  test('payment rechecks a promotion disabled after the cart preview',
      () async {
    await pos.saveProduct(
        name: 'Bread', priceCents: 10000, costCents: 1000, startingStock: 2);
    final cart = Cart()..add((await pos.products()).single);
    final rule = await promotions.createPromotion(
        auth.current!,
        const PromotionInput(
            name: 'Preview only',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 1000,
            active: true));
    expect(
        (await PromotionCheckoutService(promotions)
                .evaluate(auth.current!, cart, DateTime.now()))
            .totalDiscountCents,
        1000);
    await promotions.setActive(auth.current!, rule.id, false);
    final result = await SaleService(pos, auth).checkout(cart, 10000);
    expect(result.totalCents, 10000);
    expect((await db.select(db.sales).get()).single.discountSource, 'none');
    expect(await db.select(db.salePromotionApplications).get(), isEmpty);
  });

  test('commit allocates immutable promotion snapshot and reprint uses it',
      () async {
    final id = await pos.saveProduct(
        name: 'Bread', priceCents: 10000, costCents: 1000, startingStock: 5);
    final product = (await pos.products()).single;
    final rule = await promotions.createPromotion(
        auth.current!,
        PromotionInput(
            name: 'Weekend',
            type: 'percentage',
            rewardKind: 'percentage',
            rewardValue: 1000,
            active: true,
            targetMode: 'products',
            productIds: [id]));
    final result =
        await SaleService(pos, auth).checkout(Cart()..add(product), 9000);
    expect(result.totalCents, 9000);
    final sale = (await db.select(db.sales).get()).single;
    expect(sale.discountSource, 'promotion');
    final item = (await db.select(db.saleItems).get()).single;
    expect(item.lineTotalCents, 9000);
    expect(item.promotionDiscountCents, 1000);
    expect(item.manualDiscountCents, 0);
    final snapshot =
        (await db.select(db.salePromotionApplications).get()).single;
    expect(snapshot.promotionReference, rule.reference);
    expect(snapshot.promotionName, 'Weekend');
    expect(snapshot.discountCents, 1000);
    final sales = SalesRepository(db);
    final before = ReceiptDocument.fromDetail(
        await sales.detail(auth.current!, result.saleId), 'Test store');
    final printed = String.fromCharCodes(EscPosEncoder().encode(before, 80));
    expect(printed, contains('Promo: Weekend'));
    expect(printed, contains('PHP 10.00'));
    await promotions.updatePromotion(
        auth.current!,
        rule.id,
        const PromotionInput(
            name: 'Renamed',
            type: 'percentage',
            rewardKind: 'percentage',
            rewardValue: 2000,
            active: false));
    final reprint = ReceiptDocument.fromDetail(
        await sales.detail(auth.current!, result.saleId), 'Test store');
    expect(String.fromCharCodes(EscPosEncoder().encode(reprint, 80)), printed);
    await db.into(db.rmaCases).insert(RmaCasesCompanion.insert(
        reference: 'RMA-PROMO-1',
        origin: 'customer',
        saleId: Value(result.saleId),
        saleItemId: Value(item.id),
        issueDescription: 'Faulty',
        intakeCondition: 'Used'));
    final rma = (await db.select(db.rmaCases).get()).single;
    expect((await sales.quoteItemRefund(rma.id)).amountCents, 9000);
  });

  test('partial and full promoted returns refund historical net line cents',
      () async {
    await CashSessionRepository(db).open(auth.current!, 100000);
    final breadId = await pos.saveProduct(
        name: 'Bread', priceCents: 10000, costCents: 1000, startingStock: 5);
    final milkId = await pos.saveProduct(
        name: 'Milk', priceCents: 5000, costCents: 1000, startingStock: 2);
    await promotions.createPromotion(
        auth.current!,
        const PromotionInput(
            name: 'Ten percent',
            type: 'percentage',
            rewardKind: 'percentage',
            rewardValue: 1000,
            active: true));
    final products = await pos.products();
    final cart = Cart()
      ..add(products.singleWhere((p) => p.id == breadId))
      ..setQuantity(breadId, 3)
      ..add(products.singleWhere((p) => p.id == milkId));
    final sale = await SaleService(pos, auth).checkout(cart, 31500);
    expect(sale.totalCents, 31500);
    final bread = (await db.select(db.saleItems).get())
        .singleWhere((item) => item.productId == breadId);
    final milk = (await db.select(db.saleItems).get())
        .singleWhere((item) => item.productId == milkId);
    expect(bread.lineTotalCents, 27000);
    expect(milk.lineTotalCents, 4500);
    final returns = SaleReturnRepository(db);
    final partial = await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(bread.id, 1000, sellable: true)],
        reason: 'Customer return');
    expect(partial.refundValueCents, 9000);
    final remaining = await returns.finalize(
        auth.current!,
        sale.saleId,
        [
          ReturnSelection(bread.id, 2000, sellable: true),
          ReturnSelection(milk.id, 1000, sellable: true)
        ],
        reason: 'Customer return');
    expect(remaining.refundValueCents, 22500);
    expect(partial.refundValueCents + remaining.refundValueCents, 31500);
    expect(
        (await db.select(db.salePromotionApplications).get())
            .single
            .discountCents,
        3500);
  });

  test('manual discount remains authoritative and does not stack', () async {
    final id = await pos.saveProduct(
        name: 'Bread', priceCents: 10000, costCents: 1000, startingStock: 3);
    await promotions.createPromotion(
        auth.current!,
        const PromotionInput(
            name: 'Weekend',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 2000,
            active: true));
    final discount = ManualDiscount(
        scope: 'order',
        kind: 'fixed',
        value: 500,
        reason: 'Price match',
        requestedBy: auth.current!.id,
        authorizedBy: auth.current!.id,
        authorizedAt: DateTime.now(),
        approvedBasisCents: 10000);
    final sale = await pos.completeCashSale(
        [SaleLineRequest(id, 1)], 9500, auth.current!.id,
        manualDiscount: discount);
    expect(sale.totalCents, 9500);
    expect((await db.select(db.sales).get()).single.discountSource, 'manual');
    expect(await db.select(db.salePromotionApplications).get(), isEmpty);
    final item = (await db.select(db.saleItems).get()).single;
    expect(item.manualDiscountCents, 500);
    expect(item.promotionDiscountCents, 0);
  });

  test('BIR invoice and grand total use the committed promoted amount',
      () async {
    final dir = await Directory.systemTemp.createTemp('promotion-bir-');
    addTearDown(() => dir.delete(recursive: true));
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final id = await pos.saveProduct(
        name: 'Bread', priceCents: 10000, costCents: 1000, startingStock: 2);
    await promotions.createPromotion(
        auth.current!,
        const PromotionInput(
            name: 'Weekend',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 1000,
            active: true));
    final cash =
        CashSessionRepository(db, birReady: true, protection: protection);
    await cash.open(auth.current!, 0);
    final birPos = PosRepository(db, birReady: true, protection: protection);
    final result = await birPos
        .completeCashSale([SaleLineRequest(id, 1)], 9000, auth.current!.id);
    expect(result.totalCents, 9000);
    expect(result.birInvoiceNumber, 1);
    final state = (await db.select(db.birComplianceState).get()).single;
    expect(state.grandTotalCents, 9000);
  });
}
