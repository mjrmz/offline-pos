import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/audit_explorer_repository.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/features/audit/audit_explorer_screen.dart';

class _FailOnceRepository extends AuditExplorerRepository {
  _FailOnceRepository(super.db);
  bool fail = true;
  @override
  Future<AuditExplorerPage> page(ActiveUser user, AuditExplorerFilter filter) {
    if (fail) {
      fail = false;
      return Future.error(StateError('database internals'));
    }
    return super.page(user, filter);
  }
}

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> show(WidgetTester tester, ActiveUser user,
      {Size size = const Size(1366, 768),
      ThemeMode themeMode = ThemeMode.light}) async {
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: themeMode,
        home: Scaffold(
            body: AuditExplorerScreen(
                repository: AuditExplorerRepository(db),
                user: user,
                auth: AuthService(AuthRepository(db)),
                products: PosRepository(db)))));
    await tester.pumpAndSettle();
  }

  testWidgets('unauthorized viewer cannot open audit list', (tester) async {
    await show(
        tester, const ActiveUser('cashier', 'Cashier', UserRole.cashier));
    expect(find.text('Audit access is not available for this account.'),
        findsOneWidget);
  });

  testWidgets('filters, drawer and empty state fit desktop', (tester) async {
    await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
        action: 'sale.completed',
        details: const Value('INV-000001'),
        createdAt: Value(DateTime.now())));
    await show(tester, const ActiveUser('owner', 'Owner', UserRole.owner));
    expect(find.text('Completed sale'), findsOneWidget);
    expect(find.text('INV-000001'), findsOneWidget);
    await tester.tap(find.text('Completed sale'));
    await tester.pumpAndSettle();
    expect(find.text('Affected record'), findsOneWidget);
    await tester.tap(find.byTooltip('Close details'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'no-such-event');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.textContaining('No matching activity'), findsOneWidget);
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('Completed sale'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(1600, 900), const Size(1920, 1080)]) {
    testWidgets('desktop ${size.width.toInt()} fits in dark theme',
        (tester) async {
      await show(tester, const ActiveUser('owner', 'Owner', UserRole.owner),
          size: size, themeMode: ThemeMode.dark);
      expect(find.text('Audit Explorer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('error is safe and Retry reloads', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AuditExplorerScreen(
                repository: _FailOnceRepository(db),
                user: const ActiveUser('owner', 'Owner', UserRole.owner),
                auth: AuthService(AuthRepository(db)),
                products: PosRepository(db)))));
    await tester.pumpAndSettle();
    expect(find.text('Could not load activity.'), findsOneWidget);
    expect(find.textContaining('database internals'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No matching activity'), findsOneWidget);
  });
}
