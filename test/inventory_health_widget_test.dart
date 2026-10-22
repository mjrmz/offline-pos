import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/inventory_health_repository.dart';
import 'package:modern_offline_pos/data/daos/stock_count_repository.dart';
import 'package:modern_offline_pos/features/inventory/expiry_monitor_screen.dart';
import 'package:modern_offline_pos/features/inventory/stock_counts_screen.dart';
import 'package:modern_offline_pos/features/settings/inventory_health_settings_screen.dart';

void main() {
  testWidgets('settings reject invalid thresholds and save valid values',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(MaterialApp(
        home: InventoryHealthSettingsScreen(
            repository: InventoryHealthRepository(db))));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '90');
    await tester.enterText(fields.at(1), '60');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.textContaining('Dead stock must be at least'), findsOneWidget);
    await tester.enterText(fields.at(1), '180');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await InventoryHealthRepository(db).settings()).slowMovingDays, 90);
  });

  testWidgets(
      'expiry monitor shows remaining stock and hides cost from cashier',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Batch product', 500, 1)");
    await db.customStatement(
        "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p', 2, 2000)");
    final expired = DateTime.now()
            .subtract(const Duration(days: 2))
            .millisecondsSinceEpoch ~/
        1000;
    await db.customStatement(
        "INSERT INTO inventory_layers (id, product_id, source, quantity_received_milli, quantity_remaining_milli, unit_cost_cents, received_at, batch_number, expiry_date) VALUES ('live','p','opening',3000,2000,100,1,'LOT-1',$expired)");
    await db.customStatement(
        "INSERT INTO inventory_layers (id, product_id, source, quantity_received_milli, quantity_remaining_milli, unit_cost_cents, received_at, batch_number, expiry_date) VALUES ('gone','p','opening',1000,0,100,1,'LOT-OLD',$expired)");
    await tester.pumpWidget(MaterialApp(
        home: ExpiryMonitorScreen(
            repository: InventoryHealthRepository(db),
            user: const ActiveUser('cashier', 'Cashier', UserRole.cashier))));
    await tester.pumpAndSettle();
    expect(find.text('LOT-1'), findsOneWidget);
    expect(find.text('LOT-OLD'), findsNothing);
    expect(find.text('Expired'), findsWidgets);
    expect(find.text('Cost Value'), findsNothing);
    expect((await db.select(db.inventory).getSingle()).quantityMilli, 2000);
  });

  testWidgets('expired adjustment prefill still requires explicit post',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
        "INSERT INTO users (id, name, role) VALUES ('owner', 'Owner', 'owner')");
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('p', 'Batch product', 500, 1)");
    await db.customStatement(
        "INSERT INTO inventory (product_id, quantity, quantity_milli) VALUES ('p', 2, 2000)");
    await tester.pumpWidget(MaterialApp(
        home: Material(
            child: StockCountsScreen(
      repository: StockCountRepository(db),
      user: const ActiveUser('owner', 'Owner', UserRole.owner),
      initialAdjustmentProductId: 'p',
      initialAdjustmentBatch: 'LOT-1',
      initialAdjustmentQtyMilli: 2000,
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Adjust Stock'), findsWidgets);
    final amount = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Change (+ or -)'));
    final batch = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Batch number (batch products)'));
    expect(amount.controller!.text, '-2');
    expect(batch.controller!.text, 'LOT-1');
    expect(find.text('Expired'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await db.select(db.inventoryAdjustments).get(), isEmpty);
    expect((await db.select(db.inventory).getSingle()).quantityMilli, 2000);
  });
}
