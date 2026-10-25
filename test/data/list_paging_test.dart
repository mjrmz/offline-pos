import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/daos/inventory_movement_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/data/daos/rma_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_activity_repository.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  test('RMA SQL search and lifecycle stage page count stay aligned', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2025, 3, 4).millisecondsSinceEpoch ~/ 1000;
    for (var index = 0; index < 51; index++) {
      await db.customStatement('''INSERT INTO rma_cases
        (id, reference, origin, issue_description, intake_condition, quantity_milli, created_at)
        VALUES (?, ?, 'customer', 'Faulty screen', '', 1000, ?)''', [
        'rma-${index.toString().padLeft(3, '0')}',
        'RMA-${index.toString().padLeft(6, '0')}',
        at
      ]);
    }
    final repo = RmaRepository(db);
    final first = await repo.page(origin: 'customer', search: 'faulty');
    final second =
        await repo.page(origin: 'customer', search: 'faulty', page: 1);
    expect(first.totalCount, 51);
    expect(first.items, hasLength(50));
    expect(first.items.first.id, 'rma-050');
    expect(second.items.single.id, 'rma-000');
    expect(
        (await repo.page(origin: 'customer', stage: 'Legacy')).totalCount, 51);
    expect((await repo.page(origin: 'customer', stage: 'Completed')).totalCount,
        0);
    expect((await repo.stageCounts('customer'))['Legacy'], 51);
  });

  test('cash records merge legacy and current entries in stable SQL pages',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    final at = DateTime(2025, 3, 4).millisecondsSinceEpoch ~/ 1000;
    await db.customStatement('''INSERT INTO cash_sessions
      (id, opened_by_user_id, starting_cash_cents, opened_at)
      VALUES ('session', ?, 0, ?)''', [userId, at]);
    for (var index = 0; index < 50; index++) {
      await db.customStatement('''INSERT INTO business_cash_movements
        (id, type, amount_cents, source, category_name, recorded_by_user_id, created_at)
        VALUES (?, 'expense', 100, 'drawer', 'Office', ?, ?)''',
          ['cash-${index.toString().padLeft(3, '0')}', userId, at]);
    }
    await db.customStatement('''INSERT INTO petty_cash_entries
      (id, cash_session_id, user_id, amount_cents, category, created_at)
      VALUES ('legacy', 'session', ?, 200, 'Office', ?)''', [userId, at]);
    final repo = CashActivityRepository(db);
    final first = await repo.recordsPage(expensesOnly: true, search: 'office');
    final second =
        await repo.recordsPage(expensesOnly: true, search: 'office', page: 1);
    expect(first.totalCount, 51);
    expect(first.items, hasLength(50));
    expect(second.items.single.legacy?.id, 'legacy');
    expect((await repo.recordsPage(type: 'replenishment')).totalCount, 0);
    expect((await repo.recordsPage(fund: 'petty')).totalCount, 0);
    expect(await repo.balance('drawer'), 0);
  });
  test('movement search, filters and stable 50-row SQL pages', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
      name: 'Widget',
      priceCents: 100,
      costCents: 50,
    );
    final other = await pos.saveProduct(
      name: 'Unrelated',
      priceCents: 100,
      costCents: 50,
    );
    final at = DateTime(2025, 2, 3, 10);
    for (var index = 0; index < 51; index++) {
      await db.into(db.inventoryMovements).insert(
            InventoryMovementsCompanion.insert(
              id: Value('movement-${index.toString().padLeft(3, '0')}'),
              productId: product,
              quantityDelta: -1,
              quantityDeltaMilli: const Value(-1000),
              reason: 'sale',
              createdAt: Value(at),
            ),
          );
    }
    await db.into(db.inventoryMovements).insert(
          InventoryMovementsCompanion.insert(
            id: const Value('other-movement'),
            productId: other,
            quantityDelta: 1,
            quantityDeltaMilli: const Value(1000),
            reason: 'receiving',
            createdAt: Value(at),
          ),
        );
    final repository = InventoryMovementRepository(db);
    final first = await repository.page(search: 'widget', type: 'Sale');
    final second =
        await repository.page(page: 1, search: 'widget', type: 'Sale');
    expect(first.totalCount, 51);
    expect(first.items, hasLength(50));
    expect(first.hasPrevious, isFalse);
    expect(first.hasNext, isTrue);
    expect(first.items.first.id, 'movement-050');
    expect(second.items.single.id, 'movement-000');
    expect(second.hasPrevious, isTrue);
    expect(second.hasNext, isFalse);
    expect({
      ...first.items.map((row) => row.id),
      ...second.items.map((row) => row.id)
    }, hasLength(51));
    final receiving = await repository.page(type: 'Receiving');
    expect(receiving.totalCount, 1);
    expect(receiving.items.single.productId, other);
    final outside = await repository.page(
      from: DateTime(2025, 2, 4),
    );
    expect(outside.totalCount, 0);
    expect(outside.items, isEmpty);
  });

  test('receiving history pages and counts the same SQL filter', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Acme Supply');
    final other = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Other Supply');
    final at = DateTime(2025, 3, 4, 10);
    for (var index = 0; index < 51; index++) {
      await db.into(db.stockReceivings).insert(
            StockReceivingsCompanion.insert(
              id: Value('receiving-${index.toString().padLeft(3, '0')}'),
              sequence: Value(index + 1),
              supplierId: supplier.id,
              userId: ownerId,
              externalReference:
                  Value('INV-${index.toString().padLeft(3, '0')}'),
              receivedAt: Value(at),
            ),
          );
    }
    await db.into(db.stockReceivings).insert(
          StockReceivingsCompanion.insert(
            id: const Value('other-receiving'),
            sequence: const Value(52),
            supplierId: other.id,
            userId: ownerId,
            receivedAt: Value(at),
          ),
        );
    final repository = StockReceivingRepository(db);
    final first = await repository.historyPage(supplierId: supplier.id);
    final second =
        await repository.historyPage(page: 1, supplierId: supplier.id);
    expect(first.totalCount, 51);
    expect(first.items, hasLength(50));
    expect(first.items.first.sequence, 51);
    expect(second.items.single.sequence, 1);
    expect(second.hasNext, isFalse);
    final searched = await repository.historyPage(search: 'INV-025');
    expect(searched.totalCount, 1);
    expect(searched.items.single.sequence, 26);
    final outside = await repository.historyPage(from: DateTime(2025, 3, 5));
    expect(outside.totalCount, 0);
  });

  test('purchase orders page with supplier, date and overdue filters',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Acme Supply');
    for (var index = 0; index < 51; index++) {
      await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
            id: Value('order-${index.toString().padLeft(3, '0')}'),
            sequence: index + 1,
            supplierId: supplier.id,
            orderDate: DateTime(2025, 4, 1),
            expectedDeliveryDate: Value(DateTime(2025, 4, 3)),
            createdBy: ownerId,
          ));
    }
    final repository = PurchaseOrderRepository(db);
    final first = await repository.page(supplierId: supplier.id);
    final second = await repository.page(page: 1, supplierId: supplier.id);
    expect(first.totalCount, 51);
    expect(first.items, hasLength(50));
    expect(first.items.first.order.sequence, 51);
    expect(second.items.single.order.sequence, 1);
    expect(second.hasNext, isFalse);
    expect((await repository.page(search: 'PO-000025')).totalCount, 1);
    expect((await repository.page(status: 'Draft')).totalCount, 51);
    expect(
        (await repository.page(status: 'Overdue', today: DateTime(2025, 4, 5)))
            .totalCount,
        0);
    expect(
        (await repository.page(orderFrom: DateTime(2025, 4, 2))).totalCount, 0);
  });

  test('quotations page with live-stock readiness and matching counts',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
      name: 'Quote Widget',
      priceCents: 100,
      costCents: 50,
    );
    final at = DateTime(2025, 2, 3, 10);
    for (var index = 0; index < 51; index++) {
      final quoteId = 'quote-${index.toString().padLeft(3, '0')}';
      await db.into(db.quotations).insert(QuotationsCompanion.insert(
            id: Value(quoteId),
            reference: 'QUO-${(index + 1).toString().padLeft(6, '0')}',
            createdBy: ownerId,
            createdAt: Value(at),
          ));
      await db.into(db.quotationItems).insert(QuotationItemsCompanion.insert(
            quotationId: quoteId,
            productId: Value(product),
            productNameSnapshot: const Value('Quote Widget'),
            quantityMilli: 1000,
            unitSnapshot: 'pc',
            unitPriceCents: 100,
            lineTotalCents: 100,
          ));
    }
    final repository = QuotationRepository(db, pos);
    final first = await repository.page(status: 'awaiting stock');
    final second = await repository.page(page: 1, status: 'awaiting stock');
    expect(first.totalCount, 51);
    expect(first.items, hasLength(50));
    expect(first.items.first.reference, 'QUO-000051');
    expect(second.items.single.reference, 'QUO-000001');
    expect((await repository.page(status: 'ready')).totalCount, 0);
    expect((await repository.page(search: 'quote widget')).totalCount, 51);
    expect((await repository.overview())['awaiting stock'], 51);
  });
}
