import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../support/historical_fixture.dart';

void main() {
  test('reconstructed schema 40 matches the genuine schema 40 archive',
      () async {
    final dir = await Directory.systemTemp.createTemp('schema40-fixture-');
    try {
      final file = File('${dir.path}/seed.sqlite');
      final db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement("INSERT INTO categories (id, name) VALUES ('c', 'Test')");
      await db.customStatement("INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Test', 100, 1)");
      await db.close();
      await rebuildAsHistoricalFixture(file, 40);
      final actual = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
      final referenceFile = File('${dir.path}/reference.sqlite');
      final reference = sqlite.sqlite3.open(referenceFile.path);
      try {
        final archive = jsonDecode(
            File('test/fixtures/schema_40.json').readAsStringSync()) as Map<String, dynamic>;
        for (final statement in (archive['statements'] as List).cast<String>()) {
          reference.execute(statement);
        }
        Set<String> objects(sqlite.Database db) => db
            .select("SELECT type || ':' || name AS item FROM sqlite_master "
                "WHERE name NOT LIKE 'sqlite_%'")
            .map((r) => r['item'] as String)
            .toSet();
        expect(objects(actual), objects(reference));
        for (final table in actual.select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")) {
          final name = table['name'] as String;
          List<String> columns(sqlite.Database db) => db
              .select('PRAGMA table_info("$name")')
              .map((r) => '${r['name']}:${r['type']}:${r['notnull']}:${r['dflt_value']}:${r['pk']}')
              .toList();
          expect(columns(actual), columns(reference), reason: name);
        }
        expect(actual.select('PRAGMA user_version').single.values.single, 40);
        expect(actual.select('SELECT COUNT(*) AS n FROM products').single['n'], 1);
      } finally {
        actual.dispose();
        reference.dispose();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  for (final version in [37, 39]) {
    test('reconstructed schema $version matches its genuine archive', () async {
      final dir = await Directory.systemTemp.createTemp('schema$version-fixture-');
      try {
        final file = File('${dir.path}/seed.sqlite');
        final db = AppDatabase.forTesting(NativeDatabase(file));
        await db.customStatement("INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Test', 100, 1)");
        await db.close();
        await rebuildAsHistoricalFixture(file, version);
        final actual = sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
        final reference = sqlite.sqlite3.open('${dir.path}/reference.sqlite');
        try {
          final archive = jsonDecode(File('test/fixtures/schema_$version.json')
              .readAsStringSync()) as Map<String, dynamic>;
          for (final sql in (archive['statements'] as List).cast<String>()) {
            reference.execute(sql);
          }
          List<String> objects(sqlite.Database db) => db
              .select("SELECT type || ':' || name AS item FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY item")
              .map((r) => r['item'] as String)
              .toList();
          expect(objects(actual), objects(reference));
          for (final table in actual.select("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")) {
            final name = table['name'] as String;
            List<String> columns(sqlite.Database db) => db
                .select('PRAGMA table_info("$name")')
                .map((r) => '${r['name']}:${r['type']}:${r['notnull']}:${r['dflt_value']}:${r['pk']}')
                .toList();
            expect(columns(actual), columns(reference), reason: name);
          }
        } finally {
          actual.dispose();
          reference.dispose();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  }

  for (final version in [6, 8, 9, 10, 11, 14, 16, 17, 18, 19, 20, 21, 22, 28, 29]) {
    test('schema $version fixture keeps a product through migration', () async {
      final dir = await Directory.systemTemp.createTemp('schema$version-fixture-');
      try {
        final file = File('${dir.path}/seed.sqlite');
        var db = AppDatabase.forTesting(NativeDatabase(file));
        await db.customStatement("INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Test', 100, 1)");
        await db.close();
        await rebuildAsHistoricalFixture(file, version);
        db = AppDatabase.forTesting(NativeDatabase(file));
        try {
          expect(db.schemaVersion, 55);
          expect((await db.select(db.products).get()).single.name, 'Test');
          if (version == 22) {
            final columns = await db.customSelect('PRAGMA table_info(serial_units)').get();
            final receiving = columns.firstWhere(
                (row) => row.read<String>('name') == 'receiving_item_id');
            expect(receiving.read<int>('notnull'), 0,
                reason: 'Migrated schema must allow opening serials');
          }
        } finally {
          await db.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  }
}
