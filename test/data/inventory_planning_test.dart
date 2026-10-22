import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/inventory_planning_repository.dart';

void main() {
  test('planning keeps incoming separate and uses target less projected',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, reorder_level_qty_milli, target_stock_qty_milli, created_at) VALUES ('p', 'Example', 100, 5000, 20000, 1)");
    await db.customStatement(
        "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p', 4, 4000)");
    await db.customStatement(
        "INSERT INTO suppliers (id, name, created_at) VALUES ('s', 'Supplier', 1)");
    await db.customStatement(
        "INSERT INTO users (id, name, password_hash, role) VALUES ('u', 'Owner', 'hash', 'owner')");
    await db.customStatement(
        "INSERT INTO purchase_orders (id, sequence, supplier_id, status, order_date, created_by, created_at, updated_at) VALUES ('po', 1, 's', 'sent', 1, 'u', 1, 1)");
    await db.customStatement(
        "INSERT INTO purchase_order_lines (id, purchase_order_id, product_id, ordered_qty_milli, expected_unit_cost_cents) VALUES ('line', 'po', 'p', 6000, 100)");
    final repository = InventoryPlanningRepository(db);
    final row = (await repository.load())['p']!;
    expect(row.availableMilli, 4000);
    expect(row.incomingMilli, 6000);
    expect(row.projectedMilli, 10000);
    expect(row.suggestedReorderMilli, 10000);
    expect(row.belowReorderLevel, isTrue);
    expect(row.incomingCoversShortage, isTrue);
    await db.customStatement(
        "UPDATE purchase_orders SET status = 'cancelled' WHERE id = 'po'");
    expect((await repository.load())['p']!.incomingMilli, 0);
    expect((await repository.load())['p']!.availableMilli, 4000);
  });
}
