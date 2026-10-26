import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';

class SerialLifecycleEvent {
  final DateTime occurredAt;
  final String title;
  final String reference;
  final String? description;
  final String source;
  final String? sourceId;
  const SerialLifecycleEvent(this.occurredAt, this.title, this.reference,
      this.description, this.source, this.sourceId);
}

class SerialLifecycle {
  final String id, serial, product, status;
  final String? sku, barcode, supplier, warning;
  final List<SerialLifecycleEvent> events;
  const SerialLifecycle(this.id, this.serial, this.product, this.status,
      this.sku, this.barcode, this.supplier, this.warning, this.events);
}

class SerialSearchRow {
  final String id, serial, product, status;
  final String? reference;
  const SerialSearchRow(
      this.id, this.serial, this.product, this.status, this.reference);
}

/// A read model. Every query is bounded to one serial or a single search page.
class SerialLifecycleRepository {
  final AppDatabase db;
  const SerialLifecycleRepository(this.db);
  DateTime _seconds(QueryRow row, String column) =>
      DateTime.fromMillisecondsSinceEpoch(row.read<int>(column) * 1000);
  void _requireSerialAccess(ActiveUser user) {
    if (!user.can(PosPermission.stockReceiving) &&
        !user.can(PosPermission.manageCatalog)) {
      throw StateError('Not authorized for this action');
    }
  }

  Future<List<SerialSearchRow>> search(ActiveUser user, String query,
      {String? productId, int page = 0}) async {
    _requireSerialAccess(user);
    final term = query.trim().toLowerCase();
    final rows = await db.customSelect('''
      SELECT su.id, su.serial_number, p.name AS product, su.status,
        CASE WHEN su.status = 'rma' AND ? = 1 THEN
          (SELECT c.reference FROM rma_cases c
           WHERE c.serial_unit_id = su.id
           ORDER BY c.created_at DESC, c.id DESC LIMIT 1)
        WHEN su.status = 'sold' AND ? = 1 THEN
          (SELECT s.receipt_number FROM serial_sale_links sl
           JOIN sale_items si ON si.id = sl.sale_item_id
           JOIN sales s ON s.id = si.sale_id
           WHERE sl.serial_unit_id = su.id
             AND (? = 1 OR s.cashier_id = ?)
           ORDER BY s.created_at DESC LIMIT 1)
        WHEN ? = 1 THEN (SELECT 'RCV-' || printf('%06d', rc.sequence)
          FROM stock_receiving_items ri
          JOIN stock_receivings rc ON rc.id = ri.receiving_id
          WHERE ri.id = su.receiving_item_id LIMIT 1) END AS reference
      FROM serial_units su JOIN products p ON p.id = su.product_id
      WHERE (? = '' OR instr(lower(su.serial_number), ?) > 0)
        AND (? = '' OR su.product_id = ?)
      ORDER BY CASE WHEN lower(su.serial_number) = ? THEN 0 ELSE 1 END,
        su.serial_number, su.id LIMIT 50 OFFSET ?''', variables: [
      Variable.withInt(user.can(PosPermission.manageRma) ? 1 : 0),
      Variable.withInt(user.can(PosPermission.viewOwnSales) ? 1 : 0),
      Variable.withInt(user.can(PosPermission.viewAllSales) ? 1 : 0),
      Variable.withString(user.id),
      Variable.withInt(user.can(PosPermission.stockReceiving) ? 1 : 0),
      Variable.withString(term),
      Variable.withString(term),
      Variable.withString(productId ?? ''),
      Variable.withString(productId ?? ''),
      Variable.withString(term),
      Variable.withInt(page * 50),
    ]).get();
    return rows
        .map((r) => SerialSearchRow(r.read('id'), r.read('serial_number'),
            r.read('product'), r.read('status'), r.readNullable('reference')))
        .toList();
  }

  Future<SerialLifecycle?> load(ActiveUser user, String id) async {
    _requireSerialAccess(user);
    final base = await db.customSelect('''
      SELECT su.id, su.serial_number, su.status, su.created_at,
        su.sale_item_id, p.name AS product, p.sku, p.barcode,
        sp.name AS supplier
      FROM serial_units su JOIN products p ON p.id = su.product_id
      LEFT JOIN stock_receiving_items ri ON ri.id = su.receiving_item_id
      LEFT JOIN stock_receivings rc ON rc.id = ri.receiving_id
      LEFT JOIN suppliers sp ON sp.id = rc.supplier_id
      WHERE su.id = ? LIMIT 1''', variables: [Variable.withString(id)]).get();
    if (base.isEmpty) return null;
    final b = base.single;
    final events = <SerialLifecycleEvent>[];
    Future<void> add(String sql, List<Variable> variables,
        SerialLifecycleEvent Function(QueryRow) map) async {
      for (final row
          in await db.customSelect(sql, variables: variables).get()) {
        events.add(map(row));
      }
    }

    final v = [Variable.withString(id)];
    if (user.can(PosPermission.stockReceiving)) {
      await add(
          '''SELECT rc.id, rc.sequence, rc.received_at, sp.name AS supplier,
        ri.batch_number FROM serial_units su
        JOIN stock_receiving_items ri ON ri.id = su.receiving_item_id
        JOIN stock_receivings rc ON rc.id = ri.receiving_id
        JOIN suppliers sp ON sp.id = rc.supplier_id WHERE su.id = ?''',
          v,
          (r) => SerialLifecycleEvent(
              _seconds(r, 'received_at'),
              'Received',
              'RCV-${r.read<int>('sequence').toString().padLeft(6, '0')}',
              r.read<String>('supplier'),
              'receiving',
              r.read('id')));
    }
    if (user.can(PosPermission.viewOwnSales)) {
      await add(
          '''SELECT s.id, s.receipt_number, s.created_at, s.status,
        COALESCE(c.name, s.walk_in_name) AS customer, si.product_name,
        kc.component_name_snapshot AS component_name
        FROM (SELECT sale_item_id, serial_unit_id FROM serial_sale_links
          UNION SELECT sale_item_id, serial_unit_id
          FROM sale_item_inventory_allocations WHERE serial_unit_id IS NOT NULL) l
        JOIN sale_items si ON si.id = l.sale_item_id
        JOIN sales s ON s.id = si.sale_id
        LEFT JOIN customers c ON c.id = s.customer_id
        LEFT JOIN sale_item_kit_components kc ON kc.sale_item_id = si.id
          AND kc.component_product_id = (SELECT product_id FROM serial_units WHERE id = l.serial_unit_id)
        WHERE l.serial_unit_id = ? AND (? = 1 OR s.cashier_id = ?)
        ORDER BY s.created_at, si.id''',
          [
            Variable.withString(id),
            Variable.withInt(user.can(PosPermission.viewAllSales) ? 1 : 0),
            Variable.withString(user.id)
          ],
          (r) => SerialLifecycleEvent(
              _seconds(r, 'created_at'),
              'Sold',
              r.read<String?>('receipt_number') ?? 'Sale',
              [
                r.read<String?>('customer'),
                if (r.read<String?>('component_name') != null)
                  'Kit component of ${r.read<String>('product_name')}'
              ].whereType<String>().join(' · '),
              'sale',
              r.read('id')));
    }
    if (user.can(PosPermission.viewSalesOrders) &&
        user.can(PosPermission.viewOwnSales)) {
      await add(
          '''SELECT so.reference, f.created_at
          FROM sales_order_fulfillments f
          JOIN sales_orders so ON so.id = f.sales_order_id
          JOIN sales s ON s.id = f.sale_id
          JOIN sale_items si ON si.sale_id = s.id
          JOIN serial_sale_links sl ON sl.sale_item_id = si.id
          WHERE sl.serial_unit_id = ? AND (? = 1 OR s.cashier_id = ?)''',
          [
            Variable.withString(id),
            Variable.withInt(user.can(PosPermission.viewAllSales) ? 1 : 0),
            Variable.withString(user.id)
          ],
          (r) => SerialLifecycleEvent(
              _seconds(r, 'created_at'),
              'Sales Order fulfilled',
              r.read('reference'),
              null,
              'sales_order',
              r.read('reference')));
    }
    if (user.can(PosPermission.viewOwnSales)) {
      await add(
          '''SELECT sr.original_sale_id AS id, sr.reference, sr.created_at,
            rl.disposition
        FROM sale_return_allocations a
        JOIN sale_return_lines rl ON rl.id = a.return_line_id
        JOIN sale_returns sr ON sr.id = rl.return_id
        JOIN sales s ON s.id = sr.original_sale_id
        WHERE a.serial_unit_id = ? AND sr.status = 'finalized'
          AND (? = 1 OR s.cashier_id = ?)''',
          [
            Variable.withString(id),
            Variable.withInt(user.can(PosPermission.viewAllSales) ? 1 : 0),
            Variable.withString(user.id)
          ],
          (r) => SerialLifecycleEvent(
              DateTime.fromMillisecondsSinceEpoch(r.read<int>('created_at')),
              r.read<String>('disposition') == 'sellable'
                  ? 'Returned sellable'
                  : 'Returned non-sellable',
              r.read('reference'),
              null,
              'return',
              r.read('id')));
    }
    if (user.can(PosPermission.viewOwnSales)) {
      await add(
          '''SELECT rv.created_at, rv.kind, rv.stock_restored, s.id,
        s.receipt_number FROM sale_reversals rv
        JOIN sales s ON s.id = rv.sale_id
        JOIN sale_items si ON si.sale_id = s.id
        JOIN serial_sale_links sl ON sl.sale_item_id = si.id
        WHERE sl.serial_unit_id = ?
          AND rv.kind IN ('void', 'refund')
          AND (? = 1 OR s.cashier_id = ?)''',
          [
            Variable.withString(id),
            Variable.withInt(user.can(PosPermission.viewAllSales) ? 1 : 0),
            Variable.withString(user.id)
          ],
          (r) => SerialLifecycleEvent(
              _seconds(r, 'created_at'),
              r.read<String>('kind') == 'void'
                  ? (r.read<int>('stock_restored') == 1
                      ? 'Sale voided / restored'
                      : 'Sale voided')
                  : 'Sale refunded',
              r.read<String?>('receipt_number') ?? 'Sale',
              null,
              'sale',
              r.read('id')));
    }
    if (user.can(PosPermission.manageRma)) {
      await add('''SELECT c.id, c.reference,
          COALESCE((SELECT MAX(e.created_at) FROM rma_events e
              WHERE e.case_id = c.id AND e.status IN ('resolved','rejected')),
              c.created_at) AS event_at,
          original.id AS original_id, original.serial_number AS original_serial,
          replacement.id AS replacement_id,
          replacement.serial_number AS replacement_serial
          FROM rma_cases c
          JOIN serial_units original ON original.id = c.serial_unit_id
          JOIN serial_units replacement ON replacement.id = c.replacement_serial_unit_id
          WHERE c.serial_unit_id = ? OR c.replacement_serial_unit_id = ?''',
          [Variable.withString(id), Variable.withString(id)], (r) {
        final original = r.read<String>('original_id') == id;
        return SerialLifecycleEvent(
            _seconds(r, 'event_at'),
            original ? 'Replaced by' : 'Replacement for',
            original ? r.read('replacement_serial') : r.read('original_serial'),
            r.read('reference'),
            'serial',
            original ? r.read('replacement_id') : r.read('original_id'));
      });
      await add(
          '''SELECT id, reference, origin, created_at, status,
          replacement_serial_unit_id FROM rma_cases
          WHERE serial_unit_id = ? OR replacement_serial_unit_id = ?''',
          [Variable.withString(id), Variable.withString(id)],
          (r) => SerialLifecycleEvent(
              _seconds(r, 'created_at'),
              r.read<String>('origin') == 'customer'
                  ? 'Customer RMA opened'
                  : 'Supplier RMA opened',
              r.read('reference'),
              r.read('status'),
              'rma',
              r.read('id')));
      await add(
          '''SELECT e.created_at, e.action, e.note, c.id, c.reference
          FROM rma_lifecycle_events e JOIN rma_cases c ON c.id = e.case_id
          WHERE c.serial_unit_id = ? OR c.replacement_serial_unit_id = ?
          ORDER BY e.created_at, e.id''',
          [Variable.withString(id), Variable.withString(id)],
          (r) => SerialLifecycleEvent(
              _seconds(r, 'created_at'),
              r.read('action'),
              r.read('reference'),
              r.read('note'),
              'rma',
              r.read('id')));
      await add(
          '''SELECT e.created_at, e.status, e.note, c.id, c.reference
          FROM rma_events e JOIN rma_cases c ON c.id = e.case_id
          WHERE c.serial_unit_id = ? OR c.replacement_serial_unit_id = ?
          ORDER BY e.created_at, e.id''',
          [Variable.withString(id), Variable.withString(id)],
          (r) => SerialLifecycleEvent(
              _seconds(r, 'created_at'),
              'RMA ${r.read<String>('status')}',
              r.read('reference'),
              r.read('note'),
              'rma',
              r.read('id')));
    }
    if (user.can(PosPermission.stockReceiving)) {
      await add(
          '''SELECT pr.id, pr.sequence, pr.finalized_at,
        pr.return_date FROM purchase_return_lines l
        JOIN purchase_returns pr ON pr.id = l.purchase_return_id
        WHERE l.serial_unit_id = ? AND pr.status = 'finalized' ''',
          v,
          (r) => SerialLifecycleEvent(
              _seconds(
                  r,
                  r.readNullable<int>('finalized_at') == null
                      ? 'return_date'
                      : 'finalized_at'),
              'Returned to Supplier',
              'PRT-${r.read<int>('sequence').toString().padLeft(6, '0')}',
              null,
              'purchase_return',
              r.read('id')));
    }
    events.sort((a, b) {
      final date = a.occurredAt.compareTo(b.occurredAt);
      if (date != 0) return date;
      final source = a.source.compareTo(b.source);
      if (source != 0) return source;
      final reference = a.reference.compareTo(b.reference);
      if (reference != 0) return reference;
      final title = a.title.compareTo(b.title);
      if (title != 0) return title;
      final id = (a.sourceId ?? '').compareTo(b.sourceId ?? '');
      return id != 0 ? id : (a.description ?? '').compareTo(b.description ?? '');
    });
    final status = b.read<String>('status');
    final hasLiveSale = user.can(PosPermission.viewOwnSales)
        ? await db.customSelect('''SELECT 1 FROM
        (SELECT sale_item_id, serial_unit_id FROM serial_sale_links
         UNION SELECT sale_item_id, serial_unit_id
         FROM sale_item_inventory_allocations WHERE serial_unit_id IS NOT NULL) l
        JOIN sale_items si ON si.id = l.sale_item_id
        JOIN sales s ON s.id = si.sale_id
        WHERE l.serial_unit_id = ? AND s.status = 'completed'
          AND (? = 1 OR s.cashier_id = ?)
          AND NOT EXISTS (SELECT 1 FROM sale_return_allocations ra
            JOIN sale_return_lines rl ON rl.id = ra.return_line_id
            JOIN sale_returns sr ON sr.id = rl.return_id
            WHERE ra.serial_unit_id = l.serial_unit_id
              AND sr.original_sale_id = s.id
              AND sr.status = 'finalized') LIMIT 1''', variables: [
            Variable.withString(id),
            Variable.withInt(user.can(PosPermission.viewAllSales) ? 1 : 0),
            Variable.withString(user.id)
          ]).get()
        : <QueryRow>[];
    return SerialLifecycle(
        id,
        b.read('serial_number'),
        b.read('product'),
        status,
        b.read('sku'),
        b.read('barcode'),
        user.can(PosPermission.stockReceiving) ? b.read('supplier') : null,
        status == 'available' && hasLiveSale.isNotEmpty
            ? 'Serial history needs review'
            : null,
        events);
  }
}
