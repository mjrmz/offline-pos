import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_receiving_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/contacts/supplier_profile_drawer.dart';
import 'package:modern_offline_pos/shared/widgets/app_workspace.dart';

void main() {
  for (final size in const [
    Size(1366, 768),
    Size(1600, 900),
    Size(1920, 1080)
  ]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('supplier drawer fits $size in $mode', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final auth = AuthService(AuthRepository(db));
        final id =
            await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
        await auth.login(id, 'password123');
        final supplier = await DirectoryRepository(db)
            .saveSupplier(auth.current!, name: 'HC Play');
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: Scaffold(
                body: Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                        width: 800,
                        child: SupplierProfileDrawer(
                            supplier: supplier,
                            user: auth.current!,
                            repository: StockReceivingRepository(db)))))));
        await tester.pumpAndSettle();
        expect(find.text('HC Play'), findsOneWidget);
        expect(find.text('Overview'), findsOneWidget);
        expect(find.textContaining('Not enough history'), findsWidgets);
        expect(tester.takeException(), isNull);
        for (var repeat = 0; repeat < 2; repeat++) {
          for (final label in const [
            'Purchases',
            'Products',
            'Purchase Orders',
            'Receiving',
            'Payables',
            'Performance',
            'Overview'
          ]) {
            final tabs =
                tester.widget<AppWorkspaceTabs>(find.byType(AppWorkspaceTabs));
            tabs.onSelected(tabs.labels.indexOf(label));
            await tester.pumpAndSettle();
            if (label == 'Payables') {
              expect(find.text('Record payment'), findsOneWidget);
              expect(find.text('No tracked Receiving payables.'), findsOneWidget);
            }
            expect(tester.takeException(), isNull,
                reason:
                    'Switching to $label must not reuse another tab payload');
          }
        }
      });
    }
  }

  testWidgets('supplier payment shows allocations before confirmation', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final supplier = await DirectoryRepository(db)
        .saveSupplier(auth.current!, name: 'Supplier');
    final product = await PosRepository(db).saveProduct(
        name: 'Widget', priceCents: 900, costCents: 500, startingStock: 0);
    await StockReceivingRepository(db).receive(auth.current!, supplier.id,
        [ReceivingLineRequest(product, 10000, 500)]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
        width: 800, child: SupplierProfileDrawer(supplier: supplier,
            user: auth.current!, repository: StockReceivingRepository(db))))));
    await tester.pumpAndSettle();
    final tabs = tester.widget<AppWorkspaceTabs>(find.byType(AppWorkspaceTabs));
    tabs.onSelected(tabs.labels.indexOf('Payables'));
    await tester.pumpAndSettle();
    expect(find.text('Aging'), findsOneWidget);
    expect(find.text('Supplier Statement'), findsOneWidget);
    await tester.tap(find.text('Supplier Statement'));
    await tester.pumpAndSettle();
    expect(find.text('Statement activity'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record payment'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '10');
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Allocation preview'), findsOneWidget);
    expect(find.text('₱10.00'), findsWidgets);
  });
}
