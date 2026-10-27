import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/sale_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/loyalty_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/sale_return_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/daos/sale_lifecycle_repository.dart';
import 'package:modern_offline_pos/data/daos/management_report_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';

void main() {
  late AppDatabase db;
  late PosRepository pos;
  late AuthService auth;
  late LoyaltyRepository loyalty;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    pos = PosRepository(db);
    auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'answer');
    await auth.login(id, 'password123');
    loyalty = LoyaltyRepository(db);
    await pos.saveProduct(
        name: 'Item', priceCents: 25000, costCents: 10000, startingStock: 8);
  });
  tearDown(() => db.close());

  test('customer earns floor points atomically with sale snapshot', () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    final product = (await pos.products()).single;
    final result = await SaleService(pos, auth)
        .checkout(Cart()..add(product), 25000, customerId: customer.id);
    expect(await loyalty.balance(customer.id), 2);
    final sale = await db.customSelect(
        'SELECT * FROM sale_loyalty WHERE sale_id=?',
        variables: [Variable.withString(result.saleId)]).getSingle();
    expect(sale.read<int>('eligible_cents'), 25000);
    expect(sale.read<int>('spend_per_point_cents'), 10000);
    expect(sale.read<int>('earned_points'), 2);
    expect((await loyalty.entries(customer.id)).single.kind, 'earn');
  });

  test('anonymous and disabled sales do not earn', () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    final product = (await pos.products()).single;
    await SaleService(pos, auth).checkout(Cart()..add(product), 25000);
    await loyalty.updateSettings(
        auth.current!.id, const LoyaltySettings(false, 10000, 100, 1000));
    await SaleService(pos, auth)
        .checkout(Cart()..add(product), 25000, customerId: customer.id);
    expect(await loyalty.balance(customer.id), 0);
  });

  test('redemption uses snapshot and refuses excess balance', () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    await loyalty.adjust(customer.id, auth.current!.id, 110, 'Test reward');
    final product = (await pos.products()).single;
    final sale = await SaleService(pos, auth).checkout(
        Cart()..add(product), 24000,
        customerId: customer.id, redeemPoints: 100, rewardDiscountCents: 1000);
    expect(sale.totalCents, 24000);
    expect(await loyalty.balance(customer.id), 12);
    await loyalty.updateSettings(
        auth.current!.id, const LoyaltySettings(true, 20000, 200, 3000));
    final snapshot = await db.customSelect(
        'SELECT * FROM sale_loyalty WHERE sale_id=?',
        variables: [Variable.withString(sale.saleId)]).getSingle();
    expect(snapshot.read<int>('redeemed_points'), 100);
    expect(snapshot.read<int>('discount_cents'), 1000);
    expect(snapshot.read<int>('redeem_unit_points'), 100);
    await expectLater(
        SaleService(pos, auth).checkout(Cart()..add(product), 22000,
            customerId: customer.id,
            redeemPoints: 200,
            rewardDiscountCents: 3000),
        throwsStateError);
    expect(await loyalty.balance(customer.id), 12);
  });

  test('partial return reverses cumulative attributable earned points',
      () async {
    await CashSessionRepository(db).open(auth.current!, 100000);
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    final product = (await pos.products()).single;
    final sale = await SaleService(pos, auth).checkout(
        Cart()
          ..add(product)
          ..add(product)
          ..add(product)
          ..add(product),
        100000,
        customerId: customer.id);
    expect(await loyalty.balance(customer.id), 10);
    final item = (await db.select(db.saleItems).get()).single;
    final returns = SaleReturnRepository(db);
    await returns.finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 1000, sellable: true)],
        reason: 'Customer changed mind');
    expect(await loyalty.balance(customer.id), 8);
    expect(
        (await loyalty.entries(customer.id))
            .where((e) => e.kind == 'return_reversal')
            .single
            .points,
        -2);
  });

  test('legitimate return can leave an auditable negative balance', () async {
    await CashSessionRepository(db).open(auth.current!, 100000);
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    final product = (await pos.products()).single;
    final sale = await SaleService(pos, auth)
        .checkout(Cart()..add(product), 25000, customerId: customer.id);
    await loyalty.adjust(customer.id, auth.current!.id, -2, 'Used reward');
    final item = (await db.select(db.saleItems).get()).single;
    await SaleReturnRepository(db).finalize(auth.current!, sale.saleId,
        [ReturnSelection(item.id, 1000, sellable: true)],
        reason: 'Customer changed mind');
    expect(await loyalty.balance(customer.id), -2);
    expect((await loyalty.entries(customer.id)).last.kind, 'earn');
  });

  test('full void appends earn reversal and redemption restoration', () async {
    await CashSessionRepository(db).open(auth.current!, 100000);
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    await loyalty.adjust(customer.id, auth.current!.id, 110, 'Test reward');
    final product = (await pos.products()).single;
    final sale = await SaleService(pos, auth).checkout(
        Cart()..add(product), 24000,
        customerId: customer.id, redeemPoints: 100, rewardDiscountCents: 1000);
    expect(await loyalty.balance(customer.id), 12);
    await SalesRepository(db).reverse(auth.current!, sale.saleId, 'void',
        stockRestored: true, cashRefundConfirmed: true);
    expect(await loyalty.balance(customer.id), 110);
    expect(
        (await loyalty.entries(customer.id))
            .where((e) => e.kind == 'sale_restore')
            .single
            .points,
        100);
  });

  test('even exchange reverses old points and earns replacement once',
      () async {
    await CashSessionRepository(db).open(auth.current!, 100000);
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    final product = (await pos.products()).single;
    final sale = await SaleService(pos, auth)
        .checkout(Cart()..add(product), 25000, customerId: customer.id);
    final item = (await db.select(db.saleItems).get()).single;
    await SaleReturnRepository(db).exchange(
        auth.current!,
        sale.saleId,
        [ReturnSelection(item.id, 1000, sellable: true)],
        [SaleLineRequest(product.id, 1)],
        pos,
        reason: 'Exchange',
        cashTenderedCents: 0);
    expect(await loyalty.balance(customer.id), 2);
    final entries = await loyalty.entries(customer.id);
    expect(entries.where((e) => e.kind == 'earn').length, 2);
    expect(entries.where((e) => e.kind == 'return_reversal').single.points, -2);
  });

  test('redeemed return reduces cash refund and restores proportional points',
      () async {
    await CashSessionRepository(db).open(auth.current!, 100000);
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    await loyalty.adjust(customer.id, auth.current!.id, 110, 'Test reward');
    final product = (await pos.products()).single;
    final sale = await SaleService(pos, auth).checkout(
        Cart()
          ..add(product)
          ..add(product),
        49000,
        customerId: customer.id,
        redeemPoints: 100,
        rewardDiscountCents: 1000);
    final item = (await db.select(db.saleItems).get()).single;
    final result = await SaleReturnRepository(db).finalize(auth.current!,
        sale.saleId, [ReturnSelection(item.id, 1000, sellable: true)],
        reason: 'Customer changed mind');
    expect(result.refundValueCents, 24500);
    final retained =
        (await SaleLifecycleRepository(db).summaries())[sale.saleId]!
            .netRetained(49000);
    final report = await ManagementReportRepository(db)
        .load(ReportPeriod.named('Today', DateTime.now()));
    expect(report.refundsCents, result.refundValueCents);
    expect(report.netSalesCents, retained);
    expect(await loyalty.balance(customer.id), 62);
    expect(
        (await loyalty.entries(customer.id))
            .where((e) => e.kind == 'return_restore')
            .single
            .points,
        50);
  });

  test('manual points require reason and cannot overdraw', () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    await expectLater(loyalty.adjust(customer.id, auth.current!.id, 10, ''),
        throwsArgumentError);
    await loyalty.adjust(customer.id, auth.current!.id, 10, 'Test reward');
    await loyalty.adjust(customer.id, auth.current!.id, -3, 'Correction');
    expect(await loyalty.balance(customer.id), 7);
    await expectLater(
        loyalty.adjust(customer.id, auth.current!.id, -8, 'Correction'),
        throwsStateError);
    expect((await loyalty.entries(customer.id)).length, 2);
    expect(
        (await db.select(db.auditLogs).get())
            .where((row) => row.action == 'loyalty.adjust')
            .length,
        2);
    final cashierId = await AuthRepository(db).createUser(
        actorId: auth.current!.id,
        name: 'Cashier',
        role: UserRole.cashier,
        hash: 'test');
    await expectLater(loyalty.adjust(customer.id, cashierId, 10, 'Forbidden'),
        throwsStateError);
    expect(await loyalty.balance(customer.id), 7);
  });

  test('ledger rows cannot be updated or deleted', () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    await loyalty.adjust(customer.id, auth.current!.id, 5, 'Test reward');
    await expectLater(
        db.customStatement(
            'UPDATE loyalty_ledger SET points_delta=99 WHERE customer_id=?',
            [customer.id]),
        throwsA(isA<Exception>()));
    await expectLater(
        db.customStatement(
            'DELETE FROM loyalty_ledger WHERE customer_id=?', [customer.id]),
        throwsA(isA<Exception>()));
    expect(await loyalty.balance(customer.id), 5);
  });

  test('groups default to Retail and settings reject zero', () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    expect(await loyalty.group(customer.id), 'Retail');
    await loyalty.setGroup(customer.id, auth.current!.id, 'VIP');
    expect(await loyalty.group(customer.id), 'VIP');
    await expectLater(
        loyalty.updateSettings(
            auth.current!.id, const LoyaltySettings(true, 0, 100, 1000)),
        throwsArgumentError);
    expect((await loyalty.settings()).spendPerPointCents, 10000);
  });

  test('backup keeps ledger, group, settings and customer references',
      () async {
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    await loyalty.adjust(customer.id, auth.current!.id, 17, 'Test reward');
    await loyalty.setGroup(customer.id, auth.current!.id, 'VIP');
    await loyalty.updateSettings(
        auth.current!.id, const LoyaltySettings(true, 5000, 50, 1000));
    final dir = await Directory.systemTemp.createTemp('loyalty-backup-');
    try {
      final backup = await BackupService(db, dir).create(BackupKind.manual);
      expect(BackupService.verify(backup.file), db.schemaVersion);
      await db.close();
      final restored = AppDatabase.forTesting(NativeDatabase(backup.file));
      try {
        final restoredLoyalty = LoyaltyRepository(restored);
        expect(await restoredLoyalty.balance(customer.id), 17);
        expect(await restoredLoyalty.group(customer.id), 'VIP');
        expect((await restoredLoyalty.settings()).redeemPoints, 50);
        expect((await restored.select(restored.customers).get()).single.id,
            customer.id);
      } finally {
        await restored.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
