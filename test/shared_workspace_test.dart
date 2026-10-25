import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/shared/widgets/app_confirm_dialog.dart';
import 'package:modern_offline_pos/shared/widgets/app_feedback.dart';
import 'package:modern_offline_pos/shared/widgets/app_workspace.dart';

void main() {
  testWidgets('workspace sections share the local shell gutter',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final (width, gutter) in <(double, double)>[
      (1130, 24),
      (1364, 28),
      (1684, 32),
    ]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
        body: AppWorkspacePadding(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AppPageHeader(title: 'Workspace', subtitle: 'Records'),
          const AppMetricGrid(children: [
            AppMetricTile(label: 'Count', value: '1'),
          ]),
          const SizedBox(height: 20),
          const AppSearchField(hintText: 'Search'),
          const SizedBox(height: 20),
          Expanded(
              child: AppPagedListPanel(
                  title: 'Items',
                  total: 0,
                  count: 0,
                  itemBuilder: (_, __) => const SizedBox.shrink())),
        ])),
      )));
      await tester.pumpAndSettle();
      final left = tester.getTopLeft(find.text('Workspace')).dx;
      expect(left, gutter);
      expect(tester.getTopLeft(find.byType(AppMetricTile)).dx, left);
      expect(tester.getTopLeft(find.byType(AppSearchField)).dx, left);
      expect(tester.getTopLeft(find.byType(AppPagedListPanel)).dx, left);
      expect(tester.getBottomRight(find.byType(AppPagedListPanel)).dx,
          width - gutter);
      expect(tester.takeException(), isNull);
    }
  });

  Widget panel(int total, int count, int page) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: AppPagedListPanel(
              title: 'Records',
              total: total,
              count: count,
              page: page,
              itemBuilder: (_, index) => Text('Record $index'),
              onPrevious: () {},
              onNext: () {},
            ),
          ),
        ),
      );

  for (final total in [0, 1, 50]) {
    testWidgets('$total records hides page controls', (tester) async {
      await tester.pumpWidget(panel(total, total, 0));
      expect(find.text('Previous'), findsNothing);
      expect(find.text('Next'), findsNothing);
    });
  }

  testWidgets('51 records shows the correct first and second page ranges',
      (tester) async {
    await tester.pumpWidget(panel(51, 50, 0));
    expect(find.text('Showing 1–50 of 51'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    await tester.pumpWidget(panel(51, 1, 1));
    expect(find.text('Showing 51–51 of 51'), findsOneWidget);
    expect(find.text('Previous'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
  });

  testWidgets('100 records shows two full pages', (tester) async {
    await tester.pumpWidget(panel(100, 50, 1));
    expect(find.text('Showing 51–100 of 100'), findsOneWidget);
    expect(find.text('Previous'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
  });

  testWidgets('destructive confirmation defaults to cancel', (tester) async {
    var result = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showAppDestructiveConfirmDialog(
                      context: context,
                      title: 'Cancel quotation',
                      impact: 'The quotation cannot be converted.',
                      confirmLabel: 'Cancel quotation',
                    );
                  },
                  child: const Text('Open'),
                )),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('This action cannot be undone.'), findsOneWidget);
    await tester.tap(find.text('Keep record'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('destructive confirmation requires explicit action',
      (tester) async {
    var result = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showAppDestructiveConfirmDialog(
                      context: context,
                      title: 'Cancel quotation',
                      impact: 'The quotation cannot be converted.',
                      confirmLabel: 'Cancel quotation',
                    );
                  },
                  child: const Text('Open'),
                )),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel quotation').last);
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('routine feedback disappears after three seconds',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                  onPressed: () => showAppFeedback(context, 'Saved'),
                  child: const Text('Save'),
                )),
      ),
    ));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsNothing);
  });
}
