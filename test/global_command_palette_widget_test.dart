import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/global_search_repository.dart';
import 'package:modern_offline_pos/features/dashboard/global_command_palette.dart';

class DelayedSearch extends GlobalSearchRepository {
  DelayedSearch(super.db);
  final pending = <String, Completer<List<GlobalSearchResult>>>{};
  @override
  Future<List<GlobalSearchResult>> search(ActiveUser user, String query) {
    final completer = Completer<List<GlobalSearchResult>>();
    pending[query] = completer;
    return completer.future;
  }
}

void main() {
  const owner = ActiveUser('owner', 'Owner', UserRole.owner);

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('keyboard and mouse palette behavior in $brightness',
        (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db.into(db.products).insert(ProductsCompanion.insert(
          name: 'Wireless Mouse', priceCents: 65000));
      GlobalSearchResult? chosen;
      await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: brightness),
          home: Scaffold(body: Builder(builder: (context) => TextButton(
              onPressed: () async {
                chosen = await showDialog<GlobalSearchResult>(context: context,
                    builder: (_) => GlobalCommandPalette(
                        repository: GlobalSearchRepository(db), user: owner));
              }, child: const Text('Open palette'))))));
      await tester.tap(find.text('Open palette'));
      await tester.pumpAndSettle();
      expect(find.text('Commands'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen?.title, 'Receive Stock');
      await tester.tap(find.text('Open palette'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('global-search-input')), 'Wireless');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Products'), findsOneWidget);
      expect(find.text('Wireless Mouse'), findsOneWidget);
      await tester.tap(find.text('Wireless Mouse'));
      await tester.pumpAndSettle();
      expect(chosen?.kind, GlobalSearchKind.product);
      await tester.tap(find.text('Open palette'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(GlobalCommandPalette), findsNothing);
      await tester.tap(find.text('Open palette'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen?.title, 'Open Settings');
      await tester.tap(find.text('Open palette'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(GlobalCommandPalette), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('late results cannot replace newer query', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final delayed = DelayedSearch(db);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
        builder: (context) => TextButton(onPressed: () => showDialog<void>(
            context: context, builder: (_) => GlobalCommandPalette(
                repository: delayed, user: owner)), child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('global-search-input'));
    await tester.enterText(input, 'mo');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(input, 'mouse');
    await tester.pump(const Duration(milliseconds: 300));
    delayed.pending['mouse']!.complete(const [GlobalSearchResult(
        kind: GlobalSearchKind.product, id: 'new', title: 'Mouse result',
        subtitle: 'New query')]);
    await tester.pump();
    delayed.pending['mo']!.complete(const [GlobalSearchResult(
        kind: GlobalSearchKind.product, id: 'old', title: 'Old result',
        subtitle: 'Old query')]);
    await tester.pumpAndSettle();
    expect(find.text('Mouse result'), findsOneWidget);
    expect(find.text('Old result'), findsNothing);
  });
}
