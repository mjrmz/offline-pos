import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/supplier_payables_repository.dart';
import 'package:modern_offline_pos/features/contacts/supplier_statement_dialog.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('supplier statement shows totals and changes period in $brightness',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value('u'), name: 'Owner', role: 'owner'));
      final supplier = await db.into(db.suppliers).insertReturning(
          SuppliersCompanion.insert(name: 'Supplier A'));
      final product = await db.into(db.products).insertReturning(
          ProductsCompanion.insert(name: 'Widget', priceCents: 900,
              costCents: const Value(500)));
      final now = DateTime.now();
      final receipt = await db.into(db.stockReceivings).insertReturning(
          StockReceivingsCompanion.insert(sequence: const Value(1),
              supplierId: supplier.id, userId: 'u',
              receivedAt: Value(DateTime(now.year, now.month, 2)),
              finalizedAt: Value(DateTime(now.year, now.month, 2))));
      await db.into(db.stockReceivingItems).insert(
          StockReceivingItemsCompanion.insert(receivingId: receipt.id,
              productId: product.id, quantityMilli: 10000,
              unitCostCents: 500));
      await db.into(db.supplierPayableSources).insert(
          SupplierPayableSourcesCompanion.insert(receivingId: receipt.id));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: SupplierStatementDialog(
              supplier: supplier, repository: SupplierPayablesRepository(db),
              user: const ActiveUser('u', 'Owner', UserRole.owner)))));
      await tester.pumpAndSettle();
      expect(find.text('Supplier Statement'), findsOneWidget);
      expect(find.text('Statement activity'), findsOneWidget);
      expect(find.textContaining('RCV-000001'), findsOneWidget);
      expect(find.text('Print statement'), findsOneWidget);
      await tester.tap(find.text('This month'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last month').last);
      await tester.pumpAndSettle();
      expect(find.text('Last month'), findsOneWidget);
      expect(find.text('No activity in this period'), findsOneWidget);
    });
  }

  testWidgets('cashier cannot view supplier statement', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final supplier = await db.into(db.suppliers).insertReturning(
        SuppliersCompanion.insert(name: 'Supplier A'));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
        SupplierStatementDialog(supplier: supplier,
            repository: SupplierPayablesRepository(db),
            user: const ActiveUser('cashier', 'Cashier', UserRole.cashier)))));
    await tester.pumpAndSettle();
    expect(find.text('Supplier statement access required.'), findsOneWidget);
  });
}
