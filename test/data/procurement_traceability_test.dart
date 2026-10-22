import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/supplier_procurement_repository.dart';
import 'package:modern_offline_pos/features/inventory/documents/purchase_order_pdf.dart';
import 'package:modern_offline_pos/features/inventory/documents/receiving_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('quotation source survives notes and draft edits; copy is independent',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Part A', priceCents: 80000, costCents: 50000, startingStock: 0);
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier A');
    final quoteRepo = QuotationRepository(db, pos);
    final quote =
        await quoteRepo.create(actor, [QuoteLineRequest(productId, 10000)]);
    final po = PurchaseOrderRepository(db);
    final order = await po.create(actor, supplier.id, DateTime.now(),
        [PurchaseOrderLineInput(productId, 10000, 50000)],
        notes: 'For quotation ${quote.reference}',
        sourceQuotationReference: quote.reference,
        sourceQuantitiesMilli: {productId: 10000});
    var sources = await po.sourceLinksForOrder(order.id);
    expect(sources.single.quotationId, quote.id);
    expect(sources.single.plannedQtyMilli, 10000);
    final originalQuoteLineId = sources.single.quotationLineId;
    await quoteRepo.update(actor, quote.id,
        [QuoteLineRequest(productId, 12000)]);
    expect((await po.sourceLinksForOrder(order.id)).single.quotationLineId,
        originalQuoteLineId);
    await po.updateDraft(actor, order.id, supplier.id, DateTime.now(),
        [PurchaseOrderLineInput(productId, 10000, 50000)],
        notes: 'Edited');
    sources = await po.sourceLinksForOrder(order.id);
    expect(sources.single.quotationId, quote.id);
    expect(sources.single.quotationLineId, originalQuoteLineId);
    final copy = await po.duplicate(actor, order.id);
    expect(await po.sourceLinksForOrder(copy.id), isEmpty);
    final legacyNote = await po.create(actor, supplier.id, DateTime.now(),
        [PurchaseOrderLineInput(productId, 1000, 50000)],
        notes: 'For quotation ${quote.reference}');
    expect(await po.sourceLinksForOrder(legacyNote.id), isEmpty);
    await po.markSent(actor, order.id);
    final line = (await po.detail(order.id)).lines.single;
    final receiving = StockReceivingRepository(db);
    await receiving.receive(
        actor,
        supplier.id,
        [
          ReceivingLineRequest(productId, 4000, 52000,
              purchaseOrderLineId: line.id)
        ],
        purchaseOrderId: order.id,
        receivedAt: DateTime.now());
    final progress = await po.detail(order.id);
    expect(progress.receivedTotal, 4000);
    expect(progress.remainingTotal, 6000);
    expect(
        PurchaseOrderRepository.receivedForSource(
            sources.single, sources, progress.received[line.id]!),
        4000);
    expect((await po.activity(order.id)).map((e) => e.title),
        contains('Partial delivery'));
    expect(await pos.stockMilli(productId), 4000);
    expect((await pos.layersForProduct(productId)).single.unitCostCents, 52000);
    final bytes = await PurchaseOrderPdf(db).render(order.id);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final grn = await ReceivingPdf(db).render(progress.receivings.single.id);
    expect(String.fromCharCodes(grn.take(5)), '%PDF-');
  });

  test('source links and finalization actor survive backup', () async {
    final dir = await Directory.systemTemp.createTemp('procurement-backup-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final actor = auth.current!;
      final pos = PosRepository(db);
      final productId = await pos.saveProduct(
          name: 'Part A',
          priceCents: 80000,
          costCents: 50000,
          startingStock: 0);
      final supplier =
          await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier A');
      final quote = await QuotationRepository(db, pos)
          .create(actor, [QuoteLineRequest(productId, 1000)]);
      final po = PurchaseOrderRepository(db);
      final order = await po.create(actor, supplier.id, DateTime.now(),
          [PurchaseOrderLineInput(productId, 1000, 50000)],
          sourceQuotationReference: quote.reference,
          sourceQuantitiesMilli: {productId: 1000},
          markSent: true);
      final line = (await po.detail(order.id)).lines.single;
      final receipt = await StockReceivingRepository(db).receive(
          actor,
          supplier.id,
          [
            ReceivingLineRequest(productId, 1000, 51000,
                purchaseOrderLineId: line.id)
          ],
          purchaseOrderId: order.id);
      expect(receipt.finalizedAt, isNotNull);
      await po.close(actor, order.id);
      final closed = await po.detail(order.id);
      expect(closed.order.sentBy, actor.id);
      expect(closed.order.closedBy, actor.id);
      expect((await po.activity(order.id)).map((e) => e.title),
          contains('PO closed'));
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      expect(BackupService.verify(backup.file), 40);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect(
            (await PurchaseOrderRepository(restored)
                    .sourceLinksForOrder(order.id))
                .single
                .quotationId,
            quote.id);
        expect(
            (await PurchaseOrderRepository(restored).detail(order.id))
                .receivings
                .single
                .finalizedAt,
            isNotNull);
        expect((await PurchaseOrderRepository(restored).detail(order.id))
            .order.closedBy, actor.id);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('supplier performance uses calendar days and excludes drafts', () async {
    expect(
        SupplierProcurementRepository.calendarDays(
            DateTime(2026, 10, 1, 23), DateTime(2026, 10, 5, 1)),
        4);
    expect(
        SupplierProcurementRepository.deliveryPerformance(
            DateTime(2026, 10, 5), DateTime(2026, 10, 7)),
        'Late');
    expect(
        SupplierProcurementRepository.deliveryPerformance(
            DateTime(2026, 10, 5), DateTime(2026, 10, 3)),
        'Early');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Part A', priceCents: 80000, costCents: 50000, startingStock: 0);
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier A');
    await PurchaseOrderRepository(db).create(
        actor,
        supplier.id,
        DateTime(2026, 10, 1),
        [PurchaseOrderLineInput(productId, 1000, 50000)]);
    final summary =
        await SupplierProcurementRepository(db).summary(supplier.id);
    expect(summary.openOrders, 0);
    expect(summary.averageFirstDeliveryDays, isNull);
    expect(summary.onTimeRate, isNull);
  });

  test('supplier averages and on-time rate use sent-to-receipt dates',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Part A', priceCents: 80000, costCents: 50000, startingStock: 0);
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Supplier A');
    final po = PurchaseOrderRepository(db);
    final receiving = StockReceivingRepository(db);
    for (final (sent, received, expected) in [
      (DateTime(2026, 10, 1), DateTime(2026, 10, 5), DateTime(2026, 10, 5)),
      (DateTime(2026, 10, 10), DateTime(2026, 10, 17), DateTime(2026, 10, 15)),
    ]) {
      final order = await po.create(actor, supplier.id, sent,
          [PurchaseOrderLineInput(productId, 1000, 50000)],
          expectedDeliveryDate: expected, markSent: true);
      await (db.update(db.purchaseOrders)..where((o) => o.id.equals(order.id)))
          .write(PurchaseOrdersCompanion(sentAt: Value(sent)));
      final line = (await po.detail(order.id)).lines.single;
      await receiving.receive(
          actor,
          supplier.id,
          [
            ReceivingLineRequest(productId, 1000, 50000,
                purchaseOrderLineId: line.id)
          ],
          purchaseOrderId: order.id,
          receivedAt: received);
    }
    final summary =
        await SupplierProcurementRepository(db).summary(supplier.id);
    expect(summary.openOrders, 0);
    expect(summary.firstDeliveryDays, [7, 4]);
    expect(summary.averageFirstDeliveryDays, 5.5);
    expect(summary.averageCompletionDays, 5.5);
    expect(summary.expectedDateSamples, 2);
    expect(summary.onTimeRate, 50);
    expect(summary.costChanges.single.productName, 'Part A');
  });
}
