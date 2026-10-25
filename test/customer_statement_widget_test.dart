import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/receivables_reporting_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/customer_statement_dialog.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
        'statement shows period, totals, activity and print in $brightness',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.into(db.users).insert(UsersCompanion.insert(
          id: const Value('u'), name: 'Owner', role: 'owner'));
      final customer = await db
          .into(db.customers)
          .insertReturning(CustomersCompanion.insert(name: 'Customer'));
      final sale = await db.into(db.sales).insertReturning(
          SalesCompanion.insert(
              cashierId: 'u',
              customerId: Value(customer.id),
              totalCents: 1200,
              receiptNumber: const Value('POS-000001'),
              createdAt: Value(DateTime(2026, 10, 2))));
      await db.into(db.customerCreditEntries).insert(
          CustomerCreditEntriesCompanion.insert(
              customerId: customer.id,
              saleId: Value(sale.id),
              userId: 'u',
              amountCents: 1200,
              kind: 'credit_sale',
              createdAt: Value(DateTime(2026, 10, 2))));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
              body: CustomerStatementDialog(
                  customer: customer,
                  repository: ReceivablesReportingRepository(db),
                  user: const ActiveUser('u', 'Owner', UserRole.owner)))));
      await tester.pumpAndSettle();
      expect(find.text('Customer Statement'), findsOneWidget);
      expect(find.text('This month'), findsOneWidget);
      expect(find.text('Statement activity'), findsOneWidget);
      expect(find.textContaining('POS-000001'), findsWidgets);
      expect(find.text('Print statement'), findsOneWidget);
      await tester.tap(find.text('This month'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last month').last);
      await tester.pumpAndSettle();
      expect(find.text('Last month'), findsOneWidget);
    });
  }
}
