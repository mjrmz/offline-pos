import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/models/manual_discount.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/held_sale_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/loyalty_repository.dart';
import 'package:modern_offline_pos/backup/backup_service.dart';

void main() {
  test('held sales persist across restart without reserving stock', () async {
    final dir = await Directory.systemTemp.createTemp('pos-holds-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}pos.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(() => db.close());
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final productId = await pos.saveProduct(
        name: 'Cable', priceCents: 10000, costCents: 5000, startingStock: 5);
    final product =
        (await pos.products()).singleWhere((p) => p.id == productId);
    final cart = Cart()..add(product);
    final repository = HeldSaleRepository(db);
    final first = await repository.hold(auth.current!, cart,
        label: 'Juan', walkInName: 'Juan', walkInContact: '0917 123 4567');
    final second = await repository.hold(auth.current!, cart, label: 'Queue 2');
    expect(first.reference, 'HOLD-000001');
    expect(second.reference, 'HOLD-000002');
    expect((await pos.stockLevels())[productId]!.$1, 5000);
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.payments).get(), isEmpty);
    await db.close();

    db = AppDatabase.forTesting(NativeDatabase(file));
    final reopened = HeldSaleRepository(db);
    final rows = await reopened.all(ActiveUser(owner, 'Owner', UserRole.owner));
    expect(rows, hasLength(2));
    final snapshot = HeldSaleSnapshot.fromRow(
        rows.singleWhere((row) => row.reference == first.reference));
    expect(snapshot.lines.single['productId'], productId);
    expect(snapshot.walkInName, 'Juan');
    expect(snapshot.walkInContact, '0917 123 4567');
    expect((await PosRepository(db).stockLevels())[productId]!.$1, 5000);
    final backup = await BackupService(db, dir).create(BackupKind.manual);
    expect(BackupService.verify(backup.file), 46);
    await reopened.remove(
        ActiveUser(owner, 'Owner', UserRole.owner), rows.first.id,
        discard: true);
    expect(await reopened.all(ActiveUser(owner, 'Owner', UserRole.owner)),
        hasLength(1));
    await db.close();
  });

  test(
      'cashier needs manager password and discount is committed as sale snapshot',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final manager =
        await auth.createUser('Manager', UserRole.manager, 'managerpassword');
    final cashier = await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.login(cashier, '1234');
    await expectLater(
        auth.authorizeDiscount(cashier, '1234'), throwsStateError);
    await expectLater(
        auth.authorizeDiscount(manager, 'wrong'), throwsStateError);
    final approver = await auth.authorizeDiscount(manager, 'managerpassword');
    expect(approver.role, UserRole.manager);
    final customer = await DirectoryRepository(db).quickCreateCustomer(
        auth.current!,
        name: 'Moira',
        phone: '0917 000 0000');
    expect(customer.phone, '0917 000 0000');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Mouse', priceCents: 10000, costCents: 5000, startingStock: 2);
    final discount = ManualDiscount(
        scope: 'line',
        kind: 'percent',
        lineKey: 'mouse-line',
        value: 10,
        reason: 'Manager courtesy',
        requestedBy: cashier,
        authorizedBy: manager,
        authorizedAt: DateTime.now(),
        approvedBasisCents: 10000);
    final result = await pos.completeCashSale(
        [SaleLineRequest(id, 1, lineKey: 'mouse-line')], 10000, cashier,
        manualDiscount: discount,
        walkInName: 'Juan',
        walkInContact: '0917 123 4567',
        heldReference: 'HOLD-000001');
    expect(result.totalCents, 9000);
    final sale = (await db.select(db.sales).get()).single;
    expect(sale.customerId, isNull);
    expect(sale.walkInName, 'Juan');
    expect(sale.walkInContact, '0917 123 4567');
    expect(sale.heldReference, 'HOLD-000001');
    final line = (await db.select(db.saleItems).get()).single;
    expect(line.lineTotalCents, 9000);
    expect(line.manualDiscountCents, 1000);
    final saved = (await db.select(db.saleManualDiscounts).get()).single;
    expect(saved.authorizedBy, manager);
    expect(saved.reason, 'Manager courtesy');
    expect(saved.effectCents, 1000);
    expect(await db.select(db.customers).get(), hasLength(1));
    await expectLater(
        pos.completeCashSale(
            [SaleLineRequest(id, 1, lineKey: 'mouse-line')], 10000, cashier,
            manualDiscount: ManualDiscount(
                scope: 'order',
                kind: 'fixed',
                value: 100,
                reason: 'Price match',
                requestedBy: cashier,
                authorizedBy: cashier,
                authorizedAt: DateTime.now(),
                approvedBasisCents: 10000)),
        throwsStateError);
  });

  test('fixed order discount reduces loyalty eligible spend and rejects excess',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final customer = await DirectoryRepository(db)
        .quickCreateCustomer(auth.current!, name: 'Moira');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Keyboard', priceCents: 20000, costCents: 8000, startingStock: 2);
    final discount = ManualDiscount(
        scope: 'order',
        kind: 'fixed',
        value: 5000,
        reason: 'Price match',
        requestedBy: owner,
        authorizedBy: owner,
        authorizedAt: DateTime.now(),
        approvedBasisCents: 20000);
    final result = await pos.completeCashSale(
        [SaleLineRequest(id, 1, lineKey: id)], 15000, owner,
        customerId: customer.id, manualDiscount: discount);
    expect(result.totalCents, 15000);
    expect(await LoyaltyRepository(db).balance(customer.id), 1);
    expect(
        (await db.select(db.saleItems).get()).single.manualDiscountCents, 5000);
    await expectLater(
        pos.completeCashSale(
            [SaleLineRequest(id, 1, lineKey: id)], 20000, owner,
            manualDiscount: ManualDiscount(
                scope: 'order',
                kind: 'fixed',
                value: 25000,
                reason: 'Price match',
                requestedBy: owner,
                authorizedBy: owner,
                authorizedAt: DateTime.now(),
                approvedBasisCents: 20000)),
        throwsStateError);
    expect(await db.select(db.sales).get(), hasLength(1));
    final free = await pos.completeCashSale(
        [SaleLineRequest(id, 1, lineKey: id)], 0, owner,
        manualDiscount: ManualDiscount(
            scope: 'order',
            kind: 'percent',
            value: 100,
            reason: 'Manager courtesy',
            requestedBy: owner,
            authorizedBy: owner,
            authorizedAt: DateTime.now(),
            approvedBasisCents: 20000));
    expect(free.totalCents, 0);
    expect((await db.select(db.payments).get()).last.amountCents, 0);
  });

  test('walk-in identity snapshots do not create customers or loyalty accounts',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'Pen', priceCents: 1000, costCents: 300, startingStock: 3);
    await pos.completeCashSale([SaleLineRequest(id, 1)], 1000, owner,
        walkInName: 'Juan');
    await pos.completeCashSale([SaleLineRequest(id, 1)], 1000, owner,
        walkInContact: '0917 123 4567');
    await pos.completeCashSale([SaleLineRequest(id, 1)], 1000, owner);
    final sales = await db.select(db.sales).get();
    expect(sales[0].walkInName, 'Juan');
    expect(sales[0].walkInContact, isNull);
    expect(sales[1].walkInName, isNull);
    expect(sales[1].walkInContact, '0917 123 4567');
    expect(sales[2].walkInName, isNull);
    expect(sales[2].walkInContact, isNull);
    expect(await db.select(db.customers).get(), isEmpty);
    final ledger = await db.customSelect('SELECT * FROM loyalty_ledger').get();
    expect(ledger, isEmpty);
  });
}
