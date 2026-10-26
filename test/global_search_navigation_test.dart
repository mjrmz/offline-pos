import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/features/dashboard/home_screen.dart';
import 'package:modern_offline_pos/features/dashboard/global_command_palette.dart';
import 'package:modern_offline_pos/features/contacts/customer_profile_screen.dart';
import 'package:modern_offline_pos/features/contacts/supplier_profile_drawer.dart';
import 'package:modern_offline_pos/features/inventory/stock_receiving_screen.dart';
import 'package:modern_offline_pos/features/inventory/serial_explorer.dart';
import 'package:modern_offline_pos/features/inventory/purchase_orders_screen.dart';
import 'package:modern_offline_pos/features/contacts/quotation_screen.dart';
import 'package:modern_offline_pos/features/contacts/layaway_screen.dart';
import 'package:modern_offline_pos/features/contacts/rma_screen.dart';
import 'package:modern_offline_pos/features/sales_history/sales_history_screen.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  Future<(AppDatabase, AuthService)> mount(WidgetTester tester,
      {bool shift = false}) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    if (shift) await CashSessionRepository(db).open(auth.current!, 0);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(auth: auth,
        pos: PosRepository(db), salesRepository: SalesRepository(db),
        onChanged: () {})));
    await tester.pumpAndSettle();
    return (db, auth);
  }

  Future<void> ctrlK(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String query, String title) async {
    await ctrlK(tester);
    await tester.enterText(find.byKey(const Key('global-search-input')), query);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).last);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl K opens, Esc closes, and blocking modal keeps focus',
      (tester) async {
    await mount(tester);
    await ctrlK(tester);
    expect(find.byType(GlobalCommandPalette), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(GlobalCommandPalette), findsNothing);
    final context = tester.element(find.byType(HomeScreen));
    showDialog<void>(context: context, builder: (_) => const AlertDialog(
        title: Text('Payment confirmation'),
        content: TextField(autofocus: true)));
    await tester.pumpAndSettle();
    await ctrlK(tester);
    expect(find.byType(GlobalCommandPalette), findsNothing);
    expect(find.text('Payment confirmation'), findsOneWidget);
  });

  testWidgets('partial barcode input keeps POS focus on Ctrl K',
      (tester) async {
    await mount(tester, shift: true);
    final barcode = find.byKey(const Key('scan-first-input')).evaluate().isNotEmpty
        ? find.byKey(const Key('scan-first-input'))
        : find.byKey(const Key('barcode-serial-input'));
    await tester.enterText(barcode, '48012');
    await ctrlK(tester);
    expect(find.byType(GlobalCommandPalette), findsNothing);
    expect(barcode, findsOneWidget);
  });

  testWidgets('customer and supplier results open existing profile drawers',
      (tester) async {
    final (db, _) = await mount(tester);
    await db.into(db.customers).insert(CustomersCompanion.insert(
        name: 'Maria Search'));
    await db.into(db.suppliers).insert(SuppliersCompanion.insert(
        name: 'Supplier Search'));
    await select(tester, 'Maria Search', 'Maria Search');
    expect(find.byType(CustomerProfileScreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    await select(tester, 'Supplier Search', 'Supplier Search');
    expect(find.byType(SupplierProfileDrawer), findsOneWidget);
  });

  testWidgets('Receiving result opens existing Receiving detail',
      (tester) async {
    final (db, auth) = await mount(tester);
    final supplier = await db.into(db.suppliers).insertReturning(
        SuppliersCompanion.insert(name: 'Supplier R'));
    await db.into(db.stockReceivings).insert(StockReceivingsCompanion.insert(
        sequence: const Value(31), supplierId: supplier.id,
        userId: auth.current!.id,
        externalReference: const Value('INV-31')));
    await select(tester, 'RCV-000031', 'RCV-000031');
    expect(find.byType(StockReceivingScreen), findsOneWidget);
    expect(find.textContaining('RCV-000031'), findsWidgets);
  });

  testWidgets('product result opens existing inventory product editor',
      (tester) async {
    final (db, _) = await mount(tester);
    await db.into(db.products).insert(ProductsCompanion.insert(
        name: 'Wireless Mouse', priceCents: 65000));
    await select(tester, 'Wireless Mouse', 'Wireless Mouse');
    expect(find.byType(ProductScreen), findsOneWidget);
    expect(find.textContaining('Product details'), findsWidgets);
  });

  testWidgets('sale result opens Sales History detail', (tester) async {
    final (db, auth) = await mount(tester);
    await db.into(db.sales).insert(SalesCompanion.insert(
        cashierId: auth.current!.id, totalCents: 2500,
        receiptNumber: const Value('POS-000842')));
    await select(tester, 'POS-000842', 'POS-000842');
    expect(find.byType(SalesHistoryScreen), findsOneWidget);
    expect(find.textContaining('Receipt reference: POS-000842'), findsWidgets);
  });

  testWidgets('quotation and layaway results open existing details',
      (tester) async {
    final (db, auth) = await mount(tester);
    final customer = await db.into(db.customers).insertReturning(
        CustomersCompanion.insert(name: 'Customer Q'));
    await db.into(db.quotations).insert(QuotationsCompanion.insert(
        reference: 'Q-000015', customerId: Value(customer.id),
        createdBy: auth.current!.id));
    await db.into(db.layaways).insert(LayawaysCompanion.insert(
        reference: 'LAY-000015', customerId: customer.id,
        createdBy: auth.current!.id, totalCents: 2500));
    await select(tester, 'Q-000015', 'Q-000015');
    expect(find.byType(QuotationScreen), findsOneWidget);
    expect(find.textContaining('Q-000015'), findsWidgets);
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pumpAndSettle();
    await select(tester, 'LAY-000015', 'LAY-000015');
    expect(find.byType(LayawayScreen), findsOneWidget);
    expect(find.text('Layaway LAY-000015'), findsOneWidget);
  });

  testWidgets('PO and RMA results open existing workflows', (tester) async {
    final (db, auth) = await mount(tester);
    final supplier = await db.into(db.suppliers).insertReturning(
        SuppliersCompanion.insert(name: 'Supplier P'));
    await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
        sequence: 15, supplierId: supplier.id,
        orderDate: DateTime.now(), createdBy: auth.current!.id));
    await db.into(db.rmaCases).insert(RmaCasesCompanion.insert(
        reference: 'RMA-000015', origin: 'inbound',
        issueDescription: 'Supplier issue', intakeCondition: 'Used',
        supplierId: Value(supplier.id)));
    await select(tester, 'PO-000015', 'PO-000015');
    expect(find.byType(PurchaseOrdersScreen), findsOneWidget);
    expect(find.textContaining('PO-000015'), findsWidgets);
    await select(tester, 'RMA-000015', 'RMA-000015');
    expect(find.byType(RmaScreen), findsOneWidget);
    expect(find.textContaining('RMA-000015'), findsWidgets);
  });

  testWidgets('serial result opens lifecycle then Receiving reference', (tester) async {
    final (db, auth) = await mount(tester);
    final product = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(name: 'Serialized Mouse', priceCents: 5000));
    final supplier = await db.into(db.suppliers).insertReturning(
        SuppliersCompanion.insert(name: 'Supplier S'));
    final receipt = await db.into(db.stockReceivings).insertReturning(
        StockReceivingsCompanion.insert(sequence: const Value(10),
            supplierId: supplier.id, userId: auth.current!.id));
    final item = await db.into(db.stockReceivingItems).insertReturning(
        StockReceivingItemsCompanion.insert(receivingId: receipt.id,
            productId: product.id, quantityMilli: 1000, unitCostCents: 3000));
    await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
        productId: product.id, serialNumber: 'SERIAL-001',
        receivingItemId: Value(item.id)));
    await select(tester, 'SERIAL-001', 'SERIAL-001');
    expect(find.byType(SerialExplorer), findsOneWidget);
    expect(find.text('SERIAL-001'), findsWidgets);
    expect(find.textContaining('RCV-000010'), findsWidgets);
    await tester.tap(find.textContaining('RCV-000010').last);
    await tester.pumpAndSettle();
    expect(find.byType(StockReceivingScreen), findsOneWidget);
  });

  testWidgets('partial serial result opens lifecycle detail', (tester) async {
    final (db, _) = await mount(tester);
    final product = await db.into(db.products).insertReturning(
        ProductsCompanion.insert(name: 'Drive', priceCents: 100));
    await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
        productId: product.id, serialNumber: 'SERIAL-PARTIAL-001'));
    await select(tester, 'PARTIAL', 'SERIAL-PARTIAL-001');
    expect(find.byType(SerialExplorer), findsOneWidget);
    expect(find.text('SERIAL-PARTIAL-001'), findsWidgets);
  });

  testWidgets('create commands start existing editors without posting data',
      (tester) async {
    final (db, _) = await mount(tester);
    await select(tester, 'Create Purchase Order', 'Create Purchase Order');
    expect(find.byType(PurchaseOrdersScreen), findsOneWidget);
    expect(find.text('New Purchase Order'), findsWidgets);
    expect(await db.select(db.purchaseOrders).get(), isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await select(tester, 'Create Quotation', 'Create Quotation');
    expect(find.byType(QuotationScreen), findsOneWidget);
    expect(find.text('New quotation'), findsWidgets);
    expect(await db.select(db.quotations).get(), isEmpty);
  });
}
