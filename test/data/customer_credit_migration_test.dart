import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('v44 credit rows survive additive v45 migration', () async {
    final dir = await Directory.systemTemp.createTemp('credit-v44-');
    final file = File('${dir.path}/prior.sqlite');
    final old = sqlite.sqlite3.open(file.path);
    try {
      old.execute('PRAGMA user_version = 44');
      old.execute(
          'CREATE TABLE customers (id TEXT PRIMARY KEY, name TEXT NOT NULL, phone TEXT, address TEXT, notes TEXT, is_active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL)');
      old.execute(
          'CREATE TABLE customer_credit_entries (id TEXT PRIMARY KEY, customer_id TEXT NOT NULL, sale_id TEXT, user_id TEXT NOT NULL, amount_cents INTEGER NOT NULL, kind TEXT NOT NULL, payment_method TEXT, note TEXT, created_at INTEGER NOT NULL)');
      old.execute(
          "INSERT INTO customers (id,name,created_at) VALUES ('c','Existing',1)");
      old.execute(
          "INSERT INTO customer_credit_entries (id,customer_id,user_id,amount_cents,kind,created_at) VALUES ('e','c','u',50000,'credit_sale',2)");
    } finally {
      old.dispose();
    }
    final db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final customer = await db
          .customSelect("SELECT credit_limit_cents FROM customers WHERE id='c'")
          .getSingle();
      expect(customer.read<int?>('credit_limit_cents'), isNull);
      final entry = await db
          .customSelect(
              "SELECT amount_cents, reference FROM customer_credit_entries WHERE id='e'")
          .getSingle();
      expect(entry.read<int>('amount_cents'), 50000);
      expect(entry.read<String?>('reference'), isNull);
      final tables = await db
          .customSelect(
              "SELECT name FROM sqlite_master WHERE name='customer_credit_payment_allocations'")
          .get();
      expect(tables, hasLength(1));
      expect(db.schemaVersion, 46);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
