import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/supplier_analysis_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual costs, supplier scope, dates, and line pagination', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final directory = DirectoryRepository(db);
    final first = await directory.saveSupplier(actor, name: 'First');
    final second = await directory.saveSupplier(actor, name: 'Second');
    final productId = await PosRepository(db).saveProduct(
        name: 'Widget', priceCents: 1000, costCents: 100, startingStock: 0);
    final category = await db
        .into(db.categories)
        .insertReturning(CategoriesCompanion.insert(name: 'Hardware'));
    await db.customStatement('UPDATE products SET category_id=? WHERE id=?',
        [category.id, productId]);
    final receiving = StockReceivingRepository(db);
    final day = DateTime(2026, 10, 19, 12);
    await receiving.receive(
        actor, first.id, [ReceivingLineRequest(productId, 2000, 300)],
        receivedAt: day, externalReference: 'INV-A');
    await receiving.receive(
        actor, first.id, [ReceivingLineRequest(productId, 1000, 500)],
        receivedAt: day.add(const Duration(days: 1)),
        externalReference: 'INV-B');
    await receiving.receive(
        actor, second.id, [ReceivingLineRequest(productId, 1000, 900)],
        receivedAt: day);
    final analysis = SupplierAnalysisRepository(db);
    await db.customStatement(
        'UPDATE products SET preferred_supplier_id=? WHERE id=?',
        [first.id, productId]);
    expect(await analysis.preferredCount(first.id), 1);
    expect((await analysis.preferredPage(first.id, 0)).single.id, productId);
    final from = DateTime(2026, 10, 19);
    final until = DateTime(2026, 10, 21);
    final totals = await analysis.totals(first.id, from, until);
    expect(totals.valueCents, 1100);
    expect(totals.quantityMilli, 3000);
    expect(totals.deliveries, 2);
    expect(await analysis.lineCount(first.id, from, until), 2);
    expect((await analysis.categories(first.id, from, until)).single.$1,
        category.id);
    expect(
        await analysis.lineCount(first.id, from, until,
            categoryId: category.id),
        2);
    expect(
        await analysis.lineCount(first.id, from, until, categoryId: 'missing'),
        0);
    expect(
        await analysis.lineCount(first.id, from, until, reference: 'INV-A'), 1);
    expect(
        (await analysis.totals(first.id, from, until, reference: 'INV-A'))
            .valueCents,
        600);
    expect(await analysis.receivingCount(first.id), 2);
    expect((await analysis.receivingPage(first.id, 0)).length, 2);
    final receivingSummaries = await analysis
        .receivingSummaries(await analysis.receivingPage(first.id, 0));
    expect(receivingSummaries.length, 2);
    expect(receivingSummaries.values.map((e) => e.actualCents).toSet(),
        {500, 600});
    expect(await analysis.orderCount(first.id), 0);
    expect(await analysis.orderPage(first.id, 0), isEmpty);
    final lines = await analysis.lines(first.id, from, until, 0);
    expect(lines.map((e) => e.unitCostCents), [500, 300]);
    final products = await analysis.products(first.id, from, until);
    expect(products.single.averageCostCents, 367);
    expect(products.single.lastCostCents, 500);
    expect(products.single.minCostCents, 300);
    expect(products.single.maxCostCents, 500);
    final months = await analysis.monthlyValues(first.id, from, until);
    expect(months.single.valueCents, 1100);
    expect(months.single.deliveries, 2);
    final oneDay =
        await analysis.totals(first.id, from, DateTime(2026, 10, 20));
    expect(oneDay.valueCents, 600);
    expect((await analysis.lines(first.id, from, until, 1)), isEmpty);
    final poRepo = PurchaseOrderRepository(db);
    final order = await poRepo.create(
        actor, first.id, day, [PurchaseOrderLineInput(productId, 2000, 400)]);
    await poRepo.markSent(actor, order.id);
    final line = (await poRepo.detail(order.id)).lines.single;
    await receiving.receive(
        actor,
        first.id,
        [
          ReceivingLineRequest(productId, 1000, 500,
              purchaseOrderLineId: line.id)
        ],
        purchaseOrderId: order.id,
        receivedAt: day.add(const Duration(days: 2)));
    final orderSummary = (await analysis.orderSummaries([order]))[order.id]!;
    expect(orderSummary.expectedValueCents, 800);
    expect(orderSummary.receivedMilli, 1000);
    expect(orderSummary.remainingMilli, 1000);
  });
}
