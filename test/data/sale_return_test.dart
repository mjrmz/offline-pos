import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/sales_service.dart';
import 'package:modern_offline_pos/core/models/printer_settings.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/management_report_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/printer_settings_repository.dart';
import 'package:modern_offline_pos/hardware/printer/receipt.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_printer.dart';
import 'package:modern_offline_pos/hardware/printer/receipt_service.dart';
import 'package:modern_offline_pos/hardware/cash_drawer/cash_drawer.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sale_return_repository.dart';
import 'package:modern_offline_pos/data/daos/sale_lifecycle_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late AppDatabase db;
  late AuthService auth;
  late PosRepository pos;
  late SaleReturnRepository returns;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    pos = PosRepository(db);
    returns = SaleReturnRepository(db);
    await CashSessionRepository(db).open(auth.current!, 100000);
  });
  tearDown(() => db.close());

  test('partial multi-item returns preserve sale and historical cost',
      () async {
    final a = await pos.saveProduct(
        name: 'A', priceCents: 10000, costCents: 6000, startingStock: 5);
    final b = await pos.saveProduct(
        name: 'B', priceCents: 25000, costCents: 12000, startingStock: 2);
    final sale = await pos.completeCashSale(
        [SaleLineRequest(a, 5), SaleLineRequest(b, 2)],
        100000,
        auth.current!.id);
    final item = (await db.select(db.saleItems).get())
        .singleWhere((i) => i.productId == a);
    await pos.saveProduct(id: a, name: 'A', priceCents: 20000, costCents: 9000);
    final first = await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 2000, sellable: true)],
        reason: 'Customer changed mind');
    expect(first.reference, 'RET-000001');
    expect(first.refundValueCents, 20000);
    expect(await pos.stock(a), 2);
    expect(await pos.stock(b), 0);
    expect(
        (await returns.returnable(sale.saleId))
            .singleWhere((l) => l.item.id == item.id)
            .remainingMilli,
        3000);
    await expectLater(
        returns.finalize(auth.current!, sale.saleId,
            [ReturnSelection(item.id, 4000, sellable: true)],
            reason: 'Wrong item'),
        throwsStateError);
    final second = await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 3000, sellable: false)],
        reason: 'Wrong quantity');
    expect(second.reference, 'RET-000002');
    expect(await pos.stock(a), 2);
    expect((await db.select(db.sales).get()).single.totalCents, 100000);
    expect((await db.select(db.saleItems).get()).length, 2);
    expect(
        (await returns.returnable(sale.saleId))
            .singleWhere((l) => l.item.id == item.id)
            .remainingMilli,
        0);
    final report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.grossSalesCents, 100000);
    expect(report.refundsCents, 50000);
    expect(report.netSalesCents, 50000);
    expect(report.cogsCents,
        42000); // A non-sellable cost remains; B remains sold.
    final cash = await db.select(db.cashMovements).get();
    expect(cash.where((m) => m.kind == 'sale_return_refund').length, 2);
    expect(
        cash
            .where((m) => m.kind == 'sale_return_refund')
            .fold<int>(0, (sum, m) => sum + m.amountCents),
        -50000);
  });

  for (final (replacementPrice, expectedCash) in [
    (10000, 0),
    (13000, 3000),
    (8000, -2000)
  ]) {
    test('exchange settles net difference $expectedCash', () async {
      final a = await pos.saveProduct(
          name: 'Original',
          priceCents: 10000,
          costCents: 6000,
          startingStock: 1);
      final b = await pos.saveProduct(
          name: 'Replacement',
          priceCents: replacementPrice,
          costCents: 5000,
          startingStock: 1);
      final original = await pos
          .completeCashSale([SaleLineRequest(a, 1)], 10000, auth.current!.id);
      final item = (await db.select(db.saleItems).get()).single;
      final result = await returns.exchange(
          auth.current!,
          original.saleId,
          [ReturnSelection(item.id, 1000, sellable: true)],
          [SaleLineRequest(b, 1)],
          pos,
          reason: 'Wrong item',
          cashTenderedCents: expectedCash > 0 ? expectedCash : 0);
      expect(result.cashEffectCents, expectedCash);
      expect(result.replacementSaleId, isNotNull);
      expect(await pos.stock(a), 1);
      expect(await pos.stock(b), 0);
      final returnCash = (await db.select(db.cashMovements).get())
          .where((m) => m.referenceId == result.id)
          .fold<int>(0, (sum, m) => sum + m.amountCents);
      expect(returnCash, expectedCash < 0 ? expectedCash : 0);
      final exchangePayments = (await db.select(db.payments).get())
          .where((p) => p.saleId == result.replacementSaleId)
          .toList();
      expect(
          exchangePayments
              .where((p) => p.method == 'exchange_credit')
              .fold<int>(0, (sum, p) => sum + p.amountCents),
          replacementPrice < 10000 ? replacementPrice : 10000);
    });
  }

  test('failed replacement checkout rolls back the return', () async {
    final a = await pos.saveProduct(
        name: 'Original', priceCents: 10000, costCents: 6000, startingStock: 1);
    final b = await pos.saveProduct(
        name: 'Out of stock',
        priceCents: 12000,
        costCents: 5000,
        startingStock: 0);
    final original = await pos
        .completeCashSale([SaleLineRequest(a, 1)], 10000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    await expectLater(
        returns.exchange(
            auth.current!,
            original.saleId,
            [ReturnSelection(item.id, 1000, sellable: true)],
            [SaleLineRequest(b, 1)],
            pos,
            reason: 'Wrong item',
            cashTenderedCents: 2000),
        throwsStateError);
    expect(await returns.history(original.saleId), isEmpty);
    expect(await pos.stock(a), 0);
    expect((await db.select(db.sales).get()).length, 1);
  });

  test('incorrect exchange payment rolls back both transactions', () async {
    final a = await pos.saveProduct(
        name: 'Original', priceCents: 10000, costCents: 6000, startingStock: 1);
    final b = await pos.saveProduct(
        name: 'Replacement',
        priceCents: 13000,
        costCents: 5000,
        startingStock: 1);
    final sale = await pos
        .completeCashSale([SaleLineRequest(a, 1)], 10000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    await expectLater(
        returns.exchange(
            auth.current!,
            sale.saleId,
            [ReturnSelection(item.id, 1000, sellable: true)],
            [SaleLineRequest(b, 1)],
            pos,
            reason: 'Wrong item',
            cashTenderedCents: 4000),
        throwsStateError);
    expect(await returns.history(sale.saleId), isEmpty);
    expect(await pos.stock(a), 0);
    expect(await pos.stock(b), 1);
  });

  test('exchange accepts multiple replacement lines through sale planning',
      () async {
    final a = await pos.saveProduct(
        name: 'Original',
        priceCents: 20000,
        costCents: 10000,
        startingStock: 1);
    final b = await pos.saveProduct(
        name: 'B', priceCents: 10000, costCents: 5000, startingStock: 1);
    final c = await pos.saveProduct(
        name: 'C', priceCents: 10000, costCents: 5000, startingStock: 1);
    final sale = await pos
        .completeCashSale([SaleLineRequest(a, 1)], 20000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    final result = await returns.exchange(
        auth.current!,
        sale.saleId,
        [ReturnSelection(item.id, 1000, sellable: true)],
        [SaleLineRequest(b, 1), SaleLineRequest(c, 1)],
        pos,
        reason: 'Wrong item',
        cashTenderedCents: 0);
    expect(result.cashEffectCents, 0);
    expect(await pos.stock(b), 0);
    expect(await pos.stock(c), 0);
    expect(
        (await db.select(db.saleItems).get())
            .where((i) => i.saleId == result.replacementSaleId)
            .length,
        2);
  });

  test('exact serialized unit is restored and cannot return twice', () async {
    final id = await pos.saveProduct(
        name: 'Phone',
        priceCents: 20000,
        costCents: 12000,
        serialTracking: true,
        startingStock: 2,
        openingSerials: ['SN001', 'SN002']);
    final units = await pos.availableSerials(id);
    final sale = await pos.completeCashSale(
        [SaleLineRequest(id, 2, serialIds: units.map((s) => s.id).toList())],
        40000,
        auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    await returns.finalize(
        auth.current!,
        sale.saleId,
        [
          ReturnSelection(item.id, 1000,
              sellable: true, serialIds: [units.last.id])
        ],
        reason: 'Wrong item');
    final available = await pos.availableSerials(id);
    expect(available.map((s) => s.serialNumber), ['SN002']);
    await expectLater(
        returns.finalize(
            auth.current!,
            sale.saleId,
            [
              ReturnSelection(item.id, 1000,
                  sellable: true, serialIds: [units.last.id])
            ],
            reason: 'Wrong item'),
        throwsStateError);
  });

  test('weight return uses fixed point quantities', () async {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, auth.current!);
    final id = await pos.saveProduct(
        name: 'Rice',
        priceCents: 10000,
        costCents: 6000,
        startingStockMilli: 5500,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    final sale = await pos.completeCashSale(
        [SaleLineRequest(id, 5, quantityMilli: 5500)], 55000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 1250, sellable: true)],
        reason: 'Wrong quantity');
    expect((await returns.returnable(sale.saleId)).single.remainingMilli, 4250);
    expect(await pos.stockMilli(id), 1250);
  });

  test('cost rounding across partial weight returns never exceeds sale cost',
      () async {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, auth.current!);
    final id = await pos.saveProduct(
        name: 'Spice',
        priceCents: 100,
        costCents: 1,
        startingStockMilli: 1000,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    final sale = await pos.completeCashSale(
        [SaleLineRequest(id, 1, quantityMilli: 1000)], 100, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    for (var i = 0; i < 2; i++) {
      await returns.finalize(auth.current!, sale.saleId,
          [ReturnSelection(item.id, 500, sellable: true)],
          reason: 'Wrong quantity');
    }
    final row = await db.customSelect('''SELECT SUM(cost_cents) AS cost
      FROM sale_return_lines WHERE sale_item_id=?''',
        variables: [Variable.withString(item.id)]).getSingle();
    expect(row.read<int>('cost'), 1);
  });

  test('batch return restores the original batch', () async {
    await BusinessFeatureRepository(db)
        .setEnabled(BusinessFeature.expiryBatchTracking, true, auth.current!);
    final id = await pos.saveProduct(
        name: 'Milk',
        priceCents: 5000,
        costCents: 3000,
        startingStock: 2,
        business: const BusinessProduct(batch: true),
        openingBatches: [
          OpeningBatch(1000, 'LOT-A', null),
          OpeningBatch(1000, 'LOT-B', null)
        ]);
    final lot = (await pos.batches(id)).first;
    final sale = await pos.completeCashSale(
        [SaleLineRequest(id, 1, batchId: lot.id)], 5000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 1000, sellable: true)],
        reason: 'Wrong item');
    expect((await pos.batches(id)).first.quantityMilli, 1000);
    expect((await pos.batches(id)).last.quantityMilli, 1000);
  });

  test('multi-layer return restores original consumed cost in sale order',
      () async {
    final id = await pos.saveProduct(
        name: 'Cable', priceCents: 10000, costCents: 6000, startingStock: 1);
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    await StockReceivingRepository(db).receive(
        auth.current!, supplier.id, [ReceivingLineRequest(id, 1000, 7000)]);
    final sale = await pos
        .completeCashSale([SaleLineRequest(id, 2)], 20000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 1000, sellable: true)],
        reason: 'Wrong quantity');
    final rows = await db.customSelect('''SELECT ra.unit_cost_cents AS cost
      FROM sale_return_allocations ra JOIN sale_return_lines rl
      ON rl.id=ra.return_line_id WHERE rl.sale_item_id=?''',
        variables: [Variable.withString(item.id)]).get();
    expect(rows.single.read<int>('cost'), 6000);
  });

  test('closed cash session blocks refund without changing stock', () async {
    final id = await pos.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 6000, startingStock: 1);
    final sale = await pos
        .completeCashSale([SaleLineRequest(id, 1)], 10000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    final cash = CashSessionRepository(db);
    final active = (await cash.active())!;
    await cash.close(auth.current!, await cash.expected(active.id));
    await expectLater(
        returns.finalize(auth.current!, sale.saleId,
            [ReturnSelection(item.id, 1000, sellable: true)],
            reason: 'Wrong item'),
        throwsStateError);
    expect(await returns.history(sale.saleId), isEmpty);
    expect(await pos.stock(id), 0);
  });

  test('legacy missing allocation is shown as unavailable', () async {
    final id = await pos.saveProduct(
        name: 'Legacy', priceCents: 10000, costCents: 6000, startingStock: 1);
    final sale = await pos
        .completeCashSale([SaleLineRequest(id, 1)], 10000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    // Simulate a migrated sale that predates allocation provenance.
    await db.customStatement('DROP TRIGGER sale_allocation_no_delete');
    await db.customStatement(
        'DELETE FROM sale_item_inventory_allocations WHERE sale_item_id=?',
        [item.id]);
    final line = (await returns.returnable(sale.saleId)).single;
    expect(line.limitation, contains('allocation'));
    await expectLater(
        returns.finalize(auth.current!, sale.saleId,
            [ReturnSelection(item.id, 1000, sellable: true)],
            reason: 'Wrong item'),
        throwsStateError);
    expect(await returns.history(sale.saleId), isEmpty);
  });

  test('return receipt can be reprinted from persisted transaction', () async {
    final id = await pos.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 6000, startingStock: 1);
    final sale = await pos
        .completeCashSale([SaleLineRequest(id, 1)], 10000, auth.current!.id);
    final item = (await db.select(db.saleItems).get()).single;
    final returned = await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 1000, sellable: true)],
        reason: 'Wrong item');
    await PrinterSettingsStore(db).save(
        const PrinterSettings(enabled: true, host: 'fake', storeName: 'Store'));
    final printer = _CapturePrinter();
    final receipt = ReceiptService(SalesService(SalesRepository(db), auth),
        PrinterSettingsStore(db), printer, _NoDrawer());
    expect(await receipt.reprintReturn(returned.id), true);
    expect(printer.document!.reference, 'RET-000001');
    expect(printer.document!.lines.single.name, 'Mouse');
    expect(printer.document!.customHeader, contains('POS-000001'));
    expect(String.fromCharCodes(EscPosEncoder().encode(printer.document!, 80)),
        contains('Return / Exchange #: RET-000001'));
  });

  test('credit sale is held for receivable-aware manual handling', () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Customer');
    final id = await pos.saveProduct(
        name: 'Phone', priceCents: 10000, costCents: 6000, startingStock: 1);
    final sale = await pos.completeCreditSale(
        [SaleLineRequest(id, 1)], 0, customer.id, auth.current!.id);
    final line = (await returns.returnable(sale.saleId)).single;
    expect(line.limitation, contains('receivable'));
    await expectLater(
        returns.finalize(auth.current!, sale.saleId,
            [ReturnSelection(line.item.id, 1000, sellable: true)],
            reason: 'Wrong item'),
        throwsStateError);
  });

  test('history read model totals finalized returns and finds return reference',
      () async {
    final product = await pos.saveProduct(
        name: 'History Item',
        priceCents: 10000,
        costCents: 4000,
        startingStock: 3);
    final sale = await pos.completeCashSale(
        [SaleLineRequest(product, 3)], 30000, auth.current!.id);
    final line = (await returns.returnable(sale.saleId)).single;
    final returned = await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(line.item.id, 1000, sellable: true)],
        reason: 'Wrong item');
    final lifecycle = SaleLifecycleRepository(db);
    final summary = (await lifecycle.summaries())[sale.saleId]!;
    expect(summary.returnedCents, 10000);
    expect(summary.netRetained(30000), 20000);
    expect(summary.status('completed', 30000), 'Partially returned');
    expect(
        (await lifecycle.returnedQuantities(sale.saleId))[line.item.id], 1000);
    expect((await SalesRepository(db).searchSaleIds(returned.reference)),
        contains(sale.saleId));
  });
}

class _CapturePrinter implements ReceiptPrinter {
  ReceiptDocument? document;
  @override
  Future<void> print(ReceiptDocument value, PrinterSettings settings) async {
    document = value;
  }

  @override
  Future<void> test(PrinterSettings settings) async {}
}

class _NoDrawer implements CashDrawer {
  @override
  Future<void> open(PrinterSettings settings) async {}
}
