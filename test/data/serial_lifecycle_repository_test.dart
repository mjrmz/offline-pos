import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/serial_lifecycle_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  test('serial search ranks exact first, pages, and enforces access', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final product = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(name: 'Drive', priceCents: 100));
    for (var i = 0; i < 51; i++) {
      await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
          productId: product.id,
          serialNumber: 'AB${i.toString().padLeft(3, '0')}'));
    }
    final exact = await db.into(db.serialUnits).insertReturning(
        SerialUnitsCompanion.insert(
            productId: product.id,
            serialNumber: 'AB',
            status: const Value('available')));
    final repository = SerialLifecycleRepository(db);
    const permitted = ActiveUser('staff', 'Staff', UserRole.owner);
    final first = await repository.search(permitted, 'ab');
    expect(first, hasLength(50));
    expect(first.first.id, exact.id);
    expect(await repository.search(permitted, 'ab', page: 1), hasLength(2));
    expect((await repository.load(permitted, exact.id))?.status, 'available');
    const restricted = ActiveUser('staff', 'Staff', UserRole.cashier);
    await expectLater(repository.search(restricted, 'ab'), throwsStateError);
  });

  test('receiving and sale remain ordered historical facts', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    const user = ActiveUser('staff', 'Staff', UserRole.owner);
    await db.customStatement(
        "INSERT INTO users(id,name,role) VALUES ('staff','Staff','owner')");
    await db.into(db.suppliers).insert(SuppliersCompanion.insert(
        id: const Value('supplier'), name: 'ABC Supplier'));
    await db.into(db.customers).insert(CustomersCompanion.insert(
        id: const Value('customer'), name: 'Maria Santos'));
    await db.into(db.products).insert(ProductsCompanion.insert(
        id: const Value('product'), name: 'Drive', priceCents: 100));
    await db.customStatement("""INSERT INTO stock_receivings
      (id,sequence,supplier_id,user_id,received_at)
      VALUES ('receiving',25,'supplier','staff',1000)""");
    await db.customStatement("""INSERT INTO stock_receiving_items
      (id,receiving_id,product_id,quantity_milli,unit_cost_cents)
      VALUES ('item','receiving','product',1000,50)""");
    await db.customStatement("""INSERT INTO serial_units
      (id,product_id,serial_number,status,receiving_item_id,created_at)
      VALUES ('serial','product','SN-1','sold','item',1000)""");
    await db.customStatement("""INSERT INTO sales
      (id,receipt_number,cashier_id,customer_id,total_cents,status,created_at)
      VALUES ('sale','POS-1','staff','customer',100,'completed',2000)""");
    await db.customStatement("""INSERT INTO sale_items
      (id,sale_id,product_id,quantity,unit_price_cents)
      VALUES ('line','sale','product',1,100)""");
    await db.customStatement("""INSERT INTO serial_sale_links
      (id,serial_unit_id,sale_item_id,created_at)
      VALUES ('link','serial','line',2000)""");
    final lifecycle = await SerialLifecycleRepository(db).load(user, 'serial');
    expect(lifecycle?.events.map((e) => e.title), ['Received', 'Sold']);
    expect(lifecycle?.events.first.reference, 'RCV-000025');
    expect(lifecycle?.events.last.description, contains('Maria Santos'));
    expect(lifecycle?.status, 'sold');
    await db.customStatement("UPDATE serial_units SET status='available' WHERE id='serial'");
    final conflict = await SerialLifecycleRepository(db).load(user, 'serial');
    expect(conflict?.status, 'available');
    expect(conflict?.warning, 'Serial history needs review');
    await db.customStatement("UPDATE serial_units SET status='sold' WHERE id='serial'");
    const catalog = ActiveUser('catalog', 'Catalog', UserRole.custom, true,
        null, {PosPermission.manageCatalog});
    final restricted =
        await SerialLifecycleRepository(db).load(catalog, 'serial');
    expect(restricted?.status, 'sold');
    expect(restricted?.supplier, isNull);
    expect(restricted?.events, isEmpty);
    expect(
        (await SerialLifecycleRepository(db).search(catalog, 'SN-1'))
            .single
            .reference,
        isNull);
    const receivingOnly = ActiveUser('receiver', 'Receiver', UserRole.custom,
        true, null, {PosPermission.stockReceiving});
    final receivingView = await SerialLifecycleRepository(db)
        .load(receivingOnly, 'serial');
    expect(receivingView!.events.map((e) => e.title), ['Received']);
    expect(receivingView.events.single.description, 'ABC Supplier');
    await db.customStatement("""INSERT INTO inventory_layers
      (id,product_id,source,quantity_received_milli,quantity_remaining_milli,
       unit_cost_cents,received_at)
      VALUES ('layer','product','receiving',1000,0,50,1000)""");
    await db.customStatement("""INSERT INTO sale_item_inventory_allocations
      (id,sale_item_id,inventory_layer_id,serial_unit_id,quantity_milli,
       unit_cost_snapshot_cents,unit_selling_price_snapshot_cents,created_at)
      VALUES ('allocation','line','layer','serial',1000,50,100,2000)""");
    await db.customStatement("""INSERT INTO sale_returns
      (id,reference,original_sale_id,actor_id,kind,status,reason,
       refund_value_cents,created_at)
      VALUES ('return','RET-1','sale','staff','refund','finalized','faulty',100,3000000)""");
    await db.customStatement("""INSERT INTO sale_return_lines
      (id,return_id,sale_item_id,quantity_milli,refund_cents,disposition)
      VALUES ('return-line','return','line',1000,100,'sellable')""");
    await db.customStatement("""INSERT INTO sale_return_allocations
      (id,return_line_id,original_allocation_id,quantity_milli,serial_unit_id,
       unit_cost_cents)
      VALUES ('return-allocation','return-line','allocation',1000,'serial',50)""");
    final returned = await SerialLifecycleRepository(db).load(user, 'serial');
    expect(returned!.events.any((e) => e.title == 'Returned sellable'), isTrue);
    expect(returned.events.firstWhere((e) => e.source == 'return').sourceId,
        'sale');
    await db.customStatement("""INSERT INTO serial_units
      (id,product_id,serial_number,status,receiving_item_id,created_at)
      VALUES ('serial-2','product','SN-2','sold','item',1000)""");
    await db.customStatement("""INSERT INTO sale_item_inventory_allocations
      (id,sale_item_id,inventory_layer_id,serial_unit_id,quantity_milli,
       unit_cost_snapshot_cents,unit_selling_price_snapshot_cents,created_at)
      VALUES ('allocation-2','line','layer','serial-2',1000,50,100,2000)""");
    await db.customStatement("""INSERT INTO sale_returns
      (id,reference,original_sale_id,actor_id,kind,status,reason,
       refund_value_cents,created_at)
      VALUES ('return-2','RET-2','sale','staff','refund','finalized','damaged',100,3001000)""");
    await db.customStatement("""INSERT INTO sale_return_lines
      (id,return_id,sale_item_id,quantity_milli,refund_cents,disposition)
      VALUES ('return-line-2','return-2','line',1000,100,'non_sellable')""");
    await db.customStatement("""INSERT INTO sale_return_allocations
      (id,return_line_id,original_allocation_id,quantity_milli,serial_unit_id,
       unit_cost_cents)
      VALUES ('return-allocation-2','return-line-2','allocation-2',1000,'serial-2',50)""");
    expect(
        (await SerialLifecycleRepository(db).load(user, 'serial-2'))!
            .events
            .any((e) => e.title == 'Returned non-sellable'),
        isTrue);
    await db.customStatement("""INSERT INTO sale_reversals
      (id,sale_id,actor_id,kind,amount_cents,stock_restored,created_at)
      VALUES ('reversal','sale','staff','void',100,1,4000)""");
    await db
        .customStatement("UPDATE sales SET status='voided' WHERE id='sale'");
    await db.customStatement(
        "UPDATE serial_units SET status='available' WHERE id='serial'");
    final reversed = await SerialLifecycleRepository(db).load(user, 'serial');
    expect(reversed!.status, 'available');
    expect(reversed.events.any((e) => e.title == 'Sold'), isTrue);
    expect(reversed.events.any((e) => e.title == 'Sale voided / restored'),
        isTrue);
    expect(reversed.warning, isNull);
    await db.customStatement("""INSERT INTO serial_units
      (id,product_id,serial_number,status,receiving_item_id,created_at)
      VALUES ('replacement','product','SN-NEW','available','item',5000)""");
    await db.customStatement("""INSERT INTO rma_cases
      (id,reference,origin,serial_unit_id,issue_description,intake_condition,
       status,replacement_serial_unit_id,created_at)
      VALUES ('customer-rma','RMA-C','customer','serial','Fault','Used',
        'resolved','replacement',5000)""");
    await db.customStatement("""INSERT INTO rma_events
      (id,case_id,actor_id,status,created_at)
      VALUES ('rma-resolution','customer-rma','staff','resolved',6000)""");
    await db.customStatement("""INSERT INTO rma_cases
      (id,reference,origin,serial_unit_id,supplier_id,issue_description,
       intake_condition,status,created_at)
      VALUES ('supplier-rma','RMA-S','inbound','serial','supplier',
        'Supplier fault','Used','pending',7000)""");
    final rma = await SerialLifecycleRepository(db).load(user, 'serial');
    expect(rma!.events.any((e) => e.title == 'Customer RMA opened'), isTrue);
    expect(rma.events.any((e) => e.title == 'Supplier RMA opened'), isTrue);
    expect(rma.events.any((e) => e.title == 'RMA resolved'), isTrue);
    expect(rma.events.firstWhere((e) => e.title == 'Replaced by').reference,
        'SN-NEW');
    final replacement = await SerialLifecycleRepository(db).load(user, 'replacement');
    expect(replacement!.events.firstWhere((e) => e.title == 'Replacement for')
        .reference, 'SN-1');
    await db.customStatement("""INSERT INTO purchase_returns
      (id,sequence,supplier_id,receiving_id,return_date,status,created_by,
       finalized_at,created_at)
      VALUES ('purchase-return',9,'supplier','receiving',8000,'finalized',
        'staff',8000,8000)""");
    await db.customStatement("""INSERT INTO purchase_return_lines
      (id,purchase_return_id,product_id,receiving_item_id,inventory_layer_id,
       serial_unit_id,quantity_milli,unit_cost_cents,return_value_cents,reason)
      VALUES ('purchase-line','purchase-return','product','item','layer',
        'serial',1000,50,50,'defective')""");
    final supplierReturn = await SerialLifecycleRepository(db).load(user, 'serial');
    final purchaseEvent = supplierReturn!.events.firstWhere(
        (e) => e.title == 'Returned to Supplier');
    expect(purchaseEvent.reference, 'PRT-000009');
    expect(purchaseEvent.source, 'purchase_return');
    await db.customStatement("""INSERT INTO products
      (id,name,price_cents,product_type,is_active,created_at)
      VALUES ('kit','Bundle',500,'kit',0,9000)""");
    await db.customStatement("""INSERT INTO product_kit_components
      (id,kit_product_id,component_product_id,quantity_milli,created_at)
      VALUES ('catalog-component','kit','product',1000,9000)""");
    await db.customStatement("UPDATE products SET is_active=1 WHERE id='kit'");
    await db.customStatement("""INSERT INTO serial_units
      (id,product_id,serial_number,status,receiving_item_id,created_at)
      VALUES ('kit-serial','product','KIT-SN','sold','item',9000)""");
    await db.customStatement("""INSERT INTO sales
      (id,receipt_number,cashier_id,total_cents,status,created_at)
      VALUES ('kit-sale','POS-KIT','staff',500,'completed',10000)""");
    await db.customStatement("""INSERT INTO sale_items
      (id,sale_id,product_id,product_name,quantity,unit_price_cents)
      VALUES ('kit-line','kit-sale','kit','Bundle',1,500)""");
    await db.customStatement("""INSERT INTO sale_item_kit_components
      (id,sale_item_id,kit_product_id,component_product_id,
       component_name_snapshot,required_quantity_milli,kit_quantity_milli,
       total_quantity_milli,allocated_cost_cents,created_at)
      VALUES ('kit-component','kit-line','kit','product','Drive',1000,1000,
        1000,50,10000)""");
    await db.customStatement("""INSERT INTO serial_sale_links
      (id,serial_unit_id,sale_item_id,created_at)
      VALUES ('kit-link','kit-serial','kit-line',10000)""");
    final kit = await SerialLifecycleRepository(db).load(user, 'kit-serial');
    expect(kit!.product, 'Drive');
    expect(kit.events.firstWhere((e) => e.title == 'Sold').description,
        contains('Kit component of Bundle'));
  });
}
