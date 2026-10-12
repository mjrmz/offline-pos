import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/layaway_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/layaway_screen.dart';
import 'package:modern_offline_pos/features/contacts/quotation_screen.dart';

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
        'quotation workspace is structured on ${mobile ? 'mobile' : 'desktop'}',
        (tester) async {
      tester.view.physicalSize =
          mobile ? const Size(390, 844) : const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
      await auth.login(id, 'password123');
      await tester.pumpWidget(MaterialApp(
          home: QuotationScreen(
              repository: QuotationRepository(db, PosRepository(db)),
              directory: DirectoryRepository(db),
              products: PosRepository(db),
              user: auth.current!)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New quotation'));
      await tester.pumpAndSettle();
      expect(find.text('Customer and validity'), findsOneWidget);
      expect(find.text('Walk-in customer'), findsOneWidget);
      expect(find.text('Items'), findsOneWidget);
      expect(find.text('Save quotation'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Save quotation'))
              .onPressed,
          isNull);
    });

    testWidgets(
        'layaway requires customer and items on ${mobile ? 'mobile' : 'desktop'}',
        (tester) async {
      tester.view.physicalSize =
          mobile ? const Size(390, 844) : const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id =
          await auth.bootstrap('Owner', 'password123', 'Question?', 'Answer');
      await auth.login(id, 'password123');
      await tester.pumpWidget(MaterialApp(
          home: LayawayScreen(
              repository: LayawayRepository(db, PosRepository(db)),
              directory: DirectoryRepository(db),
              products: PosRepository(db),
              user: auth.current!)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New layaway'));
      await tester.pumpAndSettle();
      expect(find.text('Reserved items'), findsOneWidget);
      expect(find.text('Walk-in'), findsNothing);
      expect(find.text('Create layaway'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Create layaway'))
              .onPressed,
          isNull);
    });
  }
}
