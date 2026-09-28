import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/features/pos_checkout/checkout_screen.dart';

void main() {
  test('cash input accepts integer cents without floating point', () {
    expect(tryParseMoney('100'), 10000);
    expect(tryParseMoney('100.00'), 10000);
    expect(tryParseMoney('40.50'), 4050);
    expect(tryParseMoney(' 100.00 '), 10000);
    expect(tryParseMoney(''), isNull);
    expect(tryParseMoney('   '), isNull);
    expect(tryParseMoney('abc'), isNull);
    expect(tryParseMoney('1.234'), isNull);
    expect(tryParseMoney('-1'), isNull);
    expect(tryParseMoney('999999999999999999999'), isNull);
  });

  test('cash and quantity validation messages', () {
    expect(cashValidationMessage('', 8000), 'Enter cash received');
    expect(cashValidationMessage('   ', 8000), 'Enter cash received');
    expect(cashValidationMessage('abc', 8000), contains('valid amount'));
    expect(cashValidationMessage('1.234', 8000), contains('valid amount'));
    expect(cashValidationMessage('-1', 8000), contains('valid amount'));
    expect(cashValidationMessage('0', 8000), contains('greater than zero'));
    expect(cashValidationMessage('50', 8000), contains('below the total'));
    expect(cashValidationMessage('100', 8000), isNull);
    expect(cashValidationMessage('100.00', 8000), isNull);
    expect(quantityValidationMessage(''), isNotNull);
    expect(quantityValidationMessage('abc'), isNotNull);
    expect(quantityValidationMessage('0'), isNotNull);
    expect(quantityValidationMessage('-1'), isNotNull);
    expect(quantityValidationMessage('2'), isNull);
  });

  testWidgets('invalid cash disables checkout and writes nothing',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = PosRepository(db);
    final auth = AuthService(AuthRepository(db));
    final ownerId =
        await auth.bootstrap('Owner', 'password123', 'Question?', 'answer');
    await auth.login(ownerId, 'password123');
    final id = await repo.saveProduct(
        name: 'Coke', priceCents: 4000, costCents: 0, startingStock: 10);
    await tester.pumpWidget(MaterialApp(
        home:
            CheckoutScreen(repository: repo, user: auth.current!, auth: auth)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump();
    final button = find.widgetWithText(FilledButton, 'Complete sale');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(find.text('Enter cash received'), findsWidgets);
    for (final value in ['abc', '1.234', '-1', '0', '20']) {
      await tester.enterText(
          find.widgetWithText(TextField, 'Cash received'), value);
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
    }
    for (final value in ['100', '100.00', '40.50']) {
      await tester.enterText(
          find.widgetWithText(TextField, 'Cash received'), value);
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    }
    expect(await db.select(db.sales).get(), isEmpty);
    expect(await db.select(db.saleItems).get(), isEmpty);
    expect(await db.select(db.payments).get(), isEmpty);
    expect((await repo.movements(id)).length, 1);
    expect(await repo.stock(id), 10);
  });
}
