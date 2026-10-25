import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';

enum GlobalSearchKind {
  command, product, customer, supplier, sale, serial,
  quotation, salesOrder, layaway, purchaseOrder, receiving, rma
}

class GlobalSearchResult {
  const GlobalSearchResult({required this.kind, required this.id,
      required this.title, required this.subtitle, this.reference,
      this.status, this.score = 2});
  final GlobalSearchKind kind;
  final String id, title, subtitle;
  final String? reference, status;
  final int score;
}

class GlobalSearchRepository {
  const GlobalSearchRepository(this.db);
  final AppDatabase db;

  static const _commands = <(String, String, PosPermission)>[
    ('New Sale', 'POS', PosPermission.sell),
    ('Receive Stock', 'Inventory', PosPermission.stockReceiving),
    ('Create Purchase Order', 'Inventory', PosPermission.stockReceiving),
    ('Create Quotation', 'Quotations', PosPermission.manageQuotations),
    ('Open Inventory', 'Inventory', PosPermission.manageCatalog),
    ('Open Customers', 'Customers & Suppliers', PosPermission.viewContacts),
    ('Open Reports', 'Reports', PosPermission.reports),
    ('Open Cash Session', 'Cash session', PosPermission.manageCashSession),
    ('Open Settings', 'Settings', PosPermission.manageSettings),
  ];

  List<GlobalSearchResult> commands(ActiveUser user, [String query = '']) {
    final term = query.trim().toLowerCase();
    return [for (final (name, target, permission) in _commands)
      if (user.can(permission) && (term.isEmpty || name.toLowerCase().contains(term)))
        GlobalSearchResult(kind: GlobalSearchKind.command, id: name,
            title: name, subtitle: target, score: term.isEmpty ? 1 :
                name.toLowerCase() == term ? 0 : 1)];
  }

  Future<List<GlobalSearchResult>> search(ActiveUser user, String query) async {
    final term = query.trim().toLowerCase();
    final commandResults = commands(user, term);
    if (term.length < 2) return commandResults;
    final prefix = '$term%';
    Future<List<GlobalSearchResult>> group(bool permitted, String sql,
        List<Variable> variables, GlobalSearchKind kind) async {
      if (!permitted) return [];
      try {
        final rows = await db.customSelect(sql, variables: variables).get();
        return [for (final row in rows)
          GlobalSearchResult(kind: kind, id: row.read<String>('id'),
              title: row.read<String>('title'),
              subtitle: row.read<String>('subtitle'),
              reference: row.read<String?>('reference'),
              status: row.read<String?>('status'),
              score: row.read<int>('score'))];
      } catch (_) {
        // A failing group should not hide successful, permitted groups.
        return [];
      }
    }
    final groups = await Future.wait([
      group(user.can(PosPermission.sell) || user.can(PosPermission.manageCatalog) ||
          user.can(PosPermission.stockReceiving), '''
        SELECT p.id, p.name AS title,
          'SKU ' || COALESCE(p.sku, '—') || ' · Barcode ' || COALESCE(p.barcode, '—')
            AS subtitle, p.sku AS reference, NULL AS status,
          CASE WHEN lower(p.sku) = ? OR lower(p.barcode) = ? THEN 0
            WHEN lower(p.name) LIKE ? OR lower(COALESCE(p.sku,'')) LIKE ?
              OR lower(COALESCE(p.barcode,'')) LIKE ? THEN 1 ELSE 2 END AS score
        FROM products p WHERE instr(lower(p.name), ?) > 0
          OR instr(lower(COALESCE(p.sku,'')), ?) > 0
          OR instr(lower(COALESCE(p.barcode,'')), ?) > 0
        ORDER BY score, p.name LIMIT 5''',
        [Variable.withString(term), Variable.withString(term),
          Variable.withString(prefix), Variable.withString(prefix),
          Variable.withString(prefix), Variable.withString(term),
          Variable.withString(term), Variable.withString(term)],
        GlobalSearchKind.product),
      group(user.can(PosPermission.viewContacts), '''
        SELECT c.id, c.name AS title, COALESCE(c.phone,'No phone') AS subtitle,
          NULL AS reference, NULL AS status,
          CASE WHEN lower(c.name) = ? OR lower(c.phone) = ? THEN 0
            WHEN lower(c.name) LIKE ? THEN 1 ELSE 2 END AS score
        FROM customers c WHERE instr(lower(c.name), ?) > 0
          OR instr(lower(COALESCE(c.phone,'')), ?) > 0
        ORDER BY score, c.name LIMIT 5''',
        [Variable.withString(term), Variable.withString(term),
          Variable.withString(prefix), Variable.withString(term),
          Variable.withString(term)], GlobalSearchKind.customer),
      group(user.can(PosPermission.viewContacts) &&
          (user.can(PosPermission.stockReceiving) ||
              user.can(PosPermission.manageContacts)), '''
        SELECT s.id, s.name AS title,
          COALESCE(s.contact, s.phone, 'No contact') AS subtitle,
          NULL AS reference, NULL AS status,
          CASE WHEN lower(s.name) = ? OR lower(s.phone) = ? THEN 0
            WHEN lower(s.name) LIKE ? THEN 1 ELSE 2 END AS score
        FROM suppliers s WHERE instr(lower(s.name), ?) > 0
          OR instr(lower(COALESCE(s.phone,'')), ?) > 0
          OR instr(lower(COALESCE(s.contact,'')), ?) > 0
        ORDER BY score, s.name LIMIT 5''',
        [Variable.withString(term), Variable.withString(term),
          Variable.withString(prefix), Variable.withString(term),
          Variable.withString(term), Variable.withString(term)],
        GlobalSearchKind.supplier),
      group(user.can(PosPermission.viewOwnSales), '''
        SELECT s.id, COALESCE(s.receipt_number,
          CASE WHEN s.bir_invoice_number IS NOT NULL THEN
            'Invoice ' || s.bir_invoice_number ELSE 'Sale' END) AS title,
          COALESCE(c.name, s.walk_in_name, 'Walk-in') || ' · ₱' ||
            printf('%.2f', s.total_cents / 100.0) AS subtitle,
          s.receipt_number AS reference, s.status,
          CASE WHEN lower(s.receipt_number) = ? THEN 0
            WHEN lower(s.receipt_number) LIKE ? THEN 1 ELSE 2 END AS score
        FROM sales s LEFT JOIN customers c ON c.id = s.customer_id
        WHERE (? = 1 OR s.cashier_id = ?) AND (
          instr(lower(COALESCE(s.receipt_number,'')), ?) > 0 OR
          instr(lower(CAST(COALESCE(s.bir_invoice_number,'') AS TEXT)), ?) > 0 OR
          instr(lower(COALESCE(c.name,'')), ?) > 0)
        ORDER BY score, s.created_at DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withInt(user.can(PosPermission.viewAllSales) ? 1 : 0),
          Variable.withString(user.id), Variable.withString(term),
          Variable.withString(term), Variable.withString(term)],
        GlobalSearchKind.sale),
      group(user.can(PosPermission.stockReceiving), '''
        SELECT su.id, su.serial_number AS title,
          p.name || ' · ' || su.status AS subtitle,
          su.serial_number AS reference, su.status,
          CASE WHEN lower(su.serial_number) = ? THEN 0
            WHEN lower(su.serial_number) LIKE ? THEN 1 ELSE 2 END AS score
        FROM serial_units su JOIN products p ON p.id = su.product_id
        WHERE instr(lower(su.serial_number), ?) > 0
        ORDER BY score, su.created_at DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withString(term)], GlobalSearchKind.serial),
      group(user.can(PosPermission.manageQuotations), '''
        SELECT q.id, q.reference AS title,
          COALESCE(c.name, q.customer_name_snapshot, 'Walk-in') AS subtitle,
          q.reference, q.status,
          CASE WHEN lower(q.reference) = ? THEN 0
            WHEN lower(q.reference) LIKE ? THEN 1 ELSE 2 END AS score
        FROM quotations q LEFT JOIN customers c ON c.id = q.customer_id
        WHERE instr(lower(q.reference), ?) > 0 OR
          instr(lower(COALESCE(c.name,q.customer_name_snapshot,'')), ?) > 0
        ORDER BY score, q.created_at DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withString(term), Variable.withString(term)],
        GlobalSearchKind.quotation),
      group(user.can(PosPermission.viewSalesOrders), '''
        SELECT o.id, o.reference AS title,
          o.customer_name_snapshot || ' • ' ||
            CASE o.fulfillment_method WHEN 'pickup' THEN 'Pickup'
              WHEN 'delivery' THEN 'Delivery' ELSE 'No method' END ||
            ' • ' || CASE o.physical_status
              WHEN 'out_for_delivery' THEN 'Out for delivery'
              WHEN 'failed_delivery' THEN 'Failed delivery'
              WHEN 'picked_up' THEN 'Picked up'
              ELSE upper(substr(o.physical_status,1,1)) || substr(o.physical_status,2)
            END AS subtitle,
          o.reference, o.status,
          CASE WHEN lower(o.reference) = ? THEN 0
            WHEN lower(o.reference) LIKE ? THEN 1 ELSE 2 END AS score
        FROM sales_orders o
        WHERE instr(lower(o.reference), ?) > 0 OR
          instr(lower(o.customer_name_snapshot), ?) > 0
        ORDER BY score, o.created_at DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withString(term), Variable.withString(term)],
        GlobalSearchKind.salesOrder),
      group(user.can(PosPermission.manageLayaway), '''
        SELECT l.id, l.reference AS title, c.name AS subtitle,
          l.reference, l.status,
          CASE WHEN lower(l.reference) = ? THEN 0
            WHEN lower(l.reference) LIKE ? THEN 1 ELSE 2 END AS score
        FROM layaways l JOIN customers c ON c.id = l.customer_id
        WHERE instr(lower(l.reference), ?) > 0 OR instr(lower(c.name), ?) > 0
        ORDER BY score, l.created_at DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withString(term), Variable.withString(term)],
        GlobalSearchKind.layaway),
      group(user.can(PosPermission.stockReceiving), '''
        SELECT po.id, printf('PO-%06d',po.sequence) AS title,
          s.name || CASE WHEN po.supplier_reference IS NULL THEN '' ELSE
            ' · ' || po.supplier_reference END AS subtitle,
          printf('PO-%06d',po.sequence) AS reference, po.status,
          CASE WHEN lower(printf('PO-%06d',po.sequence)) = ? THEN 0
            WHEN lower(printf('PO-%06d',po.sequence)) LIKE ? THEN 1 ELSE 2 END AS score
        FROM purchase_orders po JOIN suppliers s ON s.id = po.supplier_id
        WHERE instr(lower(printf('PO-%06d',po.sequence)), ?) > 0 OR
          instr(lower(s.name), ?) > 0 OR
          instr(lower(COALESCE(po.supplier_reference,'')), ?) > 0
        ORDER BY score, po.created_at DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withString(term), Variable.withString(term),
          Variable.withString(term)], GlobalSearchKind.purchaseOrder),
      group(user.can(PosPermission.stockReceiving), '''
        SELECT r.id, printf('RCV-%06d',r.sequence) AS title,
          s.name || CASE WHEN r.external_reference IS NULL THEN '' ELSE
            ' · ' || r.external_reference END AS subtitle,
          printf('RCV-%06d',r.sequence) AS reference, NULL AS status,
          CASE WHEN lower(printf('RCV-%06d',r.sequence)) = ? THEN 0
            WHEN lower(printf('RCV-%06d',r.sequence)) LIKE ? THEN 1 ELSE 2 END AS score
        FROM stock_receivings r JOIN suppliers s ON s.id = r.supplier_id
        WHERE instr(lower(printf('RCV-%06d',r.sequence)), ?) > 0 OR
          instr(lower(s.name), ?) > 0 OR
          instr(lower(COALESCE(r.external_reference,'')), ?) > 0
        ORDER BY score, r.received_at DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withString(term), Variable.withString(term),
          Variable.withString(term)], GlobalSearchKind.receiving),
      group(user.can(PosPermission.manageRma), '''
        SELECT r.id, r.reference AS title,
          COALESCE(c.name,s.name,p.name,'Warranty case') || ' · ' || r.origin AS subtitle,
          r.reference, r.status,
          CASE WHEN lower(r.reference) = ? THEN 0
            WHEN lower(r.reference) LIKE ? THEN 1 ELSE 2 END AS score
        FROM rma_cases r LEFT JOIN customers c ON c.id = r.customer_id
          LEFT JOIN suppliers s ON s.id = r.supplier_id
          LEFT JOIN serial_units su ON su.id = r.serial_unit_id
          LEFT JOIN products p ON p.id = su.product_id
        WHERE instr(lower(r.reference), ?) > 0 OR
          instr(lower(COALESCE(c.name,'')), ?) > 0 OR
          instr(lower(COALESCE(s.name,'')), ?) > 0 OR
          instr(lower(COALESCE(su.serial_number,'')), ?) > 0 OR
          instr(lower(COALESCE(r.issue_description,'')), ?) > 0
        ORDER BY score, r.reference DESC LIMIT 5''',
        [Variable.withString(term), Variable.withString(prefix),
          Variable.withString(term), Variable.withString(term),
          Variable.withString(term), Variable.withString(term),
          Variable.withString(term)], GlobalSearchKind.rma),
    ]);
    final results = [...commandResults, for (final group in groups) ...group];
    final bestByKind = <GlobalSearchKind, int>{};
    for (final result in results) {
      final prior = bestByKind[result.kind];
      if (prior == null || result.score < prior) {
        bestByKind[result.kind] = result.score;
      }
    }
    results.sort((a, b) {
      final groupScore = bestByKind[a.kind]!.compareTo(bestByKind[b.kind]!);
      if (groupScore != 0) return groupScore;
      final kind = a.kind.index.compareTo(b.kind.index);
      return kind != 0 ? kind : a.score.compareTo(b.score);
    });
    return results.take(40).toList();
  }
}
