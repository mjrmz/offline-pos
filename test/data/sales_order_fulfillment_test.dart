import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_order_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_reservation_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';

void main() {
  test('schema 48 migrates without fabricating fulfillment links', () async {
    final dir = await Directory.systemTemp.createTemp('so-h2-migration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    final id = await AuthService(AuthRepository(seed)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(seed).saveCustomer(owner,
        name: 'Ana');
    final pos = PosRepository(seed);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 10000, costCents: 5000, startingStock: 10);
    final order = await SalesOrderRepository(seed).create(owner, customer.id,
        [SalesOrderLineRequest(product, 4000, 10000)]);
    await SalesOrderRepository(seed).transition(owner, order.id, 'confirmed');
    await StockReservationRepository(seed).reserve(owner,
        (await SalesOrderRepository(seed).lines(order.id)).single.id, 4000);
    await seed.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE sales_order_fulfillment_lines');
    raw.execute('DROP TABLE sales_order_fulfillments');
    raw.execute('ALTER TABLE stock_reservations DROP COLUMN consumed_milli');
    raw.execute('ALTER TABLE sales_order_lines DROP COLUMN sale_mode');
    raw.execute('ALTER TABLE sales_order_lines DROP COLUMN extra_cents');
    raw.execute('PRAGMA user_version = 48');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    expect(db.schemaVersion, 50);
    expect((await db.select(db.salesOrders).get()).single.id, order.id);
    expect((await db.select(db.stockReservations).get()).single.quantityMilli,
        4000);
    expect(await db.select(db.salesOrderFulfillments).get(), isEmpty);
    expect(await SalesOrderRepository(db).fulfilledByLine(order.id), isEmpty);
    await db.close();
  });

  test('partial and full fulfillment use one sale pipeline and own claim',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    await CashSessionRepository(db).open(owner, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 10000, costCents: 5000, startingStock: 10);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 10000, 10000)]);
    final line = (await orders.lines(order.id)).single;
    expect(() => pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: line.id)], 10000, id,
        customerId: customer.id, salesOrderId: order.id), throwsStateError);
    await orders.transition(owner, order.id, 'confirmed');
    final claim = await StockReservationRepository(db).reserve(owner,
        line.id, 6000);
    await db.customStatement(
        'UPDATE products SET price_cents = 15000 WHERE id = ?', [product]);
    final beforeLayer = (await pos.layersForProduct(product)).single
        .quantityRemainingMilli;
    final first = await pos.completeCashSale([
      SaleLineRequest(product, 4, lineKey: line.id)], 40000, id,
        customerId: customer.id, salesOrderId: order.id);
    expect(first.totalCents, 40000);
    expect((await orders.fulfilledByLine(order.id))[line.id], 4000);
    expect(await pos.stockMilli(product), 6000);
    expect((await pos.layersForProduct(product)).single
        .quantityRemainingMilli, beforeLayer - 4000);
    expect((await db.select(db.stockReservations).get()).single.quantityMilli,
        2000);
    expect((await db.select(db.stockReservations).get()).single.consumedMilli,
        4000);
    expect(() => pos.completeCashSale([
      SaleLineRequest(product, 7, lineKey: line.id)], 70000, id,
        customerId: customer.id, salesOrderId: order.id), throwsStateError);
    expect((await orders.fulfilledByLine(order.id))[line.id], 4000);
    final second = await pos.completeCashSale([
      SaleLineRequest(product, 6, lineKey: line.id)], 60000, id,
        customerId: customer.id, salesOrderId: order.id);
    expect(second.totalCents, 60000);
    expect((await orders.fulfilledByLine(order.id))[line.id], 10000);
    expect((await orders.fulfillmentSales(order.id)).length, 2);
    expect((await db.select(db.stockReservations).get()).single.status,
        'released');
    expect(await pos.stockMilli(product), 0);
    expect(() => StockReservationRepository(db).reserve(owner, line.id, 1000),
        throwsStateError);
    expect(claim.reference, 'RSV-000001');
    expect((await db.select(db.saleItemInventoryAllocations).get()).length,
        2);
    expect(await db.select(db.salePromotionApplications).get(), isEmpty);
  });

  test('other claims stay protected and failed checkout changes nothing',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    await CashSessionRepository(db).open(owner, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 10000, costCents: 5000, startingStock: 10);
    final orders = SalesOrderRepository(db);
    final current = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 8000, 10000)]);
    final other = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 3000, 10000)]);
    await orders.transition(owner, current.id, 'confirmed');
    await orders.transition(owner, other.id, 'confirmed');
    final currentLine = (await orders.lines(current.id)).single;
    final otherLine = (await orders.lines(other.id)).single;
    final reservations = StockReservationRepository(db);
    await reservations.reserve(owner, currentLine.id, 4000);
    await reservations.reserve(owner, otherLine.id, 3000);
    expect(() => pos.completeCashSale([
      SaleLineRequest(product, 8, lineKey: currentLine.id)], 80000, id,
        customerId: customer.id, salesOrderId: current.id), throwsStateError);
    expect(() => pos.completeCashSale([
      SaleLineRequest(product, 7, lineKey: currentLine.id)], 1000, id,
        customerId: customer.id, salesOrderId: current.id), throwsStateError);
    expect(await orders.fulfilledByLine(current.id), isEmpty);
    expect((await reservations.activeByLine(current.id))[currentLine.id],
        4000);
    expect(await pos.stockMilli(product), 10000);
    expect(await db.select(db.salesOrderFulfillments).get(), isEmpty);
    final done = await pos.completeCashSale([
      SaleLineRequest(product, 7, lineKey: currentLine.id)], 70000, id,
        customerId: customer.id, salesOrderId: current.id);
    expect(done.totalCents, 70000);
    expect(await pos.stockMilli(product), 3000);
    expect((await reservations.activeByLine(other.id))[otherLine.id], 3000);
    expect((await reservations.activeByLine(current.id))[currentLine.id],
        isNull);
  });

  test('partial fulfillment limits new reservation and cancellation keeps Sale',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    await CashSessionRepository(db).open(owner, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 10000, costCents: 5000, startingStock: 10);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 10000, 10000)]);
    await orders.transition(owner, order.id, 'confirmed');
    final line = (await orders.lines(order.id)).single;
    final sale = await pos.completeCashSale([
      SaleLineRequest(product, 4, lineKey: line.id)], 40000, id,
        customerId: customer.id, salesOrderId: order.id);
    final claims = StockReservationRepository(db);
    expect(() => claims.reserve(owner, line.id, 7000), throwsStateError);
    final claim = await claims.reserve(owner, line.id, 6000);
    await orders.transition(owner, order.id, 'cancelled');
    expect((await orders.fulfilledByLine(order.id))[line.id], 4000);
    expect((await claims.forOrder(order.id)).single.status, 'released');
    expect((await db.select(db.sales).get()).single.id, sale.saleId);
    expect(await pos.stockMilli(product), 6000);
    expect(claim.quantityMilli, 6000);
  });

  test('serial and batch selection happen in the normal Sale commit',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final directory = DirectoryRepository(db);
    final customer = await directory.saveCustomer(owner, name: 'Ana');
    final supplier = await directory.saveSupplier(owner, name: 'Supplier');
    await CashSessionRepository(db).open(owner, 0);
    final pos = PosRepository(db);
    final serialProduct = await pos.saveProduct(name: 'Laptop',
        priceCents: 50000, costCents: 30000, serialTracking: true);
    await StockReceivingRepository(db).receive(owner, supplier.id,
        [ReceivingLineRequest(serialProduct, 1000, 30000,
            serialNumbers: ['SER-1'])]);
    final serial = (await pos.availableSerials(serialProduct)).single;
    final orders = SalesOrderRepository(db);
    final serialOrder = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(serialProduct, 1000, 50000)]);
    await orders.transition(owner, serialOrder.id, 'confirmed');
    final serialLine = (await orders.lines(serialOrder.id)).single;
    await StockReservationRepository(db).reserve(owner, serialLine.id, 1000);
    expect((await pos.availableSerials(serialProduct)).single.id, serial.id);
    await pos.completeCashSale([SaleLineRequest(serialProduct, 1,
        lineKey: serialLine.id, serialIds: [serial.id])], 50000, id,
        customerId: customer.id, salesOrderId: serialOrder.id);
    expect(await pos.availableSerials(serialProduct), isEmpty);

    await BusinessFeatureRepository(db).setEnabled(
        BusinessFeature.expiryBatchTracking, true, owner);
    final batchProduct = await pos.saveProduct(name: 'Medicine',
        priceCents: 1000, costCents: 500,
        business: const BusinessProduct(batch: true));
    await StockReceivingRepository(db).receive(owner, supplier.id,
        [ReceivingLineRequest(batchProduct, 5000, 500,
            batchNumber: 'LOT-A')]);
    final batch = (await pos.batches(batchProduct)).single;
    final batchOrder = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(batchProduct, 2000, 1000)]);
    await orders.transition(owner, batchOrder.id, 'confirmed');
    final batchLine = (await orders.lines(batchOrder.id)).single;
    await StockReservationRepository(db).reserve(owner, batchLine.id, 2000);
    expect((await pos.batches(batchProduct)).single.quantityMilli, 5000);
    await pos.completeCashSale([SaleLineRequest(batchProduct, 2,
        lineKey: batchLine.id, batchId: batch.id)], 2000, id,
        customerId: customer.id, salesOrderId: batchOrder.id);
    expect((await pos.batches(batchProduct)).single.quantityMilli, 3000);
  });

  test('linked Sale void is blocked; refund keeps historical fulfillment',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    await CashSessionRepository(db).open(owner, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 1000, costCents: 500, startingStock: 2);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 1000, 1000)]);
    await orders.transition(owner, order.id, 'confirmed');
    final line = (await orders.lines(order.id)).single;
    final sale = await pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: line.id)], 1000, id,
        customerId: customer.id, salesOrderId: order.id);
    final sales = SalesRepository(db);
    expect(() => sales.reverse(owner, sale.saleId, 'void',
        stockRestored: true, cashRefundConfirmed: true), throwsStateError);
    expect((await orders.fulfilledByLine(order.id))[line.id], 1000);
    await sales.reverse(owner, sale.saleId, 'refund',
        stockRestored: true, cashRefundConfirmed: true);
    expect((await orders.fulfilledByLine(order.id))[line.id], 1000);
  });

  test('BIR invoices are allocated per committed partial fulfillment',
      () async {
    final dir = await Directory.systemTemp.createTemp('so-h2-bir-');
    addTearDown(() => dir.delete(recursive: true));
    final protection = ComplianceProtection(File('${dir.path}/compliance.json'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    await CashSessionRepository(db, birReady: true,
        protection: protection).open(owner, 0);
    final pos = PosRepository(db, birReady: true,
        protection: protection);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 1000, costCents: 500, startingStock: 2);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 2000, 1000)]);
    await orders.transition(owner, order.id, 'confirmed');
    final line = (await orders.lines(order.id)).single;
    expect(await db.select(db.birComplianceState).get(), isEmpty);
    expect(() => pos.completeCashSale([
      SaleLineRequest(product, 2, lineKey: line.id)], 1000, id,
        customerId: customer.id, salesOrderId: order.id), throwsStateError);
    expect(await db.select(db.birComplianceState).get(), isEmpty);
    final first = await pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: line.id)], 1000, id,
        customerId: customer.id, salesOrderId: order.id);
    final second = await pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: line.id)], 1000, id,
        customerId: customer.id, salesOrderId: order.id);
    expect(first.birInvoiceNumber, 1);
    expect(second.birInvoiceNumber, 2);
    expect((await db.select(db.birComplianceState).get()).single
        .grandTotalCents, 2000);
  });

  test('credit fulfillment uses normal receivable without cash settlement',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    final cash = CashSessionRepository(db);
    final session = await cash.open(owner, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 1000, costCents: 500, startingStock: 1);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 1000, 1000)]);
    await orders.transition(owner, order.id, 'confirmed');
    final line = (await orders.lines(order.id)).single;
    expect(await CustomerCreditRepository(db).balance(customer.id), 0);
    await pos.completeCreditSale([
      SaleLineRequest(product, 1, lineKey: line.id)], 0, customer.id, id,
        salesOrderId: order.id);
    expect(await CustomerCreditRepository(db).balance(customer.id), 1000);
    expect(await cash.expected(session.id), 0);
    expect((await orders.fulfilledByLine(order.id))[line.id], 1000);
  });

  test('selling permission alone cannot fulfill a Sales Order', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final owner = auth.current!;
    final role = await auth.createRole('POS only', 'Sales only',
        {PosPermission.sell});
    final staffId = await auth.createUserWithRole(
        'Staff', role, 'staffPassword123');
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    await CashSessionRepository(db).open(owner, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 1000, costCents: 500, startingStock: 1);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 1000, 1000)]);
    await orders.transition(owner, order.id, 'confirmed');
    final line = (await orders.lines(order.id)).single;
    expect(() => pos.completeCashSale([
      SaleLineRequest(product, 1, lineKey: line.id)], 1000, staffId,
        customerId: customer.id, salesOrderId: order.id), throwsStateError);
    expect(await db.select(db.sales).get(), isEmpty);
  });
}
