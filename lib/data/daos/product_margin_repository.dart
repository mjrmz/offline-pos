import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'inventory_layer_repository.dart';

class ProductMarginContext {
  final int currentPriceCents;
  final int? lastReceivingCostCents;
  final int? nextFifoCostCents;
  final String pricingPolicy;
  const ProductMarginContext(this.currentPriceCents, this.lastReceivingCostCents,
      this.nextFifoCostCents, this.pricingPolicy);

  int? get estimatedUnitMarginCents => nextFifoCostCents == null
      ? null
      : currentPriceCents - nextFifoCostCents!;
  double? get estimatedMarginPercent =>
      estimatedUnitMarginCents == null || currentPriceCents == 0
          ? null
          : estimatedUnitMarginCents! * 100 / currentPriceCents;
}

class ProductMarginRepository {
  final AppDatabase db;
  const ProductMarginRepository(this.db);

  static void requireVisibility(ActiveUser actor) {
    if (!actor.can(PosPermission.manageCatalog) &&
        !actor.can(PosPermission.stockReceiving) &&
        !actor.can(PosPermission.reports)) {
      throw StateError('Not authorized to view cost and margin');
    }
  }

  Future<ProductMarginContext> context(ActiveUser actor, String productId) async {
    requireVisibility(actor);
    final product = await (db.select(db.products)
          ..where((p) => p.id.equals(productId)))
        .getSingle();
    final receipt = await db.customSelect('''
      SELECT i.unit_cost_cents FROM stock_receiving_items i
      JOIN stock_receivings r ON r.id = i.receiving_id
      WHERE i.product_id = ? AND r.finalized_at IS NOT NULL
      ORDER BY r.finalized_at DESC, i.id DESC LIMIT 1
    ''', variables: [Variable.withString(productId)]).getSingleOrNull();
    final layer = await (db.select(db.inventoryLayers)
          ..where((l) => l.productId.equals(productId) &
              l.quantityRemainingMilli.isBiggerThanValue(0))
          ..orderBy([
            (l) => OrderingTerm(expression: l.receivedAt),
            (l) => OrderingTerm(expression: const CustomExpression<int>(
                "CASE WHEN source IN ('opening', 'legacy_opening') THEN 0 ELSE 1 END")),
            (l) => OrderingTerm(expression: l.id),
          ])
          ..limit(1))
        .getSingleOrNull();
    return ProductMarginContext(product.priceCents,
        receipt?.read<int>('unit_cost_cents'), layer?.unitCostCents,
        product.pricingPolicy);
  }

  Future<int?> expectedCost(ActiveUser actor, String productId, int quantityMilli,
      {String? batchNumber, List<String> serialIds = const []}) async {
    requireVisibility(actor);
    if (quantityMilli <= 0) return 0;
    try {
      final serials = <SerialUnit>[];
      for (final id in serialIds) {
        final serial = await (db.select(db.serialUnits)
              ..where((s) => s.id.equals(id)))
            .getSingleOrNull();
        if (serial == null || serial.productId != productId) return null;
        serials.add(serial);
      }
      final parts = await InventoryLayerRepository(db).consume(productId,
          quantityMilli, batchNumber: batchNumber, serials: serials,
          commit: false);
      return parts.fold<int>(0, (total, part) => total +
          Quantity.lineCents(part.layer.unitCostCents, part.quantityMilli));
    } on StateError {
      return null;
    }
  }

  Future<List<PriceHistoryData>> history(ActiveUser actor, String productId,
      {int page = 0}) async {
    requireVisibility(actor);
    return (db.select(db.priceHistory)
          ..where((h) => h.productId.equals(productId) &
              h.oldPriceCents.equalsExp(h.newPriceCents).not())
          ..orderBy([
            (h) => OrderingTerm.desc(h.createdAt),
            (h) => OrderingTerm.desc(h.id),
          ])
          ..limit(50, offset: page * 50))
        .get();
  }
}
