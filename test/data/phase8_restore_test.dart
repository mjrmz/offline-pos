import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/backup/restore_service.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  test('restore replaces later state with backed-up Phase 8 data', () async {
    final dir = await Directory.systemTemp.createTemp('phase8-restore-');
    final file = File('${dir.path}/live.sqlite');
    final backups = Directory('${dir.path}/backups');
    AppDatabase live = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final auth = AuthService(AuthRepository(live));
      final ownerId = await auth.bootstrap(
          'Owner', 'password123', 'Recovery question?', 'Secret answer');
      await auth.login(ownerId, 'password123');
      final featureStore = BusinessFeatureRepository(live);
      await featureStore.setEnabled(
          BusinessFeature.expiryBatchTracking, true, auth.current!);
      await featureStore.setEnabled(
          BusinessFeature.madeToOrderTracking, true, auth.current!);
      final pos = PosRepository(live);
      final itemId = await pos.saveProduct(
          name: 'Batch item',
          priceCents: 1000,
          costCents: 0,
          startingStock: 2,
          batchNumber: 'LOT-1',
          business: const BusinessProduct(batch: true));
      final orderId = await pos.saveProduct(
          name: 'Cake',
          priceCents: 2000,
          costCents: 0,
          business: const BusinessProduct(madeToOrder: true));
      final lot = (await pos.batches(itemId)).single;
      await pos.completeCashSale([
        SaleLineRequest(itemId, 1, batchId: lot.id),
        SaleLineRequest(orderId, 1, mode: 'made_order'),
      ], 3000, ownerId);
      final backup =
          await BackupService(live, backups).create(BackupKind.manual);
      await featureStore.setEnabled(
          BusinessFeature.expiryBatchTracking, false, auth.current!);
      await pos.saveProduct(
          name: 'Later item', priceCents: 500, costCents: 0, startingStock: 1);
      final restorer = RestoreService(file, backups,
          closeDatabase: () => live.close(),
          openDatabase: () async =>
              AppDatabase.forTesting(NativeDatabase(file)));
      live = await restorer.restore(backup);
      expect((await live.select(live.products).get()).length, 2);
      expect(
          (await BusinessFeatureRepository(live)
              .availability())[BusinessFeature.expiryBatchTracking],
          true);
      expect(
          (await live.select(live.inventory).get())
              .where((i) => i.productId == itemId)
              .single
              .quantityMilli,
          1000);
      expect((await live.select(live.productLots).get()).single.quantityMilli,
          1000);
      expect(
          (await live.select(live.madeOrders).get()).single.status, 'ordered');
      expect(
          (await live.select(live.saleItems).get())
              .where((i) => i.productId == itemId)
              .single
              .batchNumber,
          'LOT-1');
    } finally {
      await live.close();
      await dir.delete(recursive: true);
    }
  });
}
