import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/pos_checkout/pos_shift.dart';

void main() {
  testWidgets('shift opening card fits a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(id, 'password123');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PosShiftClosed(
                user: auth.current!,
                repository: CashSessionRepository(db),
                onOpened: () {},
                onSessions: () {}))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pos-opening-cash')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('POS opening cash validates and zero opens the shared session',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(id, 'password123');
    final cash = CashSessionRepository(db);
    var opened = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PosShiftClosed(
                user: auth.current!,
                repository: cash,
                onOpened: () => opened = true,
                onSessions: () {}))));
    await tester.pumpAndSettle();
    expect(find.text('Open your cashier shift'), findsOneWidget);
    final button = find.byKey(const Key('pos-open-shift'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('pos-opening-cash')), '1.234');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('pos-opening-cash')), '0');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect((await cash.active())?.startingCashCents, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'POS close uses shared service with positive shortage and confirmation',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(id, 'password123');
    final cash = CashSessionRepository(db);
    await cash.open(auth.current!, 10000);
    final shift = (await cash.history()).first;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      await showPosCloseShift(
                          context, cash, auth.current!, shift);
                    },
                    child: const Text('Show close'))))));
    await tester.tap(find.text('Show close'));
    await tester.pumpAndSettle();
    final button = find.byKey(const Key('pos-close-shift'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('pos-counted-cash')), '85');
    await tester.pump();
    expect(find.text('Short ₱15.00'), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Close this shift?'), findsOneWidget);
    expect((await cash.active()), isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect((await cash.active()), isNull);
    expect((await cash.history()).first.varianceCents, -1500);
  });
}
