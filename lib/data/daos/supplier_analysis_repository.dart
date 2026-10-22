import 'package:drift/drift.dart';

import '../database.dart';

/// Actual purchasing is dated by finalized Receiving, never by PO date.
class SupplierPurchaseLine {
  final String receivingId;
  final int sequence;
  final DateTime date;
  final String? supplierReference;
  final String productId;
  final String product;
  final int quantityMilli;
  final int unitCostCents;
  final int actualCents;
  final int? expectedCents;
  const SupplierPurchaseLine(
      this.receivingId,
      this.sequence,
      this.date,
      this.supplierReference,
      this.productId,
      this.product,
      this.quantityMilli,
      this.unitCostCents,
      this.actualCents,
      this.expectedCents);
}

class SupplierPurchaseTotals {
  final int valueCents;
  final int quantityMilli;
  final int deliveries;
  final int expectedCents;
  final int comparableActualCents;
  const SupplierPurchaseTotals(this.valueCents, this.quantityMilli,
      this.deliveries, this.expectedCents, this.comparableActualCents);
  int? get averageActualUnitCostCents =>
      quantityMilli <= 0 ? null : (valueCents * 1000 / quantityMilli).round();
}

class SupplierProductTotal {
  final String id;
  final String name;
  final String category;
  final int timesReceived;
  final int quantityMilli;
  final int valueCents;
  final int minCostCents;
  final int maxCostCents;
  final int lastCostCents;
  final DateTime lastReceived;
  const SupplierProductTotal(
      this.id,
      this.name,
      this.category,
      this.timesReceived,
      this.quantityMilli,
      this.valueCents,
      this.minCostCents,
      this.maxCostCents,
      this.lastCostCents,
      this.lastReceived);

  int get averageCostCents =>
      quantityMilli == 0 ? 0 : (valueCents * 1000 / quantityMilli).round();
}

class SupplierReceivingLine {
  final String product;
  final int quantityMilli;
  final int actualUnitCostCents;
  final int? expectedUnitCostCents;
  final String? batch;
  final String? serials;
  const SupplierReceivingLine(
      this.product,
      this.quantityMilli,
      this.actualUnitCostCents,
      this.expectedUnitCostCents,
      this.batch,
      this.serials);
  int get actualCents => quantityMilli * actualUnitCostCents ~/ 1000;
  int? get expectedCents => expectedUnitCostCents == null
      ? null
      : quantityMilli * expectedUnitCostCents! ~/ 1000;
}

class SupplierMonthlyValue {
  final String month;
  final int valueCents;
  final int deliveries;
  final int quantityMilli;
  const SupplierMonthlyValue(
      this.month, this.valueCents, this.deliveries, this.quantityMilli);
}

class SupplierReceivingSummary {
  final int lineCount;
  final int actualCents;
  final String? actor;
  const SupplierReceivingSummary(this.lineCount, this.actualCents, this.actor);
}

class SupplierOrderSummary {
  final int expectedValueCents;
  final int receivedMilli;
  final int remainingMilli;
  const SupplierOrderSummary(
      this.expectedValueCents, this.receivedMilli, this.remainingMilli);
}

class SupplierAnalysisRepository {
  final AppDatabase db;
  const SupplierAnalysisRepository(this.db);

  static DateTime _date(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

  Future<int> orderCount(String supplierId) async {
    final row = await db.customSelect(
        'SELECT COUNT(*) AS total FROM purchase_orders WHERE supplier_id=?',
        variables: [Variable.withString(supplierId)]).getSingle();
    return row.read<int>('total');
  }

  Future<int> preferredCount(String supplierId) async {
    final row = await db.customSelect(
        'SELECT COUNT(*) AS total FROM products WHERE preferred_supplier_id=?',
        variables: [Variable.withString(supplierId)]).getSingle();
    return row.read<int>('total');
  }

  Future<List<Product>> preferredPage(String supplierId, int page) =>
      (db.select(db.products)
            ..where((p) => p.preferredSupplierId.equals(supplierId))
            ..orderBy([(p) => OrderingTerm(expression: p.name)])
            ..limit(50, offset: page * 50))
          .get();

  Future<List<PurchaseOrder>> orderPage(String supplierId, int page) =>
      (db.select(db.purchaseOrders)
            ..where((o) => o.supplierId.equals(supplierId))
            ..orderBy([
              (o) =>
                  OrderingTerm(expression: o.sequence, mode: OrderingMode.desc)
            ])
            ..limit(50, offset: page * 50))
          .get();

  Future<Map<String, SupplierOrderSummary>> orderSummaries(
      List<PurchaseOrder> orders) async {
    if (orders.isEmpty) return {};
    final ids = orders.map((o) => o.id).toList();
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''
      WITH received AS (
        SELECT purchase_order_line_id AS line_id,
          SUM(quantity_milli) AS qty
        FROM stock_receiving_items WHERE purchase_order_line_id IS NOT NULL
        GROUP BY purchase_order_line_id
      )
      SELECT pl.purchase_order_id,
        CAST(SUM((pl.ordered_qty_milli-pl.cancelled_qty_milli)
          * pl.expected_unit_cost_cents / 1000) AS INTEGER) AS expected_value,
        SUM(COALESCE(received.qty,0)) AS received_qty,
        SUM(MAX(pl.ordered_qty_milli-pl.cancelled_qty_milli
          - COALESCE(received.qty,0),0)) AS remaining_qty
      FROM purchase_order_lines pl
      LEFT JOIN received ON received.line_id=pl.id
      WHERE pl.purchase_order_id IN ($marks)
      GROUP BY pl.purchase_order_id
    ''', variables: [for (final id in ids) Variable.withString(id)]).get();
    return {
      for (final row in rows)
        row.read<String>('purchase_order_id'): SupplierOrderSummary(
            row.read<int>('expected_value'),
            row.read<int>('received_qty'),
            row.read<int>('remaining_qty'))
    };
  }

  Future<int> receivingCount(String supplierId) async {
    final row = await db.customSelect(
        'SELECT COUNT(*) AS total FROM stock_receivings WHERE supplier_id=?',
        variables: [Variable.withString(supplierId)]).getSingle();
    return row.read<int>('total');
  }

  Future<List<StockReceiving>> receivingPage(String supplierId, int page) => (db
          .select(db.stockReceivings)
        ..where((r) => r.supplierId.equals(supplierId))
        ..orderBy([
          (r) => OrderingTerm(expression: r.receivedAt, mode: OrderingMode.desc)
        ])
        ..limit(50, offset: page * 50))
      .get();

  Future<Map<String, SupplierReceivingSummary>> receivingSummaries(
      List<StockReceiving> receipts) async {
    if (receipts.isEmpty) return {};
    final ids = receipts.map((r) => r.id).toList();
    final marks = List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''
      SELECT r.id, COUNT(i.id) AS lines,
        COALESCE(CAST(SUM(i.quantity_milli * i.unit_cost_cents / 1000) AS INTEGER),0) AS actual,
        u.name AS actor
      FROM stock_receivings r
      LEFT JOIN stock_receiving_items i ON i.receiving_id=r.id
      LEFT JOIN users u ON u.id=r.user_id
      WHERE r.id IN ($marks) GROUP BY r.id
    ''', variables: [for (final id in ids) Variable.withString(id)]).get();
    return {
      for (final row in rows)
        row.read<String>('id'): SupplierReceivingSummary(row.read<int>('lines'),
            row.read<int>('actual'), row.read<String?>('actor'))
    };
  }

  Future<List<SupplierReceivingLine>> receivingLines(String receivingId) async {
    final rows = await db.customSelect('''
      SELECT p.name, i.quantity_milli, i.unit_cost_cents,
        pl.expected_unit_cost_cents, i.batch_number,
        GROUP_CONCAT(s.serial_number, ', ') AS serials
      FROM stock_receiving_items i
      JOIN products p ON p.id=i.product_id
      LEFT JOIN purchase_order_lines pl ON pl.id=i.purchase_order_line_id
      LEFT JOIN serial_units s ON s.receiving_item_id=i.id
      WHERE i.receiving_id=? GROUP BY i.id ORDER BY p.name
    ''', variables: [Variable.withString(receivingId)]).get();
    return [
      for (final row in rows)
        SupplierReceivingLine(
            row.read<String>('name'),
            row.read<int>('quantity_milli'),
            row.read<int>('unit_cost_cents'),
            row.read<int?>('expected_unit_cost_cents'),
            row.read<String?>('batch_number'),
            row.read<String?>('serials'))
    ];
  }

  Future<String?> receivingActor(String receivingId) async {
    final row = await db.customSelect('''
      SELECT u.name FROM stock_receivings r
      LEFT JOIN users u ON u.id=r.user_id WHERE r.id=?
    ''', variables: [Variable.withString(receivingId)]).getSingleOrNull();
    return row?.read<String?>('name');
  }

  Future<String?> receivingPoReference(String receivingId) async {
    final row = await db.customSelect('''
      SELECT po.sequence FROM stock_receivings r
      LEFT JOIN purchase_orders po ON po.id=r.purchase_order_id
      WHERE r.id=?
    ''', variables: [Variable.withString(receivingId)]).getSingleOrNull();
    final sequence = row?.read<int?>('sequence');
    return sequence == null
        ? null
        : 'PO-${sequence.toString().padLeft(6, '0')}';
  }

  Future<List<SupplierMonthlyValue>> monthlyValues(
      String supplierId, DateTime from, DateTime until) async {
    final rows = await db.customSelect('''
      SELECT strftime('%Y-%m', datetime(r.received_at, 'unixepoch')) AS month,
        COUNT(DISTINCT r.id) AS deliveries,
        COALESCE(SUM(i.quantity_milli),0) AS quantity,
        COALESCE(CAST(SUM(i.quantity_milli * i.unit_cost_cents / 1000) AS INTEGER),0) AS value
      FROM stock_receivings r
      JOIN stock_receiving_items i ON i.receiving_id=r.id
      WHERE r.supplier_id=? AND r.received_at>=? AND r.received_at<?
        AND r.finalized_at IS NOT NULL
      GROUP BY month ORDER BY month
    ''', variables: _scope(supplierId, from, until)).get();
    return [
      for (final row in rows)
        SupplierMonthlyValue(row.read<String>('month'), row.read<int>('value'),
            row.read<int>('deliveries'), row.read<int>('quantity'))
    ];
  }

  List<Variable> _scope(String supplierId, DateTime from, DateTime until) => [
        Variable.withString(supplierId),
        Variable.withInt(from.millisecondsSinceEpoch ~/ 1000),
        Variable.withInt(until.millisecondsSinceEpoch ~/ 1000),
      ];

  List<Variable> _purchaseFilters(
      String? productId, String? categoryId, String reference) {
    final query = '%${reference.trim().toLowerCase()}%';
    return [
      Variable<String>(productId),
      Variable<String>(productId),
      Variable<String>(categoryId),
      Variable<String>(categoryId),
      Variable.withString(reference.trim()),
      Variable.withString(query),
      Variable.withString(query),
    ];
  }

  Future<SupplierPurchaseTotals> totals(
      String supplierId, DateTime from, DateTime until,
      {String? productId, String? categoryId, String reference = ''}) async {
    final row = await db.customSelect('''
      SELECT COALESCE(SUM(i.quantity_milli * i.unit_cost_cents / 1000),0) AS value,
        COALESCE(SUM(i.quantity_milli),0) AS quantity,
        COUNT(DISTINCT r.id) AS deliveries,
        COALESCE(SUM(CASE WHEN pl.id IS NOT NULL THEN
          i.quantity_milli * pl.expected_unit_cost_cents / 1000 ELSE 0 END),0) AS expected,
        COALESCE(SUM(CASE WHEN pl.id IS NOT NULL THEN
          i.quantity_milli * i.unit_cost_cents / 1000 ELSE 0 END),0) AS comparable
      FROM stock_receivings r
      LEFT JOIN stock_receiving_items i ON i.receiving_id = r.id
      LEFT JOIN products p ON p.id=i.product_id
      LEFT JOIN purchase_order_lines pl ON pl.id = i.purchase_order_line_id
      WHERE r.supplier_id = ? AND r.received_at >= ? AND r.received_at < ?
        AND r.finalized_at IS NOT NULL
        AND (? IS NULL OR i.product_id=?)
        AND (? IS NULL OR p.category_id=?)
        AND (?='' OR lower(COALESCE(r.external_reference,'')) LIKE ?
          OR lower(printf('RCV-%06d',r.sequence)) LIKE ?)
    ''', variables: [
      ..._scope(supplierId, from, until),
      ..._purchaseFilters(productId, categoryId, reference),
    ]).getSingle();
    return SupplierPurchaseTotals(
        row.read<int>('value'),
        row.read<int>('quantity'),
        row.read<int>('deliveries'),
        row.read<int>('expected'),
        row.read<int>('comparable'));
  }

  Future<int> lineCount(String supplierId, DateTime from, DateTime until,
      {String? productId, String? categoryId, String reference = ''}) async {
    final row = await db.customSelect('''
      SELECT COUNT(*) AS total FROM stock_receiving_items i
      JOIN stock_receivings r ON r.id=i.receiving_id
      JOIN products p ON p.id=i.product_id
      WHERE r.supplier_id=? AND r.received_at>=? AND r.received_at<?
        AND r.finalized_at IS NOT NULL
        AND (? IS NULL OR i.product_id=?)
        AND (? IS NULL OR p.category_id=?)
        AND (?='' OR lower(COALESCE(r.external_reference,'')) LIKE ?
          OR lower(printf('RCV-%06d',r.sequence)) LIKE ?)
    ''', variables: [
      ..._scope(supplierId, from, until),
      ..._purchaseFilters(productId, categoryId, reference),
    ]).getSingle();
    return row.read<int>('total');
  }

  Future<List<SupplierPurchaseLine>> lines(
      String supplierId, DateTime from, DateTime until, int page,
      {String? productId, String? categoryId, String reference = ''}) async {
    final rows = await db.customSelect('''
      SELECT r.id AS receiving_id, COALESCE(r.sequence,0) AS sequence,
        r.received_at, r.external_reference, i.product_id, p.name,
        i.quantity_milli, i.unit_cost_cents,
        CAST(i.quantity_milli * i.unit_cost_cents / 1000 AS INTEGER) AS actual,
        CASE WHEN pl.id IS NULL THEN NULL ELSE
          CAST(i.quantity_milli * pl.expected_unit_cost_cents / 1000 AS INTEGER)
        END AS expected
      FROM stock_receiving_items i
      JOIN stock_receivings r ON r.id=i.receiving_id
      JOIN products p ON p.id=i.product_id
      LEFT JOIN purchase_order_lines pl ON pl.id=i.purchase_order_line_id
      WHERE r.supplier_id=? AND r.received_at>=? AND r.received_at<?
        AND r.finalized_at IS NOT NULL
        AND (? IS NULL OR i.product_id=?)
        AND (? IS NULL OR p.category_id=?)
        AND (?='' OR lower(COALESCE(r.external_reference,'')) LIKE ?
          OR lower(printf('RCV-%06d',r.sequence)) LIKE ?)
      ORDER BY r.received_at DESC, r.sequence DESC, p.name
      LIMIT 50 OFFSET ?
    ''', variables: [
      ..._scope(supplierId, from, until),
      ..._purchaseFilters(productId, categoryId, reference),
      Variable.withInt(page * 50)
    ]).get();
    return [
      for (final r in rows)
        SupplierPurchaseLine(
            r.read<String>('receiving_id'),
            r.read<int>('sequence'),
            _date(r.read<int>('received_at')),
            r.read<String?>('external_reference'),
            r.read<String>('product_id'),
            r.read<String>('name'),
            r.read<int>('quantity_milli'),
            r.read<int>('unit_cost_cents'),
            r.read<int>('actual'),
            r.read<int?>('expected'))
    ];
  }

  Future<int> productCount(
      String supplierId, DateTime from, DateTime until) async {
    final row = await db.customSelect('''
      SELECT COUNT(DISTINCT i.product_id) AS total
      FROM stock_receiving_items i JOIN stock_receivings r ON r.id=i.receiving_id
      WHERE r.supplier_id=? AND r.received_at>=? AND r.received_at<?
        AND r.finalized_at IS NOT NULL
    ''', variables: _scope(supplierId, from, until)).getSingle();
    return row.read<int>('total');
  }

  Future<List<(String, String)>> categories(
      String supplierId, DateTime from, DateTime until) async {
    final rows = await db.customSelect('''
      SELECT DISTINCT c.id, c.name
      FROM stock_receiving_items i
      JOIN stock_receivings r ON r.id=i.receiving_id
      JOIN products p ON p.id=i.product_id
      JOIN categories c ON c.id=p.category_id
      WHERE r.supplier_id=? AND r.received_at>=? AND r.received_at<?
        AND r.finalized_at IS NOT NULL
      ORDER BY c.name
    ''', variables: _scope(supplierId, from, until)).get();
    return [
      for (final row in rows) (row.read<String>('id'), row.read<String>('name'))
    ];
  }

  Future<List<SupplierProductTotal>> products(
      String supplierId, DateTime from, DateTime until,
      {int? page}) async {
    final rows = await db.customSelect('''
      SELECT i.product_id, p.name, COALESCE(c.name,'Uncategorized') AS category,
        COUNT(DISTINCT r.id) AS times_received,
        SUM(i.quantity_milli) AS quantity,
        CAST(SUM(i.quantity_milli * i.unit_cost_cents / 1000) AS INTEGER) AS value,
        MIN(i.unit_cost_cents) AS minimum, MAX(i.unit_cost_cents) AS maximum,
        (SELECT i2.unit_cost_cents FROM stock_receiving_items i2
          JOIN stock_receivings r2 ON r2.id=i2.receiving_id
          WHERE i2.product_id=i.product_id AND r2.supplier_id=r.supplier_id
            AND r2.finalized_at IS NOT NULL AND r2.received_at>=? AND r2.received_at<?
          ORDER BY r2.received_at DESC, r2.sequence DESC LIMIT 1) AS last_cost,
        MAX(r.received_at) AS last_received
      FROM stock_receiving_items i
      JOIN stock_receivings r ON r.id=i.receiving_id
      JOIN products p ON p.id=i.product_id
      LEFT JOIN categories c ON c.id=p.category_id
      WHERE r.supplier_id=? AND r.received_at>=? AND r.received_at<?
        AND r.finalized_at IS NOT NULL
      GROUP BY i.product_id
      ORDER BY value DESC
      ${page == null ? '' : 'LIMIT 50 OFFSET ?'}
    ''', variables: [
      Variable.withInt(from.millisecondsSinceEpoch ~/ 1000),
      Variable.withInt(until.millisecondsSinceEpoch ~/ 1000),
      ..._scope(supplierId, from, until),
      if (page != null) Variable.withInt(page * 50),
    ]).get();
    return [
      for (final r in rows)
        SupplierProductTotal(
            r.read<String>('product_id'),
            r.read<String>('name'),
            r.read<String>('category'),
            r.read<int>('times_received'),
            r.read<int>('quantity'),
            r.read<int>('value'),
            r.read<int>('minimum'),
            r.read<int>('maximum'),
            r.read<int>('last_cost'),
            _date(r.read<int>('last_received')))
    ];
  }
}
