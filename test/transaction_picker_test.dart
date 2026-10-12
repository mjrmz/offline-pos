import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/product.dart';
import 'package:modern_offline_pos/shared/widgets/transaction_picker.dart';

void main() {
  testWidgets('product search matches SKU and keeps the price visible',
      (tester) async {
    PosProduct? selected;
    const mouse =
        PosProduct('mouse', 'Logitech Mouse', '12345', 50000, true, 'M-01');
    const keyboard =
        PosProduct('keyboard', 'Keyboard', null, 75000, true, 'K-01');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TransactionProductPicker(
                products: const [mouse, keyboard],
                onSelected: (p) => selected = p))));
    await tester.enterText(find.byType(TextField), 'M-01');
    await tester.pumpAndSettle();
    expect(find.text('Logitech Mouse'), findsOneWidget);
    expect(find.textContaining('500.00'), findsOneWidget);
    expect(find.text('Keyboard'), findsNothing);
    await tester.tap(find.text('Logitech Mouse'));
    expect(selected?.id, 'mouse');
  });

  testWidgets('transaction total renders peso amount', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body:
                TransactionTotal('Remaining balance', 2500000, strong: true))));
    expect(find.text('Remaining balance'), findsOneWidget);
    expect(find.textContaining('25,000.00'), findsOneWidget);
  });
}
