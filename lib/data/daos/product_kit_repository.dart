import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'pos_repository.dart';

class KitComponentView {
  final String id;
  final String productId;
  final String name;
  final int quantityMilli;
  final int availableMilli;
  final int possibleKits;
  const KitComponentView(this.id, this.productId, this.name, this.quantityMilli,
      this.availableMilli, this.possibleKits);
}

class KitAvailability {
  final String kitProductId;
  final List<KitComponentView> components;
  final int availableKits;
  final int? estimatedCostCents;
  final String? limitingComponent;
  const KitAvailability(this.kitProductId, this.components, this.availableKits,
      this.estimatedCostCents, this.limitingComponent);
}

class ProductKitRepository {
  final AppDatabase db;
  ProductKitRepository(this.db);

  Future<void> _requireManager(ActiveUser actor) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    if (!live.can(PosPermission.manageCatalog)) {
      throw StateError('Catalog management permission required');
    }
  }

  Future<void> addComponent(ActiveUser actor, String kitId, String componentId,
      int quantityMilli) async {
    await _requireManager(actor);
    await _validate(kitId, componentId, quantityMilli);
    await db.transaction(() async {
      final duplicate = await db
          .customSelect('''SELECT 1 FROM product_kit_components
        WHERE kit_product_id = ? AND component_product_id = ? LIMIT 1''',
              variables: [
            Variable.withString(kitId),
            Variable.withString(componentId)
          ]).get();
      if (duplicate.isNotEmpty) {
        throw StateError('This component is already in the kit');
      }
      await db.customStatement('''INSERT INTO product_kit_components
        (id, kit_product_id, component_product_id, quantity_milli, sort_order, created_at)
        VALUES (?, ?, ?, ?,
          (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM product_kit_components WHERE kit_product_id = ?), ?)
      ''', [
        const Uuid().v4(),
        kitId,
        componentId,
        quantityMilli,
        kitId,
        DateTime.now().millisecondsSinceEpoch ~/ 1000
      ]);
      await AuthRepository(db).audit(actor.id, 'kit.component_added',
          '$kitId / $componentId / ${Quantity.format(quantityMilli)}');
    });
  }

  Future<void> updateQuantity(ActiveUser actor, String kitId,
      String componentId, int quantityMilli) async {
    await _requireManager(actor);
    await _validate(kitId, componentId, quantityMilli);
    await db.transaction(() async {
      final previous = await db.customSelect('''SELECT quantity_milli
        FROM product_kit_components WHERE kit_product_id = ? AND component_product_id = ?''',
          variables: [
            Variable.withString(kitId),
            Variable.withString(componentId)
          ]).get();
      if (previous.isEmpty) throw StateError('Component is not in this kit');
      final changed = await db.customUpdate('''UPDATE product_kit_components
        SET quantity_milli = ? WHERE kit_product_id = ? AND component_product_id = ?''',
          variables: [
            Variable.withInt(quantityMilli),
            Variable.withString(kitId),
            Variable.withString(componentId)
          ],
          updates: {
            db.products
          });
      if (changed != 1) throw StateError('Component is not in this kit');
      await AuthRepository(db).audit(actor.id, 'kit.component_quantity_changed',
          '$kitId / $componentId / ${Quantity.format(previous.single.read<int>('quantity_milli'))} -> ${Quantity.format(quantityMilli)}');
    });
  }

  Future<void> removeComponent(
      ActiveUser actor, String kitId, String componentId) async {
    await _requireManager(actor);
    await db.transaction(() async {
      final countRows = await db.customSelect('''SELECT COUNT(*) AS count
        FROM product_kit_components WHERE kit_product_id = ?''',
          variables: [Variable.withString(kitId)]).getSingle();
      final kit = await (db.select(db.products)
            ..where((p) => p.id.equals(kitId)))
          .getSingleOrNull();
      if (kit?.isActive == true && countRows.read<int>('count') <= 1) {
        throw StateError('Archive the kit before removing its last component');
      }
      final changed = await db
          .customUpdate('''DELETE FROM product_kit_components
        WHERE kit_product_id = ? AND component_product_id = ?''', variables: [
        Variable.withString(kitId),
        Variable.withString(componentId)
      ], updates: {
        db.products
      });
      if (changed != 1) throw StateError('Component is not in this kit');
      await AuthRepository(db)
          .audit(actor.id, 'kit.component_removed', '$kitId / $componentId');
    });
  }

  Future<void> _validate(String kitId, String componentId, int milli) async {
    if (kitId == componentId) throw StateError('A kit cannot contain itself');
    if (milli <= 0) throw ArgumentError('Component quantity must be positive');
    final kit = await (db.select(db.products)..where((p) => p.id.equals(kitId)))
        .getSingleOrNull();
    final component = await (db.select(db.products)
          ..where((p) => p.id.equals(componentId)))
        .getSingleOrNull();
    if (kit?.productType != 'kit') throw StateError('Kit product is required');
    if (component == null ||
        component.productType != 'standard' ||
        !component.isActive) {
      throw StateError('An active standard product is required');
    }
    final config =
        await BusinessFeatureRepository(db).businessProduct(componentId);
    if (!config.fractional && milli % Quantity.scale != 0) {
      throw StateError('This component requires whole units');
    }
  }

  Future<KitAvailability> availability(String kitId) async {
    final all = await availabilities([kitId]);
    return all[kitId] ?? KitAvailability(kitId, const [], 0, null, null);
  }

  Future<String> definitionSignature(String kitId) async {
    return (await definitionSignatures([kitId]))[kitId] ?? '[]';
  }

  Future<Map<String, String>> definitionSignatures(Iterable<String> kitIds) async {
    final ids = kitIds.toSet().toList();
    if (ids.isEmpty) return {};
    final rows = await db.customSelect('''SELECT kit_product_id,
      component_product_id, quantity_milli FROM product_kit_components
      WHERE kit_product_id IN (${List.filled(ids.length, '?').join(',')})
      ORDER BY kit_product_id, sort_order, id''',
      variables: ids.map(Variable.withString).toList()).get();
    final grouped = <String, List<List<Object>>>{};
    for (final row in rows) {
      grouped.putIfAbsent(row.read<String>('kit_product_id'), () => []).add([
        row.read<String>('component_product_id'), row.read<int>('quantity_milli')
      ]);
    }
    return {for (final id in ids) id: jsonEncode(grouped[id] ?? [])};
  }

  Future<Map<String, KitAvailability>> availabilities(
      Iterable<String> kitIds) async {
    final ids = kitIds.toSet().toList();
    if (ids.isEmpty) return {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''SELECT c.id, c.kit_product_id,
      c.component_product_id, c.quantity_milli, p.name
      FROM product_kit_components c JOIN products p ON p.id = c.component_product_id
      WHERE c.kit_product_id IN ($placeholders)
      ORDER BY c.kit_product_id, c.sort_order, c.id''',
        variables: ids.map(Variable.withString).toList()).get();
    final stock = await PosRepository(db).stockLevels();
    final componentIds =
        rows.map((r) => r.read<String>('component_product_id')).toSet();
    final costs = <String, List<(int, int)>>{};
    if (componentIds.isNotEmpty) {
      final layerRows = await db.customSelect(
          '''SELECT product_id, unit_cost_cents, quantity_remaining_milli
        FROM inventory_layers WHERE quantity_remaining_milli > 0
        AND product_id IN (${List.filled(componentIds.length, '?').join(',')})
        ORDER BY received_at, id''',
          variables: componentIds.map(Variable.withString).toList()).get();
      for (final row in layerRows) {
        costs.putIfAbsent(row.read<String>('product_id'), () => []).add((
          row.read<int>('unit_cost_cents'),
          row.read<int>('quantity_remaining_milli')
        ));
      }
    }
    final grouped = <String, List<KitComponentView>>{};
    final totals = <String, int>{};
    final known = <String, bool>{};
    for (final row in rows) {
      final kit = row.read<String>('kit_product_id');
      final component = row.read<String>('component_product_id');
      final required = row.read<int>('quantity_milli');
      final current = stock[component] ?? (0, 0);
      final available = (current.$1 - current.$2).clamp(0, 1 << 62);
      final possible = available ~/ required;
      grouped.putIfAbsent(kit, () => []).add(KitComponentView(
          row.read<String>('id'),
          component,
          row.read<String>('name'),
          required,
          available,
          possible));
      var remainder = required;
      var lineCost = 0;
      for (final layer in costs[component] ?? const <(int, int)>[]) {
        final taken = remainder < layer.$2 ? remainder : layer.$2;
        lineCost += Quantity.lineCents(layer.$1, taken);
        remainder -= taken;
        if (remainder == 0) break;
      }
      if (remainder > 0) known[kit] = false;
      known.putIfAbsent(kit, () => true);
      totals[kit] = (totals[kit] ?? 0) + lineCost;
    }
    return {
      for (final id in ids)
        id: (() {
          final parts = grouped[id] ?? const <KitComponentView>[];
          KitComponentView? limiting;
          for (final part in parts) {
            if (limiting == null || part.possibleKits < limiting.possibleKits) {
              limiting = part;
            }
          }
          return KitAvailability(
              id,
              parts,
              limiting?.possibleKits ?? 0,
              parts.isNotEmpty && known[id] == true ? totals[id] : null,
              limiting?.name);
        })(),
    };
  }
}
