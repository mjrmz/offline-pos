import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/business_feature.dart';
import 'package:modern_offline_pos/core/models/business_product.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/business_feature_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/rma_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

class _Fixture {
  final AppDatabase db;
  final ActiveUser actor;
  final String userId;
  final String supplierId;
  final String customerId;
  late final pos = PosRepository(db);
  late final receiving = StockReceivingRepository(db);
  late final rma = RmaRepository(db);
  _Fixture(this.db, this.actor, this.userId, this.supplierId, this.customerId);

  static Future<_Fixture> create() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final directory = DirectoryRepository(db);
    final supplier = await directory.saveSupplier(actor, name: 'Vendor');
    final customer = await directory.saveCustomer(actor, name: 'Buyer');
    return _Fixture(db, actor, id, supplier.id, customer.id);
  }

  Future<(String, StockReceivingItem)> stock(
      String name, int price, int quantityMilli,
      {List<String> serials = const [],
      String? batch,
      DateTime? expiry}) async {
    if (batch != null) {
      await BusinessFeatureRepository(db)
          .setEnabled(BusinessFeature.expiryBatchTracking, true, actor);
    }
    final product = await pos.saveProduct(
        name: name,
        priceCents: price,
        costCents: price ~/ 2,
        serialTracking: serials.isNotEmpty,
        business: batch == null ? null : const BusinessProduct(batch: true));
    final receipt = await receiving.receive(actor, supplierId, [
      ReceivingLineRequest(product, quantityMilli, price ~/ 2,
          serialNumbers: serials, batchNumber: batch, expiryDate: expiry)
    ]);
    return (product, (await receiving.items(receipt.id)).single);
  }
}

void main() {
  test('cash item refund leaves other sale lines and invoice history intact',
      () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    final (mouse, _) = await f.stock('Mouse', 100000, 1000);
    final (keyboard, _) = await f.stock('Keyboard', 200000, 1000);
    await CashSessionRepository(f.db).open(f.actor, 0);
    final sale = await f.pos.completeCashSale(
        [SaleLineRequest(mouse, 1), SaleLineRequest(keyboard, 1)],
        300000,
        f.userId);
    final items = await f.db.select(f.db.saleItems).get();
    final mouseItem = items.singleWhere((i) => i.productId == mouse);
    final claim =
        await f.rma.openCustomer(f.actor, mouseItem.id, 'Fault', 'Intact');
    final quote = await SalesRepository(f.db).quoteItemRefund(claim.id);
    expect(quote.amountCents, 100000);
    expect(quote.dueCents, 100000);
    await f.rma.transition(f.actor, claim.id, 'resolved',
        customerResolution: 'refund',
        unitDisposition: 'scrap',
        payCashNow: true);
    expect((await f.db.select(f.db.sales).get()).single.id, sale.saleId);
    expect((await f.db.select(f.db.sales).get()).single.status, 'completed');
    expect((await f.db.select(f.db.saleItems).get()).length, 2);
    expect(await f.pos.stockMilli(keyboard), 0);
    expect((await f.db.select(f.db.saleItemRefunds).get()).single.amountCents,
        100000);
    expect(
        (await f.db.select(f.db.cashMovements).get())
            .where((m) => m.kind == 'item_refund')
            .single
            .amountCents,
        -100000);
    expect(
        (await SalesRepository(f.db).report(f.actor, DateTime.now()))
            .reversalCents,
        100000);
    await expectLater(
        f.rma.transition(f.actor, claim.id, 'resolved',
            customerResolution: 'refund',
            unitDisposition: 'restock',
            payCashNow: true),
        throwsA(isA<StateError>()));
    await expectLater(
        SalesRepository(f.db).reverse(f.actor, sale.saleId, 'refund',
            stockRestored: true, cashRefundConfirmed: true),
        throwsA(isA<StateError>()));
    expect((await f.db.select(f.db.saleItemRefunds).get()).length, 1);
  });

  test('partial quantity credit refund uses original line snapshot', () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    final (product, _) = await f.stock('Parts', 10000, 5000);
    await f.pos.completeCreditSale(
        [SaleLineRequest(product, 5)], 0, f.customerId, f.userId);
    final item = (await f.db.select(f.db.saleItems).get()).single;
    final claim = await f.rma.openCustomer(
        f.actor, item.id, 'Two bad', 'Sealed',
        quantityMilli: 2000);
    await f.rma.transition(f.actor, claim.id, 'resolved',
        customerResolution: 'refund', unitDisposition: 'scrap');
    final refund = (await f.db.select(f.db.saleItemRefunds).get()).single;
    expect(refund.quantityMilli, 2000);
    expect(refund.amountCents, 20000);
    expect(refund.receivableReductionCents, 20000);
    expect(await CustomerCreditRepository(f.db).balance(f.customerId), 30000);
    expect((await f.db.select(f.db.customerRefundObligations).get()), isEmpty);
    await expectLater(
        f.rma.openCustomer(f.actor, item.id, 'Too many', 'Sealed',
            quantityMilli: 4000),
        throwsA(isA<StateError>()));
  });

  test('fractional item refund preserves thousandths and cent allocation',
      () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    await BusinessFeatureRepository(f.db)
        .setEnabled(BusinessFeature.weightBasedPricing, true, f.actor);
    final product = await f.pos.saveProduct(
        name: 'Rice',
        priceCents: 199,
        costCents: 100,
        business: const BusinessProduct(unit: SaleUnit.kilogram, weight: true));
    await f.receiving.receive(
        f.actor, f.supplierId, [ReceivingLineRequest(product, 3000, 100)]);
    await f.pos.completeCreditSale(
        [SaleLineRequest(product, 0, quantityMilli: 1500)],
        0,
        f.customerId,
        f.userId);
    final item = (await f.db.select(f.db.saleItems).get()).single;
    expect(item.lineTotalCents, 299);
    final claim = await f.rma.openCustomer(
        f.actor, item.id, 'Undeliverable part', 'Sealed',
        quantityMilli: 500);
    final quote = await SalesRepository(f.db).quoteItemRefund(claim.id);
    expect(quote.amountCents, 99);
    await f.rma.transition(f.actor, claim.id, 'resolved',
        customerResolution: 'refund', unitDisposition: 'restock');
    expect(await f.pos.stockMilli(product), 2000);
    expect(await CustomerCreditRepository(f.db).balance(f.customerId), 200);
  });

  test('paid credit and mixed tenders create exact refund obligations',
      () async {
    final f = await _Fixture.create();
    final dir = await Directory.systemTemp.createTemp('rma-refund-');
    addTearDown(f.db.close);
    addTearDown(() => dir.delete(recursive: true));
    final (creditProduct, _) = await f.stock('Credit item', 100000, 1000);
    await f.pos.completeCreditSale(
        [SaleLineRequest(creditProduct, 1)], 0, f.customerId, f.userId);
    await CustomerCreditRepository(f.db)
        .payment(f.actor, f.customerId, 60000, 'gcash');
    final creditItem = (await f.db.select(f.db.saleItems).get()).single;
    final creditRma =
        await f.rma.openCustomer(f.actor, creditItem.id, 'Broken', 'Intact');
    await f.rma.transition(f.actor, creditRma.id, 'resolved',
        customerResolution: 'refund', unitDisposition: 'scrap');
    expect(await CustomerCreditRepository(f.db).balance(f.customerId), 0);
    final first = (await f.db.select(f.db.saleItemRefunds).get()).single;
    expect(first.receivableReductionCents, 40000);
    expect(first.obligationCents, 60000);

    final (mixedProduct, _) = await f.stock('Mixed item', 100000, 1000);
    await f.pos.completeCreditSale(
        [SaleLineRequest(mixedProduct, 1)], 40000, f.customerId, f.userId);
    final mixedItem = (await f.db.select(f.db.saleItems).get())
        .singleWhere((i) => i.productId == mixedProduct);
    final mixedRma =
        await f.rma.openCustomer(f.actor, mixedItem.id, 'Broken', 'Intact');
    final quote = await SalesRepository(f.db).quoteItemRefund(mixedRma.id);
    expect(quote.cashAllocationCents, 40000);
    expect(quote.creditAllocationCents, 60000);
    await f.rma.transition(f.actor, mixedRma.id, 'resolved',
        customerResolution: 'refund', unitDisposition: 'scrap');
    expect(await CustomerCreditRepository(f.db).balance(f.customerId), 0);
    expect(
        (await f.db.select(f.db.customerRefundObligations).get())
            .map((o) => o.amountCents)
            .toList(),
        [60000, 40000]);
    expect(
        (await f.db.select(f.db.cashMovements).get())
            .where((m) => m.kind == 'item_refund'),
        isEmpty);
    final backup = await BackupService(f.db, dir).create(BackupKind.manual);
    expect(BackupService.verify(backup.file), 24);
    final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
    try {
      expect((await restored.select(restored.saleItemRefunds).get()).length, 2);
      expect(
          (await restored.select(restored.customerRefundObligations).get())
              .every((o) => o.rmaCaseId != null),
          isTrue);
    } finally {
      await restored.close();
    }
  });

  test('mixed sale allocates only the claimed item proportionally', () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    final (first, _) = await f.stock('First', 100000, 1000);
    final (second, _) = await f.stock('Second', 100000, 1000);
    await f.pos.completeCreditSale(
        [SaleLineRequest(first, 1), SaleLineRequest(second, 1)],
        100000,
        f.customerId,
        f.userId);
    final item = (await f.db.select(f.db.saleItems).get())
        .singleWhere((i) => i.productId == first);
    final claim = await f.rma.openCustomer(f.actor, item.id, 'Fault', 'Intact');
    final quote = await SalesRepository(f.db).quoteItemRefund(claim.id);
    expect(quote.amountCents, 100000);
    expect(quote.cashAllocationCents, 50000);
    expect(quote.creditAllocationCents, 50000);
    await f.rma.transition(f.actor, claim.id, 'resolved',
        customerResolution: 'refund', unitDisposition: 'scrap');
    expect(await CustomerCreditRepository(f.db).balance(f.customerId), 50000);
    expect(
        (await f.db.select(f.db.customerRefundObligations).get())
            .single
            .amountCents,
        50000);
    expect(
        (await f.db.select(f.db.saleItems).get())
            .singleWhere((i) => i.productId == second)
            .lineTotalCents,
        100000);
  });

  test(
      'BIR RMA item refund appears once in Z without changing invoice or grand total',
      () async {
    final f = await _Fixture.create();
    final dir = await Directory.systemTemp.createTemp('rma-bir-');
    addTearDown(() async {
      await f.db.close();
      await dir.delete(recursive: true);
    });
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final cash =
        CashSessionRepository(f.db, birReady: true, protection: protection);
    await cash.open(f.actor, 0);
    final (product, _) = await f.stock('BIR item', 100000, 1000);
    final sale =
        await PosRepository(f.db, birReady: true, protection: protection)
            .completeCashSale([SaleLineRequest(product, 1)], 100000, f.userId);
    final item = (await f.db.select(f.db.saleItems).get()).single;
    final claim = await f.rma.openCustomer(f.actor, item.id, 'Fault', 'Intact');
    await f.rma.transition(f.actor, claim.id, 'resolved',
        customerResolution: 'refund',
        unitDisposition: 'scrap',
        payCashNow: true);
    expect((await f.db.select(f.db.sales).get()).single.birInvoiceNumber, 1);
    expect(
        (await f.db.select(f.db.birComplianceState).get())
            .single
            .grandTotalCents,
        100000);
    await cash.close(f.actor, 0);
    final z = (await f.db.select(f.db.zReadings).get()).single;
    expect(z.periodSalesCents, 100000);
    expect(z.reversalCents, 100000);
    expect(z.grandTotalCents, 100000);
    expect(sale.birInvoiceNumber, 1);
  });

  test('later-session BIR refund appears on the refund session Z-reading',
      () async {
    final f = await _Fixture.create();
    final dir = await Directory.systemTemp.createTemp('rma-bir-later-');
    addTearDown(() async {
      await f.db.close();
      await dir.delete(recursive: true);
    });
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final cash =
        CashSessionRepository(f.db, birReady: true, protection: protection);
    await cash.open(f.actor, 0);
    final (product, _) = await f.stock('Device', 100000, 1000);
    await PosRepository(f.db, birReady: true, protection: protection)
        .completeCashSale([SaleLineRequest(product, 1)], 100000, f.userId);
    await cash.close(f.actor, 100000);
    await cash.open(f.actor, 100000);
    final item = (await f.db.select(f.db.saleItems).get()).single;
    final claim = await f.rma.openCustomer(f.actor, item.id, 'Fault', 'Intact');
    await f.rma.transition(f.actor, claim.id, 'resolved',
        customerResolution: 'refund',
        unitDisposition: 'scrap',
        payCashNow: true);
    await cash.close(f.actor, 0);
    final readings = await f.db.select(f.db.zReadings).get();
    expect(readings.length, 2);
    expect(readings.last.periodSalesCents, 0);
    expect(readings.last.reversalCents, 100000);
    expect(readings.last.grandTotalCents, 100000);
    expect((await f.db.select(f.db.sales).get()).single.status, 'completed');
  });

  test('serialized refund restocks only the selected returned serial',
      () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    final (product, receivingItem) =
        await f.stock('Laptop', 100000, 2000, serials: ['OLD-1', 'OLD-2']);
    final serials = await f.receiving.serialsForItem(receivingItem.id);
    await f.pos.completeCreditSale([
      SaleLineRequest(product, 1, serialIds: [serials.first.id])
    ], 0, f.customerId, f.userId);
    final item = (await f.db.select(f.db.saleItems).get()).single;
    final claim = await f.rma.openCustomer(f.actor, item.id, 'Fault', 'Intact',
        serialUnitId: serials.first.id);
    await expectLater(
        f.pos.completeCreditSale([
          SaleLineRequest(product, 1, serialIds: [serials.first.id])
        ], 0, f.customerId, f.userId),
        throwsA(isA<StateError>()));
    await f.rma.transition(f.actor, claim.id, 'resolved',
        customerResolution: 'refund', unitDisposition: 'restock');
    expect(await f.pos.stockMilli(product), 2000);
    expect(
        (await f.db.select(f.db.serialUnits).get())
            .singleWhere((s) => s.id == serials.first.id)
            .status,
        'available');
    expect(
        (await f.db.select(f.db.inventoryMovements).get())
            .where((m) => m.reason == 'rma_restock')
            .length,
        1);
  });

  test('supplier serial replacement is linked, available once and backed up',
      () async {
    final f = await _Fixture.create();
    final dir = await Directory.systemTemp.createTemp('rma-replacement-');
    addTearDown(() async {
      await f.db.close();
      await dir.delete(recursive: true);
    });
    final (product, receivingItem) =
        await f.stock('Device', 100000, 1000, serials: ['DEFECTIVE']);
    final old = (await f.receiving.serialsForItem(receivingItem.id)).single;
    final claim = await f.rma.openInbound(
        f.actor, receivingItem.id, 'Dead on arrival', 'Sealed',
        serialUnitId: old.id);
    expect(await f.pos.stockMilli(product), 0);
    await f.rma.transition(f.actor, claim.id, 'sent_to_supplier');
    final replacement = await f.rma.receiveSupplierReplacement(
        f.actor, claim.id,
        serialNumber: 'NEW-UNIT', supplierReference: 'SUP-123');
    expect(await f.pos.stockMilli(product), 1000);
    expect(
        (await f.db.select(f.db.serialUnits).get())
            .singleWhere((s) => s.id == old.id)
            .status,
        'returned');
    expect(
        (await f.db.select(f.db.serialUnits).get())
            .singleWhere((s) => s.serialNumber == 'NEW-UNIT')
            .status,
        'available');
    expect(replacement.rmaCaseId, claim.id);
    await expectLater(
        f.rma.receiveSupplierReplacement(f.actor, claim.id,
            serialNumber: 'ANOTHER'),
        throwsA(isA<StateError>()));
    expect(await f.pos.stockMilli(product), 1000);
    final backup = await BackupService(f.db, dir).create(BackupKind.manual);
    expect(BackupService.verify(backup.file), 24);
    final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
    try {
      expect(
          (await restored.select(restored.inboundRmaReplacements).get())
              .single
              .serialUnitId,
          replacement.serialUnitId);
    } finally {
      await restored.close();
    }
  });

  test('supplier batch replacement records expiry and quarantines original',
      () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    final expiry = DateTime.now().add(const Duration(days: 100));
    final (product, receivingItem) =
        await f.stock('Milk', 10000, 3000, batch: 'OLD', expiry: expiry);
    final claim = await f.rma.openInbound(
        f.actor, receivingItem.id, 'Spoiled', 'Sealed',
        quantityMilli: 2000);
    expect(await f.pos.stockMilli(product), 1000);
    await f.rma.transition(f.actor, claim.id, 'sent_to_supplier');
    await f.rma.receiveSupplierReplacement(f.actor, claim.id,
        batchNumber: 'NEW', expiryDate: expiry);
    expect(await f.pos.stockMilli(product), 3000);
    final lots = await f.pos.batches(product);
    expect(lots.singleWhere((l) => l.batchNumber == 'OLD').quantityMilli, 1000);
    expect(lots.singleWhere((l) => l.batchNumber == 'NEW').quantityMilli, 2000);
    expect(
        lots
            .singleWhere((l) => l.batchNumber == 'NEW')
            .expiryDate
            ?.toIso8601String()
            .substring(0, 10),
        expiry.toIso8601String().substring(0, 10));
  });

  test('ordinary supplier replacement returns exactly the quarantined quantity',
      () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    final (product, item) = await f.stock('Cable', 10000, 5000);
    final claim = await f.rma.openInbound(
        f.actor, item.id, 'Two damaged', 'Opened',
        quantityMilli: 2000);
    expect(await f.pos.stockMilli(product), 3000);
    await f.rma.transition(f.actor, claim.id, 'sent_to_supplier');
    final replacement = await f.rma.receiveSupplierReplacement(
        f.actor, claim.id,
        supplierReference: 'SUP-2');
    expect(replacement.quantityMilli, 2000);
    expect(await f.pos.stockMilli(product), 5000);
    expect(
        (await f.db.select(f.db.inventoryMovements).get())
            .where((m) => m.reason == 'supplier_receiving')
            .length,
        2);
    expect((await f.db.select(f.db.rmaCases).get()).single.status, 'resolved');
    expect((await f.rma.events(claim.id)).map((e) => e.status).toList(),
        ['pending', 'sent_to_supplier', 'resolved']);
  });

  test('duplicate supplier serial rolls back replacement receipt', () async {
    final f = await _Fixture.create();
    addTearDown(f.db.close);
    final (product, item) =
        await f.stock('Device', 100000, 1000, serials: ['ORIGINAL']);
    final old = (await f.receiving.serialsForItem(item.id)).single;
    final claim = await f.rma
        .openInbound(f.actor, item.id, 'Fault', 'Intact', serialUnitId: old.id);
    await f.rma.transition(f.actor, claim.id, 'sent_to_supplier');
    await expectLater(
        f.rma.receiveSupplierReplacement(f.actor, claim.id,
            serialNumber: 'ORIGINAL'),
        throwsA(isA<Exception>()));
    expect(await f.pos.stockMilli(product), 0);
    expect(await f.db.select(f.db.inboundRmaReplacements).get(), isEmpty);
    expect((await f.db.select(f.db.rmaCases).get()).single.status,
        'sent_to_supplier');
  });
}
