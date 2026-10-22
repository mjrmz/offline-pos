import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/features/contacts/documents/quotation_preview.dart';

void main() {
  testWidgets(
      'desktop quotation preview defaults to fit page and exposes zoom controls',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1366, 768);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
        home: QuotationPreview(
      bytes: Uint8List(0),
      reference: 'Q-2026-000002',
      onPrint: () {},
      onSave: () {},
      onShare: () {},
    )));
    expect(find.text('Fit page'), findsOneWidget);
    expect(find.text('Fit width'), findsOneWidget);
    final fitPercent =
        tester.widget<Text>(find.byKey(const Key('quotePreviewZoom'))).data;
    expect(fitPercent, isNot('100%'));
    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pump();
    final smaller =
        tester.widget<Text>(find.byKey(const Key('quotePreviewZoom'))).data;
    expect(int.parse(smaller!.replaceAll('%', '')),
        lessThan(int.parse(fitPercent!.replaceAll('%', ''))));
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('quotePreviewZoom'))).data,
        fitPercent);
    await tester.tap(find.text('Fit width'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('quotePreviewZoom'))).data,
        isNotNull);
    await tester.tap(find.text('Fit page'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('quotePreviewZoom'))).data,
        fitPercent);
  });
}
