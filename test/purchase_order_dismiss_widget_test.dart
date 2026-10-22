import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/purchase_order_repository.dart';
import 'package:modern_offline_pos/features/inventory/purchase_orders_screen.dart';

void main() {
  testWidgets('ESC and Cancel dismiss PO editor without persisting a draft',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final owner = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(owner, 'password123');
    final orders = PurchaseOrderRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PurchaseOrdersScreen(
                repository: orders,
                directory: DirectoryRepository(db),
                products: PosRepository(db),
                user: auth.current!,
                onReceive: (_) {}))));
    await tester.pumpAndSettle();

    Future<void> open() async {
      await tester.tap(find.text('New Purchase Order').first);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
    }

    Future<void> escape() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(await orders.list(), isEmpty);
    }

    await open();
    await escape();
    await open();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsNothing);
    expect(await orders.list(), isEmpty);
    await open();
    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsOneWidget);
    await escape();
    await open();
    await tester.enterText(find.byType(TextField).first, 'draft reference');
    await escape();
    await open();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Dialog), findsNothing);
    expect(await orders.list(), isEmpty);
  });
}
