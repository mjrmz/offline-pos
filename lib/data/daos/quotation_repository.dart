import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/business_product.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'pos_repository.dart';
import 'paged_result.dart';

class QuoteLineRequest {
  final String? productId;
  final int quantityMilli;
  final String mode;
  final String? description;
  final String? unit;
  final int? unitPriceCents;
  final String? customNotes;
  const QuoteLineRequest(this.productId, this.quantityMilli,
      {this.mode = 'ordinary',
      this.description,
      this.unit,
      this.unitPriceCents,
      this.customNotes});
  const QuoteLineRequest.custom(this.description, this.quantityMilli,
      {required this.unit, required this.unitPriceCents, this.customNotes})
      : productId = null,
        mode = 'ordinary';
}

class QuotationRepository {
  final AppDatabase db;
  final PosRepository pos;
  QuotationRepository(this.db, this.pos);

  Future<List<Quotation>> history() => (db.select(db.quotations)
        ..orderBy([
          (q) => OrderingTerm(expression: q.createdAt, mode: OrderingMode.desc),
          (q) => OrderingTerm(expression: q.id, mode: OrderingMode.desc),
        ]))
      .get();

  Future<Quotation?> byReference(String reference) =>
      (db.select(db.quotations)
            ..where((quote) => quote.reference.equals(reference)))
          .getSingleOrNull();

  // Readiness uses the same physical stock, active layaway reservation, RMA
  // serial reservation and made-to-order exclusion as the quotation workspace.
  static const _pageSource = '''
    WITH layaway_reserved AS (
      SELECT li.product_id, SUM(li.quantity_milli) AS quantity
      FROM layaway_items li JOIN layaways l ON l.id = li.layaway_id
      WHERE l.status = 'active' GROUP BY li.product_id
    ), rma_reserved AS (
      SELECT product_id, COUNT(*) * 1000 AS quantity
      FROM serial_units WHERE status = 'rma_reserved' GROUP BY product_id
    ), order_reserved AS (
      SELECT product_id, SUM(quantity_milli) AS quantity
      FROM stock_reservations WHERE status = 'active'
      GROUP BY product_id
    ), stock AS (
      SELECT p.id, COALESCE(i.quantity_milli, 0)
        - COALESCE(l.quantity, 0) - COALESCE(r.quantity, 0)
        - COALESCE(o.quantity, 0) AS available
      FROM products p
      LEFT JOIN inventory i ON i.product_id = p.id
      LEFT JOIN layaway_reserved l ON l.product_id = p.id
      LEFT JOIN rma_reserved r ON r.product_id = p.id
      LEFT JOIN order_reserved o ON o.product_id = p.id
    ), flags AS (
      SELECT q.id, q.reference, q.customer_name_snapshot, q.created_at,
        q.valid_until, q.status,
        (SELECT COUNT(*) FROM quotation_items qi
          WHERE qi.quotation_id = q.id) AS item_count,
        (SELECT COUNT(*) FROM quotation_items qi
          WHERE qi.quotation_id = q.id AND qi.product_id IS NULL) AS unlinked_count,
        (SELECT COUNT(*) FROM quotation_items qi
          LEFT JOIN stock st ON st.id = qi.product_id
          WHERE qi.quotation_id = q.id AND qi.product_id IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM product_business_configurations config
              WHERE config.product_id = qi.product_id
                AND config.feature_id = 'madeToOrderTracking'
                AND json_extract(config.configuration_json, '\$.enabled') = 1
            )
            AND COALESCE(st.available, 0) < qi.quantity_milli
        ) AS awaiting_count
      FROM quotations q
    )
  ''';

  Future<PagedResult<Quotation>> page({
    int page = 0,
    String search = '',
    String status = 'all',
    DateTime? now,
  }) async {
    if (page < 0) throw ArgumentError.value(page, 'page');
    final conditions = <String>[];
    final variables = <Variable>[];
    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      conditions.add('''(
        instr(lower(f.reference), ?) > 0
        OR instr(lower(COALESCE(f.customer_name_snapshot, 'Walk-in')), ?) > 0
        OR EXISTS (SELECT 1 FROM quotation_items qi
          WHERE qi.quotation_id = f.id
            AND instr(lower(qi.product_name_snapshot), ?) > 0)
      )''');
      variables.addAll(List.generate(3, (_) => Variable.withString(term)));
    }
    final instant = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    switch (status) {
      case 'all':
        break;
      case 'open':
        conditions.add("f.status = 'open' AND (f.valid_until IS NULL OR f.valid_until >= ?)");
        variables.add(Variable.withInt(instant));
        break;
      case 'expired':
        conditions.add("f.status = 'open' AND f.valid_until < ?");
        variables.add(Variable.withInt(instant));
        break;
      case 'awaiting stock':
        conditions.add("f.status = 'open' AND f.awaiting_count > 0");
        break;
      case 'ready':
        conditions.add("f.status = 'open' AND f.item_count > 0 AND f.unlinked_count = 0 AND f.awaiting_count = 0");
        break;
      case 'converted':
      case 'cancelled':
        conditions.add('f.status = ?');
        variables.add(Variable.withString(status));
        break;
      default:
        throw ArgumentError.value(status, 'status');
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    return db.transaction(() async {
      final total = (await db.customSelect(
        '$_pageSource SELECT COUNT(*) AS total FROM flags f $where',
        variables: variables,
      ).getSingle()).read<int>('total');
      final ids = (await db.customSelect(
        '$_pageSource SELECT f.id FROM flags f $where '
        'ORDER BY f.created_at DESC, f.id DESC LIMIT 50 OFFSET ?',
        variables: [...variables, Variable.withInt(page * 50)],
      ).get()).map((row) => row.read<String>('id')).toList();
      if (ids.isEmpty) {
        return PagedResult(items: <Quotation>[], totalCount: total, page: page);
      }
      final quotes = await (db.select(db.quotations)
            ..where((q) => q.id.isIn(ids)))
          .get();
      final byId = {for (final quote in quotes) quote.id: quote};
      return PagedResult(
          items: [for (final id in ids) byId[id]!], totalCount: total, page: page);
    });
  }

  Future<Map<String, int>> overview({DateTime? now}) async {
    final instant = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final result = await db.customSelect('''
      $_pageSource
      SELECT
        SUM(CASE WHEN f.status = 'open' AND
          (f.valid_until IS NULL OR f.valid_until >= ?) THEN 1 ELSE 0 END) AS open_count,
        SUM(CASE WHEN f.status = 'open' AND f.valid_until < ? THEN 1 ELSE 0 END) AS expired_count,
        SUM(CASE WHEN f.status = 'open' AND f.awaiting_count > 0 THEN 1 ELSE 0 END) AS awaiting_count,
        SUM(CASE WHEN f.status = 'converted' THEN 1 ELSE 0 END) AS converted_count,
        SUM(CASE WHEN f.status = 'open' AND f.item_count > 0 AND
          f.unlinked_count = 0 AND f.awaiting_count = 0 THEN 1 ELSE 0 END) AS ready_count
      FROM flags f
    ''', variables: [Variable.withInt(instant), Variable.withInt(instant)])
        .getSingle();
    return {
      'open': result.read<int?>('open_count') ?? 0,
      'expired': result.read<int?>('expired_count') ?? 0,
      'awaiting stock': result.read<int?>('awaiting_count') ?? 0,
      'converted': result.read<int?>('converted_count') ?? 0,
      'ready': result.read<int?>('ready_count') ?? 0,
    };
  }

  /// Fetches list metadata in bounded batches instead of one query per quote.
  Future<Map<String, List<QuotationItem>>> itemsFor(
      Iterable<String> quotationIds) async {
    final ids = quotationIds.toList();
    if (ids.isEmpty) return {};
    final grouped = <String, List<QuotationItem>>{
      for (final id in ids) id: [],
    };
    for (var start = 0; start < ids.length; start += 900) {
      final batch = ids.skip(start).take(900).toList();
      final items = await (db.select(db.quotationItems)
            ..where((item) => item.quotationId.isIn(batch)))
          .get();
      for (final item in items) {
        grouped[item.quotationId]?.add(item);
      }
    }
    return grouped;
  }

  Future<Map<String, String>> receiptNumbersFor(
      Iterable<Quotation> quotations) async {
    final saleIds = quotations
        .map((quote) => quote.convertedSaleId)
        .whereType<String>()
        .toSet();
    if (saleIds.isEmpty) return {};
    final receiptNumbers = <String, String>{};
    final ids = saleIds.toList();
    for (var start = 0; start < ids.length; start += 900) {
      final batch = ids.skip(start).take(900).toList();
      final sales = await (db.select(db.sales)
            ..where((sale) => sale.id.isIn(batch)))
          .get();
      for (final sale in sales) {
        if (sale.receiptNumber != null) {
          receiptNumbers[sale.id] = sale.receiptNumber!;
        }
      }
    }
    return receiptNumbers;
  }

  Future<List<QuotationItem>> items(String id) =>
      (db.select(db.quotationItems)..where((i) => i.quotationId.equals(id)))
          .get();

  Future<List<QuotationSourcingRequirement>> sourcing(String quotationId) =>
      (db.select(db.quotationSourcingRequirements)
            ..where((r) =>
                r.quotationId.equals(quotationId) & r.status.equals('pending')))
          .get();

  Future<QuotationSourcingRequirement> requestSourcing(
          ActiveUser actor, String quotationId, String productId,
          {String? preferredSupplierId, String? notes}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageQuotations);
        final quote = await (db.select(db.quotations)
              ..where((q) => q.id.equals(quotationId)))
            .getSingleOrNull();
        if (quote == null || quote.status != 'open') {
          throw StateError('Only open quotations can request sourcing');
        }
        final line = await (db.select(db.quotationItems)
              ..where((i) =>
                  i.quotationId.equals(quotationId) &
                  i.productId.equals(productId)))
            .getSingleOrNull();
        if (line == null) throw StateError('Product is not on this quotation');
        final available = await pos.stockMilli(productId);
        final missing = line.quantityMilli - available;
        if (missing <= 0) throw StateError('Item is already available');
        if (preferredSupplierId != null) {
          final supplier = await (db.select(db.suppliers)
                ..where((s) =>
                    s.id.equals(preferredSupplierId) & s.isActive.equals(true)))
              .getSingleOrNull();
          if (supplier == null) throw StateError('Choose an active supplier');
        }
        final existing = await (db.select(db.quotationSourcingRequirements)
              ..where((r) =>
                  r.quotationId.equals(quotationId) &
                  r.productId.equals(productId) &
                  r.status.equals('pending')))
            .getSingleOrNull();
        if (existing != null) return existing;
        final requirement = await db
            .into(db.quotationSourcingRequirements)
            .insertReturning(QuotationSourcingRequirementsCompanion.insert(
                quotationId: quotationId,
                productId: productId,
                quantityRequiredMilli: line.quantityMilli,
                quantityAvailableAtRequestMilli: available,
                quantityToSourceMilli: missing,
                preferredSupplierId: Value(preferredSupplierId),
                notes:
                    Value(notes?.trim().isEmpty == true ? null : notes?.trim()),
                createdBy: live.id));
        await AuthRepository(db)
            .audit(live.id, 'quotation.sourcing_requested', requirement.id);
        return requirement;
      });

  Future<void> linkCustomItem(ActiveUser actor, String quotationId,
          String quotationItemId, String productId) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageQuotations);
        final quote = await (db.select(db.quotations)
              ..where((q) => q.id.equals(quotationId)))
            .getSingleOrNull();
        if (quote == null || quote.status != 'open') {
          throw StateError('Only open quotations can be linked');
        }
        final item = await (db.select(db.quotationItems)
              ..where((i) =>
                  i.id.equals(quotationItemId) &
                  i.quotationId.equals(quotationId)))
            .getSingleOrNull();
        if (item == null || item.productId != null) {
          throw StateError('Select an unresolved custom quotation item');
        }
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(productId)))
            .getSingleOrNull();
        if (product == null || !product.isActive) {
          throw StateError('Select an active Inventory product');
        }
        final config =
            await BusinessFeatureRepository(db).businessProduct(productId);
        if (config.tank ||
            config.refill ||
            config.madeToOrder ||
            config.unit.label != item.unitSnapshot ||
            (!config.fractional && item.quantityMilli % Quantity.scale != 0)) {
          throw StateError(
              'This product requires a different sale configuration. Edit the quotation to add it as a catalog item.');
        }
        final duplicate = await (db.select(db.quotationItems)
              ..where((i) =>
                  i.quotationId.equals(quotationId) &
                  i.productId.equals(productId)))
            .getSingleOrNull();
        if (duplicate != null) {
          throw StateError('Product is already on the quotation');
        }
        await (db.update(db.quotationItems)
              ..where((i) => i.id.equals(quotationItemId)))
            .write(QuotationItemsCompanion(productId: Value(productId)));
        await AuthRepository(db).audit(live.id, 'quotation.custom_item_linked',
            '$quotationItemId:$productId');
      });

  Future<Quotation> create(ActiveUser actor, List<QuoteLineRequest> lines,
          {String? customerId, DateTime? validUntil, String? notes}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageQuotations);
        if (lines.isEmpty ||
            lines
                    .where((l) => l.productId != null)
                    .map((l) => l.productId)
                    .toSet()
                    .length !=
                lines.where((l) => l.productId != null).length) {
          throw StateError('Add unique quotation items');
        }
        Customer? customer;
        if (customerId != null) {
          customer = await (db.select(db.customers)
                ..where((c) => c.id.equals(customerId)))
              .getSingleOrNull();
          if (customer == null || !customer.isActive) {
            throw StateError('Select an active customer');
          }
        }
        final now = DateTime.now();
        if (validUntil != null &&
            validUntil.isBefore(DateTime(now.year, now.month, now.day))) {
          throw StateError('Validity date has passed');
        }
        final next = await db.customSelect(
            "SELECT COALESCE(MAX(CAST(SUBSTR(reference, 8) AS INTEGER)), 0) + 1 AS next_number FROM quotations WHERE reference GLOB 'Q-[0-9][0-9][0-9][0-9]-[0-9]*' AND SUBSTR(reference, 3, 4) = ?",
            variables: [Variable.withString(now.year.toString())]).getSingle();
        final reference =
            'Q-${now.year}-${next.read<int>('next_number').toString().padLeft(6, '0')}';
        final quote = await db.into(db.quotations).insertReturning(
            QuotationsCompanion.insert(
                reference: reference,
                createdBy: live.id,
                customerId: Value(customerId),
                customerNameSnapshot: Value(customer?.name),
                customerPhoneSnapshot: Value(customer?.phone),
                preparedBySnapshot: Value(live.name),
                validUntil: Value(validUntil),
                notes: Value(
                    notes?.trim().isEmpty == true ? null : notes?.trim())));
        await _writeLines(quote.id, lines);
        await AuthRepository(db).audit(live.id, 'quotation.created', quote.id);
        return quote;
      });

  Future<void> _writeLines(String quotationId, List<QuoteLineRequest> lines,
      {Map<String, QuotationItem> previous = const {}}) async {
    for (final line in lines) {
      if (line.productId == null) {
        final description = line.description?.trim() ?? '';
        final unit = line.unit?.trim() ?? '';
        final price = line.unitPriceCents;
        if (description.isEmpty ||
            unit.isEmpty ||
            price == null ||
            price <= 0 ||
            line.quantityMilli <= 0 ||
            (!SaleUnit.values
                    .any((value) => value.label == unit && value.fractional) &&
                line.quantityMilli % Quantity.scale != 0)) {
          throw StateError('Enter a valid custom quotation item');
        }
        await db.into(db.quotationItems).insert(QuotationItemsCompanion.insert(
            quotationId: quotationId,
            productId: const Value(null),
            productNameSnapshot: Value(description),
            customNotes: Value(line.customNotes?.trim().isEmpty == true
                ? null
                : line.customNotes?.trim()),
            quantityMilli: line.quantityMilli,
            unitSnapshot: unit,
            unitPriceCents: price,
            lineTotalCents: Quantity.lineCents(price, line.quantityMilli)));
        continue;
      }
      final product = await (db.select(db.products)
            ..where((p) => p.id.equals(line.productId!)))
          .getSingleOrNull();
      if (product == null || !product.isActive || line.quantityMilli <= 0) {
        throw StateError('Quotation product is inactive or invalid');
      }
      final config =
          await BusinessFeatureRepository(db).businessProduct(product.id);
      if (!config.fractional && line.quantityMilli % Quantity.scale != 0) {
        throw StateError('Whole unit required');
      }
      final modes = config.tank
          ? const ['exchange', 'deposit']
          : config.refill
              ? const ['refill', 'container']
              : config.madeToOrder
                  ? const ['made_order']
                  : const ['ordinary'];
      if (!modes.contains(line.mode)) {
        throw StateError('Choose a valid quotation option for ${product.name}');
      }
      final extra = line.mode == 'deposit'
          ? config.depositCents
          : line.mode == 'container'
              ? config.containerPriceCents
              : 0;
      final old = previous[product.id];
      final basePrice = old?.unitPriceCents ?? product.priceCents;
      final quotedExtra =
          old != null && old.saleMode == line.mode ? old.extraCents : extra;
      await db.into(db.quotationItems).insert(QuotationItemsCompanion.insert(
          quotationId: quotationId,
          productId: Value(product.id),
          productNameSnapshot: Value(old?.productNameSnapshot ?? product.name),
          skuSnapshot: Value(old == null ? product.sku : old.skuSnapshot),
          barcodeSnapshot:
              Value(old == null ? product.barcode : old.barcodeSnapshot),
          saleMode: Value(line.mode),
          extraCents: Value(quotedExtra),
          quantityMilli: line.quantityMilli,
          unitSnapshot: old?.unitSnapshot ?? config.unit.label,
          unitPriceCents: basePrice,
          lineTotalCents:
              Quantity.lineCents(basePrice + quotedExtra, line.quantityMilli)));
    }
  }

  Future<Quotation> update(
          ActiveUser actor, String quotationId, List<QuoteLineRequest> lines,
          {String? customerId, DateTime? validUntil, String? notes}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageQuotations);
        final quote = await (db.select(db.quotations)
              ..where((q) => q.id.equals(quotationId)))
            .getSingleOrNull();
        if (quote == null || quote.status != 'open') {
          throw StateError('Only open quotations can be edited');
        }
        if (lines.isEmpty ||
            lines
                    .where((line) => line.productId != null)
                    .map((line) => line.productId)
                    .toSet()
                    .length !=
                lines.where((line) => line.productId != null).length) {
          throw StateError('Add unique quotation items');
        }
        Customer? customer;
        if (customerId != null) {
          customer = await (db.select(db.customers)
                ..where((c) => c.id.equals(customerId)))
              .getSingleOrNull();
          if (customer == null || !customer.isActive) {
            throw StateError('Select an active customer');
          }
        }
        final now = DateTime.now();
        if (validUntil != null &&
            validUntil.isBefore(DateTime(now.year, now.month, now.day))) {
          throw StateError('Validity date has passed');
        }
        final prior = {
          for (final item in await items(quotationId))
            if (item.productId != null) item.productId!: item
        };
        await (db.update(db.quotationSourcingRequirements)
              ..where((r) =>
                  r.quotationId.equals(quotationId) &
                  r.productId.isNotIn(lines
                      .map((line) => line.productId)
                      .whereType<String>()
                      .toList()) &
                  r.status.equals('pending')))
            .write(QuotationSourcingRequirementsCompanion(
                status: const Value('cancelled'), resolvedAt: Value(now)));
        await (db.delete(db.quotationItems)
              ..where((item) => item.quotationId.equals(quotationId)))
            .go();
        await _writeLines(quotationId, lines, previous: prior);
        await (db.update(db.quotations)..where((q) => q.id.equals(quotationId)))
            .write(QuotationsCompanion(
                customerId: Value(customerId),
                customerNameSnapshot: Value(customer?.name),
                customerPhoneSnapshot: Value(customer?.phone),
                validUntil: Value(validUntil),
                notes: Value(
                    notes?.trim().isEmpty == true ? null : notes?.trim())));
        await AuthRepository(db)
            .audit(live.id, 'quotation.updated', quotationId);
        return (db.select(db.quotations)
              ..where((q) => q.id.equals(quotationId)))
            .getSingle();
      });

  Future<CommittedSale> convertCash(
      ActiveUser actor, String quotationId, int cashReceivedCents,
      {Map<String, List<String>> serialIds = const {},
      Map<String, String> batchIds = const {}}) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageQuotations);
    final rows = await items(quotationId);
    if (rows.isEmpty) throw StateError('Quotation has no items');
    if (rows.any((item) => item.productId == null)) {
      throw StateError(
          'Resolve custom quotation items to Inventory products before checkout');
    }
    return pos.completeCashSale([
      for (final item in rows)
        SaleLineRequest(item.productId!, 0,
            quantityMilli: item.quantityMilli,
            mode: item.saleMode,
            serialIds: serialIds[item.productId!] ?? const [],
            batchId: batchIds[item.productId!])
    ], cashReceivedCents, live.id, quotationId: quotationId);
  }

  Future<void> cancel(ActiveUser actor, String quotationId) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageQuotations);
        final updated = await (db.update(db.quotations)
              ..where(
                  (q) => q.id.equals(quotationId) & q.status.equals('open')))
            .write(const QuotationsCompanion(status: Value('cancelled')));
        if (updated != 1) {
          throw StateError('Only open quotations can be cancelled');
        }
        await AuthRepository(db)
            .audit(live.id, 'quotation.cancelled', quotationId);
      });
}
