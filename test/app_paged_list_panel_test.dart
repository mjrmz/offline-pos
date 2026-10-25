import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/shared/widgets/app_workspace.dart';

void main() {
  Widget harness(int total, int page,
          {VoidCallback? next, VoidCallback? previous}) =>
      MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 900,
        height: 400,
        child: AppPagedListPanel(
          title: 'Quotations',
          total: total,
          page: page,
          count: (total - page * 50).clamp(0, 50),
          onNext: next,
          onPrevious: previous,
          itemBuilder: (_, index) => SizedBox(
              height: 74, child: Text('Record ${page * 50 + index + 1}')),
        ),
      )));

  testWidgets('one page has a header and no pagination controls',
      (tester) async {
    await tester.pumpWidget(harness(50, 0));
    expect(find.text('50 results'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(find.text('Previous'), findsNothing);
    expect(find.text('Page 1 of 1'), findsNothing);
    expect(find.byType(Scrollable), findsOneWidget);
    expect(find.text('Record 50'), findsNothing);
    await tester.scrollUntilVisible(find.text('Record 50'), 500,
        scrollable: find.byType(Scrollable));
    expect(find.text('Record 50'), findsOneWidget);
  });

  testWidgets('51 results expose only the applicable direction',
      (tester) async {
    await tester.pumpWidget(harness(51, 0, next: () {}));
    expect(find.text('Showing 1–50 of 51'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Previous'), findsNothing);
    await tester.pumpWidget(harness(51, 1, previous: () {}));
    expect(find.text('Showing 51–51 of 51'), findsOneWidget);
    expect(find.text('Previous'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('metric grid fits a compact desktop in $brightness',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1130, 768));
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: AppMetricGrid(children: [
              for (var i = 0; i < 7; i++)
                AppMetricTile(label: 'Awaiting supplier', value: '$i'),
            ]),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      final first = tester.getTopLeft(find.byType(AppMetricTile).first);
      final fifth = tester.getTopLeft(find.byType(AppMetricTile).at(4));
      expect(fifth.dy, greaterThan(first.dy));
      await tester.binding.setSurfaceSize(null);
    });
  }
}
