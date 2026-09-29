// lib/data/database.dart
//
// Local SQLite database via drift. This is the source of truth for a single
// device — never the UI, never the cloud. See docs/DATABASE_SCHEMA.md.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

part 'database.g.dart';

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

class Products extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get sku => text().nullable()();
  TextColumn get barcode => text().nullable()();
  TextColumn get categoryId => text().nullable().references(Categories, #id)();
  TextColumn get name => text()();
  IntColumn get priceCents => integer()(); // store money as integer cents
  IntColumn get costCents => integer().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get lowStockThreshold => integer().withDefault(const Constant(5))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class Categories extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get name => text()();
  TextColumn get parentCategoryId =>
      text().nullable().references(Categories, #id)();
  @override
  Set<Column> get primaryKey => {id};
}

class Inventory extends Table {
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantity => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {productId};
}

class InventoryMovements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantityDelta => integer()(); // +50 stock in, -2 sale, etc.
  TextColumn get reason =>
      text()(); // 'sale' | 'purchase' | 'adjustment' | 'damaged'
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
  TextColumn get status => text().withDefault(
      const Constant('completed'))(); // completed | voided | refunded
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class SaleItems extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get productName => text().withDefault(const Constant(''))();
  IntColumn get quantity => integer()();
  IntColumn get unitPriceCents => integer()();
  IntColumn get lineTotalCents => integer().withDefault(const Constant(0))();

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
  IntColumn get failedAttempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lockedUntil => dateTime().nullable()();
  TextColumn get recoveryQuestion => text().nullable()();
  TextColumn get recoveryAnswerHash => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SaleReversals extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleId => text().references(Sales, #id).unique()();
  TextColumn get actorId => text().references(Users, #id)();
  TextColumn get kind => text()(); // void | refund
  IntColumn get amountCents => integer()();
  BoolColumn get stockRestored => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
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

class CashMovements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get sessionId => text().references(CashSessions, #id)();
  TextColumn get saleId => text().nullable().unique().references(Sales, #id)();
  IntColumn get amountCents => integer()();
  TextColumn get kind =>
      text()(); // cash_sale; later kinds require actual cash evidence
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
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

class Settings extends Table {
  IntColumn get id => integer()();
  TextColumn get storeName => text().withDefault(const Constant(''))();
  BoolColumn get printerEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get printerTransport =>
      text().withDefault(const Constant('lan'))();
  TextColumn get printerHost => text().withDefault(const Constant(''))();
  IntColumn get printerPort => integer().withDefault(const Constant(9100))();
  TextColumn get printerDeviceId => text().withDefault(const Constant(''))();
  TextColumn get printerDeviceName => text().withDefault(const Constant(''))();
  IntColumn get printerWidthMm => integer().withDefault(const Constant(80))();
  BoolColumn get drawerEnabled =>
      boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

@DriftDatabase(tables: [
  Products,
  Categories,
  Inventory,
  InventoryMovements,
  Sales,
  SaleReversals,
  SaleItems,
  Payments,
  Users,
  CashSessions,
  CashMovements,
  AuditLogs,
  Settings,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);
  static Future<File> databaseFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'modern_offline_pos.sqlite'));
  }

  // Bump this on every schema change and add a migration step below.
  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement('CREATE UNIQUE INDEX cash_sessions_one_open '
              'ON cash_sessions ((1)) WHERE closed_at IS NULL');
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(categories);
            await m.addColumn(products, products.categoryId);
            await m.createTable(inventory);
            await m.addColumn(saleItems, saleItems.lineTotalCents);
            // Existing Phase 1 movement rows are the only prior stock source.
            await customStatement(
                'INSERT INTO inventory (product_id, quantity) '
                'SELECT product_id, SUM(quantity_delta) FROM inventory_movements '
                'GROUP BY product_id');
            await customStatement('UPDATE sale_items SET line_total_cents = '
                'quantity * unit_price_cents');
          }
          if (from < 3) {
            await m.addColumn(products, products.lowStockThreshold);
            await m.addColumn(users, users.failedAttempts);
            await m.addColumn(users, users.lockedUntil);
            await m.addColumn(users, users.recoveryQuestion);
            await m.addColumn(users, users.recoveryAnswerHash);
            await m.createTable(saleReversals);
          }
          if (from == 3) {
            await m.addColumn(saleReversals, saleReversals.stockRestored);
          }
          if (from < 5) {
            await m.addColumn(saleItems, saleItems.productName);
            await customStatement('UPDATE sale_items SET product_name = '
                'COALESCE((SELECT name FROM products WHERE products.id = sale_items.product_id), \'Unknown product\')');
          }
          if (from < 6) {
            await m.createTable(settings);
          }
          if (from < 7) {
            await m.createTable(cashMovements);
            final sessionsTable = await customSelect(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cash_sessions'")
                .get();
            if (sessionsTable.isNotEmpty) {
              await customStatement(
                  'CREATE UNIQUE INDEX cash_sessions_one_open '
                  'ON cash_sessions ((1)) WHERE closed_at IS NULL');
            }
          }
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
    final file = await AppDatabase.databaseFile();
    return NativeDatabase.createInBackground(file);
  });
}

String _uuid() {
  return const Uuid().v4();
}
