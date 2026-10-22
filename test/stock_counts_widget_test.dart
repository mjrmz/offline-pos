import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';
import 'package:modern_offline_pos/features/inventory/stock_counts_screen.dart';

void main() {
  for (final size in [
    const Size(1366, 768),
    const Size(1600, 900),
    const Size(1920, 1080)
  ]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('stock count editor fits $size in $mode', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final auth = AuthService(AuthRepository(db));
        final ownerId =
            await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
        await auth.login(ownerId, 'password123');
        await PosRepository(db).saveProduct(
            name: 'BIOGESIC',
            priceCents: 1000,
            costCents: 500,
            startingStock: 10);
        await tester.pumpWidget(MaterialApp(
            themeMode: mode,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            home: Scaffold(
                body: StockCountsScreen(
                    repository: StockCountRepository(db),
                    user: auth.current!))));
        await tester.pumpAndSettle();
        expect(find.text('Stock Counts'), findsOneWidget);
        await tester.tap(find.text('+ New Stock Count'));
        await tester.pumpAndSettle();
        expect(find.text('New Stock Count'), findsOneWidget);
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(find.text('SC-000001'), findsOneWidget);
        expect(find.text('BIOGESIC'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Escape and Cancel close count dialog without writes',
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
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    await PosRepository(db).saveProduct(
        name: 'A', priceCents: 1000, costCents: 500, startingStock: 1);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StockCountsScreen(
                repository: StockCountRepository(db), user: auth.current!))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ New Stock Count'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await db.select(db.stockCounts).get(), isEmpty);
    await tester.tap(find.text('+ New Stock Count'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await db.select(db.stockCounts).get(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct count entry reviews and posts one variance',
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
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    final pos = PosRepository(db);
    final id = await pos.saveProduct(
        name: 'BIOGESIC', priceCents: 1000, costCents: 500, startingStock: 10);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StockCountsScreen(
                repository: StockCountRepository(db), user: auth.current!))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ New Stock Count'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final counted = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.hintText == 'Counted');
    expect(tester.widget<TextField>(counted).controller!.text, isEmpty);
    await tester.enterText(counted, '8');
    await tester.pumpAndSettle();
    expect(find.textContaining('Counted 1 / 1'), findsOneWidget);
    expect(find.text('Short'), findsOneWidget);
    await tester.tap(find.text('Review & Finalize'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 variances'), findsOneWidget);
    await tester.tap(find.text('Finalize Stock Count'));
    await tester.pumpAndSettle();
    expect(await pos.stockMilli(id), 8000);
    expect((await db.select(db.inventoryAdjustments).get()).single.deltaMilli,
        -2000);
    expect(find.text('Short'), findsOneWidget);
    expect(find.text('Stale'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blank, zero, exact, invalid and immediate review stay in sync',
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
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(ownerId, 'password123');
    await PosRepository(db).saveProduct(
        name: 'Soap', priceCents: 1000, costCents: 500, startingStock: 10);
    final repository = StockCountRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: StockCountsScreen(
                repository: repository, user: auth.current!))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ New Stock Count'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final counted = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == 'Counted');
    expect(tester.widget<TextField>(counted).controller!.text, isEmpty);
    expect(find.text('Uncounted'), findsOneWidget);
    await tester.enterText(counted, '0');
    await tester.pumpAndSettle();
    expect(find.textContaining('Counted 1 / 1'), findsOneWidget);
    expect(find.text('Short'), findsOneWidget);
    expect(
        (await repository.lines((await repository.counts()).single.id))
            .single
            .countedMilli,
        0);
    await tester.enterText(counted, '10');
    await tester.pumpAndSettle();
    expect(find.text('Matched'), findsOneWidget);
    expect(find.textContaining('Variances 0'), findsWidgets);
    await tester.enterText(counted, '');
    await tester.pumpAndSettle();
    expect(find.text('Uncounted'), findsOneWidget);
    expect(find.textContaining('Counted 0 / 1'), findsOneWidget);
    await tester.enterText(counted, 'bad');
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid count'), findsOneWidget);
    await tester.enterText(counted, '9');
    await tester.tap(find.text('Review & Finalize'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 counted; 1 variances'), findsOneWidget);
    expect(
        (await repository.lines((await repository.counts()).single.id))
            .single
            .countedMilli,
        9000);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SC-000001'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(counted).controller!.text, '9');
    expect(find.textContaining('Counted 1 / 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
