import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';

class AuditExplorerFilter {
  const AuditExplorerFilter(
      {this.from,
      this.until,
      this.actorId,
      this.module,
      this.action,
      this.search = '',
      this.page = 0});
  final DateTime? from, until;
  final String? actorId, module, action;
  final String search;
  final int page;
}

class AuditExplorerRow {
  const AuditExplorerRow(
      this.log, this.actor, this.resolvedReference, this.resolvedSourceId);
  final AuditLog log;
  final String actor;
  final String? resolvedReference;
  final String? resolvedSourceId;
}

class AuditExplorerPage {
  const AuditExplorerPage(this.rows, this.total);
  final List<AuditExplorerRow> rows;
  final int total;
}

class AuditExplorerRepository {
  AuditExplorerRepository(this.db);
  final AppDatabase db;
  static const pageSize = 50;

  void _authorize(ActiveUser user) => user.require(PosPermission.manageUsers);

  Future<AuditExplorerPage> page(
      ActiveUser user, AuditExplorerFilter filter) async {
    _authorize(user);
    final conditions = <String>[];
    final args = <Object?>[];
    if (filter.from != null) {
      conditions.add('a.created_at >= ?');
      args.add(filter.from!.millisecondsSinceEpoch ~/ 1000);
    }
    if (filter.until != null) {
      conditions.add('a.created_at < ?');
      args.add(filter.until!.millisecondsSinceEpoch ~/ 1000);
    }
    if (filter.actorId != null) {
      conditions.add('a.user_id = ?');
      args.add(filter.actorId);
    }
    if (filter.module != null) {
      final prefixes = _modulePrefixes[filter.module] ?? [];
      if (filter.module == 'Other') {
        final all = _modulePrefixes.values.expand((p) => p).toList();
        conditions.add(
            'NOT (${List.filled(all.length, "(a.action = ? OR a.action LIKE ? ESCAPE '\\' OR a.action LIKE ? ESCAPE '\\')").join(' OR ')})');
        for (final prefix in all) {
          args.addAll([prefix, '${_escape(prefix)}.%', '${_escape(prefix)}_%']);
        }
      } else if (prefixes.isEmpty) {
        conditions.add('1 = 0');
      } else {
        conditions.add(
            '(${List.filled(prefixes.length, "(a.action = ? OR a.action LIKE ? ESCAPE '\\' OR a.action LIKE ? ESCAPE '\\')").join(' OR ')})');
        for (final prefix in prefixes) {
          args.addAll([prefix, '${_escape(prefix)}.%', '${_escape(prefix)}_%']);
        }
      }
    }
    if (filter.action != null) {
      conditions.add('a.action = ?');
      args.add(filter.action);
    }
    final search = filter.search.trim();
    if (search.isNotEmpty) {
      conditions
          .add('''(a.action LIKE ? ESCAPE '\\' OR u.name LIKE ? ESCAPE '\\'
        OR (a.details LIKE ? ESCAPE '\\' AND a.action NOT LIKE 'supplier_payment.%'
        AND a.action NOT LIKE 'customer_credit.%' AND a.action NOT LIKE 'cash_%'
        AND a.action NOT LIKE 'shift_handover.%' AND a.action NOT LIKE 'role_%'
        AND a.action NOT LIKE 'user_%' AND a.action NOT LIKE 'credential_%'
        AND a.action NOT LIKE 'password_%'))''');
      final pattern = '%${_escape(search)}%';
      args.addAll([pattern, pattern, pattern]);
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    const join = 'FROM audit_logs a LEFT JOIN users u ON u.id = a.user_id';
    final count = await db
        .customSelect('SELECT COUNT(*) AS n $join $where',
            variables: args.map(Variable.new).toList())
        .getSingle();
    final rows = await db.customSelect('''SELECT a.id, a.user_id, a.action,
      a.details, a.created_at, u.name AS actor,
      CASE
        WHEN a.action LIKE 'sale.%' THEN (SELECT s.receipt_number FROM sales s WHERE s.id = a.details)
        WHEN a.action LIKE 'product.%' OR a.action LIKE 'kit.%' THEN (SELECT p.name FROM products p WHERE p.id = a.details OR p.id = substr(a.details, 1, 36))
        WHEN a.action LIKE 'stock_receiving.%' THEN (SELECT 'RCV-' || printf('%06d', r.sequence) FROM stock_receivings r WHERE r.id = a.details)
        WHEN a.action LIKE 'purchase_order.%' THEN (SELECT 'PO-' || printf('%06d', p.sequence) FROM purchase_orders p WHERE p.id = a.details)
        WHEN a.action LIKE 'purchase_return.%' THEN (SELECT 'PRT-' || printf('%06d', p.sequence) FROM purchase_returns p WHERE p.id = a.details)
        WHEN a.action LIKE 'sales_order.%' THEN (SELECT s.reference FROM sales_orders s WHERE s.id = a.details)
        WHEN a.action LIKE 'rma.%' THEN (SELECT r.reference FROM rma_cases r WHERE r.id = a.details)
        WHEN a.action LIKE 'stock_count.%' THEN (SELECT c.reference FROM stock_counts c WHERE c.id = a.details)
        ELSE NULL END AS resolved_reference,
      CASE
        WHEN a.action LIKE 'purchase_return.%' THEN (SELECT p.id FROM purchase_returns p WHERE 'PRT-' || printf('%06d', p.sequence) = substr(a.details, 1, 10))
        WHEN a.action LIKE 'stock_count.%' THEN (SELECT c.id FROM stock_counts c WHERE c.reference = a.details OR c.id = a.details)
        ELSE NULL END AS resolved_source_id $join $where
      ORDER BY a.created_at DESC, a.id DESC LIMIT ? OFFSET ?''',
        variables: [...args, pageSize, filter.page * pageSize]
            .map(Variable.new)
            .toList()).get();
    return AuditExplorerPage(
        rows
            .map((row) => AuditExplorerRow(
                AuditLog(
                    id: row.read<String>('id'),
                    userId: row.readNullable<String>('user_id'),
                    action: row.read<String>('action'),
                    details: row.readNullable<String>('details'),
                    createdAt: DateTime.fromMillisecondsSinceEpoch(
                        row.read<int>('created_at') * 1000)),
                row.readNullable<String>('actor') ??
                    (row.readNullable<String>('user_id') == null
                        ? 'System'
                        : 'Unknown user'),
                row.readNullable<String>('resolved_reference'),
                row.readNullable<String>('resolved_source_id')))
            .toList(),
        count.read<int>('n'));
  }

  Future<List<(String, String)>> actors(ActiveUser user) async {
    _authorize(user);
    final rows =
        await db.customSelect('''SELECT DISTINCT u.id, u.name FROM users u
      WHERE EXISTS (SELECT 1 FROM audit_logs a WHERE a.user_id = u.id)
      ORDER BY u.name LIMIT 200''').get();
    return rows
        .map((r) => (r.read<String>('id'), r.read<String>('name')))
        .toList();
  }

  Future<List<String>> actions(ActiveUser user) async {
    _authorize(user);
    final rows = await db.customSelect('''SELECT action FROM audit_logs
      GROUP BY action ORDER BY action LIMIT 300''').get();
    return rows.map((r) => r.read<String>('action')).toList();
  }

  static String _escape(String text) => text
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  static const _modulePrefixes = <String, List<String>>{
    'POS': ['sale'],
    'Products': ['product', 'kit'],
    'Receiving': ['stock_receiving'],
    'Purchase Orders': ['purchase_order'],
    'Purchase Returns': ['purchase_return'],
    'Stock Count': ['stock_count', 'cycle_count'],
    'Inventory': ['inventory_adjustment'],
    'Customer Credit': ['customer_credit'],
    'Supplier Payables': ['supplier_payment'],
    'Sales Orders': ['sales_order'],
    'Delivery': ['made_order'],
    'RMA': ['rma'],
    'Cash Session': ['cash_session'],
    'Shift Handover': ['shift_handover'],
    'Promotions': ['promotion'],
    'Imports': ['import', 'opening_inventory'],
    'Customers': ['customer'],
    'Suppliers': ['supplier'],
    'Users': ['user', 'role', 'login', 'logout', 'credential', 'password'],
    'Settings': ['business_feature', 'bir'],
  };
}
