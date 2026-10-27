import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import '../support/historical_fixture.dart';

void main() {
  test('v44 credit rows survive additive v45 migration', () async {
    final dir = await Directory.systemTemp.createTemp('credit-v44-');
    final file = File('${dir.path}/prior.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    await seed.customStatement(
        "INSERT INTO users (id,name,role) VALUES ('u','Owner','owner')");
    await seed.customStatement(
        "INSERT INTO customers (id,name,created_at) VALUES ('c','Existing',1)");
    await seed.customStatement(
        "INSERT INTO customer_credit_entries (id,customer_id,user_id,amount_cents,kind,created_at) VALUES ('e','c','u',50000,'credit_sale',2)");
    await seed.close();
    await rebuildAsHistoricalFixture(file, 44);
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
      expect(db.schemaVersion, 55);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
