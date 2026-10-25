import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'paged_result.dart';

class SalesOrderLineRequest {
  final String productId;
  final int quantityMilli;
  final int unitPriceCents;
  final int discountCents;
  const SalesOrderLineRequest(this.productId, this.quantityMilli,
      this.unitPriceCents, {this.discountCents = 0});
}

class SalesOrderRepository {
  final AppDatabase db;
  const SalesOrderRepository(this.db);

  Future<SalesOrder?> byReference(String reference) =>
      (db.select(db.salesOrders)..where((o) => o.reference.equals(reference)))
          .getSingleOrNull();

  Future<List<SalesOrderLine>> lines(String orderId) =>
      (db.select(db.salesOrderLines)
            ..where((l) => l.salesOrderId.equals(orderId))
            ..orderBy([(l) => OrderingTerm(expression: l.sortOrder)]))
          .get();

  Future<Map<String, int>> fulfilledByLine(String orderId) async {
    final rows = await db.customSelect('''
      SELECT fl.sales_order_line_id, SUM(fl.quantity_milli) AS quantity
      FROM sales_order_fulfillment_lines fl
      JOIN sales_order_fulfillments f ON f.id = fl.fulfillment_id
      JOIN sales s ON s.id = f.sale_id
      WHERE f.sales_order_id = ? AND s.status != 'voided'
      GROUP BY fl.sales_order_line_id
    ''', variables: [Variable.withString(orderId)]).get();
    return {for (final row in rows)
      row.read<String>('sales_order_line_id'): row.read<int>('quantity')};
  }

  Future<Map<String, String>> fulfillmentStates(
      Iterable<String> orderIds) async {
    final ids = orderIds.toSet().toList();
    if (ids.isEmpty) return {};
    final result = <String, String>{};
    for (var start = 0; start < ids.length; start += 900) {
      final batch = ids.skip(start).take(900).toList();
      final placeholders = List.filled(batch.length, '?').join(',');
      final rows = await db.customSelect('''
        WITH fulfilled AS (
          SELECT fl.sales_order_line_id, SUM(fl.quantity_milli) AS quantity
          FROM sales_order_fulfillment_lines fl
          JOIN sales_order_fulfillments f ON f.id = fl.fulfillment_id
          JOIN sales s ON s.id = f.sale_id
          WHERE s.status != 'voided'
          GROUP BY fl.sales_order_line_id
        )
        SELECT l.sales_order_id,
          SUM(l.quantity_milli) AS ordered,
          SUM(COALESCE(fulfilled.quantity, 0)) AS fulfilled
        FROM sales_order_lines l
        LEFT JOIN fulfilled ON fulfilled.sales_order_line_id = l.id
        WHERE l.sales_order_id IN ($placeholders)
        GROUP BY l.sales_order_id
      ''', variables: [for (final id in batch) Variable.withString(id)]).get();
      for (final row in rows) {
        final ordered = row.read<int>('ordered');
        final fulfilled = row.read<int>('fulfilled');
        result[row.read<String>('sales_order_id')] = fulfilled == 0
            ? 'Unfulfilled' : fulfilled >= ordered
                ? 'Fulfilled' : 'Partially fulfilled';
      }
    }
    return result;
  }

  Future<List<Sale>> fulfillmentSales(String orderId) async {
    final links = await (db.select(db.salesOrderFulfillments)
      ..where((f) => f.salesOrderId.equals(orderId))
      ..orderBy([(f) => OrderingTerm(expression: f.createdAt,
          mode: OrderingMode.desc)])).get();
    if (links.isEmpty) return [];
    final sales = await (db.select(db.sales)
      ..where((s) => s.id.isIn(links.map((f) => f.saleId)))).get();
    final byId = {for (final sale in sales) sale.id: sale};
    return [for (final link in links) byId[link.saleId]!];
  }

  Future<SalesOrder?> fromQuotation(String quotationId) =>
      (db.select(db.salesOrders)
            ..where((o) => o.sourceQuotationId.equals(quotationId))
            ..orderBy([(o) => OrderingTerm(expression: o.createdAt,
                mode: OrderingMode.desc)])
            ..limit(1))
          .getSingleOrNull();

  Future<PagedResult<SalesOrder>> page({int page = 0, String search = '',
      String status = 'all', String? customerId}) async {
    if (page < 0) throw ArgumentError.value(page, 'page');
    if (!{'all', 'draft', 'confirmed', 'cancelled'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    final clauses = <String>[];
    final args = <Variable>[];
    if (status != 'all') {
      clauses.add('status = ?');
      args.add(Variable.withString(status));
    }
    if (customerId != null) {
      clauses.add('customer_id = ?');
      args.add(Variable.withString(customerId));
    }
    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      clauses.add('(instr(lower(reference), ?) > 0 OR '
          'instr(lower(customer_name_snapshot), ?) > 0)');
      args.addAll([Variable.withString(term), Variable.withString(term)]);
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return db.transaction(() async {
      final count = (await db.customSelect(
        'SELECT COUNT(*) AS n FROM sales_orders $where', variables: args,
      ).getSingle()).read<int>('n');
      final ids = (await db.customSelect(
        'SELECT id FROM sales_orders $where '
        'ORDER BY created_at DESC, id DESC LIMIT 50 OFFSET ?',
        variables: [...args, Variable.withInt(page * 50)],
      ).get()).map((r) => r.read<String>('id')).toList();
      if (ids.isEmpty) {
        return PagedResult(items: <SalesOrder>[],
            totalCount: count, page: page);
      }
      final rows = await (db.select(db.salesOrders)
            ..where((o) => o.id.isIn(ids))).get();
      final byId = {for (final row in rows) row.id: row};
      return PagedResult(items: [for (final id in ids) byId[id]!],
          totalCount: count, page: page);
    });
  }

  Future<SalesOrder> create(ActiveUser actor, String customerId,
      List<SalesOrderLineRequest> lines, {String? notes,
      String? fulfillmentMethod, DateTime? requestedDate}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageSalesOrders);
        final customer = await (db.select(db.customers)
          ..where((c) => c.id.equals(customerId))).getSingleOrNull();
        if (customer == null || !customer.isActive) {
          throw StateError('Select an active customer');
        }
        if (lines.isEmpty) throw StateError('Add at least one item');
        if (fulfillmentMethod != null &&
            !{'pickup', 'delivery'}.contains(fulfillmentMethod)) {
          throw StateError('Choose pickup or delivery');
        }
        final snapshots = <SalesOrderLinesCompanion>[];
        var subtotal = 0;
        var discounts = 0;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final product = await (db.select(db.products)
            ..where((p) => p.id.equals(line.productId))).getSingleOrNull();
          if (product == null || !product.isActive) {
            throw StateError('Select an active product');
          }
          final config = await BusinessFeatureRepository(db)
              .businessProduct(product.id);
          if (line.quantityMilli <= 0 ||
              (!config.fractional &&
                  line.quantityMilli % Quantity.scale != 0)) {
            throw StateError('Enter a valid quantity for ${product.name}');
          }
          if (line.unitPriceCents < 0 || line.discountCents < 0) {
            throw StateError('Price and discount must be nonnegative');
          }
          final gross = Quantity.lineCents(
              line.unitPriceCents, line.quantityMilli);
          if (line.discountCents > gross) {
            throw StateError('Discount exceeds line amount');
          }
          subtotal += gross;
          discounts += line.discountCents;
          snapshots.add(SalesOrderLinesCompanion.insert(
            salesOrderId: '', productId: Value(product.id),
            descriptionSnapshot: product.name,
            skuSnapshot: Value(product.sku),
            unitSnapshot: config.unit.label,
            quantityMilli: line.quantityMilli,
            unitPriceCents: line.unitPriceCents,
            discountCents: Value(line.discountCents),
            lineTotalCents: gross - line.discountCents,
            sortOrder: i));
        }
        final next = (await db.customSelect(
          "SELECT COALESCE(MAX(CAST(SUBSTR(reference, 4) AS INTEGER)), 0) + 1 AS n FROM sales_orders",
        ).getSingle()).read<int>('n');
        final order = await db.into(db.salesOrders).insertReturning(
          SalesOrdersCompanion.insert(
            reference: 'SO-${next.toString().padLeft(6, '0')}',
            customerId: customer.id,
            customerNameSnapshot: customer.name,
            createdBy: live.id,
            subtotalCents: subtotal,
            discountCents: Value(discounts),
            totalCents: subtotal - discounts,
            notes: Value(notes?.trim()),
            fulfillmentMethod: Value(fulfillmentMethod),
            requestedDate: Value(requestedDate == null ? null :
                DateTime(requestedDate.year, requestedDate.month,
                    requestedDate.day))));
        for (final snapshot in snapshots) {
          await db.into(db.salesOrderLines).insert(snapshot.copyWith(
              salesOrderId: Value(order.id)));
        }
        await AuthRepository(db).audit(live.id, 'sales_order.created', order.id);
        return order;
      });

  Future<SalesOrder> convertQuotation(ActiveUser actor, String quotationId,
      {String? fulfillmentMethod, DateTime? requestedDate}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageSalesOrders);
        final quote = await (db.select(db.quotations)
          ..where((q) => q.id.equals(quotationId))).getSingleOrNull();
        if (quote == null || quote.customerId == null) {
          throw StateError('Quotation needs a customer');
        }
        if (quote.status != 'open') {
          throw StateError('Only open quotations can create orders');
        }
        final items = await (db.select(db.quotationItems)
          ..where((i) => i.quotationId.equals(quotationId))).get();
        if (items.isEmpty) throw StateError('Quotation has no items');
        if (fulfillmentMethod != null &&
            !{'pickup', 'delivery'}.contains(fulfillmentMethod)) {
          throw StateError('Choose pickup or delivery');
        }
        final customer = await (db.select(db.customers)
          ..where((c) => c.id.equals(quote.customerId!))).getSingleOrNull();
        if (customer == null) throw StateError('Customer is unavailable');
        var total = 0;
        for (final item in items) {
          if (item.quantityMilli <= 0 || item.unitPriceCents < 0 ||
              item.lineTotalCents < 0) {
            throw StateError('Quotation contains invalid pricing');
          }
          total += item.lineTotalCents;
        }
        final next = (await db.customSelect(
          "SELECT COALESCE(MAX(CAST(SUBSTR(reference, 4) AS INTEGER)), 0) + 1 AS n FROM sales_orders",
        ).getSingle()).read<int>('n');
        final order = await db.into(db.salesOrders).insertReturning(
          SalesOrdersCompanion.insert(
            reference: 'SO-${next.toString().padLeft(6, '0')}',
            customerId: customer.id,
            customerNameSnapshot: quote.customerNameSnapshot ?? customer.name,
            sourceQuotationId: Value(quotationId),
            createdBy: live.id, subtotalCents: total, totalCents: total,
            notes: Value(quote.notes),
            fulfillmentMethod: Value(fulfillmentMethod),
            requestedDate: Value(requestedDate)));
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          await db.into(db.salesOrderLines).insert(
            SalesOrderLinesCompanion.insert(
              salesOrderId: order.id,
              productId: Value(item.productId),
              descriptionSnapshot: item.productNameSnapshot,
              skuSnapshot: Value(item.skuSnapshot),
              unitSnapshot: item.unitSnapshot,
              saleMode: Value(item.saleMode),
              extraCents: Value(item.extraCents),
              quantityMilli: item.quantityMilli,
              unitPriceCents: item.unitPriceCents + item.extraCents,
              lineTotalCents: item.lineTotalCents,
              sortOrder: i));
        }
        await AuthRepository(db).audit(live.id,
            'sales_order.created_from_quotation', order.id);
        return order;
      });

  Future<SalesOrder> updateDraft(ActiveUser actor, String id,
      String customerId, List<SalesOrderLineRequest> lines,
      {String? notes, String? fulfillmentMethod, DateTime? requestedDate}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageSalesOrders);
        final order = await (db.select(db.salesOrders)
          ..where((o) => o.id.equals(id))).getSingleOrNull();
        if (order == null || order.status != 'draft') {
          throw StateError('Only draft Sales Orders can be edited');
        }
        final customer = await (db.select(db.customers)
          ..where((c) => c.id.equals(customerId))).getSingleOrNull();
        if (customer == null || !customer.isActive) {
          throw StateError('Select an active customer');
        }
        if (lines.isEmpty) throw StateError('Add at least one item');
        if (fulfillmentMethod != null &&
            !{'pickup', 'delivery'}.contains(fulfillmentMethod)) {
          throw StateError('Choose pickup or delivery');
        }
        final snapshots = <SalesOrderLinesCompanion>[];
        var subtotal = 0, discount = 0;
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          final product = await (db.select(db.products)
            ..where((p) => p.id.equals(line.productId))).getSingleOrNull();
          if (product == null || !product.isActive) {
            throw StateError('Select an active product');
          }
          final config = await BusinessFeatureRepository(db)
              .businessProduct(product.id);
          if (line.quantityMilli <= 0 ||
              (!config.fractional &&
                  line.quantityMilli % Quantity.scale != 0)) {
            throw StateError('Enter a valid quantity');
          }
          if (line.unitPriceCents < 0 || line.discountCents < 0) {
            throw StateError('Price and discount must be nonnegative');
          }
          final gross = Quantity.lineCents(line.unitPriceCents,
              line.quantityMilli);
          if (line.discountCents > gross) {
            throw StateError('Discount exceeds line amount');
          }
          subtotal += gross;
          discount += line.discountCents;
          snapshots.add(SalesOrderLinesCompanion.insert(
            salesOrderId: id, productId: Value(product.id),
            descriptionSnapshot: product.name,
            skuSnapshot: Value(product.sku),
            unitSnapshot: config.unit.label,
            quantityMilli: line.quantityMilli,
            unitPriceCents: line.unitPriceCents,
            discountCents: Value(line.discountCents),
            lineTotalCents: gross - line.discountCents,
            sortOrder: i));
        }
        await (db.delete(db.salesOrderLines)
          ..where((l) => l.salesOrderId.equals(id))).go();
        for (final snapshot in snapshots) {
          await db.into(db.salesOrderLines).insert(snapshot);
        }
        await (db.update(db.salesOrders)..where((o) => o.id.equals(id)))
            .write(SalesOrdersCompanion(
              customerId: Value(customer.id),
              customerNameSnapshot: Value(customer.name),
              subtotalCents: Value(subtotal),
              discountCents: Value(discount),
              totalCents: Value(subtotal - discount),
              notes: Value(notes?.trim()),
              fulfillmentMethod: Value(fulfillmentMethod),
              requestedDate: Value(requestedDate),
              updatedAt: Value(DateTime.now())));
        await AuthRepository(db).audit(live.id,
            'sales_order.draft_updated', id);
        return (await (db.select(db.salesOrders)
          ..where((o) => o.id.equals(id))).getSingle());
      });

  Future<SalesOrder> transition(ActiveUser actor, String id, String status) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageSalesOrders);
        final order = await (db.select(db.salesOrders)
          ..where((o) => o.id.equals(id))).getSingleOrNull();
        if (order == null) throw StateError('Sales Order not found');
        if (!((order.status == 'draft' && status == 'confirmed') ||
            (order.status == 'confirmed' && status == 'cancelled'))) {
          throw StateError('Invalid Sales Order status change');
        }
        if (status == 'confirmed') {
          final orderLines = await lines(id);
          if (order.customerId.isEmpty || orderLines.isEmpty ||
              orderLines.any((l) => l.quantityMilli <= 0 ||
                  l.unitPriceCents < 0 || l.lineTotalCents < 0) ||
              order.totalCents < 0 ||
              order.subtotalCents - order.discountCents != order.totalCents ||
              orderLines.fold<int>(0, (sum, l) => sum + l.lineTotalCents) !=
                  order.totalCents) {
            throw StateError('Sales Order cannot be confirmed');
          }
        }
        await (db.update(db.salesOrders)..where((o) => o.id.equals(id)))
            .write(SalesOrdersCompanion(
                status: Value(status), updatedAt: Value(DateTime.now())));
        if (status == 'cancelled') {
          await (db.update(db.stockReservations)
            ..where((r) => r.salesOrderId.equals(id) &
                r.status.equals('active'))).write(StockReservationsCompanion(
                  status: const Value('released'),
                  releasedBy: Value(live.id),
                  releasedAt: Value(DateTime.now()),
                  releaseReason: const Value('Order cancelled')));
        }
        await AuthRepository(db).audit(live.id,
            'sales_order.$status', id);
        return (await (db.select(db.salesOrders)
          ..where((o) => o.id.equals(id))).getSingle());
      });
}
