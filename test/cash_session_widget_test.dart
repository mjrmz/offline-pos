import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/cash_session/cash_session_screen.dart';

void main() {
  Future<(AppDatabase, CashSessionRepository, AuthService)> setup(
      WidgetTester tester,
      {Size size = const Size(1366, 768)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(id, 'password123');
    return (db, CashSessionRepository(db), auth);
  }

  Future<void> show(
      WidgetTester tester, CashSessionRepository cash, AuthService auth) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CashSessionScreen(user: auth.current!, repository: cash))));
    await tester.pumpAndSettle();
  }

  testWidgets('no shift shows history and POS navigation without opening form',
      (tester) async {
    final (_, cash, auth) = await setup(tester);
    var visited = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CashSessionScreen(
                user: auth.current!,
                repository: cash,
                onGoPos: () => visited = true))));
    await tester.pumpAndSettle();
    expect(find.text('No active cash session'), findsOneWidget);
    expect(find.text('Previous shifts'), findsOneWidget);
    expect(find.text('Z-reading history'), findsOneWidget);
    expect(find.text('Opening cash'), findsNothing);
    expect(find.text('Open shift'), findsNothing);
    await tester.tap(find.text('Go to POS'));
    expect(visited, isTrue);
  });

  testWidgets('active shift is read only with details', (tester) async {
    final (_, cash, auth) = await setup(tester);
    await cash.open(auth.current!, 10000);
    await show(tester, cash, auth);
    expect(find.text('CURRENT SHIFT'), findsOneWidget);
    expect(find.text('Opened by Owner'), findsOneWidget);
    expect(find.text('Close shift'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('View details').first);
    await tester.pumpAndSettle();
    expect(find.text('Current shift'), findsOneWidget);
    expect(find.text('Expected cash'), findsWidgets);
  });

  testWidgets('owner retains other-user close control only', (tester) async {
    final (_, cash, auth) = await setup(tester);
    final ownerId = auth.current!.id;
    final cashierId =
        await auth.createUser('Cashier', UserRole.cashier, '1234');
    await auth.logout();
    await auth.login(cashierId, '1234');
    await cash.open(auth.current!, 10000);
    await show(tester, cash, auth);
    expect(find.text('Close other user shift'), findsNothing);
    await auth.logout();
    await auth.login(ownerId, 'password123');
    await show(tester, cash, auth);
    expect(find.text('Close other user shift'), findsOneWidget);
    expect(find.text('Close shift'), findsNothing);
  });
  testWidgets('closed shifts show compact history and narrow stack',
      (tester) async {
    final (_, cash, auth) = await setup(tester, size: const Size(400, 850));
    await cash.open(auth.current!, 10000);
    await cash.close(auth.current!, 8500);
    await show(tester, cash, auth);
    expect(find.text('Previous shifts'), findsOneWidget);
    expect(find.text('Short ₱15.00'), findsOneWidget);
    expect(find.textContaining('Today ·'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();
    expect(find.text('Previous shift'), findsOneWidget);
    expect(find.text('Opened at'), findsOneWidget);
  });

  testWidgets('Z-reading fields and desktop history columns use readable dates',
      (tester) async {
    final (db, cash, auth) = await setup(tester);
    final session = await cash.open(auth.current!, 0);
    await cash.close(auth.current!, 0);
    await db.into(db.zReadings).insert(ZReadingsCompanion.insert(
          number: 2,
          cashSessionId: session.id,
          generatedByUserId: auth.current!.id,
          generatedAt: Value(DateTime.now()),
          beginningInvoiceNumber: const Value(2),
          endingInvoiceNumber: const Value(2),
          periodSalesCents: 1500,
          reversalCents: 0,
          grandTotalCents: 2000,
          expectedCashCents: 0,
          actualCashCents: 0,
        ));
    await show(tester, cash, auth);
    expect(find.text('Z #2'), findsOneWidget);
    expect(find.text('Invoices 2–2'), findsOneWidget);
    expect(find.text('Grand total ₱20.00'), findsOneWidget);
    expect(find.textContaining('Today ·'), findsWidgets);
    await tester.tap(find.text('View details'));
    await tester.pumpAndSettle();
    expect(find.text('Grand total'), findsOneWidget);
    expect(find.text('₱20.00'), findsOneWidget);
  });
}
