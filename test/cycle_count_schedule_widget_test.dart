import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/cycle_count_schedule_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/inventory/cycle_count_schedules_screen.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('schedule screen and form fit desktop in $mode',
        (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      final productId = await PosRepository(db).saveProduct(
          name: 'A', priceCents: 100, costCents: 50, startingStock: 2);
      await CycleCountScheduleRepository(db).create(auth.current!,
          title: 'Weekly check',
          scopeType: 'products',
          scopeRefs: [productId],
          assigneeId: id,
          scheduledDate: DateTime(2026, 10, 25),
          dueDate: DateTime(2026, 10, 26));
      await tester.pumpWidget(MaterialApp(
          themeMode: mode,
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          home: CycleCountSchedulesScreen(db: db, user: auth.current!)));
      await tester.pumpAndSettle();
      expect(find.text('Cycle Count Scheduling'), findsOneWidget);
      expect(find.text('Weekly check'), findsOneWidget);
      await tester.tap(find.text('Create Schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Title or reference'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a title, scope, employee, and valid dates'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
