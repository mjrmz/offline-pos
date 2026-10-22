import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/quantity.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/operational_summary_repository.dart';
import 'package:modern_offline_pos/data/daos/inventory_health_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';

void main() {
  test('Operations counts active reservations and net customer credit',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
      name: 'Reserved item',
      priceCents: 1000,
      costCents: 500,
      startingStock: 5,
      lowStockThreshold: 2,
    );
    final customerId = await db
        .into(db.customers)
        .insertReturning(CustomersCompanion.insert(name: 'Customer'))
        .then((row) => row.id);
    final layawayId = await db
        .into(db.layaways)
        .insertReturning(
          LayawaysCompanion.insert(
            reference: 'LAY-OPS-1',
            customerId: customerId,
            createdBy: ownerId,
            totalCents: 4000,
          ),
        )
        .then((row) => row.id);
    await db.into(db.layawayItems).insert(LayawayItemsCompanion.insert(
          layawayId: layawayId,
          productId: productId,
          quantityMilli: 4 * Quantity.scale,
          unitSnapshot: 'pcs',
          unitPriceCents: 1000,
          lineTotalCents: 4000,
        ));
    await db.into(db.customerCreditEntries).insert(
          CustomerCreditEntriesCompanion.insert(
            customerId: customerId,
            userId: ownerId,
            amountCents: 500,
            kind: 'credit',
          ),
        );
    await db.into(db.customerCreditEntries).insert(
          CustomerCreditEntriesCompanion.insert(
            customerId: customerId,
            userId: ownerId,
            amountCents: -200,
            kind: 'payment',
          ),
        );

    final data = await OperationalSummaryRepository(db).load();
    expect(data.activeLayaway, 1);
    expect(data.outOfStock, isEmpty);
    expect(data.lowStockAlerts.single.availableMilli, Quantity.scale);
    expect(data.outstandingCredit, [('Customer', 300)]);
    expect(data.lowStockAlerts.single.availableMilli,
        5 * Quantity.scale - await pos.reservedStockMilli(productId));

    final today = DateTime.now();
    await db.into(db.productLots).insert(ProductLotsCompanion.insert(
          productId: productId,
          batchNumber: 'LOT-OPS-1',
          expiryDate: Value(DateTime(today.year, today.month, today.day + 10)),
          quantityMilli: const Value(Quantity.scale),
        ));
    final health = InventoryHealthRepository(db);
    await health.saveSettings(const InventoryHealthSettings(30, 90, 5));
    expect((await OperationalSummaryRepository(db).load()).expiringBatches,
        isEmpty);
    await health.saveSettings(const InventoryHealthSettings(30, 90, 15));
    expect((await OperationalSummaryRepository(db).load()).expiringBatches,
        hasLength(1));
  });
}
