import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/customer_credit_panel.dart';

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('credit panel records partial noncash payment in $brightness',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
      await auth.login(id, 'password123');
      final customer = await DirectoryRepository(db)
          .saveCustomer(auth.current!, name: 'Customer');
      final sale = await db.into(db.sales).insertReturning(
          SalesCompanion.insert(
              cashierId: id,
              customerId: Value(customer.id),
              totalCents: 1000,
              receiptNumber: const Value('POS-000001')));
      await db.into(db.customerCreditEntries).insert(
          CustomerCreditEntriesCompanion.insert(
              customerId: customer.id,
              saleId: Value(sale.id),
              userId: id,
              amountCents: 1000,
              kind: 'credit_sale'));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
              body: CustomerCreditPanel(
                  customer: customer,
                  repository: CustomerCreditRepository(db),
                  user: auth.current!))));
      await tester.pumpAndSettle();
      expect(find.text('Customer Credit / Receivables'), findsOneWidget);
      expect(find.text('Open credit sales'), findsWidgets);
      expect(find.text('Set credit limit'), findsOneWidget);
      expect(find.text('Aging'), findsOneWidget);
      expect(find.text('Aging is based on credit sale date.'), findsOneWidget);
      expect(find.text('Customer Statement'), findsOneWidget);
      await tester.tap(find.text('Customer Statement'));
      await tester.pumpAndSettle();
      expect(find.text('Customer Statement'), findsWidgets);
      expect(find.text('Statement activity'), findsOneWidget);
      await tester.tap(find.text('Close').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Amount received'), '5.00');
      await tester.tap(find.text('Cash').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmed GCash').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record payment').last);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect((await db.select(db.customerCreditEntries).get()).last.reference,
          'CPAY-000001');
      await tester.scrollUntilVisible(find.text('Credit activity'), 300,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.textContaining('CPAY-000001'), findsWidgets);
      expect(find.textContaining('Balance ₱5.00'), findsWidgets);
    });
  }
}
