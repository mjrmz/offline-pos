import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('schema 9 to 10 scales historic quantities and keeps BIR and flags',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase8-v9-');
    final file = File('${dir.path}/pos.sqlite');
    try {
      var db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO users (id, name, role) VALUES ('u', 'Owner', 'owner')");
      await db.customStatement(
          "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Rice', 5000, 0)");
      await db.customStatement(
          "INSERT INTO inventory (product_id, quantity) VALUES ('p', 5)");
      await db.customStatement(
          "INSERT INTO inventory_movements (id, product_id, quantity_delta, reason, created_at) VALUES ('m', 'p', 5, 'initial_stock', 0)");
      await db.customStatement(
          "INSERT INTO sales (id, cashier_id, total_cents, bir_invoice_number, created_at) VALUES ('s', 'u', 5000, 1, 0)");
      await db.customStatement(
          "INSERT INTO sale_items (id, sale_id, product_id, product_name, quantity, unit_price_cents, line_total_cents) VALUES ('i', 's', 'p', 'Rice', 1, 5000, 5000)");
      await db.customStatement(
          "INSERT INTO cash_sessions (id, opened_by_user_id, starting_cash_cents, opened_at, closed_at) VALUES ('c', 'u', 0, 0, 1)");
      await db.customStatement(
          "INSERT INTO bir_compliance_state (id, activated_at, highest_invoice_number, grand_total_cents, highest_z_number) VALUES (1, 0, 1, 5000, 1)");
      await db.customStatement(
          "INSERT INTO z_readings (id, number, cash_session_id, generated_at, generated_by_user_id, period_sales_cents, reversal_cents, grand_total_cents, expected_cash_cents, actual_cash_cents) VALUES ('z', 1, 'c', 1, 'u', 5000, 0, 5000, 5000, 5000)");
      await db.customStatement(
          "INSERT INTO business_feature_settings (feature_id, enabled) VALUES ('weightBasedPricing', 1)");
      await db.customStatement(
          "INSERT INTO product_business_configurations (product_id, feature_id, configuration_json) VALUES ('p', 'weightBasedPricing', '{\"enabled\":true,\"unit\":\"kilogram\"}')");
      await db.customStatement(
          "INSERT INTO product_business_configurations (product_id, feature_id, configuration_json) VALUES ('p', 'expiryBatchTracking', '{\"enabled\":true}')");
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE product_lots');
      raw.execute('DROP TABLE made_orders');
      raw.execute('DROP TABLE tank_empty_movements');
      raw.execute('ALTER TABLE inventory DROP COLUMN quantity_milli');
      raw.execute(
          'ALTER TABLE inventory_movements DROP COLUMN quantity_delta_milli');
      for (final column in [
        'quantity_milli',
        'sale_unit',
        'sale_mode',
        'batch_id',
        'batch_number',
        'extra_cents'
      ]) {
        raw.execute('ALTER TABLE sale_items DROP COLUMN $column');
      }
      raw.execute('PRAGMA user_version = 9');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect((await db.select(db.inventory).get()).single.quantityMilli, 5000);
      expect(
          (await db.select(db.inventoryMovements).get())
              .single
              .quantityDeltaMilli,
          5000);
      final item = (await db.select(db.saleItems).get()).single;
      expect(item.quantityMilli, 1000);
      expect(item.saleUnit, 'pcs');
      expect((await db.select(db.products).get()).single.name, 'Rice');
      expect((await db.select(db.sales).get()).single.birInvoiceNumber, 1);
      expect((await db.select(db.zReadings).get()).single.number, 1);
      expect((await db.select(db.businessFeatureSettings).get()).single.enabled,
          true);
      expect(
          (await db.select(db.productBusinessConfigurations).get()).length, 2);
      expect(
          (await db.select(db.productLots).get()).single.quantityMilli, 5000);
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
