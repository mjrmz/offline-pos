import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/auth/auth_screen.dart';

void main() {
  testWidgets('first-run owner setup and local password login', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    var loggedIn = false;
    await tester.pumpWidget(MaterialApp(
        home: AuthScreen(auth: auth, onChanged: () => loggedIn = true)));
    await tester.pumpAndSettle();
    expect(find.text('First owner setup'), findsOneWidget);
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
    await tester.tap(find.text('Create owner'));
    await tester.pumpAndSettle();
    expect(find.text('Login'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Password'), 'ownerPassword123');
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(loggedIn, true);
    expect(auth.current?.name, 'Owner');
  });
}
