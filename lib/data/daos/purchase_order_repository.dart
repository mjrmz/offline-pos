import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'paged_result.dart';

class PurchaseOrderLineInput {
  final String productId;
  final int quantityMilli;
  final int expectedUnitCostCents;
  final String? notes;
  const PurchaseOrderLineInput(
      this.productId, this.quantityMilli, this.expectedUnitCostCents,
      {this.notes});
}

class PurchaseOrderProgress {
  final PurchaseOrder order;
  final List<PurchaseOrderLine> lines;
  final Map<String, int> received;
  final List<StockReceiving> receivings;
  const PurchaseOrderProgress(
      this.order, this.lines, this.received, this.receivings);

  int remaining(PurchaseOrderLine line) =>
      line.orderedQtyMilli - line.cancelledQtyMilli - (received[line.id] ?? 0);
  int get ordered => lines.fold(0, (n, l) => n + l.orderedQtyMilli);
  int get receivedTotal => received.values.fold(0, (n, q) => n + q);
  int get remainingTotal => lines.fold(0, (n, l) => n + remaining(l));
  int get estimatedTotal => lines.fold(
      0,
      (n, l) =>
          n + Quantity.lineCents(l.expectedUnitCostCents, l.orderedQtyMilli));
  bool isOverdue(DateTime now) {
    final expected = order.expectedDeliveryDate;
    if (expected == null ||
        remainingTotal <= 0 ||
        !{'sent', 'partially_received'}.contains(status)) {
      return false;
    }
    final expectedDay = DateTime(expected.year, expected.month, expected.day);
    final today = DateTime(now.year, now.month, now.day);
    return expectedDay.isBefore(today);
  }

  String get status {
    if (order.status == 'draft' ||
        order.status == 'cancelled' ||
        order.status == 'closed') {
      return order.status;
    }
    if (receivedTotal == 0) return 'sent';
    return remainingTotal == 0 ? 'fully_received' : 'partially_received';
  }
}

class ReceivedCostVariance {
  final int expectedCents;
  final int actualCents;
  const ReceivedCostVariance(this.expectedCents, this.actualCents);
  int get differenceCents => actualCents - expectedCents;
  double? get percent =>
      expectedCents == 0 ? null : differenceCents * 100 / expectedCents;
}

class PurchaseOrderActivity {
  final DateTime at;
  final String title;
  final String detail;
  final String? actorName;
  const PurchaseOrderActivity(this.at, this.title, this.detail, this.actorName);
}

class PurchaseOrderRepository {
  final AppDatabase db;
  const PurchaseOrderRepository(this.db);

  Future<List<PurchaseOrderLineSourceLink>> sourceLinksForOrder(
      String orderId) async {
    final lines = await (db.select(db.purchaseOrderLines)
          ..where((l) => l.purchaseOrderId.equals(orderId)))
        .get();
    if (lines.isEmpty) return [];
    return (db.select(db.purchaseOrderLineSourceLinks)
          ..where((s) => s.purchaseOrderLineId.isIn(lines.map((l) => l.id))))
        .get();
  }

  Future<List<PurchaseOrderLineSourceLink>> sourceLinksForQuotation(
          String quotationId) =>
      (db.select(db.purchaseOrderLineSourceLinks)
            ..where((s) => s.quotationId.equals(quotationId)))
          .get();

  Future<Map<String, List<Quotation>>> sourceQuotationsForOrder(
      String orderId) async {
    final links = await sourceLinksForOrder(orderId);
    if (links.isEmpty) return {};
    final quotes = await (db.select(db.quotations)
          ..where((q) => q.id.isIn(links.map((s) => s.quotationId))))
        .get();
    final byId = {for (final quote in quotes) quote.id: quote};
    final result = <String, List<Quotation>>{};
    for (final link in links) {
      final quote = byId[link.quotationId];
      if (quote != null) {
        result.putIfAbsent(link.purchaseOrderLineId, () => []).add(quote);
      }
    }
    return result;
  }

  static int receivedForSource(PurchaseOrderLineSourceLink source,
      Iterable<PurchaseOrderLineSourceLink> lineSources, int receivedQtyMilli) {
    final ordered = lineSources.toList()
      ..sort((a, b) {
        final date = a.createdAt.compareTo(b.createdAt);
        return date != 0 ? date : a.id.compareTo(b.id);
      });
    var left = receivedQtyMilli;
    for (final link in ordered) {
      final applied = left.clamp(0, link.plannedQtyMilli);
      if (link.id == source.id) return applied;
      left -= applied;
    }
    return 0;
  }

  Future<Quotation?> _sourceQuotation(String? reference) async {
    if (reference == null || reference.trim().isEmpty) return null;
    final quote = await (db.select(db.quotations)
          ..where((q) => q.reference.equals(reference.trim())))
        .getSingleOrNull();
    if (quote == null) throw StateError('Source quotation was not found');
    return quote;
  }

  Future<void> _writeSourceLink(String lineId, String productId,
      int plannedQtyMilli, Quotation quote, String actorId) async {
    if (plannedQtyMilli <= 0) return;
    final quoteItem = await (db.select(db.quotationItems)
          ..where((i) =>
              i.quotationId.equals(quote.id) & i.productId.equals(productId)))
        .getSingleOrNull();
    if (quoteItem == null) {
      throw StateError('Product is not linked to the source quotation');
    }
    await db
        .into(db.purchaseOrderLineSourceLinks)
        .insert(PurchaseOrderLineSourceLinksCompanion.insert(
          purchaseOrderLineId: lineId,
          quotationId: quote.id,
          quotationLineId: Value(quoteItem.id),
          plannedQtyMilli: plannedQtyMilli,
          createdByUserId: Value(actorId),
        ));
  }

  Future<List<PurchaseOrder>> list() => (db.select(db.purchaseOrders)
        ..orderBy([
          (o) => OrderingTerm(expression: o.sequence, mode: OrderingMode.desc)
        ]))
      .get();

  /// Mirrors PurchaseOrderProgress.status and isOverdue using SQL aggregates.
  Future<PagedResult<PurchaseOrderProgress>> page({
    int page = 0,
    String search = '',
    String status = 'All',
    String? supplierId,
    DateTime? orderFrom,
    DateTime? orderThrough,
    DateTime? deliveryFrom,
    DateTime? deliveryThrough,
    DateTime? today,
  }) async {
    if (page < 0) throw ArgumentError.value(page, 'page');
    final conditions = <String>[];
    final variables = <Variable>[];
    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      conditions.add('''(
        instr(lower(printf('PO-%06d', q.sequence)), ?) > 0
        OR instr(lower(s.name), ?) > 0
        OR instr(lower(COALESCE(q.supplier_reference, '')), ?) > 0
      )''');
      variables.addAll(List.generate(3, (_) => Variable.withString(term)));
    }
    if (supplierId != null) {
      conditions.add('q.supplier_id = ?');
      variables.add(Variable.withString(supplierId));
    }
    void addRange(String column, DateTime? from, DateTime? through) {
      if (from != null) {
        conditions.add('$column >= ?');
        variables.add(Variable.withInt(
            DateTime(from.year, from.month, from.day).millisecondsSinceEpoch ~/
                1000));
      }
      if (through != null) {
        conditions.add('$column < ?');
        variables.add(Variable.withInt(
            DateTime(through.year, through.month, through.day + 1)
                    .millisecondsSinceEpoch ~/
                1000));
      }
    }

    addRange('q.order_date', orderFrom, orderThrough);
    addRange('q.expected_delivery_date', deliveryFrom, deliveryThrough);
    final localToday = today ?? DateTime.now();
    final todayEpoch =
        DateTime(localToday.year, localToday.month, localToday.day)
                .millisecondsSinceEpoch ~/
            1000;
    switch (status) {
      case 'All':
        break;
      case 'Open':
        conditions.add(
            "q.computed_status IN ('sent', 'partially_received') AND q.remaining > 0");
        break;
      case 'Awaiting delivery':
      case 'Sent':
        conditions.add("q.computed_status = 'sent'");
        break;
      case 'Completed':
        conditions.add("q.computed_status IN ('fully_received', 'closed')");
        break;
      case 'Overdue':
        conditions.add(
            "q.computed_status IN ('sent', 'partially_received') AND q.remaining > 0 AND q.expected_delivery_date < ?");
        variables.add(Variable.withInt(todayEpoch));
        break;
      default:
        final raw = status.toLowerCase().replaceAll(' ', '_');
        if (!{
          'draft',
          'partially_received',
          'fully_received',
          'closed',
          'cancelled'
        }.contains(raw)) {
          throw ArgumentError.value(status, 'status');
        }
        conditions.add('q.computed_status = ?');
        variables.add(Variable.withString(raw));
    }
    const source = '''
      WITH received AS (
        SELECT i.purchase_order_line_id AS line_id,
          SUM(i.quantity_milli) AS quantity
        FROM stock_receiving_items i
        WHERE i.purchase_order_line_id IS NOT NULL
        GROUP BY i.purchase_order_line_id
      ), progress AS (
        SELECT o.id, o.sequence, o.supplier_id, o.supplier_reference,
          o.order_date, o.expected_delivery_date, o.status,
          COALESCE(SUM(COALESCE(r.quantity, 0)), 0) AS received,
          COALESCE(SUM(l.ordered_qty_milli - l.cancelled_qty_milli
            - COALESCE(r.quantity, 0)), 0) AS remaining
        FROM purchase_orders o
        LEFT JOIN purchase_order_lines l ON l.purchase_order_id = o.id
        LEFT JOIN received r ON r.line_id = l.id
        GROUP BY o.id
      ), q AS (
        SELECT p.*, CASE
          WHEN p.status IN ('draft', 'cancelled', 'closed') THEN p.status
          WHEN p.received = 0 THEN 'sent'
          WHEN p.remaining = 0 THEN 'fully_received'
          ELSE 'partially_received' END AS computed_status
        FROM progress p
      )
    ''';
    const from = 'FROM q JOIN suppliers s ON s.id = q.supplier_id';
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    return db.transaction(() async {
      final total = (await db
              .customSelect(
                '$source SELECT COUNT(*) AS total $from $where',
                variables: variables,
              )
              .getSingle())
          .read<int>('total');
      final ids = (await db.customSelect(
        '$source SELECT q.id $from $where ORDER BY q.sequence DESC, q.id DESC LIMIT 50 OFFSET ?',
        variables: [...variables, Variable.withInt(page * 50)],
      ).get())
          .map((row) => row.read<String>('id'))
          .toList();
      final progress = await progressFor(ids);
      return PagedResult(
        items: [for (final id in ids) progress[id]!],
        totalCount: total,
        page: page,
      );
    });
  }

  Future<Map<String, PurchaseOrderProgress>> progressFor(
      Iterable<String> orderIds) async {
    final ids = orderIds.toList();
    if (ids.isEmpty) return {};
    final orders = await (db.select(db.purchaseOrders)
          ..where((o) => o.id.isIn(ids)))
        .get();
    final lines = await (db.select(db.purchaseOrderLines)
          ..where((l) => l.purchaseOrderId.isIn(ids)))
        .get();
    final receipts = await (db.select(db.stockReceivings)
          ..where((r) => r.purchaseOrderId.isIn(ids)))
        .get();
    final receiptIds = receipts.map((r) => r.id).toList();
    final received = <String, int>{};
    for (var start = 0; start < receiptIds.length; start += 900) {
      final batch = receiptIds.skip(start).take(900).toList();
      final items = await (db.select(db.stockReceivingItems)
            ..where((i) => i.receivingId.isIn(batch)))
          .get();
      for (final item in items) {
        if (item.purchaseOrderLineId != null) {
          received.update(
              item.purchaseOrderLineId!, (value) => value + item.quantityMilli,
              ifAbsent: () => item.quantityMilli);
        }
      }
    }
    return {
      for (final order in orders)
        order.id: PurchaseOrderProgress(
          order,
          lines.where((line) => line.purchaseOrderId == order.id).toList(),
          {
            for (final line
                in lines.where((line) => line.purchaseOrderId == order.id))
              if (received.containsKey(line.id)) line.id: received[line.id]!,
          },
          receipts
              .where((receipt) => receipt.purchaseOrderId == order.id)
              .toList(),
        ),
    };
  }

  Future<int> incomingForProduct(String productId) async {
    var incoming = 0;
    for (final order in await list()) {
      final progress = await detail(order.id);
      if (!{'sent', 'partially_received'}.contains(progress.status)) {
        continue;
      }
      for (final line in progress.lines) {
        if (line.productId == productId) incoming += progress.remaining(line);
      }
    }
    return incoming;
  }

  Future<PurchaseOrderProgress> detail(String id) async {
    final order = await (db.select(db.purchaseOrders)
          ..where((o) => o.id.equals(id)))
        .getSingle();
    final lines = await (db.select(db.purchaseOrderLines)
          ..where((l) => l.purchaseOrderId.equals(id)))
        .get();
    final receivings = await (db.select(db.stockReceivings)
          ..where((r) => r.purchaseOrderId.equals(id))
          ..orderBy([(r) => OrderingTerm(expression: r.receivedAt)]))
        .get();
    final received = <String, int>{};
    for (final receipt in receivings) {
      final items = await (db.select(db.stockReceivingItems)
            ..where((i) => i.receivingId.equals(receipt.id)))
          .get();
      for (final item in items) {
        if (item.purchaseOrderLineId != null) {
          received.update(
              item.purchaseOrderLineId!, (old) => old + item.quantityMilli,
              ifAbsent: () => item.quantityMilli);
        }
      }
    }
    return PurchaseOrderProgress(order, lines, received, receivings);
  }

  Future<ReceivedCostVariance> receivedCostVariance(String id) async {
    final progress = await detail(id);
    final expectedByLine = {
      for (final line in progress.lines) line.id: line.expectedUnitCostCents
    };
    var expected = 0;
    var actual = 0;
    for (final receipt in progress.receivings) {
      final items = await (db.select(db.stockReceivingItems)
            ..where((i) => i.receivingId.equals(receipt.id)))
          .get();
      for (final item in items) {
        final cost = expectedByLine[item.purchaseOrderLineId];
        if (cost == null) continue;
        expected += Quantity.lineCents(cost, item.quantityMilli);
        actual += Quantity.lineCents(item.unitCostCents, item.quantityMilli);
      }
    }
    return ReceivedCostVariance(expected, actual);
  }

  Future<List<PurchaseOrderActivity>> activity(String id) async {
    final progress = await detail(id);
    final users = {
      for (final user in await db.select(db.users).get()) user.id: user.name
    };
    final order = progress.order;
    final events = <PurchaseOrderActivity>[
      PurchaseOrderActivity(
          order.createdAt, 'PO created', number(order), users[order.createdBy]),
    ];
    if (order.sentAt != null) {
      events.add(PurchaseOrderActivity(
          order.sentAt!, 'PO sent', number(order), users[order.sentBy]));
    }
    var cumulative = 0;
    for (final receipt in progress.receivings) {
      final items = await (db.select(db.stockReceivingItems)
            ..where((i) => i.receivingId.equals(receipt.id)))
          .get();
      final linked = items
          .where((i) => i.purchaseOrderLineId != null)
          .fold<int>(0, (sum, item) => sum + item.quantityMilli);
      cumulative += linked;
      events.add(PurchaseOrderActivity(
          receipt.finalizedAt ?? receipt.receivedAt,
          cumulative >= progress.ordered
              ? 'PO fully received'
              : 'Partial delivery',
          'RCV-${(receipt.sequence ?? 0).toString().padLeft(6, '0')} · ${Quantity.format(cumulative)} received',
          users[receipt.userId]));
    }
    if (order.cancelledAt != null) {
      events.add(PurchaseOrderActivity(
          order.cancelledAt!,
          'Remaining quantity cancelled',
          order.cancelReason ?? '',
          users[order.cancelledBy]));
    }
    if (order.closedAt != null) {
      events.add(PurchaseOrderActivity(
          order.closedAt!, 'PO closed', number(order), users[order.closedBy]));
    }
    events.sort((a, b) => a.at.compareTo(b.at));
    return events;
  }

  Future<PurchaseOrder> create(ActiveUser actor, String supplierId,
          DateTime orderDate, List<PurchaseOrderLineInput> lines,
          {DateTime? expectedDeliveryDate,
          String? supplierReference,
          String? notes,
          String? sourceQuotationReference,
          Map<String, int>? sourceQuantitiesMilli,
          bool markSent = false}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final sourceQuotation =
            await _sourceQuotation(sourceQuotationReference);
        final supplier = await (db.select(db.suppliers)
              ..where((s) => s.id.equals(supplierId)))
            .getSingleOrNull();
        if (supplier == null || !supplier.isActive) {
          throw StateError('Select an active supplier');
        }
        if (lines.isEmpty) throw StateError('Add at least one product');
        if (expectedDeliveryDate != null &&
            expectedDeliveryDate.isBefore(
                DateTime(orderDate.year, orderDate.month, orderDate.day))) {
          throw StateError('Expected delivery cannot precede order date');
        }
        final seen = <String>{};
        for (final line in lines) {
          if (!seen.add(line.productId)) {
            throw StateError('Combine duplicate product lines');
          }
          if (line.quantityMilli <= 0 || line.expectedUnitCostCents < 0) {
            throw StateError(
                'Enter a positive quantity and valid expected cost');
          }
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(line.productId)))
              .getSingleOrNull();
          if (product == null || !product.isActive) {
            throw StateError('Select an active product');
          }
          final config =
              await BusinessFeatureRepository(db).businessProduct(product.id);
          if (!config.fractional && line.quantityMilli % Quantity.scale != 0) {
            throw StateError('This product requires whole units');
          }
        }
        final max = await db
            .customSelect(
                'SELECT COALESCE(MAX(sequence), 0) + 1 AS next FROM purchase_orders')
            .getSingle();
        final sequence = max.read<int>('next');
        final order = await db
            .into(db.purchaseOrders)
            .insertReturning(PurchaseOrdersCompanion.insert(
              sequence: sequence,
              supplierId: supplierId,
              status: Value(markSent ? 'sent' : 'draft'),
              orderDate: orderDate,
              expectedDeliveryDate: Value(expectedDeliveryDate),
              supplierReference: Value(_clean(supplierReference)),
              notes: Value(_clean(notes)),
              createdBy: live.id,
              sentAt: Value(markSent ? DateTime.now() : null),
              sentBy: Value(markSent ? live.id : null),
            ));
        for (final line in lines) {
          final savedLine = await db
              .into(db.purchaseOrderLines)
              .insertReturning(PurchaseOrderLinesCompanion.insert(
                purchaseOrderId: order.id,
                productId: line.productId,
                orderedQtyMilli: line.quantityMilli,
                expectedUnitCostCents: line.expectedUnitCostCents,
                notes: Value(_clean(line.notes)),
              ));
          if (sourceQuotation != null) {
            final planned = sourceQuantitiesMilli?[line.productId] ?? 0;
            if (planned > line.quantityMilli) {
              throw StateError(
                  'Quotation sourcing quantity exceeds PO line quantity');
            }
            await _writeSourceLink(savedLine.id, line.productId, planned,
                sourceQuotation, live.id);
          }
        }
        await AuthRepository(db).audit(
            live.id,
            markSent ? 'purchase_order.sent' : 'purchase_order.created',
            order.id);
        return order;
      });

  Future<void> updateDraft(ActiveUser actor, String id, String supplierId,
          DateTime orderDate, List<PurchaseOrderLineInput> lines,
          {DateTime? expectedDeliveryDate,
          String? supplierReference,
          String? notes,
          String? sourceQuotationReference,
          Map<String, int>? sourceQuantitiesMilli,
          bool markSent = false}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final sourceQuotation =
            await _sourceQuotation(sourceQuotationReference);
        final progress = await detail(id);
        if (progress.status != 'draft' || progress.receivings.isNotEmpty) {
          throw StateError('Only an unreceived draft can be edited');
        }
        final supplier = await (db.select(db.suppliers)
              ..where((s) => s.id.equals(supplierId)))
            .getSingleOrNull();
        if (supplier == null || !supplier.isActive) {
          throw StateError('Select an active supplier');
        }
        if (lines.isEmpty) throw StateError('Add at least one product');
        if (expectedDeliveryDate != null &&
            expectedDeliveryDate.isBefore(
                DateTime(orderDate.year, orderDate.month, orderDate.day))) {
          throw StateError('Expected delivery cannot precede order date');
        }
        final seen = <String>{};
        for (final line in lines) {
          if (!seen.add(line.productId)) {
            throw StateError('Combine duplicate product lines');
          }
          if (line.quantityMilli <= 0 || line.expectedUnitCostCents < 0) {
            throw StateError(
                'Enter a positive quantity and valid expected cost');
          }
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(line.productId)))
              .getSingleOrNull();
          if (product == null || !product.isActive) {
            throw StateError('Select an active product');
          }
          final config =
              await BusinessFeatureRepository(db).businessProduct(product.id);
          if (!config.fractional && line.quantityMilli % Quantity.scale != 0) {
            throw StateError('This product requires whole units');
          }
        }
        final priorLinks = await sourceLinksForOrder(id);
        final priorProduct = {
          for (final line in progress.lines) line.id: line.productId
        };
        await (db.delete(db.purchaseOrderLineSourceLinks)
              ..where((s) =>
                  s.purchaseOrderLineId.isIn(progress.lines.map((l) => l.id))))
            .go();
        await (db.delete(db.purchaseOrderLines)
              ..where((l) => l.purchaseOrderId.equals(id)))
            .go();
        for (final line in lines) {
          final previousPlanned = priorLinks
              .where(
                  (s) => priorProduct[s.purchaseOrderLineId] == line.productId)
              .fold<int>(0, (sum, s) => sum + s.plannedQtyMilli);
          if (previousPlanned + (sourceQuantitiesMilli?[line.productId] ?? 0) >
              line.quantityMilli) {
            throw StateError(
                'Quotation sourcing quantity exceeds PO line quantity');
          }
          final savedLine = await db
              .into(db.purchaseOrderLines)
              .insertReturning(PurchaseOrderLinesCompanion.insert(
                purchaseOrderId: id,
                productId: line.productId,
                orderedQtyMilli: line.quantityMilli,
                expectedUnitCostCents: line.expectedUnitCostCents,
                notes: Value(_clean(line.notes)),
              ));
          for (final old in priorLinks.where(
              (s) => priorProduct[s.purchaseOrderLineId] == line.productId)) {
            await db.into(db.purchaseOrderLineSourceLinks).insert(
                PurchaseOrderLineSourceLinksCompanion.insert(
                    purchaseOrderLineId: savedLine.id,
                    quotationId: old.quotationId,
                    quotationLineId: Value(old.quotationLineId),
                    plannedQtyMilli: old.plannedQtyMilli,
                    createdAt: Value(old.createdAt),
                    createdByUserId: Value(old.createdByUserId)));
          }
          if (sourceQuotation != null) {
            final existingQty = priorLinks
                .where((s) =>
                    priorProduct[s.purchaseOrderLineId] == line.productId &&
                    s.quotationId == sourceQuotation.id)
                .fold<int>(0, (sum, s) => sum + s.plannedQtyMilli);
            final addedQty = sourceQuantitiesMilli?[line.productId] ?? 0;
            if (addedQty > 0 && existingQty > 0) {
              await (db.update(db.purchaseOrderLineSourceLinks)
                    ..where((s) =>
                        s.purchaseOrderLineId.equals(savedLine.id) &
                        s.quotationId.equals(sourceQuotation.id)))
                  .write(PurchaseOrderLineSourceLinksCompanion(
                      plannedQtyMilli: Value(existingQty + addedQty)));
            } else if (addedQty > 0) {
              await _writeSourceLink(savedLine.id, line.productId, addedQty,
                  sourceQuotation, live.id);
            }
          }
        }
        await (db.update(db.purchaseOrders)..where((o) => o.id.equals(id)))
            .write(PurchaseOrdersCompanion(
          supplierId: Value(supplierId),
          orderDate: Value(orderDate),
          expectedDeliveryDate: Value(expectedDeliveryDate),
          supplierReference: Value(_clean(supplierReference)),
          notes: Value(_clean(notes)),
          updatedAt: Value(DateTime.now()),
          status: Value(markSent ? 'sent' : 'draft'),
          sentAt: Value(markSent ? DateTime.now() : null),
          sentBy: Value(markSent ? live.id : null),
        ));
        await AuthRepository(db).audit(live.id, 'purchase_order.edited', id);
        if (markSent) {
          await AuthRepository(db).audit(live.id, 'purchase_order.sent', id);
        }
      });

  Future<void> markSent(ActiveUser actor, String id) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final detailRow = await detail(id);
        if (detailRow.status != 'draft' || detailRow.lines.isEmpty) {
          throw StateError('Only a nonempty draft can be marked sent');
        }
        await (db.update(db.purchaseOrders)..where((o) => o.id.equals(id)))
            .write(PurchaseOrdersCompanion(
                status: const Value('sent'),
                sentAt: Value(DateTime.now()),
                sentBy: Value(live.id),
                updatedAt: Value(DateTime.now())));
        await AuthRepository(db).audit(live.id, 'purchase_order.sent', id);
      });

  Future<void> cancel(ActiveUser actor, String id, String reason) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.cancelPurchaseOrders);
        if (reason.trim().isEmpty) {
          throw StateError('Enter a cancellation reason');
        }
        final progress = await detail(id);
        if (progress.status == 'closed' ||
            progress.status == 'cancelled' ||
            progress.status == 'fully_received') {
          throw StateError('This order cannot be cancelled');
        }
        for (final line in progress.lines) {
          final open = progress.remaining(line);
          await (db.update(db.purchaseOrderLines)
                ..where((l) => l.id.equals(line.id)))
              .write(PurchaseOrderLinesCompanion(
                  cancelledQtyMilli: Value(line.cancelledQtyMilli + open)));
        }
        await (db.update(db.purchaseOrders)..where((o) => o.id.equals(id)))
            .write(PurchaseOrdersCompanion(
                status: const Value('cancelled'),
                cancelledBy: Value(live.id),
                cancelledAt: Value(DateTime.now()),
                cancelReason: Value(reason.trim()),
                updatedAt: Value(DateTime.now())));
        await AuthRepository(db).audit(
            live.id, 'purchase_order.cancelled', '$id: ${reason.trim()}');
      });

  Future<void> close(ActiveUser actor, String id) => db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.cancelPurchaseOrders);
        final progress = await detail(id);
        if (progress.status != 'fully_received') {
          throw StateError('Only a fully received order can be closed');
        }
        await (db.update(db.purchaseOrders)..where((o) => o.id.equals(id)))
            .write(PurchaseOrdersCompanion(
                status: const Value('closed'),
                closedAt: Value(DateTime.now()),
                closedBy: Value(live.id),
                updatedAt: Value(DateTime.now())));
        await AuthRepository(db).audit(live.id, 'purchase_order.closed', id);
      });

  Future<PurchaseOrder> duplicate(ActiveUser actor, String id) async {
    final source = await detail(id);
    return create(actor, source.order.supplierId, DateTime.now(), [
      for (final line in source.lines)
        PurchaseOrderLineInput(
            line.productId, line.orderedQtyMilli, line.expectedUnitCostCents,
            notes: line.notes)
    ]);
  }

  static String number(PurchaseOrder order) =>
      'PO-${order.sequence.toString().padLeft(6, '0')}';
  static String? _clean(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();
}
