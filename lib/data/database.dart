// lib/data/database.dart
//
// Local SQLite database via drift. This is the source of truth for a single
// device — never the UI, never the cloud. See docs/DATABASE_SCHEMA.md.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

class Products extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get sku => text().nullable()();
  TextColumn get barcode => text().nullable()();
  TextColumn get name => text()();
  IntColumn get priceCents => integer()(); // store money as integer cents
  IntColumn get costCents => integer().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class InventoryMovements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantityDelta => integer()(); // +50 stock in, -2 sale, etc.
  TextColumn get reason => text()(); // 'sale' | 'purchase' | 'adjustment' | 'damaged'
  TextColumn get referenceId => text().nullable()(); // e.g. Sale.id
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class Sales extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get cashierId => text().references(Users, #id)();
  IntColumn get totalCents => integer()();
  TextColumn get status =>
      text().withDefault(const Constant('completed'))(); // completed | voided | refunded
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class SaleItems extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantity => integer()();
  IntColumn get unitPriceCents => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class Payments extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get method => text()(); // cash | gcash | card | other
  IntColumn get amountCents => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class Users extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get name => text()();
  TextColumn get pinHash => text().nullable()(); // cashier
  TextColumn get passwordHash => text().nullable()(); // admin/manager
  TextColumn get role => text()(); // cashier | manager | owner
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

class CashSessions extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get openedByUserId => text().references(Users, #id)();
  IntColumn get startingCashCents => integer()();
  IntColumn get expectedCashCents => integer().nullable()();
  IntColumn get actualCashCents => integer().nullable()();
  DateTimeColumn get openedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get closedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class AuditLogs extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get userId => text().nullable()();
  TextColumn get action => text()(); // 'login' | 'void' | 'refund' | ...
  TextColumn get details => text().nullable()(); // JSON-encoded context
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

@DriftDatabase(tables: [
  Products,
  InventoryMovements,
  Sales,
  SaleItems,
  Payments,
  Users,
  CashSessions,
  AuditLogs,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  // Bump this on every schema change and add a migration step below.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // Example pattern for future migrations:
          // if (from < 2) {
          //   await m.addColumn(products, products.someNewColumn);
          // }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA busy_timeout = 5000');
        },
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'modern_offline_pos.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

String _uuid() {
  // Replace with package:uuid's Uuid().v4() in the real app.
  return DateTime.now().microsecondsSinceEpoch.toString();
}
