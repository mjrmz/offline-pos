import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_order_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_reservation_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_return_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<ActiveUser> seed(AppDatabase db) async {
  final id = await AuthService(AuthRepository(db)).bootstrap(
      'Owner', 'password123', 'Q?', 'answer');
  await db.customStatement(
      "INSERT INTO customers (id, name, created_at) VALUES ('c1', 'Ana', 0)");
  await db.customStatement(
      "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 10000, 0)");
  await db.customStatement(
      "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p1', 10, 10000)");
  return ActiveUser(id, 'Owner', UserRole.owner);
}

void main() {
  test('47 to 48 migration retains stock and leaves orders unreserved', () async {
    final dir = await Directory.systemTemp.createTemp('reservation-upgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final original = AppDatabase.forTesting(NativeDatabase(file));
    final owner = await seed(original);
    final order = await SalesOrderRepository(original).create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 4000, 10000)]);
    await original.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP TABLE sales_order_fulfillment_lines');
    raw.execute('DROP TABLE sales_order_fulfillments');
    raw.execute('ALTER TABLE sales_order_lines DROP COLUMN sale_mode');
    raw.execute('ALTER TABLE sales_order_lines DROP COLUMN extra_cents');
    raw.execute('DROP TABLE stock_reservations');
    raw.execute('PRAGMA user_version = 47');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    expect(db.schemaVersion, 50);
    expect((await db.select(db.inventory).get()).single.quantityMilli, 10000);
    expect((await db.select(db.salesOrders).get()).single.id, order.id);
    expect(await db.select(db.stockReservations).get(), isEmpty);
    await db.close();
  });

  test('explicit partial reserve, stale check, release and cancellation', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final owner = await seed(db);
    final orders = SalesOrderRepository(db);
    final reservations = StockReservationRepository(db);
    final first = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 8000, 10000)]);
    final second = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 7000, 10000)]);
    final firstLine = (await orders.lines(first.id)).single;
    final secondLine = (await orders.lines(second.id)).single;
    expect(() => reservations.reserve(owner, firstLine.id, 1000),
        throwsStateError);
    expect((await reservations.stock('p1')).available, 10000);
    await orders.transition(owner, first.id, 'confirmed');
    await orders.transition(owner, second.id, 'confirmed');
    final held = await reservations.reserve(owner, firstLine.id, 4000);
    expect(held.reference, 'RSV-000001');
    expect((await reservations.activeByLine(first.id))[firstLine.id], 4000);
    expect((await reservations.stock('p1')).onHand, 10000);
    expect((await reservations.stock('p1')).reserved, 4000);
    expect((await reservations.stock('p1')).available, 6000);
    expect((await PosRepository(db).stockLevels())['p1']!.$2, 4000);
    expect(() => reservations.reserve(owner, secondLine.id, 7000),
        throwsStateError);
    final secondHold = await reservations.reserve(owner, secondLine.id, 6000);
    expect((await reservations.stock('p1')).available, 0);
    expect(() => reservations.reserve(owner, firstLine.id, 1000),
        throwsStateError);
    await reservations.release(owner, secondHold.id, reason: 'Needed elsewhere');
    expect((await reservations.stock('p1')).available, 6000);
    await orders.transition(owner, first.id, 'cancelled');
    expect((await reservations.stock('p1')).available, 10000);
    expect((await reservations.forOrder(first.id)).single.status, 'released');
    expect((await db.select(db.inventory).get()).single.quantityMilli, 10000);
    expect(await db.select(db.inventoryMovements).get(), isEmpty);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.cashMovements).get(), isEmpty);
    expect(await db.select(db.customerCreditEntries).get(), isEmpty);
  });

  test('stock reduction below an active reservation is blocked', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final owner = await seed(db);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 8000, 10000)]);
    await orders.transition(owner, order.id, 'confirmed');
    await StockReservationRepository(db).reserve(owner,
        (await orders.lines(order.id)).single.id, 8000);
    expect(() => StockCountRepository(db).adjust(owner,
        const AdjustmentRequest('p1', -3000, 'Count correction')),
        throwsStateError);
    expect((await db.select(db.inventory).get()).single.quantityMilli, 10000);
  });

  test('supplier return cannot remove reserved stock', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Widget', priceCents: 1000, costCents: 700, startingStock: 0);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    final supplier = await DirectoryRepository(db).saveSupplier(owner,
        name: 'Supplier');
    final receiving = StockReceivingRepository(db);
    final receipt = await receiving.receive(owner, supplier.id,
        [ReceivingLineRequest(product, 10000, 700)]);
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 8000, 1000)]);
    await orders.transition(owner, order.id, 'confirmed');
    await StockReservationRepository(db).reserve(owner,
        (await orders.lines(order.id)).single.id, 8000);
    final returns = PurchaseReturnRepository(db);
    final item = (await returns.sources(receipt.id)).single.item;
    final draft = await returns.createDraft(owner, receipt.id,
        [PurchaseReturnLineInput(item.id, 3000,
            PurchaseReturnReason.damaged)]);
    expect(() => returns.finalize(owner, draft.id), throwsStateError);
    expect(await pos.stockMilli(product), 10000);
  });

  test('walk-in POS cannot consume stock claimed by a Sales Order', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    await CashSessionRepository(db).open(owner, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget',
        priceCents: 1000, costCents: 700, startingStock: 10);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
        name: 'Ana');
    final orders = SalesOrderRepository(db);
    final order = await orders.create(owner, customer.id,
        [SalesOrderLineRequest(product, 4000, 1000)]);
    await orders.transition(owner, order.id, 'confirmed');
    final layerBefore = (await pos.layersForProduct(product)).single
        .quantityRemainingMilli;
    await StockReservationRepository(db).reserve(owner,
        (await orders.lines(order.id)).single.id, 4000);
    expect((await pos.layersForProduct(product)).single
        .quantityRemainingMilli, layerBefore);
    expect(await db.select(db.saleItemInventoryAllocations).get(), isEmpty);
    expect(() => pos.completeCashSale(
        [SaleLineRequest(product, 7)], 7000, id), throwsStateError);
    expect(await pos.stockMilli(product), 10000);
    await pos.completeCashSale([SaleLineRequest(product, 6)], 6000, id);
    expect(await pos.stockMilli(product), 4000);
    expect(await pos.reservedStockMilli(product), 4000);
  });

  test('concurrent full requests cannot oversubscribe stock', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final owner = await seed(db);
    final orders = SalesOrderRepository(db);
    final a = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 6000, 10000)]);
    final b = await orders.create(owner, 'c1',
        [const SalesOrderLineRequest('p1', 6000, 10000)]);
    await orders.transition(owner, a.id, 'confirmed');
    await orders.transition(owner, b.id, 'confirmed');
    final repo = StockReservationRepository(db);
    final results = await Future.wait([
      repo.reserve(owner, (await orders.lines(a.id)).single.id, 6000)
          .then((_) => true, onError: (_) => false),
      repo.reserve(owner, (await orders.lines(b.id)).single.id, 6000)
          .then((_) => true, onError: (_) => false),
    ]);
    expect(results.where((result) => result), hasLength(1));
    expect((await repo.stock('p1')).reserved, 6000);
  });
}
