import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/rma_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  test('customer and inbound RMA retain origin, serial and status events',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-rma-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final directory = DirectoryRepository(db);
      final customer = await directory.saveCustomer(actor,
          name: 'Juan', phone: '09171234567');
      final supplier = await directory.saveSupplier(actor, name: 'Vendor');
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Device',
          sku: 'DEV-100',
          barcode: '4801234567890',
          priceCents: 50000,
          costCents: 25000,
          serialTracking: true);
      final receiving = StockReceivingRepository(db);
      final delivery = await receiving.receive(actor, supplier.id, [
        ReceivingLineRequest(product, 2000, 25000,
            serialNumbers: ['S-1', 'S-2'])
      ]);
      final receivingItem = (await receiving.items(delivery.id)).single;
      final serials = await receiving.serialsForItem(receivingItem.id);
      final sale = await pos.completeCreditSale([
        SaleLineRequest(product, 1, serialIds: [serials.first.id])
      ], 0, customer.id, userId);
      final saleItem = (await db.select(db.saleItems).get()).single;
      final rma = RmaRepository(db);
      expect(
          (await rma.choices('customer', 'Juan')).single.itemId, saleItem.id);
      for (final term in ['09171234567', 'DEV-100', '4801234567890', 'S-1']) {
        expect(
            (await rma.choices('customer', term)).single.itemId, saleItem.id);
      }
      final customerCase = await rma.openCustomer(
          actor, saleItem.id, 'Screen fails', 'Case intact',
          serialUnitId: serials.first.id);
      final inboundCase = await rma.openInbound(
          actor, receivingItem.id, 'Dead on arrival', 'Sealed',
          serialUnitId: serials.last.id);
      expect(customerCase.reference, matches(RegExp(r'^RMA-\d{4}-\d{6}$')));
      expect(inboundCase.reference, matches(RegExp(r'^SRMA-\d{4}-\d{6}$')));
      expect(await pos.stockMilli(product), 0);
      expect(customerCase.saleId, sale.saleId);
      expect(customerCase.customerId, customer.id);
      expect(inboundCase.supplierId, supplier.id);
      expect(inboundCase.receivingId, delivery.id);
      await rma.transition(actor, customerCase.id, 'sent_to_supplier');
      await rma.transition(actor, customerCase.id, 'resolved',
          customerResolution: 'repaired_return',
          unitDisposition: 'return_to_customer');
      await rma.transition(actor, inboundCase.id, 'rejected',
          note: 'Vendor rejected claim', unitDisposition: 'scrap');
      expect(
          (await db.select(db.serialUnits).get())
              .where((s) => s.id == serials.last.id)
              .single
              .status,
          'scrapped');
      expect((await rma.events(customerCase.id)).map((e) => e.status).toList(),
          ['pending', 'sent_to_supplier', 'resolved']);
      expect(
          (await db.select(db.auditLogs).get())
              .where((a) => a.action.startsWith('rma.'))
              .length,
          5);
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect((await restored.select(restored.rmaCases).get()).length, 2);
        expect((await restored.select(restored.rmaEvents).get()).length, 5);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('nonserialized supplier RMA quarantines measured stock and restocks',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Vendor');
    final pos = PosRepository(db);
    final product =
        await pos.saveProduct(name: 'Item', priceCents: 5000, costCents: 1000);
    final receiving = StockReceivingRepository(db);
    final header = await receiving.receive(
        actor, supplier.id, [ReceivingLineRequest(product, 3000, 1000)]);
    final item = (await receiving.items(header.id)).single;
    final rma = RmaRepository(db);
    final row = await rma.openInbound(actor, item.id, 'Damaged', 'Box open',
        quantityMilli: 2000);
    expect(await pos.stockMilli(product), 1000);
    await expectLater(
        pos.completeCashSale([SaleLineRequest(product, 2)], 10000, id),
        throwsA(isA<StateError>()));
    await rma.transition(actor, row.id, 'resolved', unitDisposition: 'restock');
    expect(await pos.stockMilli(product), 3000);
  });

  test('serialized replacement consumes one stock unit without a new sale',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Vendor');
    final customer =
        await DirectoryRepository(db).saveCustomer(actor, name: 'Buyer');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Device',
        priceCents: 50000,
        costCents: 25000,
        serialTracking: true);
    final receiving = StockReceivingRepository(db);
    final delivery = await receiving.receive(actor, supplier.id, [
      ReceivingLineRequest(product, 2000, 25000, serialNumbers: ['OLD', 'NEW'])
    ]);
    final item = (await receiving.items(delivery.id)).single;
    final serials = await receiving.serialsForItem(item.id);
    await pos.completeCreditSale([
      SaleLineRequest(product, 1, serialIds: [serials.first.id])
    ], 0, customer.id, id);
    final saleItem = (await db.select(db.saleItems).get()).single;
    final rma = RmaRepository(db);
    final claim = await rma.openCustomer(actor, saleItem.id, 'Broken', 'Intact',
        serialUnitId: serials.first.id);
    await rma.transition(actor, claim.id, 'resolved',
        customerResolution: 'same_item_replacement',
        unitDisposition: 'scrap',
        replacementSerialUnitId: serials.last.id);
    expect(await pos.stockMilli(product), 0);
    expect((await db.select(db.sales).get()).length, 1);
    expect((await db.select(db.payments).get()).length, 1);
    expect(
        (await db.select(db.inventoryMovements).get())
            .where((m) => m.reason == 'rma_replacement')
            .length,
        1);
    final saved = (await db.select(db.rmaCases).get()).single;
    expect(saved.replacementSerialUnitId, serials.last.id);
    expect(
        (await db.select(db.serialUnits).get())
            .where((s) => s.id == serials.first.id)
            .single
            .status,
        'scrapped');
    expect(
        (await db.select(db.serialUnits).get())
            .where((s) => s.id == serials.last.id)
            .single
            .status,
        'sold');
    await expectLater(
        rma.transition(actor, claim.id, 'resolved',
            customerResolution: 'same_item_replacement',
            unitDisposition: 'scrap',
            replacementSerialUnitId: serials.last.id),
        throwsA(isA<StateError>()));
  });
}
