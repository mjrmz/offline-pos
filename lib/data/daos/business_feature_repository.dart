import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/business_feature.dart';
import '../../core/models/business_product.dart';
import 'auth_repository.dart';
import '../database.dart';

/// Local availability and retained per-product configuration are independent.
class BusinessFeatureRepository {
  BusinessFeatureRepository(this.db);
  final AppDatabase db;

  Future<Map<BusinessFeature, bool>> availability() async {
    final rows = await db.select(db.businessFeatureSettings).get();
    final stored = {for (final row in rows) row.featureId: row.enabled};
    return {
      for (final feature in BusinessFeature.values)
        feature: stored[feature.name] ?? false,
    };
  }

  Future<void> setEnabled(
      BusinessFeature feature, bool enabled, ActiveUser actor) async {
    await db.transaction(() async {
      final live = await AuthRepository(db).requireActive(actor.id);
      live.require(PosPermission.manageSettings);
      await db.into(db.businessFeatureSettings).insert(
          BusinessFeatureSettingsCompanion.insert(
              featureId: feature.name, enabled: Value(enabled)),
          mode: InsertMode.insertOrReplace);
      await AuthRepository(db).audit(
          live.id,
          enabled ? 'business_feature.enabled' : 'business_feature.disabled',
          feature.name);
    });
  }

  Future<void> setInitialSelections(
      Set<BusinessFeature> selected, ActiveUser actor) async {
    await db.transaction(() async {
      final live = await AuthRepository(db).requireActive(actor.id);
      live.require(PosPermission.manageSettings);
      for (final feature in selected) {
        await db.into(db.businessFeatureSettings).insert(
            BusinessFeatureSettingsCompanion.insert(
                featureId: feature.name, enabled: const Value(true)),
            mode: InsertMode.insertOrReplace);
        await AuthRepository(db)
            .audit(live.id, 'business_feature.enabled', feature.name);
      }
    });
  }

  Future<Map<String, Object?>?> productConfiguration(
      String productId, BusinessFeature feature) async {
    final row = await (db.select(db.productBusinessConfigurations)
          ..where((c) =>
              c.productId.equals(productId) & c.featureId.equals(feature.name)))
        .getSingleOrNull();
    if (row == null) return null;
    return Map<String, Object?>.from(jsonDecode(row.configurationJson) as Map);
  }

  Future<Map<String, BusinessProduct>> allProductConfigurations(
      {Iterable<String>? productIds}) async {
    final ids = productIds?.toList();
    if (ids != null && ids.isEmpty) return {};
    final query = db.select(db.productBusinessConfigurations);
    if (ids != null) {
      query.where((c) => c.productId.isIn(ids));
    }
    final rows = await query.get();
    final byProduct = <String, Map<BusinessFeature, Map<String, Object?>>>{};
    for (final row in rows) {
      final feature = BusinessFeature.values
          .where((f) => f.name == row.featureId)
          .firstOrNull;
      if (feature == null) continue;
      (byProduct[row.productId] ??= {})[feature] =
          Map<String, Object?>.from(jsonDecode(row.configurationJson) as Map);
    }
    return {
      for (final entry in byProduct.entries)
        entry.key: BusinessProduct.fromFeatureMaps(entry.value)
    };
  }

  Future<BusinessProduct> businessProduct(String productId) async =>
      (await allProductConfigurations())[productId] ?? const BusinessProduct();

  Future<void> writeProductConfiguration(
      String productId, BusinessProduct config, int priceCents) async {
    config.validate(priceCents);
    final flags = await availability();
    for (final entry in config.toFeatureMaps().entries) {
      if (flags[entry.key] != true) continue;
      await db.into(db.productBusinessConfigurations).insert(
          ProductBusinessConfigurationsCompanion.insert(
              productId: productId,
              featureId: entry.key.name,
              configurationJson: jsonEncode(entry.value)),
          mode: InsertMode.insertOrReplace);
    }
  }
}
