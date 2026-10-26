import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/active_user.dart';
import 'package:modern_offline_pos/data/database.dart';
import 'package:modern_offline_pos/data/daos/audit_explorer_repository.dart';
import 'package:modern_offline_pos/features/audit/audit_event_presenter.dart';

void main() {
  late AppDatabase db;
  late AuditExplorerRepository repository;
  const admin = ActiveUser('admin', 'Admin', UserRole.owner);
  const viewer = ActiveUser('viewer', 'Viewer', UserRole.cashier);
  const auditor = ActiveUser('auditor', 'Auditor', UserRole.custom, true,
      'auditor', {PosPermission.manageUsers});
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = AuditExplorerRepository(db);
  });
  tearDown(() => db.close());

  Future<void> add(int number, String action, String? details,
          {String? actor, DateTime? at}) =>
      db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
          id: Value('event-${number.toString().padLeft(3, '0')}'),
          userId: Value(actor),
          action: action,
          details: Value(details),
          createdAt: Value(at ?? DateTime(2026, 10, 26, 10))));

  test('pages 50 newest events with stable ID tie break', () async {
    for (var i = 0; i < 55; i++) {
      await add(i, 'sale.completed', 'INV-${i.toString().padLeft(6, '0')}');
    }
    final first = await repository.page(admin, const AuditExplorerFilter());
    final second =
        await repository.page(admin, const AuditExplorerFilter(page: 1));
    expect(first.total, 55);
    expect(first.rows.length, 50);
    expect(first.rows.first.log.id, 'event-054');
    expect(second.rows.length, 5);
    expect(second.rows.last.log.id, 'event-000');
    expect((await db.select(db.auditLogs).get()).length, 55);
  });

  test('filters by date, actor, module, action and search', () async {
    await add(1, 'sale.completed', 'INV-000001',
        actor: 'a', at: DateTime(2026, 10, 25));
    await add(2, 'product.price_changed', 'p: 100 → 200 cents', actor: 'b');
    await add(3, 'sale.completed', 'INV-000003', actor: 'a');
    expect(
        (await repository.page(
                admin, AuditExplorerFilter(from: DateTime(2026, 10, 26))))
            .total,
        2);
    expect(
        (await repository.page(admin, const AuditExplorerFilter(actorId: 'b')))
            .total,
        1);
    expect(
        (await repository.page(admin, const AuditExplorerFilter(module: 'POS')))
            .total,
        2);
    expect(
        (await repository.page(admin,
                const AuditExplorerFilter(action: 'product.price_changed')))
            .total,
        1);
    expect(
        (await repository.page(
                admin, const AuditExplorerFilter(search: 'INV-000003')))
            .total,
        1);
  });

  test('permission, sensitive metadata and legacy fallback', () async {
    await add(
        1, 'supplier_payment.recorded', 'SPAY-000041:supplier:95000:cash');
    await add(2, 'user_created',
        '{"reference":"USER-01","passwordHash":"secret","token":"secret","name":"Alex"}');
    await add(3, 'legacy_odd_event', null);
    await expectLater(
        repository.page(viewer, const AuditExplorerFilter()), throwsStateError);
    final rows =
        (await repository.page(admin, const AuditExplorerFilter())).rows;
    final payment = AuditEventPresenter.present(
        rows.firstWhere((r) => r.log.action == 'supplier_payment.recorded'),
        admin);
    expect(payment.action, 'Recorded supplier payment');
    expect(payment.reference, 'SPAY-000041');
    final restricted = AuditEventPresenter.present(
        rows.firstWhere((r) => r.log.action == 'supplier_payment.recorded'),
        auditor);
    expect(restricted.reference, 'SPAY-000041');
    expect(restricted.fields, isEmpty);
    final user = AuditEventPresenter.present(
        rows.firstWhere((r) => r.log.action == 'user_created'), admin);
    expect(user.fields.map((f) => f.value), isNot(contains('secret')));
    final legacy = AuditEventPresenter.present(
        rows.firstWhere((r) => r.log.action == 'legacy_odd_event'), admin);
    expect(legacy.reference, 'Not recorded');
    expect(legacy.row.actor, 'System');
  });

  test('source mapping follows persisted IDs and never invents a diff', () {
    const id = '123e4567-e89b-12d3-a456-426614174000';
    for (final pair in <(String, String)>[
      ('sale.completed', 'sale'),
      ('stock_receiving.finalized', 'receiving'),
      ('purchase_order.sent', 'purchase_order'),
      ('sales_order.created', 'sales_order'),
      ('rma.received', 'rma'),
      ('product.price_changed', 'product')
    ]) {
      final item = AuditEventPresenter.present(
          AuditExplorerRow(
              AuditLog(
                  id: 'event',
                  userId: null,
                  action: pair.$1,
                  details: id,
                  createdAt: DateTime(2026)),
              'System',
              null,
              null),
          admin);
      expect(item.source, pair.$2);
      expect(item.sourceId, id);
      expect(item.fields, isEmpty);
    }
  });

  test('import summary is curated and file paths are shortened', () {
    final item = AuditEventPresenter.present(
        AuditExplorerRow(
            AuditLog(
                id: 'import',
                userId: null,
                action: 'import.products',
                details:
                    '{"file":"C:/private/catalog.csv","created":4,"updated":2,"token":"secret"}',
                createdAt: DateTime(2026)),
            'System',
            null,
            null),
        admin);
    expect(item.module, 'Imports');
    expect(item.fields.map((f) => f.value),
        containsAll(['catalog.csv', '4', '2']));
    expect(item.fields.map((f) => f.value), isNot(contains('secret')));
  });
}
