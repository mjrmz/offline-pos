import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/promotion_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/promotions/promotions_screen.dart';

void main() {
  testWidgets('empty workspace and create form validation', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db))
        .bootstrap('Owner', 'password123', 'Q?', 'answer');
    final repo = PromotionRepository(db);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PromotionsScreen(
                repository: repo,
                user: ActiveUser(id, 'Owner', UserRole.owner)))));
    await tester.pumpAndSettle();
    expect(find.text('No promotions yet'), findsOneWidget);
    await tester.tap(find.text('New promotion'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save promotion'));
    await tester.pumpAndSettle();
    expect(find.text('Name required'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Weekend');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Discount (%)'), '10');
    await tester.tap(find.text('Save promotion'));
    await tester.pumpAndSettle();
    expect(
        await repo.countPromotions(ActiveUser(id, 'Owner', UserRole.owner)), 1);
  });

  testWidgets('workspace and editor fit desktop sizes in both themes',
      (tester) async {
    for (final size in [
      const Size(1366, 768),
      const Size(1600, 900),
      const Size(1920, 1080)
    ]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        final id = await AuthService(AuthRepository(db))
            .bootstrap('Owner', 'password123', 'Q?', 'answer');
        await tester.pumpWidget(MaterialApp(
            themeMode: mode,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            home: Scaffold(
                body: PromotionsScreen(
                    repository: PromotionRepository(db),
                    user: ActiveUser(id, 'Owner', UserRole.owner)))));
        await tester.pumpAndSettle();
        await tester.tap(find.text('New promotion'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('BASIC INFORMATION'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await db.close();
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  testWidgets('detail separates performance and activity; duplicate is a draft',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await AuthService(AuthRepository(db))
        .bootstrap('Owner', 'password123', 'Q?', 'answer');
    final owner = ActiveUser(id, 'Owner', UserRole.owner);
    final repo = PromotionRepository(db);
    await repo.createPromotion(
        owner,
        const PromotionInput(
            name: 'Weekend',
            type: 'fixed',
            rewardKind: 'fixed',
            rewardValue: 500,
            active: true));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PromotionsScreen(repository: repo, user: owner))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekend').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Performance'));
    await tester.pumpAndSettle();
    expect(find.text('Promoted sales'), findsOneWidget);
    expect(find.text('Top promoted products'), findsOneWidget);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Configuration changes'), findsOneWidget);
    expect(find.textContaining('created'), findsWidgets);
    await tester.tap(find.text('Duplicate promotion'));
    await tester.pumpAndSettle();
    final copies = await repo.listPromotions(owner, search: 'Copy');
    expect(copies, hasLength(1));
    expect(copies.single.isDraft, isTrue);
    expect(tester.takeException(), isNull);
  });
}
