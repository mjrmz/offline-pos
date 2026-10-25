import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/core/services/sales_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/directory_repository.dart';
import 'package:modern_offline_pos/data/daos/layaway_repository.dart';
import 'package:modern_offline_pos/data/daos/pos_repository.dart';
import 'package:modern_offline_pos/data/daos/quotation_repository.dart';
import 'package:modern_offline_pos/data/daos/sales_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/layaway_screen.dart';
import 'package:modern_offline_pos/features/contacts/quotation_screen.dart';
import 'package:modern_offline_pos/features/sales_history/sales_history_screen.dart';
import 'package:modern_offline_pos/shared/widgets/app_workspace.dart';

void main() {
  testWidgets('Sales, Quotations and Layaway use one shell gutter',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final user = auth.current!;
    final pos = PosRepository(db);
    final directory = DirectoryRepository(db);
    final screens = <(Widget, Key)>[
      (
        SalesHistoryScreen(
            sales: SalesService(SalesRepository(db), auth), user: user),
        const Key('sales-transaction-workspace')
      ),
      (
        QuotationScreen(
            repository: QuotationRepository(db, pos),
            directory: directory,
            products: pos,
            user: user),
        const Key('quotation-list-panel')
      ),
      (
        LayawayScreen(
            repository: LayawayRepository(db, pos),
            directory: directory,
            products: pos,
            user: user),
        const Key('layaway-list-panel')
      ),
    ];
    for (final (screen, panelKey) in screens) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Row(children: [
        const SizedBox(width: 236),
        Expanded(child: screen),
      ]))));
      await tester.pumpAndSettle();
      const left = 236.0 + 28.0;
      expect(tester.getTopLeft(find.byType(AppPageHeader)).dx, left);
      expect(tester.getTopLeft(find.byType(AppMetricTile).first).dx, left);
      expect(tester.getTopLeft(find.byType(AppSearchField)).dx, left);
      expect(tester.getTopLeft(find.byKey(panelKey)).dx, left);
      expect(tester.getBottomRight(find.byKey(panelKey)).dx, 1600 - 28);
      expect(tester.takeException(), isNull);
    }
  });
}
