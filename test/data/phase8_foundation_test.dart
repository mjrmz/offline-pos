import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

Future<void> deleteTempDirectory(Directory dir) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  test('independent local flags retain stored product configuration', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId = await auth.bootstrap(
          'Owner', 'password123', 'Recovery question?', 'Secret answer');
      await auth.login(ownerId, 'password123');
      final owner = auth.current!;
      final features = BusinessFeatureRepository(db);
      expect((await features.availability()).values.every((v) => !v), true);
      for (final feature in BusinessFeature.values) {
        await features.setEnabled(feature, true, owner);
      }
      final configs = <BusinessFeature, BusinessProduct>{
        BusinessFeature.weightBasedPricing:
            const BusinessProduct(unit: SaleUnit.kilogram, weight: true),
        BusinessFeature.containerRefillPricing: const BusinessProduct(
            unit: SaleUnit.bottle, refill: true, containerPriceCents: 1200),
        BusinessFeature.tankDepositExchange:
            const BusinessProduct(tank: true, depositCents: 50000),
        BusinessFeature.expiryBatchTracking: const BusinessProduct(batch: true),
        BusinessFeature.unitOfMeasureVariety:
            const BusinessProduct(unit: SaleUnit.meter),
        BusinessFeature.madeToOrderTracking:
            const BusinessProduct(madeToOrder: true),
      };
      final ids = <BusinessFeature, String>{};
      final saved = <BusinessFeature, Map<String, Object?>>{};
      for (final feature in BusinessFeature.values) {
        ids[feature] = await PosRepository(db).saveProduct(
            name: feature.name,
            priceCents: 5000,
            costCents: 0,
            business: configs[feature]);
        saved[feature] =
            (await features.productConfiguration(ids[feature]!, feature))!;
      }
      expect((await features.availability()).values.every((v) => v), true);
      for (final feature in BusinessFeature.values) {
        await features.setEnabled(feature, false, owner);
        expect(await features.productConfiguration(ids[feature]!, feature),
            saved[feature]);
        await features.setEnabled(feature, true, owner);
        expect(await features.productConfiguration(ids[feature]!, feature),
            saved[feature]);
      }
      expect(
          (await db.select(db.auditLogs).get())
              .where((a) => a.action.startsWith('business_feature.'))
              .length,
          18);
    } finally {
      await db.close();
    }
  });

  test('version 8 migration retains existing POS rows and defaults flags off',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase8-migration-');
    final file = File('${dir.path}/pos.sqlite');
    try {
      var db = AppDatabase.forTesting(NativeDatabase(file));
      await db.customStatement(
          "INSERT INTO users (id, name, role) VALUES ('u', 'Owner', 'owner')");
      await db.customStatement(
          "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Existing', 125, 0)");
      await db.customStatement(
          "INSERT INTO inventory (product_id, quantity) VALUES ('p', 7)");
      await db.customStatement(
          "INSERT INTO sales (id, cashier_id, total_cents, created_at) VALUES ('s', 'u', 125, 0)");
      await db.customStatement(
          "INSERT INTO sale_items (id, sale_id, product_id, product_name, quantity, unit_price_cents, line_total_cents) VALUES ('i', 's', 'p', 'Existing', 1, 125, 125)");
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
      raw.execute('DROP TABLE business_feature_settings');
      raw.execute('DROP TABLE product_business_configurations');
      raw.execute('PRAGMA user_version = 8');
      raw.dispose();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect((await db.select(db.products).get()).single.name, 'Existing');
      expect((await db.select(db.inventory).get()).single.quantity, 7);
      expect((await db.select(db.sales).get()).single.totalCents, 125);
      expect(
          (await db.select(db.saleItems).get()).single.productName, 'Existing');
      expect(
          (await BusinessFeatureRepository(db).availability())
              .values
              .every((v) => !v),
          true);
      await db.close();
    } finally {
      await deleteTempDirectory(dir);
    }
  });

  test('local feature rows survive restart and SQLite backup', () async {
    final dir = await Directory.systemTemp.createTemp('phase8-backup-');
    final file = File('${dir.path}/pos.sqlite');
    try {
      var db = AppDatabase.forTesting(NativeDatabase(file));
      final auth = AuthService(AuthRepository(db));
      final ownerId = await auth.bootstrap(
          'Owner', 'password123', 'Recovery question?', 'Secret answer');
      await auth.login(ownerId, 'password123');
      final features = BusinessFeatureRepository(db);
      await features.setEnabled(
          BusinessFeature.weightBasedPricing, true, auth.current!);
      final productId = await PosRepository(db).saveProduct(
          name: 'Rice',
          priceCents: 5000,
          costCents: 0,
          business:
              const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
      final expected = await features.productConfiguration(
          productId, BusinessFeature.weightBasedPricing);
      final backup = await BackupService(db, Directory('${dir.path}/backups'))
          .create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      expect(
          (await BusinessFeatureRepository(db)
              .availability())[BusinessFeature.weightBasedPricing],
          true);
      expect(
          await BusinessFeatureRepository(db).productConfiguration(
              productId, BusinessFeature.weightBasedPricing),
          expected);
      await db.close();
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      expect(
          (await BusinessFeatureRepository(restored)
              .availability())[BusinessFeature.weightBasedPricing],
          true);
      expect(
          await BusinessFeatureRepository(restored).productConfiguration(
              productId, BusinessFeature.weightBasedPricing),
          expected);
      await restored.close();
    } finally {
      await deleteTempDirectory(dir);
    }
  });

  test('cashier and manager cannot change business availability', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      await db.customStatement(
          "INSERT INTO users (id, name, role) VALUES ('c', 'Cashier', 'cashier'), ('m', 'Manager', 'manager')");
      final features = BusinessFeatureRepository(db);
      for (final actor in [
        const ActiveUser('c', 'Cashier', UserRole.cashier),
        const ActiveUser('m', 'Manager', UserRole.manager),
      ]) {
        await expectLater(
            features.setEnabled(
                BusinessFeature.weightBasedPricing, true, actor),
            throwsStateError);
      }
      expect(
          (await features.availability())[BusinessFeature.weightBasedPricing],
          false);
      expect(await db.select(db.auditLogs).get(), isEmpty);
    } finally {
      await db.close();
    }
  });
}
