import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/customer_credit_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/customer_profile_screen.dart';
import 'package:modern_offline_pos/features/contacts/customer_profile_ui.dart';

void main() {
  testWidgets('RMA and quotation lists page at 50 records', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    for (var index = 0; index < 51; index++) {
      await db.into(db.rmaCases).insert(RmaCasesCompanion.insert(
          reference: 'RMA-$index',
          origin: 'customer',
          customerId: Value(customer.id),
          issueDescription: 'Issue',
          intakeCondition: 'Received'));
      await db.into(db.quotations).insert(QuotationsCompanion.insert(
          reference: 'QUO-$index',
          customerId: Value(customer.id),
          createdBy: auth.current!.id));
      await db.into(db.customerCreditEntries).insert(
          CustomerCreditEntriesCompanion.insert(
              customerId: customer.id,
              userId: auth.current!.id,
              amountCents: 100,
              kind: 'credit_sale'));
    }
    await tester.pumpWidget(MaterialApp(
        home: CustomerProfileScreen(
            customer: customer,
            repository: CustomerCreditRepository(db),
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RMA'));
    await tester.pumpAndSettle();
    expect(find.text('51 results'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 2'), findsOneWidget);
    await tester.tap(find.text('Credit'));
    await tester.pumpAndSettle();
    expect(find.text('51 results'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 2'), findsOneWidget);
    await tester.ensureVisible(find.text('Quotations').first);
    await tester.tap(find.text('Quotations').first);
    await tester.pumpAndSettle();
    expect(find.text('51 results'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing customer resets profile tab and note context',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final directory = DirectoryRepository(db);
    final first = await directory.saveCustomer(auth.current!,
        name: 'Moira', notes: 'Call before delivery');
    final second = await directory.saveCustomer(auth.current!, name: 'Ava');
    var selected = first;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (context, update) => Column(children: [
                  TextButton(
                      onPressed: () => update(() => selected = second),
                      child: const Text('Switch customer')),
                  Expanded(
                      child: CustomerProfileScreen(
                          customer: selected,
                          repository: CustomerCreditRepository(db),
                          user: auth.current!)),
                ]))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Notes'));
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('Call before delivery'), findsOneWidget);
    await tester.tap(find.text('Switch customer'));
    await tester.pumpAndSettle();
    expect(find.text('Ava'), findsOneWidget);
    expect(find.text('Lifetime net spend'), findsOneWidget);
    expect(find.text('Call before delivery'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('customer purchases exposes period and bounded history',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question', 'Answer');
    await auth.login(id, 'password123');
    final customer = await DirectoryRepository(db)
        .saveCustomer(auth.current!, name: 'Moira');
    await tester.pumpWidget(MaterialApp(
        home: CustomerProfileScreen(
            customer: customer,
            repository: CustomerCreditRepository(db),
            user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Purchases').first);
    await tester.pumpAndSettle();
    expect(find.text('This month'), findsOneWidget);
    expect(find.text('No purchases for this period.'), findsOneWidget);
    expect(find.text('Previous'), findsNothing);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final size in const [
      Size(1366, 768),
      Size(1600, 900),
      Size(1920, 1080)
    ]) {
      testWidgets('customer profile tabs fit $size in $mode', (tester) async {
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
            await auth.bootstrap('Owner', 'password123', 'Question', 'answer');
        await auth.login(id, 'password123');
        final customer = await DirectoryRepository(db)
            .saveCustomer(auth.current!, name: 'Moira');
        await db.into(db.rmaCases).insert(RmaCasesCompanion.insert(
            reference: 'RMA-001',
            origin: 'customer',
            customerId: Value(customer.id),
            issueDescription: 'Fault',
            intakeCondition: 'Received'));
        await db.into(db.quotations).insert(QuotationsCompanion.insert(
            reference: 'QUO-001',
            customerId: Value(customer.id),
            createdBy: auth.current!.id));
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home: CustomerProfileScreen(
                customer: customer,
                repository: CustomerCreditRepository(db),
                user: auth.current!)));
        await tester.pumpAndSettle();
        expect(find.text('Overview'), findsOneWidget);
        expect(find.text('Rewards'), findsOneWidget);
        expect(find.text('Moira'), findsOneWidget);
        expect(find.text('Lifetime net spend'), findsOneWidget);
        final kpis = tester.widget<CustomerProfileKpis>(
            find.byType(CustomerProfileKpis).first);
        expect(kpis.values.length, 6);
        final tileHeights = tester
            .widgetList<SizedBox>(find.descendant(
                of: find.byType(CustomerProfileKpis).first,
                matching: find.byType(SizedBox)))
            .where((box) => box.height == 83)
            .map((box) => box.height)
            .toList();
        expect(tileHeights.length, 6);
        expect(find.text('Recent activity'), findsOneWidget);
        expect(find.text('Recent purchases'), findsOneWidget);
        await tester.drag(find.byType(ListView).first, const Offset(0, -1000));
        await tester.pumpAndSettle();
        expect(find.text('Customer information'), findsOneWidget);
        expect(find.text('No purchases yet.'), findsNothing);
        await tester.tap(find.text('Rewards'));
        await tester.pumpAndSettle();
        expect(find.text('No rewards activity'), findsOneWidget);
        await tester.tap(find.text('Adjust points'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('No rewards activity'), findsOneWidget);
        await tester.tap(find.text('Adjust points'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Credit'));
        await tester.pumpAndSettle();
        expect(find.text('Outstanding credit'), findsOneWidget);
        expect(find.text('Purchases'), findsOneWidget);
        await tester.tap(find.text('RMA'));
        await tester.pumpAndSettle();
        expect(find.text('RMA-001'), findsOneWidget);
        await tester.ensureVisible(find.text('Quotations'));
        await tester.tap(find.text('Quotations'));
        await tester.pumpAndSettle();
        expect(find.text('QUO-001'), findsOneWidget);
        expect(find.text('All'), findsOneWidget);
        await tester
            .ensureVisible(find.widgetWithText(ChoiceChip, 'Converted'));
        await tester.tap(find.widgetWithText(ChoiceChip, 'Converted'));
        await tester.pumpAndSettle();
        expect(find.text('No quotations'), findsOneWidget);
        await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'All'));
        await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
        await tester.pumpAndSettle();
        expect(find.text('QUO-001'), findsOneWidget);
        await tester.ensureVisible(find.text('Notes'));
        await tester.tap(find.text('Notes'));
        await tester.pumpAndSettle();
        expect(find.text('No notes'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
