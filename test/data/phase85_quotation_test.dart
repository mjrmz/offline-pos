import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/features/contacts/documents/quotation_pdf.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'custom quotation remains commercial until explicitly linked and received',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final repo = QuotationRepository(db, pos);
      final quote = await repo.create(actor, [
        const QuoteLineRequest.custom('ASUS TUF B850-PLUS WIFI', 1000,
            unit: 'pcs',
            unitPriceCents: 1250000,
            customNotes: 'Special order · Estimated availability 3–5 days')
      ]);
      var line = (await repo.items(quote.id)).single;
      expect(line.productId, isNull);
      expect(line.lineTotalCents, 1250000);
      expect(line.customNotes, contains('Special order'));
      expect(await db.select(db.products).get(), isEmpty);
      expect(await db.select(db.inventory).get(), isEmpty);
      expect(await db.select(db.inventoryLayers).get(), isEmpty);
      expect(await db.select(db.inventoryMovements).get(), isEmpty);
      expect(await db.select(db.sales).get(), isEmpty);
      expect(
          ascii.decode(
              (await QuotationPdf(db).render(quote.id)).take(5).toList()),
          '%PDF-');
      await expectLater(
          repo.convertCash(actor, quote.id, 1250000), throwsStateError);
      final productId = await pos.saveProduct(
          name: 'ASUS TUF GAMING B850-PLUS WIFI',
          priceCents: 1290000,
          costCents: 900000,
          startingStock: 0);
      await expectLater(
          repo.requestSourcing(actor, quote.id, productId), throwsStateError);
      await repo.linkCustomItem(actor, quote.id, line.id, productId);
      line = (await repo.items(quote.id)).single;
      expect(line.productId, productId);
      expect(line.productNameSnapshot, 'ASUS TUF B850-PLUS WIFI');
      expect(line.unitPriceCents, 1250000);
      expect(await pos.stockMilli(productId), 0);
      final requirement =
          await repo.requestSourcing(actor, quote.id, productId);
      expect(requirement.quantityToSourceMilli, 1000);
      final supplier = await DirectoryRepository(db)
          .saveSupplier(actor, name: 'Parts Supplier');
      await StockReceivingRepository(db).receive(
          actor, supplier.id, [ReceivingLineRequest(productId, 1000, 950000)]);
      final sale = await repo.convertCash(actor, quote.id, 1250000);
      expect(sale.totalCents, 1250000);
      expect(
          (await db.select(db.saleItems).get()).single.unitPriceCents, 1250000);
      expect((await repo.history()).single.status, 'converted');
      await expectLater(
          repo.linkCustomItem(actor, quote.id, line.id, productId),
          throwsStateError);
    } finally {
      await db.close();
    }
  });

  test('open custom line can be edited and removed without creating products',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final repo = QuotationRepository(db, pos);
      final quote = await repo.create(actor, [
        const QuoteLineRequest.custom('Unspecified board', 1000,
            unit: 'pcs', unitPriceCents: 100000)
      ]);
      await repo.update(actor, quote.id, [
        const QuoteLineRequest.custom('ASUS TUF B850-PLUS WIFI', 2000,
            unit: 'pcs',
            unitPriceCents: 1250000,
            customNotes: 'Revised specification')
      ]);
      expect((await repo.items(quote.id)).single.lineTotalCents, 2500000);
      expect((await repo.items(quote.id)).single.customNotes,
          'Revised specification');
      final catalogId = await pos.saveProduct(
          name: 'Mouse', priceCents: 45000, costCents: 20000, startingStock: 0);
      await repo.update(actor, quote.id, [QuoteLineRequest(catalogId, 1000)]);
      expect((await repo.items(quote.id)).single.productId, catalogId);
      expect((await db.select(db.products).get()).length, 1);
      await repo.cancel(actor, quote.id);
      await expectLater(
          repo.update(actor, quote.id, [
            const QuoteLineRequest.custom('New', 1000,
                unit: 'pcs', unitPriceCents: 100)
          ]),
          throwsStateError);
    } finally {
      await db.close();
    }
  });
  test(
      'zero-stock quote records supplier demand without inventory, then converts after receiving',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Order-only mouse',
          priceCents: 45000,
          costCents: 20000,
          startingStock: 0);
      final repo = QuotationRepository(db, pos);
      final quote = await repo.create(actor, [QuoteLineRequest(product, 1000)]);
      final pdf = await QuotationPdf(db).render(quote.id);
      expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
      expect(await pos.stockMilli(product), 0);
      expect(await db.select(db.inventoryLayers).get(), isEmpty);
      expect(await db.select(db.sales).get(), isEmpty);
      await expectLater(
          repo.convertCash(actor, quote.id, 45000), throwsStateError);
      final requirement = await repo.requestSourcing(actor, quote.id, product);
      expect(requirement.quantityToSourceMilli, 1000);
      expect((await repo.requestSourcing(actor, quote.id, product)).id,
          requirement.id);
      expect(await pos.stockMilli(product), 0);
      expect(await db.select(db.inventoryLayers).get(), isEmpty);
      final supplier =
          await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier');
      await StockReceivingRepository(db).receive(
          actor, supplier.id, [ReceivingLineRequest(product, 1000, 24000)]);
      expect(await pos.stockMilli(product), 1000);
      await pos.saveProduct(
          id: product,
          name: 'Order-only mouse',
          priceCents: 47000,
          costCents: 24000);
      final sale = await repo.convertCash(actor, quote.id, 45000);
      expect(sale.totalCents, 45000);
      expect((await repo.history()).single.status, 'converted');
    } finally {
      await db.close();
    }
  });
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
      expect(quote.customerNameSnapshot, 'Juan');
      expect(await pos.stockMilli(product), 2000);
      expect(await db.select(db.sales).get(), isEmpty);
      expect(await db.select(db.payments).get(), isEmpty);
      expect(await db.select(db.cashMovements).get(), isEmpty);
      await pos.saveProduct(
          id: product, name: 'Cable', priceCents: 60000, costCents: 10000);
      await expectLater(
          quoteRepo.convertCash(actor, quote.id, 100), throwsStateError);
      expect((await quoteRepo.history()).single.status, 'open');
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

  test('tank and refill options are quoted and survive later price changes',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      final features = BusinessFeatureRepository(db);
      for (final feature in BusinessFeature.values) {
        await features.setEnabled(feature, true, actor);
      }
      final pos = PosRepository(db);
      final tank = await pos.saveProduct(
          name: 'LPG',
          priceCents: 100000,
          costCents: 0,
          startingStock: 2,
          business: const BusinessProduct(tank: true, depositCents: 50000));
      final water = await pos.saveProduct(
          name: 'Water',
          priceCents: 3000,
          costCents: 0,
          startingStock: 2,
          business:
              const BusinessProduct(refill: true, containerPriceCents: 2000));
      final repo = QuotationRepository(db, pos);
      await expectLater(
          repo.create(actor, [QuoteLineRequest(tank, 1000)]), throwsStateError);
      final quote = await repo.create(actor, [
        QuoteLineRequest(tank, 1000, mode: 'deposit'),
        QuoteLineRequest(water, 1000, mode: 'container'),
      ]);
      expect(quote.reference, matches(RegExp(r'^Q-\d{4}-\d{6}$')));
      final lines = await repo.items(quote.id);
      expect(lines.map((line) => line.saleMode),
          containsAll(['deposit', 'container']));
      expect(lines.map((line) => line.lineTotalCents),
          containsAll([150000, 5000]));
      expect(await pos.stockMilli(tank), 2000);
      expect(await pos.stockMilli(water), 2000);
      final pdf = await QuotationPdf(db).render(quote.id);
      expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
      expect(QuotationPdf.safeFilename(quote.reference, 'Juan / Dela Cruz'),
          'Quotation-${quote.reference}-Juan-Dela-Cruz.pdf');
      await pos.saveProduct(
          id: tank,
          name: 'LPG',
          priceCents: 120000,
          costCents: 0,
          business: const BusinessProduct(tank: true, depositCents: 60000));
      final sale = await repo.convertCash(actor, quote.id, 155000);
      expect(sale.totalCents, 155000);
      expect((await db.select(db.saleItems).get()).map((i) => i.saleMode),
          containsAll(['deposit', 'container']));
      expect((await repo.history()).single.convertedSaleId, sale.saleId);
      final second = await repo
          .create(actor, [QuoteLineRequest(water, 1000, mode: 'refill')]);
      await repo.cancel(actor, second.id);
      expect((await repo.history()).firstWhere((q) => q.id == second.id).status,
          'cancelled');
      await expectLater(
          repo.convertCash(actor, second.id, 3000), throwsStateError);
    } finally {
      await db.close();
    }
  });

  test('serialized quotation allocates exact units only at sale', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Motherboard',
          priceCents: 350000,
          costCents: 200000,
          serialTracking: true,
          startingStock: 2,
          openingSerials: ['SER-1', 'SER-2']);
      final repo = QuotationRepository(db, pos);
      final quote = await repo.create(actor, [QuoteLineRequest(product, 2000)]);
      final serials = await pos.availableSerials(product);
      expect(serials.length, 2);
      expect(await pos.stockMilli(product), 2000);
      await expectLater(
          repo.convertCash(actor, quote.id, 700000, serialIds: {
            product: [serials.first.id]
          }),
          throwsStateError);
      expect((await repo.history()).single.status, 'open');
      expect(await pos.stockMilli(product), 2000);
      final sale = await repo.convertCash(actor, quote.id, 700000,
          serialIds: {product: serials.map((s) => s.id).toList()});
      expect(sale.totalCents, 700000);
      expect(await pos.availableSerials(product), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('batch and fractional weight quotes leave inventory untouched',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      final features = BusinessFeatureRepository(db);
      for (final feature in BusinessFeature.values) {
        await features.setEnabled(feature, true, actor);
      }
      final pos = PosRepository(db);
      final medicine = await pos.saveProduct(
          name: 'Medicine',
          priceCents: 10000,
          costCents: 5000,
          startingStock: 3,
          business: const BusinessProduct(batch: true),
          openingBatches: const [OpeningBatch(3000, 'LOT-1', null)]);
      final rice = await pos.saveProduct(
          name: 'Rice',
          priceCents: 5000,
          costCents: 2000,
          startingStockMilli: 5000,
          business:
              const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
      final repo = QuotationRepository(db, pos);
      final quote = await repo.create(actor,
          [QuoteLineRequest(medicine, 1000), QuoteLineRequest(rice, 2500)]);
      expect((await repo.items(quote.id)).map((line) => line.quantityMilli),
          containsAll([1000, 2500]));
      expect(await pos.stockMilli(medicine), 3000);
      expect(await pos.stockMilli(rice), 5000);
      expect((await pos.batches(medicine)).single.quantityMilli, 3000);
      expect(await db.select(db.sales).get(), isEmpty);
      final batch = (await pos.batches(medicine)).single;
      final sale = await repo
          .convertCash(actor, quote.id, 22500, batchIds: {medicine: batch.id});
      expect(sale.totalCents, 22500);
      expect(await pos.stockMilli(medicine), 2000);
      expect(await pos.stockMilli(rice), 2500);
    } finally {
      await db.close();
    }
  });
  test('editing an open quote preserves its saved unit price', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Cable', priceCents: 50000, costCents: 10000, startingStock: 3);
      final repo = QuotationRepository(db, pos);
      final quote = await repo.create(actor, [QuoteLineRequest(product, 1000)]);
      await pos.saveProduct(
          id: product, name: 'Cable', priceCents: 60000, costCents: 10000);
      await repo.update(actor, quote.id, [QuoteLineRequest(product, 2000)],
          notes: 'Revised quantity');
      final item = (await repo.items(quote.id)).single;
      expect(item.unitPriceCents, 50000);
      expect(item.lineTotalCents, 100000);
      expect(await pos.stockMilli(product), 3000);
      final sale = await repo.convertCash(actor, quote.id, 100000);
      expect(sale.totalCents, 100000);
      await expectLater(
          repo.update(actor, quote.id, [QuoteLineRequest(product, 1000)]),
          throwsStateError);
    } finally {
      await db.close();
    }
  });
}
