import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/sale_service.dart';
import 'package:modern_offline_pos/core/services/sales_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;
  late PosRepository pos;
  late SalesService sales;
  late String ownerId;
  late DateTime clock;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    clock = DateTime.now();
    auth = AuthService(AuthRepository(db), clock: () => clock);
    pos = PosRepository(db);
    sales = SalesService(SalesRepository(db), auth);
    ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Favorite place?', '  Baguio  ');
    await auth.login(ownerId, 'ownerPassword123');
  });
  tearDown(() => db.close());

  Future<String> sell(String userId, int productPrice,
      {int stock = 5, int threshold = 1}) async {
    final productId = await pos.saveProduct(
        name: 'Item ${DateTime.now().microsecondsSinceEpoch}',
        priceCents: productPrice,
        costCents: 100,
        startingStock: stock,
        lowStockThreshold: threshold);
    final cart = Cart()
      ..add((await pos.products()).firstWhere((p) => p.id == productId));
    final result = await SaleService(pos, auth).checkout(cart, productPrice);
    expect((await db.select(db.sales).get()).last.cashierId, userId);
    return result.saleId;
  }

  test('credentials hashed, cashier PIN, privileged password, logout and swap',
      () async {
    final cashierId =
        await auth.createUser('Cashier', UserRole.cashier, '1234');
    final managerId =
        await auth.createUser('Manager', UserRole.manager, 'managerPassword');
    final owner = await auth.repository.user(ownerId);
    final cashier = await auth.repository.user(cashierId);
    final manager = await auth.repository.user(managerId);
    expect(owner!.passwordHash, isNot('ownerPassword123'));
    expect(owner.recoveryAnswerHash, isNot('baguio'));
    expect(cashier!.pinHash, isNot('1234'));
    expect(manager!.passwordHash, isNot('managerPassword'));
    expect(cashier.passwordHash, isNull);
    await auth.logout();
    expect(auth.current, isNull);
    await expectLater(auth.login(cashierId, '0000'), throwsStateError);
    expect((await auth.repository.user(cashierId))!.failedAttempts, 1);
    await auth.login(cashierId, '1234');
    expect(auth.current!.role, UserRole.cashier);
    await auth.lock();
    expect(auth.current, isNull);
    await expectLater(auth.login(managerId, 'wrongPassword'), throwsStateError);
    await auth.login(managerId, 'managerPassword');
    expect(auth.current!.role, UserRole.manager);
    final actions = (await db.select(db.auditLogs).get()).map((a) => a.action);
    expect(
        actions,
        containsAll([
          'login_success',
          'login_failed',
          'logout',
          'register_locked',
          'user_created'
        ]));
    expect(
        (await db.select(db.auditLogs).get())
            .every((a) => !(a.details ?? '').contains('1234')),
        true);
  });

  test('temporary lockout expires on injected clock; recovery resets password',
      () async {
    await auth.logout();
    for (var i = 0; i < AuthService.maxAttempts; i++) {
      await expectLater(auth.login(ownerId, 'wrong'), throwsStateError);
    }
    expect((await auth.repository.user(ownerId))!.failedAttempts,
        AuthService.maxAttempts);
    await expectLater(
        auth.login(ownerId, 'ownerPassword123'), throwsStateError);
    clock = clock.add(AuthService.lockDuration).add(const Duration(seconds: 1));
    await auth.login(ownerId, 'ownerPassword123');
    await auth.logout();
    await expectLater(
        auth.recover(ownerId, 'wrong', 'newPassword123'), throwsStateError);
    await auth.recover(ownerId, ' BAGUIO ', 'newPassword123');
    await expectLater(
        auth.login(ownerId, 'ownerPassword123'), throwsStateError);
    await auth.login(ownerId, 'newPassword123');
    expect((await auth.repository.user(ownerId))!.passwordHash,
        isNot('newPassword123'));
  });

  test('cashier sees own sales and cannot reverse, report or manage users',
      () async {
    final cashierId =
        await auth.createUser('Cashier', UserRole.cashier, '1234');
    final ownerSale = await sell(ownerId, 4000);
    await auth.logout();
    await auth.login(cashierId, '1234');
    final cashierSale = await sell(cashierId, 3000);
    final visible = await sales.history();
    expect(visible.map((s) => s.sale.id), [cashierSale]);
    await expectLater(sales.detail(ownerSale), throwsStateError);
    expect(() => sales.voidSale(cashierSale), throwsStateError);
    expect(() => sales.refundSale(cashierSale, returnToSellableStock: true),
        throwsStateError);
    expect(() => sales.report(clock), throwsStateError);
    await expectLater(
        auth.createUser('Other', UserRole.cashier, '5555'), throwsStateError);
    await auth.logout();
    await auth.login(ownerId, 'ownerPassword123');
    expect((await sales.history()).length, 2);
    expect((await sales.detail(cashierSale)).items.single.unitPriceCents, 3000);
  });

  test('void restores stock once, retains history, audits actor', () async {
    final managerId =
        await auth.createUser('Manager', UserRole.manager, 'managerPassword');
    final saleId = await sell(ownerId, 4000, stock: 2);
    final productId = (await db.select(db.saleItems).get()).single.productId;
    await auth.logout();
    await auth.login(managerId, 'managerPassword');
    await sales.voidSale(saleId);
    expect((await db.select(db.sales).get()).single.status, 'voided');
    expect((await db.select(db.saleReversals).get()).single.kind, 'void');
    expect(
        (await db.select(db.saleReversals).get()).single.stockRestored, true);
    expect((await db.select(db.saleItems).get()).length, 1);
    expect((await db.select(db.payments).get()).length, 1);
    expect(await pos.stock(productId), 2);
    expect((await pos.movements(productId)).map((m) => m.quantityDelta),
        containsAll([2, -1, 1]));
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'sale_voided')
            .single
            .userId,
        managerId);
    await expectLater(sales.voidSale(saleId), throwsStateError);
    await expectLater(sales.refundSale(saleId, returnToSellableStock: false),
        throwsStateError);
  });

  test('full refund restores stock and prevents duplicate reversal', () async {
    final saleId = await sell(ownerId, 4000, stock: 2);
    final productId = (await db.select(db.saleItems).get()).single.productId;
    await sales.refundSale(saleId, returnToSellableStock: true);
    expect((await db.select(db.sales).get()).single.status, 'refunded');
    final reversal = (await db.select(db.saleReversals).get()).single;
    expect(reversal.kind, 'refund');
    expect(reversal.amountCents, 4000);
    expect(reversal.actorId, ownerId);
    expect(reversal.stockRestored, true);
    expect(await pos.stock(productId), 2);
    expect((await pos.movements(productId)).last.reason, 'refund');
    expect(
        (await db.select(db.auditLogs).get())
            .any((a) => a.action == 'sale_refunded'),
        true);
    await expectLater(sales.refundSale(saleId, returnToSellableStock: false),
        throwsStateError);
    await expectLater(sales.voidSale(saleId), throwsStateError);
  });

  test('full refund without restock leaves sellable stock unchanged', () async {
    final saleId = await sell(ownerId, 4000, stock: 2);
    final productId = (await db.select(db.saleItems).get()).single.productId;
    await sales.refundSale(saleId, returnToSellableStock: false);
    expect((await db.select(db.sales).get()).single.status, 'refunded');
    expect(
        (await db.select(db.saleReversals).get()).single.stockRestored, false);
    expect(await pos.stock(productId), 1);
    expect((await pos.movements(productId)).length, 2);
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'sale_refunded'),
        hasLength(1));
    await expectLater(sales.refundSale(saleId, returnToSellableStock: true),
        throwsStateError);
    await expectLater(sales.voidSale(saleId), throwsStateError);
  });

  for (final caseName in [
    'void',
    'refund with restock',
    'refund without restock'
  ]) {
    test('$caseName failure rolls back status, stock, movement and event',
        () async {
      final isVoid = caseName == 'void';
      final saleId = await sell(ownerId, 4000, stock: 2);
      final productId = (await db.select(db.saleItems).get()).single.productId;
      await db.customStatement(
          "CREATE TRIGGER fail_reversal BEFORE INSERT ON audit_logs WHEN NEW.action = 'sale_${isVoid ? 'voided' : 'refunded'}' BEGIN SELECT RAISE(ABORT, 'forced failure'); END");
      await expectLater(
          isVoid
              ? sales.voidSale(saleId)
              : sales.refundSale(saleId,
                  returnToSellableStock: caseName == 'refund with restock'),
          throwsException);
      expect((await db.select(db.sales).get()).single.status, 'completed');
      expect(await db.select(db.saleReversals).get(), isEmpty);
      expect(await pos.stock(productId), 1);
      expect((await pos.movements(productId)).length, 2);
    });
  }

  test(
      'reports count completed sales and cash, exclude reversals, show low stock',
      () async {
    final first = await sell(ownerId, 4000, stock: 2, threshold: 1);
    await sell(ownerId, 3000, stock: 3, threshold: 1);
    await pos.saveProduct(
        name: 'Low item',
        priceCents: 1000,
        costCents: 100,
        startingStock: 1,
        lowStockThreshold: 1);
    await sales.voidSale(first);
    final report = await sales.report(clock);
    expect(report.completedCount, 1);
    expect(report.grossCents, 7000);
    expect(report.reversalCents, 4000);
    expect(report.netCents, 3000);
    expect(report.paymentBreakdown['cash'], 3000);
    expect(report.lowStock, contains(('Low item', 1)));
  });

  test('deactivation blocks login but preserves historical user and sale',
      () async {
    final cashierId =
        await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.logout();
    await auth.login(cashierId, '1234');
    final saleId = await sell(cashierId, 4000);
    await auth.logout();
    await auth.login(ownerId, 'ownerPassword123');
    await auth.setActive(cashierId, false);
    await expectLater(auth.login(cashierId, '1234'), throwsStateError);
    expect((await sales.detail(saleId)).summary.cashierName, 'Cashier');
    expect((await db.select(db.sales).get()).single.cashierId, cashierId);
  });

  test('full shift: lock, cashier login, sell, logout, owner void', () async {
    final cashierId =
        await auth.createUser('Shift cashier', UserRole.cashier, '4567');
    await auth.lock();
    await auth.login(cashierId, '4567');
    final saleId = await sell(cashierId, 5000, stock: 3);
    expect((await sales.history()).single.sale.id, saleId);
    await auth.logout();
    expect(auth.current, isNull);
    final cart = Cart()..add((await pos.products()).single);
    await expectLater(
        SaleService(pos, auth).checkout(cart, 5000), throwsStateError);
    expect(cart.isEmpty, false);
    await auth.login(ownerId, 'ownerPassword123');
    await sales.voidSale(saleId);
    expect((await db.select(db.sales).get()).single.status, 'voided');
    expect((await db.select(db.saleItems).get()).single.quantity, 1);
    expect((await db.select(db.payments).get()).single.amountCents, 5000);
    await auth.logout();
    expect(auth.current, isNull);
  });

  test('manager may void an older completed sale', () async {
    final managerId =
        await auth.createUser('Manager', UserRole.manager, 'managerPassword');
    final saleId = await sell(ownerId, 4000);
    final item = (await db.select(db.saleItems).get()).single;
    await (db.update(db.sales)..where((s) => s.id.equals(saleId))).write(
        SalesCompanion(
            createdAt:
                Value(DateTime.now().subtract(const Duration(days: 30)))));
    await auth.logout();
    await auth.login(managerId, 'managerPassword');
    expect((await sales.report(clock)).netCents, 0);
    clock = clock.add(const Duration(days: 2));
    await sales.voidSale(saleId);
    expect((await db.select(db.sales).get()).single.status, 'voided');
    expect((await db.select(db.saleReversals).get()).single.kind, 'void');
    expect(await pos.stock(item.productId), 5);
    expect((await pos.movements(item.productId)).last.quantityDelta, 1);
    expect(
        (await db.select(db.auditLogs).get())
            .where((a) => a.action == 'sale_voided'),
        hasLength(1));
  });

  test('failed privileged user write rolls back account creation', () async {
    final before = (await auth.repository.allUsers()).length;
    await db.customStatement(
        "CREATE TRIGGER fail_user_audit BEFORE INSERT ON audit_logs WHEN NEW.action = 'user_created' BEGIN SELECT RAISE(ABORT, 'forced failure'); END");
    await expectLater(auth.createUser('Would fail', UserRole.cashier, '5678'),
        throwsException);
    expect((await auth.repository.allUsers()).length, before);
  });
}
