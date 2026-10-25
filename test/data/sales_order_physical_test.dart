import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_order_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('schema 49 migration preserves order and initializes physical state', () async {
    final dir = await Directory.systemTemp.createTemp('phase-j-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/pos.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    final id = await AuthService(AuthRepository(seed)).bootstrap('Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(seed).saveCustomer(owner, name: 'Ana');
    final product = await PosRepository(seed).saveProduct(name: 'Widget', priceCents: 10000,
      costCents: 5000, startingStock: 3);
    final order = await SalesOrderRepository(seed).create(owner, customer.id,
      [SalesOrderLineRequest(product, 1000, 10000)]);
    await seed.close();
    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP INDEX IF EXISTS sales_orders_physical_queue');
    raw.execute('DROP INDEX IF EXISTS sales_order_physical_events_order');
    raw.execute('DROP TABLE sales_order_physical_events');
    for (final column in ['physical_status','scheduled_at','contact_name_snapshot',
      'contact_phone_snapshot','delivery_address_snapshot','fulfillment_instructions',
      'delivery_fee_cents','recipient_name','physical_completed_at']) {
      raw.execute('ALTER TABLE sales_orders DROP COLUMN $column');
    }
    raw.execute('ALTER TABLE sales DROP COLUMN delivery_fee_cents');
    raw.execute('PRAGMA user_version = 49');
    raw.dispose();
    final db = AppDatabase.forTesting(NativeDatabase(file));
    expect(db.schemaVersion, 50);
    final migrated = (await db.select(db.salesOrders).get()).single;
    expect(migrated.id, order.id);
    expect(migrated.physicalStatus, 'pending');
    expect(migrated.deliveryAddressSnapshot, isNull);
    expect(migrated.deliveryFeeCents, 0);
    final backup = await BackupService(db, dir).create(BackupKind.manual);
    expect(BackupService.verify(backup.file), 50);
    await db.close();
  });

  test('pickup and delivery transitions are guarded and append events without sales', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final role = await auth.createRole('Viewer', 'View orders',
      {PosPermission.viewSalesOrders});
    final viewerId = await auth.createUserWithRole('Viewer', role, 'viewerPassword123');
    final customer = await DirectoryRepository(db).saveCustomer(owner,
      name: 'Ana', phone: '123', address: 'Old address');
    final product = await PosRepository(db).saveProduct(name: 'Widget',
      priceCents: 10000, costCents: 5000, startingStock: 3);
    final repo = SalesOrderRepository(db);
    final pickup = await repo.create(owner, customer.id,
      [SalesOrderLineRequest(product, 1000, 10000)], fulfillmentMethod: 'pickup');
    await repo.transition(owner, pickup.id, 'confirmed');
    expect(() => repo.transitionPhysical(
      ActiveUser(viewerId, 'Viewer', UserRole.custom), pickup.id, 'scheduled',
      scheduledAt: DateTime(2026, 10, 25)), throwsStateError);
    expect(() => repo.transitionPhysical(owner, pickup.id, 'ready'), throwsStateError);
    await repo.transitionPhysical(owner, pickup.id, 'scheduled', scheduledAt: DateTime.now());
    expect(() => repo.transitionPhysical(owner, pickup.id, 'out_for_delivery'), throwsStateError);
    expect(() => repo.transitionPhysical(owner, pickup.id, 'ready'), throwsStateError);
    expect((await db.select(db.sales).get()), isEmpty);
    expect((await db.select(db.saleItemInventoryAllocations).get()), isEmpty);
    final delivery = await repo.create(owner, customer.id,
      [SalesOrderLineRequest(product, 1000, 10000)], fulfillmentMethod: 'delivery');
    expect(delivery.deliveryAddressSnapshot, 'Old address');
    await db.customStatement("UPDATE customers SET address='New address' WHERE id=?", [customer.id]);
    expect((await repo.byReference(delivery.reference))!.deliveryAddressSnapshot, 'Old address');
    await repo.transition(owner, delivery.id, 'confirmed');
    await repo.configurePhysical(owner, delivery.id, method: 'delivery',
      contactName: 'Ana', address: 'Old address', deliveryFeeCents: 20000);
    await repo.transitionPhysical(owner, delivery.id, 'scheduled', scheduledAt: DateTime(2026, 10, 25));
    expect(() => repo.transitionPhysical(owner, delivery.id, 'picked_up'), throwsStateError);
    expect((await repo.physicalEvents(delivery.id)).length, 1);
    expect((await repo.physicalQueue()).items.length, 2);
    expect((await repo.physicalQueue(status: 'today')).items.map((o) => o.id),
      contains(pickup.id));
    final pickupLine = (await repo.lines(pickup.id)).single;
    await PosRepository(db).completeCashSale(
      [SaleLineRequest(product, 1, lineKey: pickupLine.id)], 10000, id,
      customerId: customer.id, salesOrderId: pickup.id);
    await repo.transitionPhysical(owner, pickup.id, 'ready');
    final handedOver = await repo.transitionPhysical(owner, pickup.id, 'picked_up',
      recipientName: 'Ana');
    expect(handedOver.physicalStatus, 'picked_up');
    expect(() => repo.transitionPhysical(owner, pickup.id, 'scheduled',
      scheduledAt: DateTime(2026, 10, 26)), throwsStateError);
  });

  test('delivery fee is collected on final Sale only', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db)).bootstrap('Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final customer = await DirectoryRepository(db).saveCustomer(owner,
      name: 'Ana', address: 'Main Street');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(name: 'Widget', priceCents: 10000,
      costCents: 5000, startingStock: 10);
    final repo = SalesOrderRepository(db);
    final order = await repo.create(owner, customer.id,
      [SalesOrderLineRequest(product, 10000, 10000)], fulfillmentMethod: 'delivery');
    await repo.configurePhysical(owner, order.id, method: 'delivery',
      contactName: 'Ana', address: 'Main Street', deliveryFeeCents: 20000);
    await repo.transition(owner, order.id, 'confirmed');
    final line = (await repo.lines(order.id)).single;
    final first = await pos.completeCashSale([SaleLineRequest(product, 4, lineKey: line.id)],
      40000, id, customerId: customer.id, salesOrderId: order.id);
    expect(first.totalCents, 40000);
    expect((await db.select(db.sales).get()).single.deliveryFeeCents, 0);
    final second = await pos.completeCashSale([SaleLineRequest(product, 6, lineKey: line.id)],
      80000, id, customerId: customer.id, salesOrderId: order.id);
    expect(second.totalCents, 80000);
    expect((await db.select(db.sales).get()).map((s) => s.deliveryFeeCents).toList(),
      [0, 20000]);
    final salesBeforePhysical = (await db.select(db.sales).get()).length;
    final stockBeforePhysical = await pos.stockMilli(product);
    final reservationsBeforePhysical = await db.select(db.stockReservations).get();
    final creditBeforePhysical = await db.select(db.customerCreditEntries).get();
    final cashBeforePhysical = await db.select(db.cashMovements).get();
    final birBeforePhysical = await db.select(db.birComplianceState).get();
    await repo.transitionPhysical(owner, order.id, 'scheduled', scheduledAt: DateTime(2026, 10, 25));
    await repo.transitionPhysical(owner, order.id, 'ready');
    await repo.transitionPhysical(owner, order.id, 'out_for_delivery');
    await repo.transitionPhysical(owner, order.id, 'failed_delivery', notes: 'Customer unavailable');
    await repo.transitionPhysical(owner, order.id, 'scheduled', scheduledAt: DateTime(2026, 10, 26));
    await repo.transitionPhysical(owner, order.id, 'ready');
    await repo.transitionPhysical(owner, order.id, 'out_for_delivery');
    final completed = await repo.transitionPhysical(owner, order.id, 'delivered',
      recipientName: 'Ana', notes: 'Handed over');
    expect(completed.recipientName, 'Ana');
    expect(completed.physicalCompletedAt, isNotNull);
    final events = await repo.physicalEvents(order.id);
    expect(events.map((e) => e.newStatus), contains('failed_delivery'));
    expect(events.where((e) => e.newStatus == 'failed_delivery').single.notes,
      'Customer unavailable');
    expect(events.every((e) => e.actorId == id), isTrue);
    expect(() => repo.transitionPhysical(owner, order.id, 'ready'), throwsStateError);
    expect((await db.select(db.sales).get()).length, salesBeforePhysical);
    expect(await pos.stockMilli(product), stockBeforePhysical);
    expect(await db.select(db.stockReservations).get(), reservationsBeforePhysical);
    expect(await db.select(db.customerCreditEntries).get(), creditBeforePhysical);
    expect(await db.select(db.cashMovements).get(), cashBeforePhysical);
    expect(await db.select(db.birComplianceState).get(), birBeforePhysical);
    expect(() => pos.completeCashSale([SaleLineRequest(product, 1, lineKey: line.id)],
      30000, id, customerId: customer.id, salesOrderId: order.id), throwsStateError);
  });
}
