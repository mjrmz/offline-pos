import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/layaway_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  test('layaway reserves stock, records deposits and completes once', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-layaway-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final actor = auth.current!;
      final customer =
          await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
      final cash = CashSessionRepository(db);
      final session = await cash.open(actor, 0);
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Item', priceCents: 50000, costCents: 10000, startingStock: 2);
      final repo = LayawayRepository(db, pos);
      final row = await repo.create(actor, customer.id,
          [LayawayLineRequest(product, 1000)], 20000, 'cash');
      expect(await pos.stockMilli(product), 2000);
      expect(await pos.reservedStockMilli(product), 1000);
      expect(await cash.expected(session.id), 20000);
      expect(await db.select(db.sales).get(), isEmpty);
      await expectLater(
          pos.completeCashSale([SaleLineRequest(product, 2)], 100000, id),
          throwsA(isA<StateError>()));
      await repo.payment(actor, row.id, 10000, 'cash');
      expect(await repo.balance(row.id), 20000);
      final sale = await repo.complete(actor, row.id);
      expect(sale.totalCents, 50000);
      expect(await pos.stockMilli(product), 1000);
      expect(await pos.reservedStockMilli(product), 0);
      expect(await cash.expected(session.id), 50000);
      expect((await repo.history()).single.saleId, sale.saleId);
      await expectLater(
          repo.complete(actor, row.id), throwsA(isA<StateError>()));
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect(
            (await restored.select(restored.layawayPayments).get()).length, 2);
        expect((await restored.select(restored.layaways).get()).single.status,
            'completed');
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('cancel releases reserved serial and creates refund due', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final actor = auth.current!;
    final directory = DirectoryRepository(db);
    final customer = await directory.saveCustomer(actor, name: 'Juan');
    final supplier = await directory.saveSupplier(actor, name: 'Vendor');
    final cash = CashSessionRepository(db);
    final session = await cash.open(actor, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Laptop',
        priceCents: 50000,
        costCents: 30000,
        serialTracking: true);
    await StockReceivingRepository(db).receive(actor, supplier.id, [
      ReceivingLineRequest(product, 1000, 30000, serialNumbers: ['L-1'])
    ]);
    final serial = (await pos.availableSerials(product)).single;
    final repo = LayawayRepository(db, pos);
    final row = await repo.create(
        actor,
        customer.id,
        [
          LayawayLineRequest(product, 1000, serialIds: [serial.id])
        ],
        20000,
        'cash');
    expect(await pos.availableSerials(product), isEmpty);
    expect(await pos.stockMilli(product), 1000);
    await repo.cancel(actor, row.id);
    expect((await pos.availableSerials(product)).single.id, serial.id);
    expect(await pos.stockMilli(product), 1000);
    expect(
        (await CustomerCreditRepository(db).refundObligations(customer.id))
            .single
            .amountCents,
        20000);
    expect(await cash.expected(session.id), 20000);
  });

  test('BIR layaway deposits stay outside sales until completion', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-bir-layaway-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final protection =
          ComplianceProtection(File('${dir.path}/compliance.json'));
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final actor = auth.current!;
      final customer =
          await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
      final cash =
          CashSessionRepository(db, birReady: true, protection: protection);
      final session = await cash.open(actor, 0);
      final pos = PosRepository(db, birReady: true, protection: protection);
      final product = await pos.saveProduct(
          name: 'Item', priceCents: 50000, costCents: 10000, startingStock: 1);
      final repo = LayawayRepository(db, pos);
      final layaway = await repo.create(actor, customer.id,
          [LayawayLineRequest(product, 1000)], 20000, 'cash');
      expect(await db.select(db.sales).get(), isEmpty);
      expect(await cash.expected(session.id), 20000);
      final sale = await repo.complete(actor, layaway.id);
      expect(sale.birInvoiceNumber, 1);
      expect(await cash.expected(session.id), 50000);
      await cash.close(actor, 50000);
      final z = (await db.select(db.zReadings).get()).single;
      expect(z.periodSalesCents, 50000);
      expect(z.grandTotalCents, 50000);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
