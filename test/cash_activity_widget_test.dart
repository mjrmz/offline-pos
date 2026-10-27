import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_activity_repository.dart';
import 'package:modern_offline_pos/data/daos/petty_cash_repository.dart';
import 'package:modern_offline_pos/features/cash_session/petty_cash_screen.dart';
import 'package:modern_offline_pos/features/dashboard/home_screen.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Expenses separates expense records from fund activity',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final cash = CashActivityRepository(db);
    final category = (await cash.categories()).first;
    await cash.addOpeningCash(auth.current!,
        fund: 'company', amountCents: 10000, note: 'Opening count');
    await cash.replenish(auth.current!,
        amountCents: 3000, destination: 'petty');
    await cash.expense(auth.current!,
        amountCents: 500,
        source: 'petty',
        categoryId: category.id,
        payee: 'Grab');
    await tester.pumpWidget(MaterialApp(
        home: PettyCashScreen(
            repository: PettyCashRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsOneWidget);
    await tester.tap(find.text('Expense Records'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Grab'), findsOneWidget);
    expect(find.text('Transfer'), findsNothing);
    expect(find.text('Opening balance'), findsNothing);
    await tester.tap(find.text('Cash Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Transfer'), findsOneWidget);
    expect(find.text('Opening balance'), findsOneWidget);
    await tester.tap(find.text('Petty Cash'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Grab'), findsOneWidget);
    expect(find.text('Opening balance'), findsNothing);
  });
  testWidgets('Escape dismisses replenish inside the POS shell',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            auth: auth,
            pos: PosRepository(db),
            salesRepository: SalesRepository(db),
            onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byTooltip('Expenses'), 200,
        scrollable: find.descendant(
            of: find.byKey(const Key('sidebar-navigation')),
            matching: find.byType(Scrollable)));
    await tester.tap(find.byTooltip('Expenses'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Petty Cash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add cash'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Add cash to petty cash'), findsNothing);
    expect(find.text('Expenses'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Escape dismisses replenish without changing cash',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final session = await CashSessionRepository(db).open(auth.current!, 100000);
    await tester.pumpWidget(MaterialApp(
        home: PettyCashScreen(
            repository: PettyCashRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Petty Cash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add cash'));
    await tester.pumpAndSettle();
    expect(find.text('Add cash to petty cash'), findsOneWidget);
    final amountField = tester.widget<TextField>(find
        .descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField))
        .first);
    final amountController = amountField.controller!;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(() => amountController.addListener(() {}), returnsNormally);
    await tester.pumpAndSettle();
    expect(find.text('Add cash to petty cash'), findsNothing);
    expect(find.text('Expenses'), findsWidgets);
    expect(tester.takeException(), isNull);
    expect(await CashActivityRepository(db).history(), isEmpty);
    expect(await CashSessionRepository(db).expected(session.id), 100000);
  });
  testWidgets('Cancel and Escape discard replenishment draft', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final session = await CashSessionRepository(db).open(auth.current!, 100000);
    final cash = CashActivityRepository(db);
    await cash.addOpeningCash(auth.current!,
        fund: 'company', amountCents: 10000, note: 'Opening count');
    await tester.pumpWidget(MaterialApp(
        home: PettyCashScreen(
            repository: PettyCashRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    for (final escape in [false, true]) {
      await tester.tap(find.text('Petty Cash'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add cash'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      await tester.enterText(fields.first, '25.00');
      await tester.enterText(fields.last, 'Draft only');
      if (escape) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tap(find.text('Cancel'));
      }
      await tester.pumpAndSettle();
      expect(find.text('Add cash to petty cash'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    expect((await cash.history()).where((m) => m.type == 'replenishment'),
        isEmpty);
    expect(await cash.balance('petty'), 0);
    expect(await cash.balance('company'), 10000);
    expect(await CashSessionRepository(db).expected(session.id), 100000);
  });
  testWidgets('Escape closes category menu before expense dialog',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final session = await CashSessionRepository(db).open(auth.current!, 100000);
    await tester.pumpWidget(MaterialApp(
        home: PettyCashScreen(
            repository: PettyCashRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record expense').first);
    await tester.pumpAndSettle();
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.first, '100.00');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Record expense'), findsWidgets);
    expect(find.text('PAID FROM'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('PAID FROM'), findsNothing);
    expect(find.text('Expenses'), findsWidgets);
    expect(tester.takeException(), isNull);
    expect(await CashActivityRepository(db).history(), isEmpty);
    expect(await CashSessionRepository(db).expected(session.id), 100000);
  });
  testWidgets('Escape closes category and reversal dialogs without writes',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final cash = CashActivityRepository(db);
    final category = (await cash.categories()).first;
    final movement = await cash.expense(auth.current!,
        amountCents: 850,
        source: 'personal',
        categoryId: category.id,
        personallyPaidBy: 'MJ',
        payee: 'Grab');
    await tester.pumpWidget(MaterialApp(
        home: PettyCashScreen(
            repository: PettyCashRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More ▾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expense categories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find
            .descendant(
                of: find.byType(AlertDialog).last,
                matching: find.byType(TextField))
            .first,
        'Draft category');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Expense categories'), findsOneWidget);
    expect(find.text('New category'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Expense categories'), findsNothing);
    expect((await cash.categories()).any((c) => c.name == 'Draft category'),
        false);
    await tester.tap(find.textContaining('Grab').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reverse expense'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find
            .descendant(
                of: find.byType(AlertDialog), matching: find.byType(TextField))
            .first,
        'Draft reversal');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Reverse cash movement?'), findsNothing);
    expect(find.text('Expenses'), findsWidgets);
    expect(tester.takeException(), isNull);
    expect((await cash.history()).where((m) => m.reversalOfId == movement.id),
        isEmpty);
  });
  for (final size in [
    const Size(1366, 768),
    const Size(1600, 900),
    const Size(1920, 1080)
  ]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets(
          'cash activity layout and expense dialog fit ${size.width}x${size.height} in $mode',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final auth = AuthService(AuthRepository(db));
        final id =
            await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
        await auth.login(id, 'ownerPassword123');
        await CashSessionRepository(db).open(auth.current!, 100000);
        await tester.pumpWidget(MaterialApp(
            themeMode: mode,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            home: PettyCashScreen(
                repository: PettyCashRepository(db), user: auth.current!)));
        await tester.pumpAndSettle();
        expect(find.text('Expenses'), findsWidgets);
        expect(find.text('No expenses recorded yet.'), findsOneWidget);
        await tester.tap(find.text('Record expense').first);
        await tester.pumpAndSettle();
        expect(find.text('PAID FROM'), findsOneWidget);
        expect(find.text('CASH EFFECT'), findsOneWidget);
        expect(find.textContaining('Current shift'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('personally paid activity opens audit detail', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
    await auth.login(id, 'ownerPassword123');
    final cash = CashActivityRepository(db);
    final category = (await cash.categories()).first;
    await cash.expense(auth.current!,
        amountCents: 850,
        source: 'personal',
        categoryId: category.id,
        personallyPaidBy: 'MJ',
        payee: 'Grab',
        reference: 'OR-123');
    await tester.pumpWidget(MaterialApp(
        home: PettyCashScreen(
            repository: PettyCashRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Reimbursements due'), findsWidgets);
    await tester.tap(find.textContaining('Grab').first);
    await tester.pumpAndSettle();
    expect(find.text('EXPENSE'), findsWidgets);
    expect(find.text('OR-123'), findsOneWidget);
    expect(find.textContaining('Reimbursement due; no business cash reduced'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
