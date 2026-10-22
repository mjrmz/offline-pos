import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/auth/auth_screen.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/models/printer_settings.dart';
import 'package:modern_offline_pos/data/daos/printer_settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final size in const [
    Size(1366, 768),
    Size(1600, 900),
    Size(1920, 1080),
    Size(480, 800)
  ]) {
    testWidgets('login fits $size', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
      await tester.pumpWidget(
          MaterialApp(home: AuthScreen(auth: auth, onChanged: () {})));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.text('Log in'), findsOneWidget);
      expect(find.text('Recover owner password offline'), findsOneWidget);
      expect(find.byTooltip('Show credential'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cashier uses PIN and manager uses password', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
    await auth.login(ownerId, 'ownerPassword123');
    await auth.createUser('Cashier A', UserRole.cashier, '1234');
    await auth.createUser('Manager A', UserRole.manager, 'managerPassword123');
    await auth.logout();
    await tester.pumpWidget(
        MaterialApp(home: AuthScreen(auth: auth, onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cashier A (Cashier)').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'PIN'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'PIN'))
            .obscureText,
        isTrue);
    expect(find.text('Recover owner password offline'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manager A (Manager)').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget);
  });

  testWidgets('configured business name and missing logo fallback in dark mode',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'business.logo.path': 'C:/missing/logo.png'});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
    await PrinterSettingsStore(db)
        .save(const PrinterSettings(storeName: 'Retail Demo'));
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: AuthScreen(auth: auth, onChanged: () {})));
    await tester.pumpAndSettle();
    expect(find.text('Retail Demo'), findsOneWidget);
    expect(find.byIcon(Icons.storefront_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed password shows contextual error and visibility toggles',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
    await tester.pumpWidget(
        MaterialApp(home: AuthScreen(auth: auth, onChanged: () {})));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'wrong');
    await tester.tap(find.byTooltip('Show credential'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide credential'), findsOneWidget);
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect password.'), findsOneWidget);
  });
  testWidgets('existing lockout disables login and shows remaining time',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id =
        await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
    for (var attempt = 0; attempt < AuthService.maxAttempts; attempt++) {
      try {
        await auth.login(id, 'wrong');
      } on StateError catch (_) {}
    }
    await tester.pumpWidget(
        MaterialApp(home: AuthScreen(auth: auth, onChanged: () {})));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Account temporarily locked. Try again in'),
        findsOneWidget);
    final button = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Log in'));
    expect(button.onPressed, isNull);
  });

  testWidgets('credential receives initial focus and Enter submits',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    await auth.bootstrap('MJ', 'ownerPassword123', 'Place?', 'Baguio');
    var loggedIn = false;
    await tester.pumpWidget(MaterialApp(
        home: AuthScreen(auth: auth, onChanged: () => loggedIn = true)));
    await tester.pumpAndSettle();
    final field =
        tester.widget<TextField>(find.widgetWithText(TextField, 'Password'));
    expect(field.focusNode?.hasFocus, isTrue);
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'ownerPassword123');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(loggedIn, isTrue);
  });

  testWidgets('first-run owner setup and local password login', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    var loggedIn = false;
    await tester.pumpWidget(MaterialApp(
        home: AuthScreen(auth: auth, onChanged: () => loggedIn = true)));
    await tester.pumpAndSettle();
    expect(find.text('Set up your workspace'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextField, 'Owner name'), 'Owner');
    await tester.enterText(
        find.widgetWithText(TextField, 'Owner password (8+ characters)'),
        'ownerPassword123');
    await tester.enterText(
        find.widgetWithText(TextField, 'Offline recovery question'),
        'Favorite place?');
    await tester.enterText(
        find.widgetWithText(TextField, 'Recovery answer'), 'Baguio');
    await tester.ensureVisible(find.text('Create owner'));
    await tester.tap(find.text('Create owner'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'ownerPassword123');
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(loggedIn, true);
    expect(auth.current?.name, 'Owner');
  });
}
