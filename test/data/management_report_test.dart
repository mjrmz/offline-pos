import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_activity_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/management_report_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';

void main() {
  test('adjustment allocation costs affect profit without expenses or cash',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Cable', priceCents: 10000, costCents: 9000);
    final receiving = StockReceivingRepository(db);
    await receiving.receive(auth.current!, supplier.id,
        [ReceivingLineRequest(productId, 5000, 5000)]);
    await Future<void>.delayed(const Duration(seconds: 1));
    await receiving.receive(auth.current!, supplier.id,
        [ReceivingLineRequest(productId, 5000, 7000)]);
    final counts = StockCountRepository(db);
    await counts.adjust(auth.current!,
        AdjustmentRequest(productId, -7000, 'Stock count variance'));
    await counts.adjust(
        auth.current!,
        AdjustmentRequest(productId, 2000, 'Stock count variance',
            unitCostCents: 5000));
    final report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.adjustmentsComplete, true);
    expect(report.adjustmentImpactCents, -29000);
    expect(
        report.adjustments
            .singleWhere((a) => a.label == 'Stock count shortage')
            .knownImpactCents,
        -39000);
    expect(
        report.adjustments
            .singleWhere((a) => a.label == 'Stock count overage')
            .knownImpactCents,
        10000);
    expect(report.expenseCents, 0);
    expect(report.operatingProfitCents, -29000);
    expect(report.inventory.single.costCents, 31000);
    expect(await db.select(db.businessCashMovements).get(), isEmpty);
    final posted = await db.select(db.inventoryAdjustments).get();
    final shortage = posted.singleWhere((a) => a.deltaMilli < 0);
    await (db.update(db.inventoryAdjustments)
          ..where((a) => a.id.equals(shortage.id)))
        .write(InventoryAdjustmentsCompanion(
            createdAt:
                Value(DateTime.now().subtract(const Duration(days: 1)))));
    final today = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(today.adjustmentImpactCents, 10000);
    await db.delete(db.inventoryAdjustmentAllocations).go();
    final partial = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(partial.adjustmentsComplete, false);
    expect(partial.incompleteAdjustmentEvents, 1);
  });
  test('named and custom periods use inclusive local calendar dates', () {
    final now = DateTime(2026, 10, 15, 14);
    expect(
        ReportPeriod.named('Today', now)
            .contains(DateTime(2026, 10, 15, 23, 59)),
        true);
    expect(ReportPeriod.named('Today', now).contains(DateTime(2026, 10, 16)),
        false);
    expect(
        ReportPeriod.named('Yesterday', now).contains(DateTime(2026, 10, 14)),
        true);
    expect(ReportPeriod.named('This week', now).start, DateTime(2026, 10, 12));
    expect(ReportPeriod.named('This month', now).end, DateTime(2026, 11));
    expect(ReportPeriod.named('Last month', now).start, DateTime(2026, 9));
    final custom =
        ReportPeriod.custom(DateTime(2026, 10, 1), DateTime(2026, 10, 15));
    expect(custom.contains(DateTime(2026, 10, 15, 23, 59)), true);
    expect(custom.contains(DateTime(2026, 10, 16)), false);
  });

  test('FIFO COGS and inventory valuation use persisted layer costs', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Cable', priceCents: 10000, costCents: 9000);
    final receiving = StockReceivingRepository(db);
    await receiving.receive(auth.current!, supplier.id,
        [ReceivingLineRequest(productId, 5000, 5000)]);
    await Future<void>.delayed(const Duration(seconds: 1));
    await receiving.receive(auth.current!, supplier.id,
        [ReceivingLineRequest(productId, 5000, 7000)]);
    await pos.completeCashSale([SaleLineRequest(productId, 8)], 80000, ownerId);
    await pos.saveProduct(
        id: productId, name: 'Cable', priceCents: 10000, costCents: 8000);
    final report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.grossSalesCents, 80000);
    final saleDay =
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    expect(report.dailyGrossSales[saleDay], 80000);
    expect(report.dailySales[saleDay], 80000);
    expect(report.dailyRefunds.containsKey(saleDay), false);
    expect(report.cogsCents, 46000); // 5 × ₱50 + 3 × ₱70
    expect(report.grossProfitCents, 34000);
    expect(report.cogsComplete, true);
    expect(report.inventory.single.quantityMilli, 2000);
    expect(report.inventory.single.costCents, 14000);
    expect(report.inventory.single.retailCents, 20000);
    await StockCountRepository(db)
        .adjust(auth.current!, AdjustmentRequest(productId, -1000, 'Damaged'));
    final afterAdjustment = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(afterAdjustment.cogsCents, 46000);
    expect(afterAdjustment.adjustmentImpactCents, -7000);
  });

  test('reversals and personal expenses follow management P&L rules', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 6000);
    await StockReceivingRepository(db).receive(auth.current!, supplier.id,
        [ReceivingLineRequest(productId, 2000, 6000)]);
    final sale = await pos
        .completeCashSale([SaleLineRequest(productId, 1)], 10000, ownerId);
    final cash = CashActivityRepository(db);
    final category = (await cash.categories()).first;
    await cash.addOpeningCash(auth.current!,
        fund: 'company', amountCents: 10000, note: 'Opening count');
    await cash.replenish(auth.current!,
        amountCents: 3000, destination: 'petty');
    await cash.expense(auth.current!,
        amountCents: 850,
        source: 'personal',
        categoryId: category.id,
        payee: 'NBS',
        personallyPaidBy: 'MJ');
    var report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.netSalesCents, 10000);
    expect(report.cogsCents, 6000);
    expect(report.expenseCents, 850);
    expect(report.operatingProfitCents, 3150);
    expect(report.expensesBySource['personal'], 850);
    expect(report.expensesByPayee['NBS'], 850);
    await SalesRepository(db)
        .reverse(auth.current!, sale.saleId, 'refund', stockRestored: false);
    report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.netSalesCents, 0);
    expect(report.cogsCents, 6000); // no stock restoration
    expect(report.expenseCents, 850);
    expect(report.reversalCents, 10000);
  });

  test('weight COGS uses fixed-point allocated quantity', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final features = BusinessFeatureRepository(db);
    for (final feature in BusinessFeature.values) {
      await features.setEnabled(feature, true, auth.current!);
    }
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Rice',
        priceCents: 10000,
        costCents: 6000,
        startingStockMilli: 2000,
        openingCostCents: 6000,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    await pos.completeCashSale(
        [SaleLineRequest(productId, 0, quantityMilli: 1500)], 15000, id);
    final report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.cogsCents, 9000);
    expect(report.grossProfitCents, 6000);
    expect(report.products['Rice']?.quantityMilli, 1500);
    expect(report.inventory.single.costCents, 3000);
  });

  test('known allocation COGS survives an incomplete legacy sale item',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Cable',
        priceCents: 10000,
        costCents: 9999,
        startingStockMilli: 3000,
        openingCostCents: 5000);
    final first = await pos
        .completeCashSale([SaleLineRequest(productId, 1)], 10000, ownerId);
    final firstItems = await (db.select(db.saleItems)
          ..where((i) => i.saleId.equals(first.saleId)))
        .get();
    expect(firstItems, hasLength(1));
    // An imported legacy sale has no allocation snapshot. Committed
    // allocations are immutable, so create that legacy shape directly.
    final legacySale = await db.into(db.sales).insertReturning(
        SalesCompanion.insert(cashierId: ownerId, totalCents: 10000));
    final legacyItem = await db.into(db.saleItems).insertReturning(
        SaleItemsCompanion.insert(
            saleId: legacySale.id,
            productId: productId,
            quantity: 1,
            quantityMilli: const Value(1000),
            unitPriceCents: 10000,
            lineTotalCents: const Value(10000)));
    await pos.saveProduct(
        id: productId, name: 'Cable', priceCents: 10000, costCents: 20000);
    final report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.cogsCents, 5000);
    expect(report.cogsComplete, false);
    expect(report.incompleteCostItems, 1);
    expect(report.incompleteCostRevenueCents, 10000);
    expect(report.incompleteCostItemIds, [legacyItem.id]);
    expect(report.netSalesCents, 20000);
    expect(report.grossProfitCents, 15000); // partial only; UI hides it
  });
}
