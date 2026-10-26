import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/supplier_payables_repository.dart';
import 'package:modern_offline_pos/data/daos/inventory_health_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/features/dashboard/dashboard_repository.dart';
import 'package:modern_offline_pos/features/dashboard/dashboard_screen.dart';

class _FixedDashboardRepository extends DashboardRepository {
  final DashboardSnapshot fixed;
  const _FixedDashboardRepository(super.db, this.fixed);
  @override
  Future<DashboardSnapshot> load(ActiveUser user) async => fixed;
}

const _busySnapshot = DashboardSnapshot(
    salesCents: 2458000,
    transactions: 18,
    heldSales: 2,
    receivablesCents: 1583200,
    payablesCents: 823000,
    outOfStock: 2,
    lowStock: 5,
    nearExpiry: 3,
    openSalesOrders: 7,
    failedDeliveries: 1,
    openPurchaseOrders: 4,
    openRmas: 2,
    pendingHandovers: 1);

void main() {
  test('receivables use customer credit entry balances', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO customers(id,name,created_at) VALUES ('c','Customer',?)",
        [now]);
    for (final (id, amount) in [('credit', 2000), ('payment', -500)]) {
      await db.customStatement('''INSERT INTO customer_credit_entries
        (id,customer_id,user_id,amount_cents,kind,created_at)
        VALUES (?,'c',?,?,?,?)''', [id, ownerId, amount, id, now]);
    }
    expect(await CustomerCreditRepository(db).totalOutstanding(), 1500);
  });

  test('completed sales summary scopes to own sales and excludes voids',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId = await auth.bootstrap(
        'Owner', 'ownerPassword123', 'Question?', 'answer');
    await auth.login(ownerId, 'ownerPassword123');
    final cashierId = await auth.createUser('Alex', UserRole.cashier, '1234');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final (id, actor, amount, status) in [
      ('a', cashierId, 1200, 'completed'),
      ('b', ownerId, 3400, 'completed'),
      ('c', cashierId, 500, 'voided'),
    ]) {
      await db.customStatement('''INSERT INTO sales
        (id,cashier_id,total_cents,status,created_at)
        VALUES (?,?,?,?,?)''', [id, actor, amount, status, now]);
    }
    final own = ActiveUser(cashierId, 'Alex', UserRole.custom, true, 'own',
        {PosPermission.viewOwnSales});
    final all = ActiveUser(ownerId, 'Owner', UserRole.custom, true, 'all',
        {PosPermission.viewOwnSales, PosPermission.viewAllSales});
    final ownSummary = await DashboardRepository(db).load(own);
    final allSummary = await DashboardRepository(db).load(all);
    expect(ownSummary.salesCents, 1200);
    expect(ownSummary.transactions, 1);
    expect(allSummary.salesCents, 4600);
    expect(allSummary.transactions, 2);
  });

  test('near expiry counts remaining batch groups from Inventory Health',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 26);
    final expiry =
        now.add(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000;
    final received = now.millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO products(id,name,price_cents,created_at) VALUES ('p','Milk',100,?)",
        [received]);
    for (final id in ['a', 'b']) {
      await db.customStatement('''INSERT INTO inventory_layers
        (id,product_id,quantity_received_milli,quantity_remaining_milli,
         unit_cost_cents,batch_number,expiry_date,received_at)
         VALUES (?, 'p', 1000, 1000, 50, 'batch-1', ?, ?)''',
          [id, expiry, received]);
    }
    for (final (id, batch, date, remaining) in [
      ('expired', 'B2', now.subtract(const Duration(days: 1)), 1000),
      ('later', 'B3', now.add(const Duration(days: 365)), 1000),
      ('empty', 'B4', now.add(const Duration(days: 3)), 0),
    ]) {
      await db.customStatement('''INSERT INTO inventory_layers
        (id,product_id,quantity_received_milli,quantity_remaining_milli,
         unit_cost_cents,batch_number,expiry_date,received_at)
         VALUES (?, 'p', 1000, ?, 50, ?, ?, ?)''', [
        id,
        remaining,
        batch,
        date.millisecondsSinceEpoch ~/ 1000,
        received
      ]);
    }
    expect(await InventoryHealthRepository(db).nearExpiryCount(now: now), 1);
  });

  test('full access snapshot reads available operational summaries', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final user = ActiveUser('owner', 'Owner', UserRole.owner);
    final result = await DashboardRepository(db).load(user);
    expect(result.salesCents, 0);
    expect(result.receivablesCents, 0);
    expect(result.payablesCents, 0);
    expect(result.openSalesOrders, 0);
    expect(result.openRmas, 0);
  });

  test('payable summary uses supplier payable balances', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await SupplierPayablesRepository(db).totalOutstanding(), 0);
  });

  test('restricted snapshot omits sales, credit and held sale queries',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final user = ActiveUser('limited', 'Limited', UserRole.custom, true,
        'limited', {PosPermission.stockCount});
    final result = await DashboardRepository(db).load(user);
    expect(result.salesCents, isNull);
    expect(result.transactions, isNull);
    expect(result.heldSales, isNull);
    expect(result.receivablesCents, isNull);
  });

  testWidgets(
      'inventory focused home has useful actions without financial data',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final user = ActiveUser('limited', 'Inventory User', UserRole.custom, true,
        'limited', {PosPermission.stockCount, PosPermission.stockReceiving});
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DashboardScreen(
                user: user,
                repository: DashboardRepository(db),
                shift: null,
                navigate: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.text('Receive stock'), findsOneWidget);
    expect(find.text('Stock count'), findsOneWidget);
    expect(find.text('Sales today'), findsNothing);
    expect(find.text('Receivables'), findsNothing);
  });

  testWidgets('restricted snapshot fields stay hidden in the UI',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final user = ActiveUser('limited', 'Stock Clerk', UserRole.custom, true,
        'limited', {PosPermission.stockCount});
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DashboardScreen(
                user: user,
                repository: _FixedDashboardRepository(db, _busySnapshot),
                shift: null,
                navigate: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.text('Receivables'), findsNothing);
    expect(find.text('Payables'), findsNothing);
    expect(find.text('Completed sales today'), findsNothing);
    expect(find.text('Low stock'), findsOneWidget);
  });

  testWidgets('near expiry attention opens Expiry Monitor', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final targets = <String>[];
    final user = ActiveUser('stock', 'Stock Clerk', UserRole.custom, true,
        'stock', {PosPermission.stockCount});
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DashboardScreen(
                user: user,
                repository: _FixedDashboardRepository(db, _busySnapshot),
                shift: null,
                navigate: targets.add))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3 batches near expiry'));
    await tester.tap(find.text('3 batches near expiry'));
    expect(targets, contains('Expiry Monitor'));
  });

  testWidgets('dashboard summaries navigate to their existing modules',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final targets = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DashboardScreen(
                user: const ActiveUser('owner', 'Owner', UserRole.owner),
                repository: _FixedDashboardRepository(db, _busySnapshot),
                shift: null,
                navigate: targets.add))));
    await tester.pumpAndSettle();
    for (final (label, target) in [
      ('1 delivery needs attention', 'Sales Orders'),
      ('1 handover awaits acknowledgment', 'Cash session'),
      ('2 held sales to resume', 'POS'),
      ('2 products out of stock', 'Out of stock'),
      ('5 products low on stock', 'Low stock'),
      ('3 batches near expiry', 'Expiry Monitor'),
      ('Receivables', 'Customers & Suppliers'),
      ('Payables', 'Customers & Suppliers'),
      ('Open purchase orders', 'Purchase Orders'),
      ('Open RMAs', 'RMA / Warranty'),
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      expect(targets.last, target);
    }
    await tester.scrollUntilVisible(find.text('More'), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reports').last);
    expect(targets.last, 'Reports');
  });

  for (final width in [1366.0, 1600.0, 1920.0]) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('full access dashboard fits $width $brightness',
          (tester) async {
        final height = width == 1366
            ? 768.0
            : width == 1600
                ? 900.0
                : 1080.0;
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
                body: DashboardScreen(
                    user: const ActiveUser('owner', 'Owner', UserRole.owner),
                    repository: _FixedDashboardRepository(db, _busySnapshot),
                    shift: null,
                    navigate: (_) {}))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('At a glance'), findsOneWidget);
      });

      testWidgets('POS focused dashboard fits $width $brightness',
          (tester) async {
        final height = width == 1366
            ? 768.0
            : width == 1600
                ? 900.0
                : 1080.0;
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final user =
            ActiveUser('cashier', 'Alex', UserRole.custom, true, 'cashier', {
          PosPermission.sell,
          PosPermission.manageCashSession,
          PosPermission.resumeSale,
          PosPermission.viewOwnSales
        });
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
                body: DashboardScreen(
                    user: user,
                    repository: _FixedDashboardRepository(db, _busySnapshot),
                    shift: null,
                    navigate: (_) {}))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Cash session'), findsWidgets);
        expect(find.text('Payables'), findsNothing);
      });
    }
  }
}
