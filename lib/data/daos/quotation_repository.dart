import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'pos_repository.dart';

class QuoteLineRequest {
  final String productId;
  final int quantityMilli;
  const QuoteLineRequest(this.productId, this.quantityMilli);
}

class QuotationRepository {
  final AppDatabase db;
  final PosRepository pos;
  QuotationRepository(this.db, this.pos);

  Future<List<Quotation>> history() => (db.select(db.quotations)
        ..orderBy([
          (q) => OrderingTerm(expression: q.createdAt, mode: OrderingMode.desc)
        ]))
      .get();

  Future<List<QuotationItem>> items(String id) =>
      (db.select(db.quotationItems)..where((i) => i.quotationId.equals(id)))
          .get();

  Future<Quotation> create(ActiveUser actor, List<QuoteLineRequest> lines,
          {String? customerId, DateTime? validUntil, String? notes}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageQuotations);
        if (lines.isEmpty ||
            lines.map((l) => l.productId).toSet().length != lines.length) {
          throw StateError('Add unique quotation items');
        }
        if (customerId != null) {
          final customer = await (db.select(db.customers)
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
        final quote = await db.into(db.quotations).insertReturning(
            QuotationsCompanion.insert(
                reference:
                    'Q-${const Uuid().v4().substring(0, 8).toUpperCase()}',
                createdBy: live.id,
                customerId: Value(customerId),
                validUntil: Value(validUntil),
                notes: Value(
                    notes?.trim().isEmpty == true ? null : notes?.trim())));
        for (final line in lines) {
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(line.productId)))
              .getSingleOrNull();
          if (product == null || !product.isActive || line.quantityMilli <= 0) {
            throw StateError('Quotation product is inactive or invalid');
          }
          final config =
              await BusinessFeatureRepository(db).businessProduct(product.id);
          if (!config.fractional && line.quantityMilli % Quantity.scale != 0) {
            throw StateError('Whole unit required');
          }
          if (config.tank || config.refill || config.madeToOrder) {
            throw StateError(
                'This product needs a transaction option at checkout');
          }
          await db.into(db.quotationItems).insert(
              QuotationItemsCompanion.insert(
                  quotationId: quote.id,
                  productId: product.id,
                  quantityMilli: line.quantityMilli,
                  unitSnapshot: config.unit.label,
                  unitPriceCents: product.priceCents,
                  lineTotalCents: Quantity.lineCents(
                      product.priceCents, line.quantityMilli)));
        }
        await AuthRepository(db).audit(live.id, 'quotation.created', quote.id);
        return quote;
      });

  Future<CommittedSale> convertCash(
      ActiveUser actor, String quotationId, int cashReceivedCents,
      {Map<String, List<String>> serialIds = const {},
      Map<String, String> batchIds = const {}}) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageQuotations);
    final rows = await items(quotationId);
    if (rows.isEmpty) throw StateError('Quotation has no items');
    return pos.completeCashSale([
      for (final item in rows)
        SaleLineRequest(item.productId, 0,
            quantityMilli: item.quantityMilli,
            serialIds: serialIds[item.productId] ?? const [],
            batchId: batchIds[item.productId])
    ], cashReceivedCents, live.id, quotationId: quotationId);
  }
}
