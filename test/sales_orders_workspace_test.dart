import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_order_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/sales_orders_screen.dart';

void main() {
  testWidgets('Sales Orders workspace opens draft editor', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    final user = ActiveUser(id, 'Owner', UserRole.owner);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: SalesOrderRepository(db),
        directory: DirectoryRepository(db), products: PosRepository(db),
        user: user))));
    await tester.pumpAndSettle();
    expect(find.text('Sales Orders'), findsOneWidget);
    await tester.tap(find.text('New Sales Order'));
    await tester.pumpAndSettle();
    expect(find.text('Customer'), findsOneWidget);
    expect(find.text('Fulfillment intent'), findsOneWidget);
    expect(find.text('Save draft'), findsOneWidget);
  });
  testWidgets('confirmed order shows explicit reservation controls',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap(
        'Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final user = ActiveUser(id, 'Owner', UserRole.owner);
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('c1', 'Ana', 0)");
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p1', 'Bread', 1000, 0)");
    await db.customStatement(
        "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p1', 10, 10000)");
    final orders = SalesOrderRepository(db);
    final order = await orders.create(user, 'c1',
        [const SalesOrderLineRequest('p1', 4000, 1000)]);
    await orders.transition(user, order.id, 'confirmed');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      SalesOrdersScreen(repository: orders,
        directory: DirectoryRepository(db), products: PosRepository(db),
        user: user, auth: auth))));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    expect(find.text('Reserve stock'), findsOneWidget);
    expect(find.textContaining('Reserved 0'), findsOneWidget);
    await tester.tap(find.text('Reserve stock'));
    await tester.pumpAndSettle();
    expect(find.text('Requested: 4'), findsOneWidget);
    expect(find.text('Available: 10'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(order.reference));
    await tester.pumpAndSettle();
    expect(find.text('Fulfill Order'), findsOneWidget);
    await tester.tap(find.text('Fulfill Order'));
    await tester.pumpAndSettle();
    expect(find.textContaining('remaining 4'), findsOneWidget);
    expect(find.text('Open checkout'), findsOneWidget);
    await tester.tap(find.text('Open checkout'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fulfilling Sales Order'), findsOneWidget);
  });
}
