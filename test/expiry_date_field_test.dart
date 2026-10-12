import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/shared/widgets/expiry_date_field.dart';

void main() {
  testWidgets('expiry can be selected and cleared without typing',
      (tester) async {
    DateTime? date;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
      builder: (context, update) => Scaffold(
        body: ExpiryDateField(
          value: date,
          onChanged: (value) => update(() => date = value),
        ),
      ),
    )));
    await tester.tap(find.text('Choose expiry date'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(date, isNotNull);
    expect(find.byTooltip('Clear expiry date'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear expiry date'));
    await tester.pump();
    expect(date, isNull);
  });
}
