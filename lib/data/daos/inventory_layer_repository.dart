import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../database.dart';

class LayerConsumption {
  final InventoryLayer layer;
  final int quantityMilli;
  final String? serialUnitId;
  const LayerConsumption(this.layer, this.quantityMilli, {this.serialUnitId});
}

/// Called inside the enclosing sale transaction. Batch selection remains
/// explicit; ordinary stock uses received date, opening priority, then layer id.
class InventoryLayerRepository {
  final AppDatabase db;
  const InventoryLayerRepository(this.db);

  Future<List<LayerConsumption>> consume(String productId, int quantityMilli,
      {String? batchNumber,
      List<SerialUnit> serials = const [],
      bool commit = true}) async {
    final rows = await (db.select(db.inventoryLayers)
          ..where((l) =>
              l.productId.equals(productId) &
              l.quantityRemainingMilli.isBiggerThanValue(0))
          ..orderBy([
            (l) => OrderingTerm(expression: l.receivedAt),
            (l) => OrderingTerm(
                expression: const CustomExpression<int>(
                    "CASE WHEN source IN ('opening', 'legacy_opening') THEN 0 ELSE 1 END")),
            (l) => OrderingTerm(expression: l.id),
          ]))
        .get();
    final selected = <LayerConsumption>[];
    var remaining = quantityMilli;
    if (serials.isNotEmpty) {
      for (final serial in serials) {
        final layer =
            rows.where((l) => l.id == serial.inventoryLayerId).firstOrNull;
        if (layer == null) {
          throw StateError('Serial has no available source layer');
        }
        if (batchNumber != null && layer.batchNumber != batchNumber) {
          throw StateError('Serial belongs to a different batch');
        }
        selected.add(LayerConsumption(layer, 1000, serialUnitId: serial.id));
        remaining -= 1000;
      }
    } else {
      for (final layer in rows) {
        if (batchNumber != null && layer.batchNumber != batchNumber) continue;
        if (remaining == 0) break;
        final take = math.min(remaining, layer.quantityRemainingMilli);
        selected.add(LayerConsumption(layer, take));
        remaining -= take;
      }
    }
    if (remaining != 0) {
      throw StateError('Inventory layers do not match available stock');
    }
    final totals = <String, int>{};
    for (final part in selected) {
      totals.update(part.layer.id, (v) => v + part.quantityMilli,
          ifAbsent: () => part.quantityMilli);
    }
    if (!commit) return selected;
    for (final entry in totals.entries) {
      final layer = rows.firstWhere((l) => l.id == entry.key);
      final changed = await (db.update(db.inventoryLayers)
            ..where((l) =>
                l.id.equals(layer.id) &
                l.quantityRemainingMilli.isBiggerOrEqualValue(entry.value)))
          .write(InventoryLayersCompanion(
              quantityRemainingMilli:
                  Value(layer.quantityRemainingMilli - entry.value)));
      if (changed != 1) throw StateError('Inventory layer changed during sale');
    }
    return selected;
  }
}
