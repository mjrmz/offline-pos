import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/backup/compliance_protection.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';

void main() {
  test('BIR cash, full credit and mixed sales separate revenue and cash',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-credit-');
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      final customer =
          await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
      final cash =
          CashSessionRepository(db, birReady: true, protection: protection);
      final session = await cash.open(actor, 0);
      final pos = PosRepository(db, birReady: true, protection: protection);
      final product = await pos.saveProduct(
          name: 'Item', priceCents: 50000, costCents: 0, startingStock: 3);
      final first = await pos
          .completeCashSale([SaleLineRequest(product, 1)], 50000, ownerId);
      final second = await pos.completeCreditSale(
          [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
      final third = await pos.completeCreditSale(
          [SaleLineRequest(product, 1)], 20000, customer.id, ownerId);
      expect([
        first.birInvoiceNumber,
        second.birInvoiceNumber,
        third.birInvoiceNumber
      ], [
        1,
        2,
        3
      ]);
      expect(await cash.expected(session.id), 70000);
      expect(await CustomerCreditRepository(db).balance(customer.id), 80000);
      expect(
          (await db.select(db.birComplianceState).get()).single.grandTotalCents,
          150000);
      final z = (await cash.close(actor, 70000)).session;
      expect(z.expectedCashCents, 70000);
      expect((await db.select(db.zReadings).get()).single.periodSalesCents,
          150000);
      expect((await SalesRepository(db).history(actor)).length, 3);
      expect(
          (await SalesRepository(db).detail(actor, third.saleId))
              .summary
              .paymentMethod,
          'mixed');
      final backup = await BackupService(db, Directory('${dir.path}/backups'))
          .create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect(
            (await restored.select(restored.customerCreditEntries).get())
                .fold<int>(0, (sum, entry) => sum + entry.amountCents),
            80000);
        expect(
            (await restored.select(restored.zReadings).get())
                .single
                .periodSalesCents,
            150000);
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test(
      'customer payment reduces balance and increases only current cash drawer',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final customer =
        await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
    final cash = CashSessionRepository(db);
    final session = await cash.open(actor, 100000);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Item', priceCents: 50000, costCents: 0, startingStock: 1);
    await pos.completeCreditSale(
        [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
    await CustomerCreditRepository(db)
        .payment(actor, customer.id, 15000, 'cash');
    expect(await CustomerCreditRepository(db).balance(customer.id), 35000);
    expect(
        (await CustomerCreditRepository(db).entries(customer.id))
            .last
            .paymentMethod,
        'cash');
    expect(await cash.expected(session.id), 115000);
    expect((await db.select(db.sales).get()).length, 1);
  });

  test('credit sale reversal appends ledger correction and failure rolls back',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final customer =
        await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Item', priceCents: 50000, costCents: 0, startingStock: 1);
    final sale = await pos.completeCreditSale(
        [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
    await db.customStatement(
        "CREATE TRIGGER reject_reversal_credit BEFORE INSERT ON customer_credit_entries "
        "WHEN NEW.kind = 'sale_reversal' BEGIN SELECT RAISE(ABORT, 'ledger unavailable'); END");
    await expectLater(
        SalesRepository(db)
            .reverse(actor, sale.saleId, 'void', stockRestored: true),
        throwsA(isA<Exception>()));
    expect((await db.select(db.sales).get()).single.status, 'completed');
    expect(await CustomerCreditRepository(db).balance(customer.id), 50000);
    await db.customStatement('DROP TRIGGER reject_reversal_credit');
    await SalesRepository(db)
        .reverse(actor, sale.saleId, 'void', stockRestored: true);
    expect(await CustomerCreditRepository(db).balance(customer.id), 0);
    expect(
        (await CustomerCreditRepository(db).entries(customer.id))
            .map((e) => e.kind)
            .toList(),
        ['credit_sale', 'sale_reversal']);
  });

  test('BIR credit reversal stays separate from issued grand total', () async {
    final dir = await Directory.systemTemp.createTemp('phase85-credit-void-');
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
      await auth.login(ownerId, 'password123');
      final actor = auth.current!;
      final customer =
          await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
      final cash =
          CashSessionRepository(db, birReady: true, protection: protection);
      final session = await cash.open(actor, 0);
      final pos = PosRepository(db, birReady: true, protection: protection);
      final product = await pos.saveProduct(
          name: 'Item', priceCents: 50000, costCents: 0, startingStock: 1);
      final sale = await pos.completeCreditSale(
          [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
      await SalesRepository(db)
          .reverse(actor, sale.saleId, 'void', stockRestored: true);
      expect(await CustomerCreditRepository(db).balance(customer.id), 0);
      expect(await cash.expected(session.id), 0);
      await cash.close(actor, 0);
      final z = (await db.select(db.zReadings).get()).single;
      expect(z.periodSalesCents, 50000);
      expect(z.reversalCents, 50000);
      expect(z.grandTotalCents, 50000);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('BIR mixed reversal refunds cash without changing issued grand total',
      () async {
    final dir = await Directory.systemTemp.createTemp('phase85-mixed-z-');
    final protection =
        ComplianceProtection(File('${dir.path}/compliance.json'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
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
          name: 'Item', priceCents: 50000, costCents: 0, startingStock: 1);
      final sale = await pos.completeCreditSale(
          [SaleLineRequest(product, 1)], 20000, customer.id, id);
      await SalesRepository(db).reverse(actor, sale.saleId, 'void',
          stockRestored: true, cashRefundConfirmed: true);
      expect(await cash.expected(session.id), 0);
      expect(await CustomerCreditRepository(db).balance(customer.id), 0);
      await cash.close(actor, 0);
      final z = (await db.select(db.zReadings).get()).single;
      expect(z.periodSalesCents, 50000);
      expect(z.reversalCents, 50000);
      expect(z.grandTotalCents, 50000);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('mixed credit reversal is blocked until cash refund can be recorded',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final customer =
        await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Item', priceCents: 50000, costCents: 0, startingStock: 1);
    final sale = await pos.completeCreditSale(
        [SaleLineRequest(product, 1)], 20000, customer.id, ownerId);
    await expectLater(
        SalesRepository(db)
            .reverse(actor, sale.saleId, 'void', stockRestored: true),
        throwsA(isA<StateError>()));
    expect((await db.select(db.sales).get()).single.status, 'completed');
    expect(await CustomerCreditRepository(db).balance(customer.id), 30000);
    final session = await CashSessionRepository(db).open(actor, 50000);
    await SalesRepository(db).reverse(actor, sale.saleId, 'void',
        stockRestored: true, cashRefundConfirmed: true);
    expect(await CustomerCreditRepository(db).balance(customer.id), 0);
    expect(await CashSessionRepository(db).expected(session.id), 30000);
    expect((await db.select(db.cashMovements).get()).single.kind,
        'mixed_sale_cash_refund');
    expect((await db.select(db.cashMovements).get()).single.referenceId,
        (await db.select(db.saleReversals).get()).single.id);
  });

  test('paid pooled credit reversal creates explicit refundable obligation',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final customer = await DirectoryRepository(db)
        .saveCustomer(actor, name: 'Pooled account');
    final session = await CashSessionRepository(db).open(actor, 0);
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Item', priceCents: 50000, costCents: 0, startingStock: 2);
    final first = await pos.completeCreditSale(
        [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
    await pos.completeCreditSale(
        [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
    final credit = CustomerCreditRepository(db);
    await credit.payment(actor, customer.id, 80000, 'cash');
    expect(await credit.balance(customer.id), 20000);
    await SalesRepository(db)
        .reverse(actor, first.saleId, 'void', stockRestored: true);
    expect(await credit.balance(customer.id), 0);
    final obligation = (await credit.refundObligations(customer.id)).single;
    expect(obligation.amountCents, 30000);
    expect(obligation.settledCents, 0);
    await credit.settleRefund(actor, obligation.id, 10000, 'cash',
        note: 'Partial return');
    expect((await credit.refundObligations(customer.id)).single.settledCents,
        10000);
    expect(
        (await db.select(db.customerRefundSettlements).get())
            .single
            .amountCents,
        10000);
    expect(
        (await db.select(db.cashMovements).get())
            .where((m) => m.kind == 'customer_credit_refund')
            .single
            .referenceId,
        (await db.select(db.customerRefundSettlements).get()).single.id);
    expect(await CashSessionRepository(db).expected(session.id), 70000);
    final dir = await Directory.systemTemp.createTemp('phase85-refund-backup-');
    try {
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect(
            (await restored.select(restored.customerRefundObligations).get())
                .single
                .amountCents,
            30000);
        expect(
            (await restored.select(restored.customerRefundObligations).get())
                .single
                .settledCents,
            10000);
        expect(
            (await restored.select(restored.customerRefundSettlements).get())
                .single
                .amountCents,
            10000);
      } finally {
        await restored.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
    await credit.settleRefund(actor, obligation.id, 20000, 'cash');
    expect(await CashSessionRepository(db).expected(session.id), 50000);
  });

  test('partially paid single credit sale leaves no negative utang', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final actor = auth.current!;
    final customer =
        await DirectoryRepository(db).saveCustomer(actor, name: 'Juan');
    final product = await PosRepository(db).saveProduct(
        name: 'Item', priceCents: 50000, costCents: 0, startingStock: 1);
    final sale = await PosRepository(db).completeCreditSale(
        [SaleLineRequest(product, 1)], 0, customer.id, ownerId);
    await CashSessionRepository(db).open(actor, 0);
    final credit = CustomerCreditRepository(db);
    await credit.payment(actor, customer.id, 30000, 'cash');
    await SalesRepository(db)
        .reverse(actor, sale.saleId, 'void', stockRestored: true);
    expect(await credit.balance(customer.id), 0);
    expect((await credit.refundObligations(customer.id)).single.amountCents,
        30000);
    expect((await credit.entries(customer.id)).last.amountCents, -20000);
  });
}
