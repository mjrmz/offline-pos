import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/data/daos/petty_cash_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test(
      'schema 29 petty cash survives cash activity migration without double counting',
      () async {
    final dir = await Directory.systemTemp.createTemp('cash-v29-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final shift = await CashSessionRepository(db).open(auth.current!, 100000);
      final legacy = await PettyCashRepository(db)
          .record(auth.current!, amountCents: 12000, category: 'Transport');
      await db.close();
      db = null;
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE business_cash_movements');
      raw.execute('DROP TABLE cash_expense_categories');
      raw.execute('PRAGMA user_version = 29');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect((await db.select(db.pettyCashEntries).get()).single.id, legacy.id);
      expect(await CashSessionRepository(db).expected(shift.id), 88000);
      expect(await db.select(db.businessCashMovements).get(), isEmpty);
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });
  test('schema 28 catalog quotation lines survive nullable product migration',
      () async {
    final dir = await Directory.systemTemp.createTemp('quote-v28-custom-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Legacy quote product',
          priceCents: 50000,
          costCents: 10000,
          startingStock: 0);
      final quote = await QuotationRepository(db, pos)
          .create(auth.current!, [QuoteLineRequest(product, 1000)]);
      await db.close();
      db = null;
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('CREATE TABLE quotation_items_v28 ('
          'id TEXT NOT NULL PRIMARY KEY, quotation_id TEXT NOT NULL, '
          'product_id TEXT NOT NULL, product_name_snapshot TEXT NOT NULL, '
          'sku_snapshot TEXT, barcode_snapshot TEXT, '
          'sale_mode TEXT NOT NULL DEFAULT \'ordinary\', '
          'extra_cents INTEGER NOT NULL DEFAULT 0, quantity_milli INTEGER NOT NULL, '
          'unit_snapshot TEXT NOT NULL, unit_price_cents INTEGER NOT NULL, '
          'line_total_cents INTEGER NOT NULL)');
      raw.execute('INSERT INTO quotation_items_v28 SELECT id, quotation_id, '
          'product_id, product_name_snapshot, sku_snapshot, barcode_snapshot, '
          'sale_mode, extra_cents, quantity_milli, unit_snapshot, '
          'unit_price_cents, line_total_cents FROM quotation_items');
      raw.execute('DROP TABLE quotation_items');
      raw.execute('ALTER TABLE quotation_items_v28 RENAME TO quotation_items');
      raw.execute('PRAGMA user_version = 28');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      final restored = (await (db.select(db.quotationItems)
                ..where((item) => item.quotationId.equals(quote.id)))
              .get())
          .single;
      expect(db.schemaVersion, 46);
      expect(restored.productId, product);
      expect(restored.unitPriceCents, 50000);
      expect(restored.customNotes, isNull);
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });
  test('schema 22 upgrades warranty snapshots without changing legacy RMA',
      () async {
    final dir = await Directory.systemTemp.createTemp('rma-v22-warranty-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
          "VALUES ('legacy-rma', 'RMA-OLD', 'customer', 'Fault', 'Unknown', 1000, 'pending', 0)");
      await db.close();
      db = null;
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE serial_warranty_snapshots');
      raw.execute('PRAGMA user_version = 22');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect(db.schemaVersion, 46);
      expect((await db.select(db.rmaCases).get()).single.reference, 'RMA-OLD');
      expect(await db.select(db.serialWarrantySnapshots).get(), isEmpty);
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });

  test('schema 21 RMA survives append-only lifecycle migration', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-v21-rma-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
          "VALUES ('legacy-rma', 'RMA-OLD', 'customer', 'Fault', 'Unknown', 1000, 'pending', 0)");
      await db.close();
      db = null;
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE rma_lifecycle_events');
      raw.execute('PRAGMA user_version = 21');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect((await db.select(db.rmaCases).get()).single.reference, 'RMA-OLD');
      expect(await db.select(db.rmaLifecycleEvents).get(), isEmpty);
      expect(db.schemaVersion, 46);
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });

  test('schema 18 RMA survives item refund and supplier replacement migration',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-v18-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
          "VALUES ('r', 'RMA-18', 'inbound', 'Fault', 'Intact', 1000, 'pending', 0)");
      await db.close();
      db = null;
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE sale_item_refunds');
      raw.execute('DROP TABLE inbound_rma_replacements');
      raw.execute('DROP INDEX customer_refund_rma_case');
      raw.execute(
          'ALTER TABLE customer_refund_obligations DROP COLUMN rma_case_id');
      raw.execute('PRAGMA user_version = 18');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect((await db.select(db.rmaCases).get()).single.reference, 'RMA-18');
      expect(await db.select(db.saleItemRefunds).get(), isEmpty);
      expect(await db.select(db.inboundRmaReplacements).get(), isEmpty);
      expect(db.schemaVersion, 46);
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });

  test('schema 17 RMA records survive schema 18 replacement link migration',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-v17-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
          "VALUES ('r', 'RMA-OLD', 'customer', 'Fault', 'Intact', 1000, 'pending', 0)");
      await db.close();
      db = null;
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute(
          'ALTER TABLE rma_cases DROP COLUMN replacement_serial_unit_id');
      raw.execute('PRAGMA user_version = 17');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      final cases = await db.select(db.rmaCases).get();
      expect(cases.single.reference, 'RMA-OLD');
      expect(cases.single.replacementSerialUnitId, isNull);
      expect(db.schemaVersion, 46);
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });

  test('schema 16 upgrades refund accounting without losing credit entries',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-v16-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO users (id, name, role) VALUES ('u', 'Owner', 'owner')");
      await db.customStatement(
          "INSERT INTO customers (id, name, created_at) VALUES ('c', 'Juan', 0)");
      await db.customStatement(
          "INSERT INTO customer_credit_entries (id, customer_id, user_id, amount_cents, kind, created_at) VALUES ('e', 'c', 'u', 500, 'credit_sale', 0)");
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE layaway_payments');
      raw.execute('DROP TABLE layaway_serials');
      raw.execute('DROP TABLE layaway_items');
      raw.execute('DROP TABLE layaways');
      raw.execute('DROP TABLE quotation_items');
      raw.execute('DROP TABLE quotations');
      raw.execute('DROP TABLE rma_events');
      raw.execute('DROP TABLE rma_cases');
      raw.execute('DROP TABLE serial_sale_links');
      raw.execute('DROP TABLE serial_units');
      raw.execute('DROP TABLE customer_refund_settlements');
      raw.execute('DROP TABLE customer_refund_obligations');
      raw.execute('ALTER TABLE cash_movements DROP COLUMN reference_id');
      raw.execute('ALTER TABLE products DROP COLUMN serial_tracking');
      raw.execute('PRAGMA user_version = 16');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect(db.schemaVersion, 46);
      expect(
          (await db.select(db.customerCreditEntries).get()).single.amountCents,
          500);
      expect(await db.select(db.customerRefundObligations).get(), isEmpty);
      await db.close();
      db = null;
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });
  test('schema 14 adds debt payment method and receipt settings', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-v14-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO users (id, name, role) VALUES ('u', 'Owner', 'owner')");
      await db.customStatement(
          "INSERT INTO customers (id, name, created_at) VALUES ('c', 'Juan', 0)");
      await db.customStatement(
          "INSERT INTO customer_credit_entries (id, customer_id, user_id, amount_cents, kind, created_at) VALUES ('e', 'c', 'u', 50000, 'credit_sale', 0)");
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE layaway_payments');
      raw.execute('DROP TABLE layaway_serials');
      raw.execute('DROP TABLE layaway_items');
      raw.execute('DROP TABLE layaways');
      raw.execute('DROP TABLE quotation_items');
      raw.execute('DROP TABLE quotations');
      raw.execute('DROP TABLE rma_events');
      raw.execute('DROP TABLE rma_cases');
      raw.execute('DROP TABLE serial_sale_links');
      raw.execute('DROP TABLE serial_units');
      raw.execute('DROP TABLE customer_refund_settlements');
      raw.execute('DROP TABLE customer_refund_obligations');
      raw.execute('ALTER TABLE cash_movements DROP COLUMN reference_id');
      raw.execute('ALTER TABLE products DROP COLUMN serial_tracking');
      raw.execute(
          'ALTER TABLE customer_credit_entries DROP COLUMN payment_method');
      for (final column in [
        'store_address',
        'store_contact',
        'receipt_header',
        'receipt_footer'
      ]) {
        raw.execute('ALTER TABLE settings DROP COLUMN $column');
      }
      raw.execute('PRAGMA user_version = 14');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect(
          (await db.select(db.customerCreditEntries).get()).single.amountCents,
          50000);
      expect(
          (await db.select(db.customerCreditEntries).get())
              .single
              .paymentMethod,
          isNull);
      await db.customStatement(
          "INSERT INTO settings (id, store_name) VALUES (1, 'Shop')");
      expect((await db.select(db.settings).get()).single.receiptFooter, '');
      await db.close();
      db = null;
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });

  test('schema 11 backfills sale session from cash movement', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-v11-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO users (id, name, role) VALUES ('u', 'Owner', 'owner')");
      await db.customStatement(
          "INSERT INTO cash_sessions (id, opened_by_user_id, starting_cash_cents, opened_at) VALUES ('c', 'u', 0, 0)");
      await db.customStatement(
          "INSERT INTO sales (id, cashier_id, cash_session_id, total_cents, created_at) VALUES ('s', 'u', 'c', 50000, 0)");
      await db.customStatement(
          "INSERT INTO cash_movements (id, session_id, sale_id, amount_cents, kind, created_at) VALUES ('m', 'c', 's', 50000, 'cash_sale', 0)");
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE layaway_payments');
      raw.execute('DROP TABLE layaway_serials');
      raw.execute('DROP TABLE layaway_items');
      raw.execute('DROP TABLE layaways');
      raw.execute('DROP TABLE quotation_items');
      raw.execute('DROP TABLE quotations');
      raw.execute('DROP TABLE rma_events');
      raw.execute('DROP TABLE rma_cases');
      raw.execute('DROP TABLE serial_sale_links');
      raw.execute('DROP TABLE serial_units');
      raw.execute('DROP TABLE customer_refund_settlements');
      raw.execute('DROP TABLE customer_refund_obligations');
      raw.execute('ALTER TABLE cash_movements DROP COLUMN reference_id');
      raw.execute('ALTER TABLE products DROP COLUMN serial_tracking');
      raw.execute('DROP INDEX IF EXISTS stock_receivings_supplier');
      raw.execute('DROP TABLE stock_receiving_items');
      raw.execute('DROP TABLE stock_receivings');
      raw.execute('DROP INDEX IF EXISTS sales_cash_session');
      raw.execute('DROP INDEX IF EXISTS customer_credit_entries_customer');
      raw.execute('DROP TABLE customer_credit_entries');
      raw.execute('ALTER TABLE sales DROP COLUMN customer_id');
      raw.execute('ALTER TABLE sales DROP COLUMN cash_session_id');
      raw.execute('PRAGMA user_version = 11');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect((await db.select(db.sales).get()).single.cashSessionId, 'c');
      await db.close();
      db = null;
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });

  test('schema 10 upgrades to current schema and preserves Phase 8 data',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-v10-');
    final file = File('${dir.path}/pos.sqlite');
    AppDatabase? db;
    try {
      db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Rice', 5500, 0)");
      await db.customStatement(
          "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p', 2, 2000)");
      await db.customStatement(
          "INSERT INTO product_lots (id, product_id, batch_number, quantity_milli, received_at) VALUES ('b', 'p', 'Lot A', 2000, 0)");
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute('DROP TABLE layaway_payments');
      raw.execute('DROP TABLE layaway_serials');
      raw.execute('DROP TABLE layaway_items');
      raw.execute('DROP TABLE layaways');
      raw.execute('DROP TABLE quotation_items');
      raw.execute('DROP TABLE quotations');
      raw.execute('DROP TABLE rma_events');
      raw.execute('DROP TABLE rma_cases');
      raw.execute('DROP TABLE serial_sale_links');
      raw.execute('DROP TABLE serial_units');
      raw.execute('DROP TABLE customer_refund_settlements');
      raw.execute('DROP TABLE customer_refund_obligations');
      raw.execute('ALTER TABLE cash_movements DROP COLUMN reference_id');
      raw.execute('ALTER TABLE products DROP COLUMN serial_tracking');
      raw.execute('DROP INDEX IF EXISTS stock_receivings_supplier');
      raw.execute('DROP TABLE stock_receiving_items');
      raw.execute('DROP TABLE stock_receivings');
      for (final table in [
        'customers',
        'suppliers',
        'petty_cash_entries',
        'price_history'
      ]) {
        raw.execute('DROP TABLE $table');
      }
      raw.execute('DROP INDEX IF EXISTS customer_credit_entries_customer');
      raw.execute('DROP TABLE customer_credit_entries');
      raw.execute('DROP INDEX IF EXISTS sales_cash_session');
      raw.execute('ALTER TABLE sales DROP COLUMN customer_id');
      raw.execute('ALTER TABLE sales DROP COLUMN cash_session_id');
      raw.execute('PRAGMA user_version = 10');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect(db.schemaVersion, 46);
      expect((await db.select(db.products).get()).single.name, 'Rice');
      expect(
          (await db.select(db.productLots).get()).single.quantityMilli, 2000);
      expect(await db.select(db.customers).get(), isEmpty);
      expect(await db.select(db.priceHistory).get(), isEmpty);
      await db.close();
      db = null;
    } finally {
      await db?.close();
      await dir.delete(recursive: true);
    }
  });
}
