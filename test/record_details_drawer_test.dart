import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/shared/widgets/record_details_drawer.dart';

void main() {
  testWidgets(
      'details drawer opens beside list and closes by X, Escape and backdrop',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var actionCount = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TextButton(
          onPressed: () => showRecordDetailsDrawer<void>(
            context: tester.element(find.byType(TextButton).first),
            builder: (context) => RecordDetailsDrawer(
              title: const Text('Record 123'),
              content: Column(children: [
                const Text('Details'),
                const SizedBox(height: 1200),
                const Text('End of details'),
              ]),
              actions: [
                TextButton(
                  onPressed: () => actionCount++,
                  child: const Text('Action'),
                )
              ],
            ),
          ),
          child: const Text('Open record'),
        ),
      ),
    ));
    Future<void> open() async {
      await tester.tap(find.text('Open record'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('record-details-drawer')), findsOneWidget);
      expect(find.text('Open record'), findsOneWidget);
    }

    await open();
    final drawer = find.byKey(const Key('record-details-drawer'));
    expect(tester.getSize(drawer).width, 560);
    expect(tester.getTopLeft(drawer).dx, 806);
    final headerTop = tester.getTopLeft(find.text('Record 123')).dy;
    final actionTop = tester.getTopLeft(find.text('Action')).dy;
    await tester.drag(
        find.byKey(const Key('record-details-scroll')), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Record 123')).dy, headerTop);
    expect(tester.getTopLeft(find.text('Action')).dy, actionTop);
    await tester.tap(find.text('Action'));
    expect(actionCount, 1);
    await tester.tap(find.byTooltip('Close details'));
    await tester.pumpAndSettle();
    expect(drawer, findsNothing);

    await open();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(drawer, findsNothing);

    await open();
    await tester.tapAt(const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(drawer, findsNothing);
  });

  testWidgets('narrow drawer, zero stock and missing progress fit safely',
      (tester) async {
    tester.view.physicalSize = const Size(420, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showRecordDetailsDrawer<void>(
          context: context,
          builder: (context) => RecordDetailsDrawer(
            width: 680,
            title:
                const Text('A very long product or order name that must fit'),
            content: const Column(children: [
              DrawerMetricGrid(metrics: [
                DrawerMetric(label: 'Physical stock', value: '0'),
                DrawerMetric(label: 'Reserved stock', value: '0'),
              ]),
              DrawerStockDonut(
                  available: 0,
                  reserved: 0,
                  availableLabel: '0 units',
                  reservedLabel: '0 units'),
              DrawerProgressSummary(value: null, label: 'Receiving progress'),
            ]),
            primaryAction: FilledButton(
                onPressed: null, child: const Text('Open full details')),
            secondaryActions: [
              OutlinedButton(onPressed: () {}, child: const Text('Print PO')),
              OutlinedButton(onPressed: () {}, child: const Text('Save PDF')),
              OutlinedButton(
                  onPressed: () {}, child: const Text('Duplicate PO')),
            ],
          ),
        ),
        child: const Text('Open'),
      ),
    ))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('record-details-drawer'))).width,
        420);
    expect(find.text('No physical stock to chart.'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
