import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/global_search_repository.dart';

void main() {
  late AppDatabase db;
  late GlobalSearchRepository search;
  const owner = ActiveUser('owner', 'Owner', UserRole.owner);
  const cashier = ActiveUser('cashier', 'Cashier', UserRole.cashier);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    search = GlobalSearchRepository(db);
    await db.into(db.users).insert(UsersCompanion.insert(
        id: const Value('owner'), name: 'Owner', role: 'owner'));
    await db.into(db.users).insert(UsersCompanion.insert(
        id: const Value('cashier'), name: 'Cashier', role: 'cashier'));
  });
  tearDown(() => db.close());

  test('searches ten entity types by supported fields with bounded results', () async {
    final product = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(name: 'Wireless Mouse', priceCents: 65000,
            sku: const Value('M185-BLK'), barcode: const Value('4801234567890')));
    final customer = await db.into(db.customers).insertReturning(
        CustomersCompanion.insert(name: 'Maria Santos',
            phone: const Value('09171234567')));
    final supplier = await db.into(db.suppliers).insertReturning(
        SuppliersCompanion.insert(name: 'ABC Distribution',
            phone: const Value('0288880000')));
    await db.into(db.sales).insert(SalesCompanion.insert(
        cashierId: owner.id, customerId: Value(customer.id),
        totalCents: 65000, receiptNumber: const Value('POS-000842')));
    final receipt = await db.into(db.stockReceivings).insertReturning(
        StockReceivingsCompanion.insert(sequence: const Value(31),
            supplierId: supplier.id, userId: owner.id,
            externalReference: const Value('INV-7292')));
    final item = await db.into(db.stockReceivingItems).insertReturning(
        StockReceivingItemsCompanion.insert(receivingId: receipt.id,
            productId: product.id, quantityMilli: 1000, unitCostCents: 40000));
    final serial = await db.into(db.serialUnits).insertReturning(
        SerialUnitsCompanion.insert(productId: product.id,
            serialNumber: 'SERIAL-001', receivingItemId: Value(item.id)));
    await db.into(db.quotations).insert(QuotationsCompanion.insert(
        reference: 'Q-000015', customerId: Value(customer.id),
        createdBy: owner.id));
    await db.into(db.layaways).insert(LayawaysCompanion.insert(
        reference: 'LAY-000015', customerId: customer.id,
        createdBy: owner.id, totalCents: 65000));
    await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
        sequence: 15, supplierId: supplier.id, orderDate: DateTime.now(),
        createdBy: owner.id, supplierReference: const Value('SUP-REF-1')));
    await db.into(db.rmaCases).insert(RmaCasesCompanion.insert(
        reference: 'RMA-000015', origin: 'customer',
        issueDescription: 'Mouse issue', intakeCondition: 'Used',
        customerId: Value(customer.id), serialUnitId: Value(serial.id)));

    Future<void> matches(String query, GlobalSearchKind kind) async {
      expect((await search.search(owner, query)).any((r) => r.kind == kind), isTrue,
          reason: '$query should find $kind');
    }
    await matches('Wireless', GlobalSearchKind.product);
    await matches('M185-BLK', GlobalSearchKind.product);
    await matches('4801234567890', GlobalSearchKind.product);
    await matches('09171234567', GlobalSearchKind.customer);
    await matches('0288880000', GlobalSearchKind.supplier);
    await matches('POS-000842', GlobalSearchKind.sale);
    await matches('SERIAL-001', GlobalSearchKind.serial);
    await matches('Q-000015', GlobalSearchKind.quotation);
    await matches('LAY-000015', GlobalSearchKind.layaway);
    await matches('PO-000015', GlobalSearchKind.purchaseOrder);
    await matches('INV-7292', GlobalSearchKind.receiving);
    await matches('RMA-000015', GlobalSearchKind.rma);
    expect((await search.search(owner, 'RCV-000031')).first.kind,
        GlobalSearchKind.receiving);
    expect((await search.search(owner, 'Mouse')).length, lessThanOrEqualTo(40));
  });

  test('exact SKU beats weak name and blank query loads commands only', () async {
    await db.into(db.products).insert(ProductsCompanion.insert(
        name: 'Mouse Pad', priceCents: 10000));
    await db.into(db.products).insert(ProductsCompanion.insert(
        name: 'Accessory', priceCents: 10000,
        sku: const Value('mouse')));
    final results = await search.search(owner, 'mouse');
    expect(results.first.title, 'Accessory');
    expect((await search.search(owner, '')).every((r) =>
        r.kind == GlobalSearchKind.command), isTrue);
  });

  test('cashier sees own sale and permitted commands, not procurement', () async {
    await db.into(db.products).insert(ProductsCompanion.insert(
        name: 'Public Mouse', priceCents: 1000));
    await db.into(db.customers).insert(CustomersCompanion.insert(
        name: 'Public Customer'));
    final supplier = await db.into(db.suppliers).insertReturning(
        SuppliersCompanion.insert(name: 'Private Supplier'));
    await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
        sequence: 1, supplierId: supplier.id,
        orderDate: DateTime.now(), createdBy: owner.id));
    await db.into(db.rmaCases).insert(RmaCasesCompanion.insert(
        reference: 'RMA-PRIVATE', origin: 'inbound',
        issueDescription: 'Private issue', intakeCondition: 'Used',
        supplierId: Value(supplier.id)));
    await db.into(db.sales).insert(SalesCompanion.insert(
        cashierId: owner.id, totalCents: 100,
        receiptNumber: const Value('POS-000001')));
    await db.into(db.sales).insert(SalesCompanion.insert(
        cashierId: cashier.id, totalCents: 100,
        receiptNumber: const Value('POS-000002')));
    expect((await search.search(cashier, 'Private')).isEmpty, isTrue);
    expect((await search.search(cashier, 'PO-000001')).isEmpty, isTrue);
    expect((await search.search(cashier, 'RMA-PRIVATE')).isEmpty, isTrue);
    expect((await search.search(cashier, 'POS-000001')).isEmpty, isTrue);
    expect((await search.search(cashier, 'POS-000002')).single.kind,
        GlobalSearchKind.sale);
    expect((await search.search(cashier, 'Public Mouse')).single.kind,
        GlobalSearchKind.product);
    expect((await search.search(cashier, 'Public Customer')).single.kind,
        GlobalSearchKind.customer);
    final commands = search.commands(cashier);
    expect(commands.any((r) => r.title == 'New Sale'), isTrue);
    expect(commands.any((r) => r.title == 'Open Reports'), isFalse);
    expect(commands.any((r) => r.title == 'Receive Stock'), isFalse);
  });
}
