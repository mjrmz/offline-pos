import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';

void main() {
  test('quote has no accounting effect and converts once at quoted price',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-quote-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final customer =
          await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
      final product = await pos.saveProduct(
          name: 'Cable', priceCents: 50000, costCents: 10000, startingStock: 2);
      final quoteRepo = QuotationRepository(db, pos);
      final quote = await quoteRepo.create(
          actor, [QuoteLineRequest(product, 1000)],
          customerId: customer.id);
      expect(await pos.stockMilli(product), 2000);
      expect(await db.select(db.sales).get(), isEmpty);
      expect(await db.select(db.payments).get(), isEmpty);
      expect(await db.select(db.cashMovements).get(), isEmpty);
      await pos.saveProduct(
          id: product, name: 'Cable', priceCents: 60000, costCents: 10000);
      final sale = await quoteRepo.convertCash(actor, quote.id, 50000);
      expect(sale.totalCents, 50000);
      expect(
          (await db.select(db.saleItems).get()).single.unitPriceCents, 50000);
      expect((await db.select(db.sales).get()).single.customerId, customer.id);
      expect((await quoteRepo.history()).single.convertedSaleId, sale.saleId);
      await expectLater(quoteRepo.convertCash(actor, quote.id, 50000),
          throwsA(isA<StateError>()));
      expect(await pos.stockMilli(product), 1000);
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect((await restored.select(restored.quotations).get()).single.status,
            'converted');
        expect(
            (await restored.select(restored.quotationItems).get()).length, 1);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
