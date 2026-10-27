import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Rebuilds a seeded test database with DDL captured from genuine schema 7,
/// 8, 22, 29, 40, and 49 backups. Intermediate versions reverse changes in
/// the app's corresponding migrations. The seed file is used only as a source
/// of rows; it is never passed to Drift with a lowered user_version.
Future<void> rebuildAsHistoricalFixture(File seedFile, int version) async {
  if (!(version == 6 || version == 8 || version == 9 ||
      (version >= 10 && version <= 22) ||
      (version >= 28 && version <= 29) ||
      (version >= 36 && version <= 49))) {
    throw ArgumentError.value(version, 'version', 'Unsupported historical checkpoint');
  }
  final baseVersion = version == 6 ? 7 : version <= 9 ? 8 :
      version <= 22 ? 22 : version <= 29 ? 29 : version < 40 ? 40 : 49;
  final source = sqlite.sqlite3.open(seedFile.path, mode: sqlite.OpenMode.readOnly);
  final historicalFile = File('${seedFile.path}.historical');
  if (historicalFile.existsSync()) historicalFile.deleteSync();
  final historical = sqlite.sqlite3.open(historicalFile.path);
  try {
    final archive = jsonDecode(
        File('test/fixtures/schema_$baseVersion.json').readAsStringSync()) as Map<String, dynamic>;
    if (archive['version'] != baseVersion) throw StateError('Wrong archived schema');
    final statements = (archive['statements'] as List).cast<String>();
    final triggers = <String>[];
    for (var statement in statements) {
      if (version == 28 && statement.startsWith('CREATE TABLE "quotation_items"')) {
        statement = statement
            .replaceFirst('"product_id" TEXT NULL', '"product_id" TEXT NOT NULL')
            .replaceFirst(', "custom_notes" TEXT NULL', '');
      }
      if (statement.toUpperCase().startsWith('CREATE TRIGGER')) {
        triggers.add(statement);
      } else {
        historical.execute(statement);
      }
    }
    if (version == 6) {
      historical.execute('DROP TABLE cash_movements');
      historical.execute('DROP INDEX cash_sessions_one_open');
    }
    if (version == 9) {
      final phase22 = jsonDecode(
          File('test/fixtures/schema_22.json').readAsStringSync()) as Map<String, dynamic>;
      for (final sql in (phase22['statements'] as List).cast<String>()) {
        if (sql.startsWith('CREATE TABLE "business_feature_settings"') ||
            sql.startsWith('CREATE TABLE "product_business_configurations"')) {
          historical.execute(sql);
        }
      }
    }
    if (baseVersion == 49 && version < 49) {
      historical.execute('DROP TABLE sales_order_fulfillment_lines');
      historical.execute('DROP TABLE sales_order_fulfillments');
      historical.execute('ALTER TABLE sales_order_lines DROP COLUMN sale_mode');
      historical.execute('ALTER TABLE sales_order_lines DROP COLUMN extra_cents');
      historical.execute('ALTER TABLE stock_reservations DROP COLUMN consumed_milli');
    }
    if (baseVersion == 49 && version < 48) historical.execute('DROP TABLE stock_reservations');
    if (baseVersion == 49 && version < 47) {
      historical.execute('DROP TABLE sales_order_lines');
      historical.execute('DROP TABLE sales_orders');
    }
    if (baseVersion == 49 && version < 46) {
      historical.execute('DROP TABLE supplier_payment_allocations');
      historical.execute('DROP TABLE supplier_payments');
      historical.execute('DROP TABLE supplier_payable_sources');
    }
    if (baseVersion == 49 && version < 45) {
      historical.execute('DROP INDEX customer_credit_payment_reference');
      historical.execute('DROP TABLE customer_credit_payment_allocations');
      historical.execute('ALTER TABLE customer_credit_entries DROP COLUMN reference');
      historical.execute('ALTER TABLE customers DROP COLUMN credit_limit_cents');
    }
    if (baseVersion == 49 && version < 44) {
      historical.execute('DROP TABLE purchase_return_lines');
      historical.execute('DROP TABLE purchase_returns');
      historical.execute('ALTER TABLE inventory_movements DROP COLUMN inventory_layer_id');
    }
    if (baseVersion == 49 && version < 43) {
      historical.execute('DROP INDEX sale_promotion_applications_promotion');
    }
    if (baseVersion == 49 && version < 42) {
      historical.execute('DROP TABLE sale_promotion_applications');
      historical.execute('ALTER TABLE sale_items DROP COLUMN promotion_discount_cents');
      historical.execute('ALTER TABLE sales DROP COLUMN discount_source');
    }
    if (baseVersion == 49 && version < 41) {
      historical.execute('DROP TABLE promotion_product_targets');
      historical.execute('DROP TABLE promotion_category_targets');
      historical.execute('DROP TABLE promotions');
    }
    if (baseVersion == 40) {
      // Reverse schema 40 back to the older checkpoints used by legacy tests.
      historical.execute('DROP TABLE role_permissions');
      historical.execute('DROP TABLE roles');
      if (version < 39) {
        historical.execute('DROP TABLE purchase_order_line_source_links');
        historical.execute('ALTER TABLE purchase_orders DROP COLUMN sent_by');
        historical.execute('ALTER TABLE purchase_orders DROP COLUMN closed_by');
        historical.execute('ALTER TABLE stock_receivings DROP COLUMN finalized_at');
      }
      if (version < 38) {
        historical.execute('DROP INDEX stock_receivings_sequence');
        historical.execute('ALTER TABLE stock_receivings DROP COLUMN sequence');
      }
      if (version < 37) historical.execute('DROP TABLE inventory_health_settings');
    }
    if (baseVersion == 29 && version < 29) {
      // The schema 29 archive differs from 28 only in quotation_items:
      // nullable product_id plus custom_notes. The table DDL was changed above.
    }
    if (baseVersion == 22) {
      if (version < 22) historical.execute('DROP TABLE rma_lifecycle_events');
      if (version < 20) {
        historical.execute('DROP TABLE sale_item_inventory_allocations');
        historical.execute('DROP TABLE inventory_layers');
        historical.execute('ALTER TABLE products DROP COLUMN pricing_policy');
        historical.execute('ALTER TABLE stock_receiving_items DROP COLUMN unit_selling_price_cents');
        historical.execute('ALTER TABLE serial_units DROP COLUMN inventory_layer_id');
      }
      if (version < 19) {
        historical.execute('DROP TABLE sale_item_refunds');
        historical.execute('DROP TABLE inbound_rma_replacements');
        historical.execute('DROP INDEX customer_refund_rma_case');
        historical.execute('ALTER TABLE customer_refund_obligations DROP COLUMN rma_case_id');
      }
      if (version < 18) {
        historical.execute('ALTER TABLE rma_cases DROP COLUMN replacement_serial_unit_id');
      }
      if (version < 17) {
        for (final table in [
          'customer_refund_settlements', 'customer_refund_obligations',
          'serial_sale_links', 'serial_units', 'rma_events', 'rma_cases',
          'quotation_items', 'quotations', 'layaway_payments', 'layaway_serials',
          'layaway_items', 'layaways',
        ]) {
          historical.execute('DROP TABLE $table');
        }
        historical.execute('ALTER TABLE cash_movements DROP COLUMN reference_id');
        historical.execute('ALTER TABLE products DROP COLUMN serial_tracking');
      }
      if (version < 16) {
        for (final column in [
          'store_address', 'store_contact', 'receipt_header', 'receipt_footer'
        ]) {
          historical.execute('ALTER TABLE settings DROP COLUMN $column');
        }
      }
      if (version < 15) {
        historical.execute('ALTER TABLE customer_credit_entries DROP COLUMN payment_method');
      }
      if (version < 14) {
        historical.execute('DROP TABLE stock_receiving_items');
        historical.execute('DROP TABLE stock_receivings');
      }
      if (version < 13) {
        historical.execute('DROP TABLE customer_credit_entries');
        historical.execute('ALTER TABLE sales DROP COLUMN customer_id');
      }
      if (version < 12) {
        historical.execute('DROP INDEX sales_cash_session');
        historical.execute('ALTER TABLE sales DROP COLUMN cash_session_id');
      }
      if (version < 11) {
        for (final table in ['price_history', 'petty_cash_entries', 'suppliers', 'customers']) {
          historical.execute('DROP TABLE $table');
        }
      }
    }

    final sourceTables = source
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'] as String)
        .toSet();
    final targetTables = historical
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'] as String)
        .where((name) => !name.startsWith('sqlite_'));
    historical.execute('ATTACH DATABASE ? AS seed', [seedFile.path]);
    for (final table in targetTables.where(sourceTables.contains)) {
      final targetColumns = historical
          .select('PRAGMA main.table_info("$table")')
          .map((r) => r['name'] as String)
          .toSet();
      final sourceColumns = historical
          .select('PRAGMA seed.table_info("$table")')
          .map((r) => r['name'] as String)
          .toSet();
      final common = targetColumns.intersection(sourceColumns).toList();
      if (common.isEmpty) continue;
      final names = common.map((name) => '"$name"').join(', ');
      historical.execute('INSERT INTO main."$table" ($names) '
          'SELECT $names FROM seed."$table"');
    }
    historical.execute('DETACH DATABASE seed');
    for (final trigger in triggers) {
      if (version < 40 && trigger.contains('users_valid_role_')) {
        continue;
      }
      if (baseVersion == 22 && version < 20 &&
          (trigger.contains('inventory_layer_') ||
           trigger.contains('sale_allocation_'))) {
        continue;
      }
      if (baseVersion == 22 && version < 17 &&
          trigger.contains('receiving_item_') && version < 14) {
        continue;
      }
      historical.execute(trigger);
    }
    historical.execute('PRAGMA user_version = $version');
    if (historical.select('PRAGMA integrity_check').single.values.single != 'ok' ||
        historical.select('PRAGMA foreign_key_check').isNotEmpty) {
      throw StateError('Reconstructed historical fixture is invalid');
    }
  } finally {
    historical.dispose();
    source.dispose();
  }
  final prior = File('${seedFile.path}.seed');
  if (prior.existsSync()) prior.deleteSync();
  seedFile.renameSync(prior.path);
  try {
    historicalFile.renameSync(seedFile.path);
    prior.deleteSync();
  } catch (_) {
    if (!seedFile.existsSync()) prior.renameSync(seedFile.path);
    rethrow;
  }
}
