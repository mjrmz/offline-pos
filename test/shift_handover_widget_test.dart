import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cash_session_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/cash_session/shift_handover_panel.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('wizard count, review, acknowledgment and history in $mode',
        (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final ownerId =
          await auth.bootstrap('Owner', 'ownerPassword123', 'Q?', 'answer');
      final owner = await auth.login(ownerId, 'ownerPassword123');
      await auth.createUser('Receiver', UserRole.cashier, '1234');
      final session = await CashSessionRepository(db).open(owner, 100000);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: mode,
          home: Scaffold(
              body: SingleChildScrollView(
                  child: ShiftHandoverPanel(
                      db: db, user: owner, sessionId: session.id)))));
      await tester.pumpAndSettle();
      expect(find.text('Start Shift Handover'), findsOneWidget);
      await tester.tap(find.text('Start Shift Handover'));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 3'), findsOneWidget);
      await tester.tap(find.text('Incoming cashier'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receiver').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Count cash'));
      await tester.pumpAndSettle();
      expect(find.text('Step 2 of 3'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '1');
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Step 3 of 3'), findsOneWidget);
      expect(find.text('Balanced'), findsOneWidget);
      await tester.ensureVisible(find.text('Submit for acknowledgment'));
      await tester.tap(find.text('Submit for acknowledgment'));
      await tester.pumpAndSettle();
      expect(find.text('Manager acknowledgment'), findsOneWidget);
      await tester.ensureVisible(find.text('Manager acknowledgment'));
      await tester.tap(find.text('Manager acknowledgment'));
      await tester.pumpAndSettle();
      expect(find.text('Acknowledge HOV-000001'), findsOneWidget);
      await tester.tap(find.text('Acknowledge and complete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Handover Complete'), findsOneWidget);
      expect(find.textContaining('HOV-000001'), findsWidgets);
    });
  }
}
