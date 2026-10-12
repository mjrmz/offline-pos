import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/rma_lifecycle_repository.dart';
import 'package:modern_offline_pos/data/daos/rma_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';

void main() {
  for (final outcome in ['no_fault', 'reject_claim']) {
    test('$outcome customer property stays open until exact handoff', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final directory = DirectoryRepository(db);
      final supplier = await directory.saveSupplier(actor, name: 'Vendor');
      final customer = await directory.saveCustomer(actor, name: 'Buyer');
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Device',
          priceCents: 5000,
          costCents: 3000,
          serialTracking: true);
      final receipt =
          await StockReceivingRepository(db).receive(actor, supplier.id, [
        ReceivingLineRequest(product, 1000, 3000, serialNumbers: ['ORIGINAL'])
      ]);
      final item =
          (await StockReceivingRepository(db).items(receipt.id)).single;
      final original =
          (await StockReceivingRepository(db).serialsForItem(item.id)).single;
      await pos.completeCreditSale([
        SaleLineRequest(product, 1, serialIds: [original.id])
      ], 0, customer.id, userId);
      final sold = (await db.select(db.saleItems).get()).single;
      final rma = RmaLifecycleRepository(db);
      final claim =
          await rma.request(actor, sold.id, 'Fault', serialUnitId: original.id);
      await rma.approve(actor, claim.id);
      await rma.receive(actor, claim.id, 1000, returnedSerial: 'ORIGINAL');
      await rma.inspect(actor, claim.id, 1000, 'Good', false, 'No fault');
      await rma.authorize(actor, claim.id, outcome, 'return_to_customer',
          note: outcome == 'reject_claim' ? 'Outside policy' : null);
      expect(
          (await db.select(db.rmaCases).get())
              .singleWhere((row) => row.id == claim.id)
              .status,
          'pending');
      await expectLater(
          rma.handoff(actor, claim.id, 'Buyer', serialUnitId: 'wrong'),
          throwsStateError);
      await rma.handoff(actor, claim.id, 'Buyer', serialUnitId: original.id);
      expect(await rma.nextAction(claim.id), 'Complete');
    });
  }

  for (final treatment in ['restart', 'custom', 'none']) {
    test(
        'replacement handoff persists $treatment warranty without rewriting sale',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final directory = DirectoryRepository(db);
      final supplier = await directory.saveSupplier(actor, name: 'Vendor');
      final customer = await directory.saveCustomer(actor, name: 'Buyer');
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Device',
          priceCents: 5000,
          costCents: 3000,
          serialTracking: true);
      final receipt =
          await StockReceivingRepository(db).receive(actor, supplier.id, [
        ReceivingLineRequest(product, 2000, 3000,
            serialNumbers: ['ORIGINAL', 'STORE-NEW'])
      ]);
      final item =
          (await StockReceivingRepository(db).items(receipt.id)).single;
      final serials =
          await StockReceivingRepository(db).serialsForItem(item.id);
      await pos.completeCreditSale([
        SaleLineRequest(product, 1, serialIds: [serials.first.id])
      ], 0, customer.id, userId);
      final sold = (await db.select(db.saleItems).get()).single;
      final rma = RmaLifecycleRepository(db);
      final claim = await rma.request(actor, sold.id, 'Fault',
          serialUnitId: serials.first.id);
      await rma.approve(actor, claim.id);
      await rma.receive(actor, claim.id, 1000, returnedSerial: 'ORIGINAL');
      await rma.inspect(actor, claim.id, 1000, 'Damaged', true, 'Fault');
      await rma.authorize(actor, claim.id, 'replacement', 'scrap');
      await rma.reserveReplacement(actor, claim.id, serials.last.id);
      await rma.executeDisposition(actor, claim.id);
      final end = DateTime.now().add(const Duration(days: 180));
      if (treatment == 'custom') {
        await db.customStatement(
            "INSERT INTO users (id, name, role) VALUES ('manager', 'Manager', 'manager')");
        await expectLater(
            rma.handoff(
                const ActiveUser('manager', 'Manager', UserRole.manager),
                claim.id,
                'Buyer',
                serialUnitId: serials.last.id,
                warrantyTreatment: treatment,
                warrantyEndAt: end),
            throwsStateError);
      }
      await rma.handoff(actor, claim.id, 'Buyer',
          serialUnitId: serials.last.id,
          warrantyTreatment: treatment,
          warrantyEndAt: treatment == 'none' ? null : end);
      final snapshot =
          (await db.select(db.serialWarrantySnapshots).get()).single;
      expect(snapshot.serialUnitId, serials.last.id);
      expect(snapshot.treatment, treatment);
      expect(snapshot.startAt == null, treatment == 'none');
      expect(snapshot.endAt == null, treatment == 'none');
      expect((await db.select(db.saleItems).get()).single.id, sold.id);
    });
  }

  for (final decision in ['repair', 'no_fault', 'rejected']) {
    test('supplier $decision returns exact original before customer handoff',
        () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final userId =
          await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(userId, 'password123');
      final actor = auth.current!;
      final directory = DirectoryRepository(db);
      final supplier = await directory.saveSupplier(actor, name: 'Vendor');
      final customer = await directory.saveCustomer(actor, name: 'Buyer');
      final pos = PosRepository(db);
      final product = await pos.saveProduct(
          name: 'Board',
          priceCents: 5000,
          costCents: 3000,
          serialTracking: true);
      final receipt =
          await StockReceivingRepository(db).receive(actor, supplier.id, [
        ReceivingLineRequest(product, 1000, 3000, serialNumbers: ['ORIGINAL'])
      ]);
      final item =
          (await StockReceivingRepository(db).items(receipt.id)).single;
      final original =
          (await StockReceivingRepository(db).serialsForItem(item.id)).single;
      await pos.completeCreditSale([
        SaleLineRequest(product, 1, serialIds: [original.id])
      ], 0, customer.id, userId);
      final sold = (await db.select(db.saleItems).get()).single;
      final rma = RmaLifecycleRepository(db);
      final claim =
          await rma.request(actor, sold.id, 'Fault', serialUnitId: original.id);
      await rma.approve(actor, claim.id);
      await rma.receive(actor, claim.id, 1000, returnedSerial: 'ORIGINAL');
      await rma.inspect(actor, claim.id, 1000, 'Damaged', true, 'Fault');
      await rma.authorize(actor, claim.id, 'supplier_warranty', 'supplier');
      final supplierClaim = await rma.sendToSupplier(actor, claim.id);
      await rma.supplierDecision(actor, supplierClaim.id, decision);
      await expectLater(
          rma.supplierReturnOriginal(actor, supplierClaim.id, 'WRONG', 'good'),
          throwsStateError);
      await rma.supplierReturnOriginal(
          actor, supplierClaim.id, 'ORIGINAL', 'good',
          reference: 'RETURN-1');
      expect((await db.select(db.serialUnits).get()).length, 1);
      expect((await db.select(db.serialUnits).get()).single.id, original.id);
      if (decision == 'rejected') {
        expect(await rma.nextAction(supplierClaim.id), 'Resolve rejected item');
        await rma.supplierRejectedDisposition(
            actor, supplierClaim.id, 'return_to_customer');
        expect(
            await rma.nextAction(claim.id), 'Hand returned item to customer');
      } else {
        expect(
            await rma.nextAction(claim.id), 'Hand repaired item to customer');
      }
      await rma.handoff(actor, claim.id, 'Buyer', serialUnitId: original.id);
      expect(await rma.nextAction(claim.id), 'Complete');
      expect((await db.select(db.serialUnits).get()).single.status, 'sold');
      expect(
          (await db.select(db.serialWarrantySnapshots).get()).single.treatment,
          'continue_original');
    });
  }

  test(
      'supplier replacement is held for waiting customer and handed off exactly',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final actor = auth.current!;
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Vendor');
    final customer =
        await DirectoryRepository(db).saveCustomer(actor, name: 'Buyer');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Board', priceCents: 5000, costCents: 3000, serialTracking: true);
    final receipt =
        await StockReceivingRepository(db).receive(actor, supplier.id, [
      ReceivingLineRequest(product, 1000, 3000, serialNumbers: ['ORIGINAL'])
    ]);
    final item = (await StockReceivingRepository(db).items(receipt.id)).single;
    final original =
        (await StockReceivingRepository(db).serialsForItem(item.id)).single;
    await pos.completeCreditSale([
      SaleLineRequest(product, 1, serialIds: [original.id])
    ], 0, customer.id, userId);
    final sold = (await db.select(db.saleItems).get()).single;
    final rma = RmaLifecycleRepository(db);
    final claim =
        await rma.request(actor, sold.id, 'Fault', serialUnitId: original.id);
    await rma.approve(actor, claim.id);
    await rma.receive(actor, claim.id, 1000, returnedSerial: 'ORIGINAL');
    await rma.inspect(actor, claim.id, 1000, 'Damaged', true, 'Fault');
    await rma.authorize(actor, claim.id, 'supplier_warranty', 'supplier');
    final createdLink = (await rma.history(claim.id))
        .singleWhere((event) => event.action == 'supplier_claim_opened');
    final created = (await db.select(db.rmaCases).get())
        .singleWhere((row) => row.id == createdLink.relatedCaseId);
    expect(created.status, 'pending');
    expect(
        (await rma.history(created.id))
            .any((event) => event.action == 'supplier_requested'),
        isFalse);
    expect(
        (await rma.history(claim.id))
            .any((event) => event.action == 'custody_supplier'),
        isFalse);
    await expectLater(
        rma.authorize(actor, claim.id, 'supplier_warranty', 'supplier'),
        throwsStateError);
    expect(
        (await db.select(db.rmaCases).get())
            .where((row) => row.origin == 'inbound')
            .length,
        1);
    final supplierClaim = await rma.sendToSupplier(actor, claim.id);
    expect(supplierClaim.id, created.id);
    expect(await rma.nextAction(claim.id), 'Waiting on supplier');
    await rma.supplierDecision(actor, supplierClaim.id, 'replacement');
    expect(await rma.nextAction(claim.id), 'Waiting on supplier');
    await rma.supplierReplacement(actor, supplierClaim.id, 'SUPPLIER-NEW',
        reference: 'SR-1');
    expect(
        (await rma.history(supplierClaim.id))
            .singleWhere((event) => event.action == 'supplier_fulfilled')
            .condition,
        'new');
    expect(
        (await db.select(db.serialWarrantySnapshots).get())
            .singleWhere((w) => w.sourceRmaCaseId == supplierClaim.id)
            .treatment,
        'unknown');
    final replacement = (await db.select(db.serialUnits).get())
        .singleWhere((unit) => unit.serialNumber == 'SUPPLIER-NEW');
    expect(replacement.status, 'rma');
    expect(await pos.stockMilli(product), 0);
    expect(await rma.nextAction(claim.id),
        'Hand supplier replacement to customer');
    await rma.handoff(actor, claim.id, 'Buyer', serialUnitId: replacement.id);
    final warranty = (await db.select(db.serialWarrantySnapshots).get())
        .singleWhere((w) =>
            w.serialUnitId == replacement.id && w.source == 'legacy_unknown');
    expect(warranty.treatment, 'continue_original');
    expect(warranty.endAt, isNull);
    expect(await rma.nextAction(claim.id), 'Complete');
    expect(
        (await db.select(db.serialUnits).get())
            .singleWhere((unit) => unit.id == replacement.id)
            .status,
        'sold');
    expect(
        (await db.select(db.serialUnits).get())
            .singleWhere((unit) => unit.id == original.id)
            .serialNumber,
        'ORIGINAL');
  });

  test('cash refund completes customer case while supplier recovery stays open',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final actor = auth.current!;
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Vendor');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Board', priceCents: 5000, costCents: 3000, serialTracking: true);
    final receipt =
        await StockReceivingRepository(db).receive(actor, supplier.id, [
      ReceivingLineRequest(product, 1000, 3000, serialNumbers: ['DEFECTIVE'])
    ]);
    final item = (await StockReceivingRepository(db).items(receipt.id)).single;
    final serial =
        (await StockReceivingRepository(db).serialsForItem(item.id)).single;
    await CashSessionRepository(db).open(actor, 0);
    await pos.completeCashSale([
      SaleLineRequest(product, 1, serialIds: [serial.id])
    ], 5000, userId);
    final sold = (await db.select(db.saleItems).get()).single;
    final rma = RmaLifecycleRepository(db);
    final claim =
        await rma.request(actor, sold.id, 'Fault', serialUnitId: serial.id);
    await rma.approve(actor, claim.id);
    await rma.receive(actor, claim.id, 1000, returnedSerial: 'DEFECTIVE');
    await rma.inspect(
        actor, claim.id, 1000, 'Damaged', true, 'Fault reproduced');
    final quote = await SalesRepository(db).quoteItemRefund(claim.id);
    await rma.authorize(actor, claim.id, 'refund', 'supplier',
        amountCents: quote.amountCents, method: 'cash');
    final linked = (await rma.history(claim.id))
        .singleWhere((event) => event.action == 'supplier_claim_opened');
    expect(
        (await db.select(db.rmaCases).get())
            .singleWhere((row) => row.id == linked.relatedCaseId)
            .status,
        'pending');
    await rma.executeRefund(actor, claim.id, payCashNow: true);
    expect(await rma.nextAction(claim.id), 'Complete');
    final supplierClaim = await rma.sendToSupplier(actor, claim.id);
    expect(await rma.nextAction(claim.id), 'Complete');
    expect(await rma.nextAction(supplierClaim.id), 'Record supplier decision');
    expect(
        (await db.select(db.rmaCases).get())
            .singleWhere((e) => e.id == claim.id)
            .status,
        'resolved');
    expect(
        (await db.select(db.rmaCases).get())
            .singleWhere((e) => e.id == supplierClaim.id)
            .status,
        'sent_to_supplier');
  });

  test('direct supplier claim quarantines Receiving stock without a customer',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final actor = auth.current!;
    final supplier =
        await DirectoryRepository(db).saveSupplier(actor, name: 'Vendor');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Board', priceCents: 5000, costCents: 3000, serialTracking: true);
    final receipt =
        await StockReceivingRepository(db).receive(actor, supplier.id, [
      ReceivingLineRequest(product, 2000, 3000,
          serialNumbers: ['DOA-1', 'GOOD-2'])
    ]);
    final item = (await StockReceivingRepository(db).items(receipt.id)).single;
    final serial =
        (await StockReceivingRepository(db).serialsForItem(item.id)).first;
    final lifecycle = RmaLifecycleRepository(db);
    final claim = await lifecycle.requestDirectSupplier(
        actor, item.id, 'Dead on arrival', 'Damaged',
        serialUnitId: serial.id);
    expect(claim.customerId, isNull);
    expect(claim.saleId, isNull);
    expect(await lifecycle.nextAction(claim.id), 'Send to supplier');
    expect(
        (await db.select(db.serialUnits).get())
            .singleWhere((unit) => unit.id == serial.id)
            .status,
        'rma');
    await lifecycle.sendDirectSupplier(actor, claim.id);
    expect(await lifecycle.nextAction(claim.id), 'Record supplier decision');
    expect((await lifecycle.history(claim.id)).map((event) => event.action),
        ['supplier_intake', 'supplier_requested', 'custody_supplier']);
    await lifecycle.supplierDecision(actor, claim.id, 'repair');
    await lifecycle.supplierReturnOriginal(
        actor, claim.id, serial.serialNumber, 'good');
    expect(
        (await db.select(db.serialUnits).get())
            .singleWhere((unit) => unit.id == serial.id)
            .status,
        'rma');
    await lifecycle.supplierReturnedDisposition(actor, claim.id, 'restock');
    expect(
        (await db.select(db.serialUnits).get())
            .singleWhere((unit) => unit.id == serial.id)
            .status,
        'available');
    expect(await pos.stockMilli(product), 2000);
  });

  test('backup preserves open RMA lifecycle facts', () async {
    final dir = await Directory.systemTemp.createTemp('rma-lifecycle-backup-');
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      await db.customStatement(
          "INSERT INTO users (id, name, role) VALUES ('u', 'Owner', 'owner')");
      await db.customStatement(
          "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
          "VALUES ('c', 'RMA-2026-000001', 'customer', 'Fault', '', 1000, 'pending', 0)");
      await db.customStatement(
          "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) "
          "VALUES ('e', 'c', 'u', 'requested', 1000, 0)");
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        expect((await restored.select(restored.rmaCases).get()).single.status,
            'pending');
        expect(
            (await restored.select(restored.rmaLifecycleEvents).get())
                .single
                .action,
            'requested');
      } finally {
        await restored.close();
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('request, approval, partial receipt and inspection are distinct facts',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final actor = auth.current!;
    final directory = DirectoryRepository(db);
    final customer = await directory.saveCustomer(actor, name: 'Buyer');
    final supplier = await directory.saveSupplier(actor, name: 'Vendor');
    final pos = PosRepository(db);
    final product =
        await pos.saveProduct(name: 'Mouse', priceCents: 5000, costCents: 2000);
    await StockReceivingRepository(db).receive(
        actor, supplier.id, [ReceivingLineRequest(product, 3000, 2000)]);
    await pos.completeCreditSale(
        [SaleLineRequest(product, 3)], 0, customer.id, userId);
    final item = (await db.select(db.saleItems).get()).single;
    final lifecycle = RmaLifecycleRepository(db);
    final claim = await lifecycle.request(actor, item.id, 'Stops working',
        quantityMilli: 2000);
    expect(await lifecycle.nextAction(claim.id), 'Approve claim');
    expect(await pos.stockMilli(product), 0);
    await expectLater(
        lifecycle.inspect(
            actor, claim.id, 1000, 'Good', true, 'Fault reproduced'),
        throwsStateError);
    await lifecycle.approve(actor, claim.id);
    expect(await pos.stockMilli(product), 0);
    expect(await lifecycle.nextAction(claim.id), 'Receive returned item');
    await lifecycle.receive(actor, claim.id, 1000);
    expect(await pos.stockMilli(product), 0);
    await expectLater(
        lifecycle.receive(actor, claim.id, 2000), throwsStateError);
    await lifecycle.inspect(
        actor, claim.id, 1000, 'Good', true, 'Fault reproduced');
    await expectLater(
        lifecycle.inspect(actor, claim.id, 1000, 'Good', true, 'Duplicate'),
        throwsStateError);
    expect((await lifecycle.history(claim.id)).map((e) => e.action),
        ['requested', 'approved', 'received', 'custody_store', 'inspected']);
    await expectLater(
        RmaRepository(db).transition(actor, claim.id, 'resolved',
            customerResolution: 'refund', unitDisposition: 'scrap'),
        throwsStateError);
    await lifecycle.receive(actor, claim.id, 1000);
    await lifecycle.inspect(
        actor, claim.id, 1000, 'Damaged', true, 'Second unit defective');
    final quote = await SalesRepository(db).quoteItemRefund(claim.id);
    await lifecycle.authorize(actor, claim.id, 'refund', 'scrap',
        amountCents: quote.amountCents, method: 'obligation');
    expect(await db.select(db.saleItemRefunds).get(), isEmpty);
    expect(await lifecycle.nextAction(claim.id), 'Complete refund');
  });

  test('serialized replacement reservation blocks POS and handoff completes',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final actor = auth.current!;
    final directory = DirectoryRepository(db);
    final customer = await directory.saveCustomer(actor, name: 'Buyer');
    final supplier = await directory.saveSupplier(actor, name: 'Vendor');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Device',
        priceCents: 10000,
        costCents: 5000,
        serialTracking: true);
    final receipt =
        await StockReceivingRepository(db).receive(actor, supplier.id, [
      ReceivingLineRequest(product, 2000, 5000,
          serialNumbers: ['ORIGINAL', 'REPLACEMENT'])
    ]);
    final item = (await StockReceivingRepository(db).items(receipt.id)).single;
    final serials = await StockReceivingRepository(db).serialsForItem(item.id);
    await pos.completeCreditSale([
      SaleLineRequest(product, 1, serialIds: [serials.first.id])
    ], 0, customer.id, userId);
    final sold = (await db.select(db.saleItems).get()).single;
    final rma = RmaLifecycleRepository(db);
    final claim = await rma.request(actor, sold.id, 'Broken',
        serialUnitId: serials.first.id);
    await rma.approve(actor, claim.id);
    await expectLater(
        rma.receive(actor, claim.id, 1000, returnedSerial: 'DIFFERENT'),
        throwsStateError);
    expect(
        (await db.select(db.serialUnits).get())
            .singleWhere((s) => s.id == serials.first.id)
            .status,
        'sold');
    await rma.receive(actor, claim.id, 1000, returnedSerial: 'ORIGINAL');
    expect(await pos.stockMilli(product), 1000);
    await rma.inspect(actor, claim.id, 1000, 'Damaged', true, 'Dead');
    await rma.authorize(actor, claim.id, 'replacement', 'scrap');
    await rma.reserveReplacement(actor, claim.id, serials.last.id);
    expect(await pos.reservedStockMilli(product), 1000);
    await expectLater(
        pos.completeCreditSale([
          SaleLineRequest(product, 1, serialIds: [serials.last.id])
        ], 0, customer.id, userId),
        throwsStateError);
    await rma.releaseReplacement(actor, claim.id);
    expect(await pos.reservedStockMilli(product), 0);
    await rma.reserveReplacement(actor, claim.id, serials.last.id);
    await rma.executeDisposition(actor, claim.id);
    expect(await pos.stockMilli(product), 1000);
    final originalEnd = DateTime.utc(2027, 1, 1);
    await db.customStatement(
        'INSERT INTO serial_warranty_snapshots '
        '(id, serial_unit_id, treatment, source, start_at, end_at, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'original-warranty',
          serials.first.id,
          'custom',
          'original_sale',
          DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000,
          originalEnd.millisecondsSinceEpoch ~/ 1000,
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ]);
    await rma.handoff(actor, claim.id, 'Buyer', serialUnitId: serials.last.id);
    final continued = (await db.select(db.serialWarrantySnapshots).get())
        .singleWhere((w) => w.serialUnitId == serials.last.id);
    expect(continued.treatment, 'continue_original');
    expect(continued.endAt?.year, 2027);
    expect(continued.endAt?.month, 1);
    expect(
        (await db.select(db.serialWarrantySnapshots).get())
            .singleWhere((w) => w.id == 'original-warranty')
            .endAt
            ?.year,
        2027);
    expect(await pos.stockMilli(product), 0);
    expect((await db.select(db.rmaCases).get()).single.status, 'resolved');
    expect(
        (await db.select(db.serialUnits).get())
            .singleWhere((s) => s.id == serials.last.id)
            .status,
        'sold');
    expect(await rma.nextAction(claim.id), 'Complete');
  });

  test('supplier decision and credit fulfillment stay separate from customer',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final actor = auth.current!;
    final supplier = await DirectoryRepository(db)
        .saveSupplier(actor, name: 'Actual supplier');
    final customer =
        await DirectoryRepository(db).saveCustomer(actor, name: 'Buyer');
    final pos = PosRepository(db);
    final product = await pos.saveProduct(
        name: 'Device',
        priceCents: 10000,
        costCents: 5000,
        serialTracking: true);
    final receipt =
        await StockReceivingRepository(db).receive(actor, supplier.id, [
      ReceivingLineRequest(product, 1000, 5000, serialNumbers: ['SUP-1'])
    ]);
    final item = (await StockReceivingRepository(db).items(receipt.id)).single;
    final serial =
        (await StockReceivingRepository(db).serialsForItem(item.id)).single;
    await pos.completeCreditSale([
      SaleLineRequest(product, 1, serialIds: [serial.id])
    ], 0, customer.id, userId);
    final sold = (await db.select(db.saleItems).get()).single;
    final rma = RmaLifecycleRepository(db);
    final claim =
        await rma.request(actor, sold.id, 'Fault', serialUnitId: serial.id);
    await rma.approve(actor, claim.id);
    await rma.receive(actor, claim.id, 1000, returnedSerial: 'SUP-1');
    await rma.inspect(actor, claim.id, 1000, 'Damaged', true, 'Fault');
    await rma.authorize(actor, claim.id, 'replacement', 'supplier');
    final supplierClaim = await rma.sendToSupplier(actor, claim.id);
    expect(supplierClaim.supplierId, supplier.id);
    expect(await rma.nextAction(supplierClaim.id), 'Record supplier decision');
    await rma.supplierDecision(actor, supplierClaim.id, 'credit');
    expect(
        (await db.select(db.rmaCases).get())
            .singleWhere((c) => c.id == claim.id)
            .status,
        'pending');
    await rma.supplierCredit(actor, supplierClaim.id, 5000, 'CM-1');
    expect(await rma.nextAction(supplierClaim.id), 'Complete');
    expect(
        (await db.select(db.rmaCases).get())
            .singleWhere((c) => c.id == supplierClaim.id)
            .status,
        'resolved');
    expect(
        (await db.select(db.rmaCases).get())
            .singleWhere((c) => c.id == claim.id)
            .status,
        'pending');
  });
}
