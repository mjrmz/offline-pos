import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/core/services/auth_service.dart';
import 'package:modern_offline_pos/data/daos/auth_repository.dart';
import 'package:modern_offline_pos/data/daos/rma_repository.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/features/contacts/rma_screen.dart';
import 'package:modern_offline_pos/features/contacts/rma_detail_page.dart';

void main() {
  testWidgets('wide queue stays structured in light and dark', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) VALUES ('wide', 'RMA-2026-000100', 'customer', 'Issue', '', 1000, 'pending', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, created_at) VALUES ('wide-event', 'wide', ?, 'requested', ?)",
        [userId, now]);
    for (final width in [1600.0, 1920.0]) {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        tester.view.physicalSize = Size(width, width == 1600 ? 900 : 1080);
        await tester.pumpWidget(MaterialApp(
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            themeMode: mode,
            home:
                RmaScreen(repository: RmaRepository(db), user: auth.current!)));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('rma-row-wide')), findsOneWidget);
        expect(tester.getSize(find.byKey(const ValueKey('rma-row-wide'))).width,
            lessThanOrEqualTo(1460));
        expect(find.byKey(const ValueKey('active-workspace-heading')),
            findsOneWidget);
        expect(
            tester
                .getSize(find.byKey(const ValueKey('workspace-customer')))
                .height,
            greaterThanOrEqualTo(40));
        expect(find.text('Today'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('queue begins at 1366 and searches receipt', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final userId = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(userId, 'password123');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('customer', 'Walk-in account', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO products (id, name, sku, price_cents, created_at) VALUES ('product', 'Motherboard', 'MB-01', 350000, ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO sales (id, receipt_number, cashier_id, customer_id, total_cents, created_at) VALUES ('sale', 'POS-000124', ?, 'customer', 350000, ?)",
        [userId, now]);
    await db.customStatement(
        "INSERT INTO sale_items (id, sale_id, product_id, product_name, quantity, quantity_milli, unit_price_cents, line_total_cents) VALUES ('item', 'sale', 'product', 'Motherboard', 1, 1000, 350000, 350000)");
    await db.customStatement(
        "INSERT INTO serial_units (id, product_id, serial_number, status, created_at) VALUES ('serial', 'product', 'SN-124', 'sold', ?)",
        [now]);
    for (var i = 0; i < 8; i++) {
      await db.customStatement(
          "INSERT INTO rma_cases (id, reference, origin, customer_id, sale_id, sale_item_id, serial_unit_id, issue_description, intake_condition, quantity_milli, status, created_at) VALUES (?, ?, 'customer', 'customer', 'sale', 'item', 'serial', 'Issue', '', 1000, 'pending', ?)",
          ['queue-$i', 'RMA-2026-${i.toString().padLeft(6, '0')}', now]);
      await db.customStatement(
          "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, created_at) VALUES (?, ?, ?, 'requested', ?)",
          ['queue-event-$i', 'queue-$i', userId, now]);
    }
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-customer')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-inbound')), findsOneWidget);
    expect(
        tester.getSize(find.byKey(const ValueKey('rma-status-strip'))).height,
        greaterThanOrEqualTo(76));
    expect(find.textContaining('Receipt #POS-000124'), findsWidgets);
    expect(find.textContaining('Serial SN-124'), findsWidgets);
    await tester.tap(find
        .descendant(
            of: find.byKey(const ValueKey('rma-status-strip')),
            matching: find.text('Approval'))
        .first);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<ChoiceChip>(
                find.widgetWithText(ChoiceChip, 'Awaiting approval'))
            .selected,
        isTrue);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const ValueKey('rma-row-queue-0'))).dy,
        lessThan(768));
    expect(tester.takeException(), isNull);
    await tester.enterText(
        find.byKey(const ValueKey('rma-search')), 'POS-000124');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rma-row-queue-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rma-row-queue-0')));
    await tester.pumpAndSettle();
    expect(find.text('RMA-2026-000000'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rma-row-queue-0')), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.descendant(
                of: find.byKey(const ValueKey('rma-search')),
                matching: find.byType(TextField)))
            .controller!
            .text,
        'POS-000124');
    for (final term in [
      'RMA-2026-000000',
      'Walk-in account',
      'Motherboard',
      'MB-01',
      'SN-124'
    ]) {
      await tester.enterText(find.byKey(const ValueKey('rma-search')), term);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rma-row-queue-0')), findsOneWidget,
          reason: 'Search should match $term');
    }
    await tester.enterText(
        find.byKey(const ValueKey('rma-search')), 'no match');
    await tester.pumpAndSettle();
    expect(find.text('No Customer RMAs found'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('rma-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Rejected / Cancelled'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-inbound')));
    await tester.pumpAndSettle();
    expect(find.text('No Supplier RMAs found'), findsOneWidget);
    expect(find.text('New Supplier RMA'), findsOneWidget);
  });

  testWidgets(
      'completed customer links to ready supplier claim and sends inline',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('customer', 'RMA-2026-000050', 'customer', 'Fault', '', 1000, 'resolved', 0)");
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('supplier', 'SRMA-2026-000050', 'inbound', 'Fault', '', 1000, 'pending', 0)");
    for (final (eventId, caseId, action, related) in [
      ('e1', 'customer', 'requested', null),
      ('e2', 'customer', 'approved', null),
      ('e3', 'customer', 'received', null),
      ('e4', 'customer', 'inspected', null),
      ('e5', 'customer', 'intent', null),
      ('e6', 'customer', 'supplier_claim_opened', 'supplier'),
      ('e7', 'customer', 'refund_executed', null),
      ('e8', 'customer', 'completed', null),
      ('e9', 'supplier', 'supplier_created', 'customer'),
    ]) {
      await db.customStatement(
          'INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, related_case_id, created_at) '
          'VALUES (?, ?, ?, ?, ?, 0)',
          [eventId, caseId, id, action, related]);
    }
    await db.customStatement(
        "UPDATE rma_lifecycle_events SET outcome = 'refund', disposition = 'supplier', amount_cents = 500 "
        "WHERE id = 'e5'");
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RMA-2026-000050'));
    await tester.pumpAndSettle();
    expect(find.text('Customer fulfillment'), findsOneWidget);
    expect(find.text('Completed'), findsWidgets);
    expect(find.text('Supplier recovery'), findsOneWidget);
    expect(find.text('Ready to send'), findsWidgets);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('rma-action-panel')),
            matching: find.byType(FilledButton)),
        findsNothing);
    await tester.ensureVisible(find.text('View Supplier RMA').last);
    await tester.tap(find.text('View Supplier RMA').last);
    await tester.pumpAndSettle();
    expect(find.text('Send to supplier'), findsWidgets);
    expect(find.text('Current custody: Store'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('Confirm sent to supplier'));
    await tester.pumpAndSettle();
    expect(
        (await db.select(db.rmaCases).get())
            .singleWhere((row) => row.id == 'supplier')
            .status,
        'sent_to_supplier');
    expect(
        (await db.select(db.rmaLifecycleEvents).get()).any((event) =>
            event.caseId == 'customer' && event.action == 'custody_supplier'),
        isTrue);
    await tester.ensureVisible(find.text('Activity & custody history').last);
    await tester.tap(find.text('Activity & custody history').last);
    await tester.pumpAndSettle();
    expect(find.text('Item sent to supplier'), findsOneWidget);
    await tester.tap(find.text('Credit').last);
    await tester.ensureVisible(find.text('Record decision'));
    await tester.tap(find.text('Record decision'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Record supplier fulfillment').last);
    await tester.tap(find.text('Record supplier fulfillment').last);
    await tester.pumpAndSettle();
    expect(find.text('Record supplier credit'), findsWidgets);
    expect(find.text('Credit amount received *'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View Customer RMA').last);
    await tester.tap(find.text('View Customer RMA').last);
    await tester.pumpAndSettle();
    expect(find.text('Customer fulfillment'), findsWidgets);
  });

  testWidgets('1366 workspace density, wrapping filters and secondary views',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 3; i++) {
      await db.customStatement(
          "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) VALUES (?, ?, 'customer', 'Issue', '', 1000, 'pending', ?)",
          ['c$i', 'RMA-2026-00000$i', now - (i * 86400)]);
      await db.customStatement(
          "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) VALUES (?, ?, ?, 'requested', 1000, ?)",
          ['e$i', 'c$i', id, now]);
    }
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) VALUES ('legacy', 'RMA-LEGACY', 'customer', 'Old claim', '', 1000, 'pending', ?)",
        [now - 3 * 86400]);
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.text('RMA / Warranty'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-customer')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-inbound')), findsOneWidget);
    expect(find.text('New Customer RMA'), findsOneWidget);
    expect(find.text('New Supplier RMA'), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('rma-search'))).width,
        greaterThan(1000));
    expect(find.byKey(const ValueKey('rma-status-strip')), findsOneWidget);
    expect(find.text('More filters'), findsOneWidget);
    expect(find.text('RMA-2026-000000'), findsOneWidget);
    expect(find.textContaining('Walk-in customer'), findsWidgets);
    expect(find.text('Today'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('rma-row-c0'))).dy,
        lessThan(768));
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('rma-row-legacy')), 160,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('RMA-LEGACY'), findsOneWidget);
    expect(find.text('Detailed physical history unavailable'), findsOneWidget);
    expect(find.text('3 days'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, 800));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Aging & attention'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.text('Aging & attention'));
    await tester.pumpAndSettle();
    expect(find.text('Customer claims awaiting suppliers'), findsOneWidget);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();
    expect(find.text('RMA overview'), findsOneWidget);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('RMA settings'), findsOneWidget);
  });

  testWidgets('supplier provenance, lifecycle labels and narrow layout',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.customStatement(
        "INSERT INTO customers (id, name, created_at) VALUES ('customer', 'Juan Dela Cruz', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO suppliers (id, name, created_at) VALUES ('supplier', 'ABC Distribution', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO products (id, name, price_cents, created_at) VALUES ('product', 'BIOSTAR A520 M-K', 200000, ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO serial_units (id, product_id, serial_number, created_at) VALUES ('serial', 'product', 'MB003', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO stock_receivings (id, supplier_id, user_id, external_reference, received_at) VALUES ('receiving', 'supplier', ?, 'REC-2026-000123', ?)",
        [id, now]);
    await db.customStatement(
        "INSERT INTO stock_receiving_items (id, receiving_id, product_id, quantity_milli, unit_cost_cents) VALUES ('item', 'receiving', 'product', 1000, 100000)");
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, customer_id, issue_description, intake_condition, quantity_milli, status, created_at) VALUES ('customer-rma', 'RMA-2026-000003', 'customer', 'customer', 'Issue', '', 1000, 'pending', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, supplier_id, receiving_id, receiving_item_id, serial_unit_id, issue_description, intake_condition, quantity_milli, status, created_at) VALUES ('direct', 'SRMA-2026-000041', 'inbound', 'supplier', 'receiving', 'item', 'serial', 'Issue', '', 1000, 'pending', ?)",
        [now - 86400]);
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, supplier_id, issue_description, intake_condition, quantity_milli, status, created_at) VALUES ('linked', 'SRMA-2026-000042', 'inbound', 'supplier', 'Issue', '', 1000, 'pending', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) VALUES ('event1', 'direct', ?, 'supplier_intake', 1000, ?)",
        [id, now]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, related_case_id, created_at) VALUES ('event2', 'linked', ?, 'supplier_requested', 1000, 'customer-rma', ?)",
        [id, now]);
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, supplier_id, issue_description, intake_condition, quantity_milli, status, created_at) VALUES ('decision', 'SRMA-2026-000043', 'inbound', 'supplier', 'Issue', '', 1000, 'pending', ?)",
        [now]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) VALUES ('event3', 'decision', ?, 'supplier_requested', 1000, ?)",
        [id, now]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, outcome, created_at) VALUES ('event4', 'decision', ?, 'supplier_decision', 'credit', ?)",
        [id, now]);
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('rma-row-customer-rma')), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Juan Dela Cruz'), findsOneWidget);
    expect(find.textContaining('Item'), findsWidgets);
    await tester.drag(find.byType(ListView).last, const Offset(0, 800));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('workspace-inbound')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-inbound')));
    await tester.pumpAndSettle();
    expect(find.text('New Customer RMA'), findsNothing);
    expect(find.text('New Supplier RMA'), findsOneWidget);
    expect(find.text('Awaiting approval'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Ready to send'), findsOneWidget);
    expect(
        find.widgetWithText(ChoiceChip, 'Fulfillment pending'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('rma-search'))).width,
        lessThan(390));
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('rma-row-direct')), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Inventory / Receiving'), findsWidgets);
    expect(find.textContaining('REC-2026-000123'), findsWidgets);
    expect(find.textContaining('Linked RMA-2026-000003'), findsWidgets);
    expect(find.textContaining('ABC Distribution'), findsWidgets);
    expect(find.textContaining('BIOSTAR A520 M-K'), findsWidgets);
    expect(find.textContaining('Serial MB003'), findsWidgets);
    expect(find.text('1 day'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView).last, const Offset(0, 800));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.widgetWithText(ChoiceChip, 'Fulfillment pending'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Fulfillment pending'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('rma-row-decision')), 160,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('SRMA-2026-000043'), findsOneWidget);
    expect(find.text('SRMA-2026-000041'), findsNothing);
    await tester.drag(find.byType(ListView).last, const Offset(0, 800));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('RMA settings stays hidden from manager', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(
            repository: RmaRepository(db),
            user: ActiveUser(id, 'Manager', UserRole.manager))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('narrow empty RMA workspace and creation step in $mode',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(AuthRepository(db));
      final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
      await auth.login(id, 'password123');
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: mode,
          home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace-customer')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('New Customer RMA'));
      await tester.pumpAndSettle();
      expect(find.text('Find transaction'), findsOneWidget);
      expect(find.text('Step 1 of 4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'customer and supplier queues use lifecycle facts and open detail',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('c', 'RMA-2026-000001', 'customer', 'No display', '', 1000, 'pending', 0)");
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('s', 'SRMA-2026-000001', 'inbound', 'No display', '', 1000, 'sent_to_supplier', 0)");
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) "
        "VALUES ('e1', 'c', ?, 'requested', 1000, 0)",
        [id]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, related_case_id, created_at) "
        "VALUES ('e2', 's', ?, 'supplier_requested', 1000, 'c', 0)",
        [id]);
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace-customer')), findsOneWidget);
    expect(find.text('RMA-2026-000001'), findsOneWidget);
    expect(find.text('SRMA-2026-000001'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Awaiting approval'));
    await tester.pumpAndSettle();
    expect(find.text('RMA-2026-000001'), findsOneWidget);
    await tester.tap(find.text('RMA-2026-000001').first);
    await tester.pumpAndSettle();
    expect(find.text('Request'), findsOneWidget);
    expect(find.text('CURRENT STEP'), findsOneWidget);
    expect(find.text('Reported issue'), findsOneWidget);
    expect(find.text('No display'), findsOneWidget);
    await tester.ensureVisible(find.text('Activity & custody history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity & custody history'));
    await tester.pumpAndSettle();
    expect(find.text('RMA requested'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-inbound')));
    await tester.pumpAndSettle();
    expect(find.text('New Supplier RMA'), findsOneWidget);
    await tester.tap(find.text('New Supplier RMA'));
    await tester.pumpAndSettle();
    expect(find.text('New supplier RMA'), findsOneWidget);
    expect(find.text('Step 1 of 4 · Source'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Select exact Receiving stock'), findsOneWidget);
    expect(find.text('Enter at least two characters or scan a serial.'),
        findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('SRMA-2026-000001'), findsOneWidget);
    expect(find.text('RMA-2026-000001'), findsNothing);
    await tester.tap(find.text('SRMA-2026-000001'));
    await tester.pumpAndSettle();
    expect(find.text('Customer impact'), findsOneWidget);
    expect(find.text('View Customer RMA'), findsOneWidget);
  });

  testWidgets('receipt, inspection and resolution stay in detail workspace',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('c', 'RMA-2026-000002', 'customer', 'No display', '', 1000, 'pending', 0)");
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) "
        "VALUES ('e1', 'c', ?, 'requested', 1000, 0)",
        [id]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, created_at) "
        "VALUES ('e2', 'c', ?, 'approved', 0)",
        [id]);
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RMA-2026-000002'));
    await tester.pumpAndSettle();
    expect(find.text('Receive returned item'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Record receipt'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Receive now *'))
            .controller!
            .text,
        '1');
    await tester.tap(find.text('Record receipt'));
    await tester.pumpAndSettle();
    expect(find.text('Inspect returned item'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Condition *'), findsOneWidget);
    expect(find.text('Not tested'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(
                find.widgetWithText(TextField, 'Inspect quantity *'))
            .controller!
            .text,
        '1');
    expect(find.text('Record inspection'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Condition *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Good').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not tested'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Inspection finding *'), 'No fault');
    await tester.ensureVisible(find.text('Record inspection'));
    await tester.tap(find.text('Record inspection'));
    await tester.pumpAndSettle();
    expect(find.text('Choose resolution'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final unselected = tester
        .widget<Card>(find.byKey(const ValueKey('rma-choice-no_fault')))
        .color;
    expect(find.text('Return the exact inspected item to the customer.'),
        findsOneWidget);
    await tester.tap(find.text('No fault found').last);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<Card>(find.byKey(const ValueKey('rma-choice-no_fault')))
            .color,
        isNot(unselected));
    await tester.ensureVisible(find.text('Review resolution'));
    await tester.tap(find.text('Review resolution'));
    await tester.pumpAndSettle();
    expect(find.text('Review resolution'), findsOneWidget);
    expect(find.text('Authorize resolution'), findsOneWidget);
    await tester.tap(find.text('Authorize resolution'));
    await tester.pumpAndSettle();
    expect(find.text('Customer fulfillment'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Returned item')).dy,
        lessThan(tester.getTopLeft(find.text('Customer fulfillment')).dy));
    await tester.tap(find.text('Hand item to customer').last);
    await tester.pumpAndSettle();
    expect(find.text('Customer handoff'), findsOneWidget);
    expect(find.text('Confirm customer handoff'), findsOneWidget);
  });

  testWidgets('approval stays inline and updates desktop action panel',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('inline', 'RMA-2026-000088', 'customer', 'LAN port problem', '', 1000, 'pending', 0)");
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) "
        "VALUES ('request-inline', 'inline', ?, 'requested', 1000, 0)",
        [id]);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.light(),
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RMA-2026-000088'));
    await tester.pumpAndSettle();
    expect(find.text('Customer RMA'), findsWidgets);
    expect(find.text('Awaiting approval'), findsWidgets);
    expect(find.byKey(const ValueKey('rma-status-chip')), findsOneWidget);
    expect(find.text('2 OF 6'), findsOneWidget);
    for (final stage in [
      'Request',
      'Approval',
      'Receive',
      'Inspect',
      'Resolution',
      'Complete'
    ]) {
      expect(find.text(stage), findsWidgets);
    }
    expect(find.text('CURRENT STEP'), findsOneWidget);
    expect(find.text('Approve claim'), findsWidgets);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('rma-action-panel'))).dx,
        greaterThan(tester.getTopLeft(find.text('Returned item')).dx));
    expect(
        tester.getTopLeft(find.text('Approve claim').last).dy, lessThan(768));
    await tester.tap(find.text('Approve claim').last);
    await tester.pumpAndSettle();
    expect(find.text('Receive returned item'), findsOneWidget);
    expect(find.text('Record receipt'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
        (await db.select(db.rmaLifecycleEvents).get())
            .any((e) => e.caseId == 'inline' && e.action == 'approved'),
        isTrue);
    await tester.ensureVisible(find.text('Activity & custody history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity & custody history'));
    await tester.pumpAndSettle();
    expect(find.text('RMA approved'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('supplier decision is inline and narrow action comes first',
      (tester) async {
    tester.view.physicalSize = const Size(430, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('supplier-inline', 'SRMA-2026-000088', 'inbound', 'Defective', '', 1000, 'sent_to_supplier', 0)");
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, created_at) "
        "VALUES ('sent-inline', 'supplier-inline', ?, 'supplier_requested', 0)",
        [id]);
    final row = (await db.select(db.rmaCases).get()).single;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: RmaDetailPage(
          row: row,
          repository: RmaRepository(db),
          user: auth.current!,
          onAction: () async {},
          onRefresh: () async {},
          onRelease: () async {},
          onSendToSupplier: () async {},
          onDisposition: () async {},
          onSupplierDisposition: () async {},
          onOpenRelated: (_) async {},
        )));
    await tester.pumpAndSettle();
    expect(find.text('Record supplier decision'), findsOneWidget);
    expect(find.text('Awaiting supplier'), findsOneWidget);
    expect(find.text('Supplier decision'), findsOneWidget);
    expect(find.text('Fulfillment'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.getTopLeft(find.byKey(const ValueKey('rma-action-panel'))).dy,
        lessThan(tester.getTopLeft(find.text('Source / item')).dy));
    await tester.tap(find.text('Credit'));
    await tester.ensureVisible(find.text('Record decision'));
    await tester.tap(find.text('Record decision'));
    await tester.pumpAndSettle();
    expect(find.text('Record supplier fulfillment'), findsWidgets);
    expect(
        (await db.select(db.rmaLifecycleEvents).get()).any((e) =>
            e.caseId == 'supplier-inline' &&
            e.action == 'supplier_decision' &&
            e.outcome == 'credit'),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('waiting supplier state has a link but no primary action',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('waiting', 'RMA-2026-000089', 'customer', 'Fault', '', 1000, 'pending', 0)");
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('recovery', 'SRMA-2026-000089', 'inbound', 'Fault', '', 1000, 'sent_to_supplier', 0)");
    for (final (eventId, caseId, action, quantity, related) in [
      ('w1', 'waiting', 'requested', 1000, null),
      ('w2', 'waiting', 'approved', null, null),
      ('w3', 'waiting', 'received', 1000, null),
      ('w4', 'waiting', 'inspected', 1000, null),
      ('w5', 'waiting', 'intent', null, null),
      ('w6', 'waiting', 'supplier_claim_opened', null, 'recovery'),
      ('w7', 'recovery', 'supplier_requested', null, 'waiting'),
    ]) {
      await db.customStatement(
          'INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, related_case_id, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, 0)',
          [eventId, caseId, id, action, quantity, related]);
    }
    await db.customStatement(
        "UPDATE rma_lifecycle_events SET outcome = 'supplier_warranty', disposition = 'supplier' WHERE id = 'w5'");
    final row = (await db.select(db.rmaCases).get())
        .singleWhere((e) => e.id == 'waiting');
    await tester.pumpWidget(MaterialApp(
        home: RmaDetailPage(
      row: row,
      repository: RmaRepository(db),
      user: auth.current!,
      onAction: () async {},
      onRefresh: () async {},
      onRelease: () async {},
      onSendToSupplier: () async {},
      onDisposition: () async {},
      onSupplierDisposition: () async {},
      onOpenRelated: (_) async {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('CURRENT STATUS'), findsOneWidget);
    expect(find.text('Waiting on supplier'), findsOneWidget);
    expect(find.text('SRMA: SRMA-2026-000089'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('rma-action-panel')),
            matching: find.byType(FilledButton)),
        findsNothing);
    expect(find.text('View Supplier RMA'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('exact replacement selection remains a dialog', (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('reserve', 'RMA-2026-000090', 'customer', 'Fault', '', 1000, 'pending', 0)");
    for (final (eventId, action, amount) in [
      ('r1', 'requested', 1000),
      ('r2', 'approved', null),
      ('r3', 'received', 1000),
      ('r4', 'inspected', 1000),
      ('r5', 'intent', null),
    ]) {
      await db.customStatement(
          'INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, quantity_milli, created_at) '
          'VALUES (?, ?, ?, ?, ?, 0)',
          [eventId, 'reserve', id, action, amount]);
    }
    await db.customStatement(
        "UPDATE rma_lifecycle_events SET outcome = 'replacement', disposition = 'hold' WHERE id = 'r5'");
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RMA-2026-000090'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reserve replacement').last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Exact replacement serial'), findsOneWidget);
  });

  testWidgets('supplier desktop detail shows operational status and sections',
      (tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = AuthService(AuthRepository(db));
    final id = await auth.bootstrap('Owner', 'password123', 'Q?', 'answer');
    await auth.login(id, 'password123');
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('linked-c', 'RMA-2026-000091', 'customer', 'Fault', '', 1000, 'resolved', 0)");
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('linked-s', 'SRMA-2026-000091', 'inbound', 'Fault', '', 1000, 'pending', 0)");
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, related_case_id, created_at) "
        "VALUES ('sc', 'linked-s', ?, 'supplier_created', 'linked-c', 0)",
        [id]);
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, created_at) "
        "VALUES ('cc', 'linked-c', ?, 'completed', 0)",
        [id]);
    final supplier = (await db.select(db.rmaCases).get())
        .singleWhere((e) => e.id == 'linked-s');
    await tester.pumpWidget(MaterialApp(
        home: RmaDetailPage(
      row: supplier,
      repository: RmaRepository(db),
      user: auth.current!,
      onAction: () async {},
      onRefresh: () async {},
      onRelease: () async {},
      onSendToSupplier: () async {},
      onDisposition: () async {},
      onSupplierDisposition: () async {},
      onOpenRelated: (_) async {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Supplier RMA'), findsOneWidget);
    expect(find.text('Ready to send'), findsWidgets);
    expect(find.text('Source / item'), findsOneWidget);
    expect(find.text('Supplier decision'), findsOneWidget);
    expect(find.text('Fulfillment'), findsOneWidget);
    expect(find.text('Customer impact'), findsOneWidget);
    expect(find.text('View Customer RMA'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('rma-action-panel'))).dx,
        greaterThan(tester.getTopLeft(find.text('Source / item')).dx));
    expect(tester.getTopLeft(find.text('Confirm sent to supplier')).dy,
        lessThan(768));
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail uses available width at 1600 and caps it at 1920',
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
    await db.customStatement(
        "INSERT INTO rma_cases (id, reference, origin, issue_description, intake_condition, quantity_milli, status, created_at) "
        "VALUES ('wide', 'RMA-2026-000092', 'customer', 'Fault', '', 1000, 'pending', 0)");
    await db.customStatement(
        "INSERT INTO rma_lifecycle_events (id, case_id, actor_id, action, created_at) "
        "VALUES ('wide-event', 'wide', ?, 'requested', 0)",
        [id]);
    await tester.pumpWidget(MaterialApp(
        home: RmaScreen(repository: RmaRepository(db), user: auth.current!)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RMA-2026-000092'));
    await tester.pumpAndSettle();
    final width1600 = tester.getSize(find.byType(RmaDetailPage)).width;
    expect(width1600, greaterThan(1400));
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pumpAndSettle();
    await tester.tap(find.text('RMA-2026-000092'));
    await tester.pumpAndSettle();
    final width1920 = tester.getSize(find.byType(RmaDetailPage)).width;
    expect(width1920, lessThanOrEqualTo(1600));
    expect(width1920, greaterThan(1500));
    expect(tester.takeException(), isNull);
  });
}
