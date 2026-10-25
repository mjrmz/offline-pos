import 'package:drift/drift.dart';
import 'dart:convert';

import '../../core/models/active_user.dart';
import '../../core/models/cart.dart';
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

class MarginSaleLine {
  final String key;
  final String productId;
  final int quantityMilli;
  final int sellingCents;
  final int? costCents;
  final String mode;
  final String? batchId;
  final List<String> serialIds;
  const MarginSaleLine(this.key, this.productId, this.quantityMilli,
      this.sellingCents, this.costCents, this.mode, this.batchId,
      this.serialIds);
}

class BelowCostQuote {
  final int saleValueCents;
  final int? expectedCostCents;
  final String fingerprint;
  const BelowCostQuote(this.saleValueCents, this.expectedCostCents,
      this.fingerprint);
  bool get isBelowCost => expectedCostCents != null &&
      saleValueCents < expectedCostCents!;
  int get estimatedLossCents => isBelowCost
      ? expectedCostCents! - saleValueCents : 0;
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
    return _expectedCost(productId, quantityMilli,
        batchNumber: batchNumber, serialIds: serialIds);
  }

  Future<int?> _expectedCost(String productId, int quantityMilli,
      {String? batchNumber, List<String> serialIds = const [],
      Map<String, int> reservedMilliByLayer = const {}}) async {
    final parts = await _expectedParts(productId, quantityMilli,
        batchNumber: batchNumber, serialIds: serialIds,
        reservedMilliByLayer: reservedMilliByLayer);
    if (parts == null) return null;
    return parts.fold<int>(0, (total, part) => total +
        Quantity.lineCents(part.layer.unitCostCents, part.quantityMilli));
  }

  Future<List<LayerConsumption>?> _expectedParts(
      String productId, int quantityMilli,
      {String? batchNumber, List<String> serialIds = const [],
      Map<String, int> reservedMilliByLayer = const {}}) async {
    if (quantityMilli <= 0) return const [];
    try {
      final serials = <SerialUnit>[];
      for (final id in serialIds) {
        final serial = await (db.select(db.serialUnits)
              ..where((s) => s.id.equals(id)))
            .getSingleOrNull();
        if (serial == null || serial.productId != productId) return null;
        serials.add(serial);
      }
      return await InventoryLayerRepository(db).consume(productId,
          quantityMilli, batchNumber: batchNumber, serials: serials,
          commit: false, reservedMilliByLayer: reservedMilliByLayer);
    } on StateError {
      return null;
    }
  }

  static BelowCostQuote quote(List<MarginSaleLine> lines, int saleValueCents) {
    final known = lines.every((line) => line.costCents != null);
    final cost = known
        ? lines.fold<int>(0, (sum, line) => sum + line.costCents!)
        : null;
    final fingerprint = jsonEncode([
      saleValueCents, cost,
      for (final line in lines) [
        line.key, line.productId, line.quantityMilli, line.sellingCents,
        line.costCents, line.mode, line.batchId, line.serialIds,
      ],
    ]);
    return BelowCostQuote(saleValueCents, cost, fingerprint);
  }

  /// The checkout guard can evaluate a Cashier's cart without granting
  /// general access to inventory costs or history.
  Future<BelowCostQuote> quoteCart(Cart cart, int saleValueCents,
      {Map<String, String> batchNumbers = const {}}) async {
    final lines = <MarginSaleLine>[];
    final reserved = <String, int>{};
    for (final line in cart.lines) {
      final parts = await _expectedParts(line.product.id, line.quantityMilli,
          batchNumber: line.batchId == null ? null : batchNumbers[line.batchId],
          serialIds: line.serialIds, reservedMilliByLayer: reserved);
      final cost = parts?.fold<int>(0, (sum, part) => sum +
          Quantity.lineCents(part.layer.unitCostCents, part.quantityMilli));
      if (parts != null) {
        for (final part in parts) {
          reserved.update(part.layer.id, (value) => value + part.quantityMilli,
              ifAbsent: () => part.quantityMilli);
        }
      }
      lines.add(MarginSaleLine(line.id, line.product.id, line.quantityMilli,
          line.totalCents, cost, line.mode, line.batchId, line.serialIds));
    }
    return quote(lines, saleValueCents);
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
