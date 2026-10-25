import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/active_user.dart';
import '../../core/models/business_product.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'import_repository.dart';

class OpeningInventoryImportRepository {
  OpeningInventoryImportRepository(this.db);
  final AppDatabase db;

  static String key(String? value) => (value ?? '').trim().toLowerCase();
  static int valueCents(ImportRow row) {
    final quantity = Quantity.tryParse(row.values['quantity'] ?? '') ?? 0;
    final cost = ImportRepository.cents(row.values['unit_cost'] ?? '') ?? 0;
    return (quantity * cost + 500) ~/ 1000;
  }

  static DateTime? parseDate(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    final parts = value.split('-').map(int.parse).toList();
    final date = DateTime(parts[0], parts[1], parts[2]);
    return date.year == parts[0] &&
            date.month == parts[1] &&
            date.day == parts[2]
        ? date
        : null;
  }

  Future<ImportPreview> validate(
      List<List<String>> csv, Map<String, String> mapping) async {
    if (!mapping.values.any((f) => ['sku', 'barcode', 'product'].contains(f))) {
      throw const FormatException('Map SKU, barcode, or product name');
    }
    for (final required in ['quantity', 'unit_cost']) {
      if (!mapping.containsValue(required)) {
        throw FormatException('Map the $required column');
      }
    }
    final products = await db.select(db.products).get();
    final layers = await db.select(db.inventoryLayers).get();
    final movements = await db.select(db.inventoryMovements).get();
    final serials = await db.select(db.serialUnits).get();
    final lots = await db.select(db.productLots).get();
    final allocations = await db.select(db.saleItemInventoryAllocations).get();
    final stocks = await db.select(db.inventory).get();
    final configs =
        await BusinessFeatureRepository(db).allProductConfigurations();
    final bySku = <String, List<Product>>{},
        byBarcode = <String, List<Product>>{},
        byName = <String, List<Product>>{};
    for (final product in products) {
      if (key(product.sku).isNotEmpty) {
        (bySku[key(product.sku)] ??= []).add(product);
      }
      if (key(product.barcode).isNotEmpty) {
        (byBarcode[key(product.barcode)] ??= []).add(product);
      }
      (byName[key(product.name)] ??= []).add(product);
    }
    final layerProductById = {
      for (final layer in layers) layer.id: layer.productId
    };
    final productIdsWithLayers = {for (final layer in layers) layer.productId};
    final existingLots = {
      for (final lot in lots) '${lot.productId}:${key(lot.batchNumber)}'
    };
    final realHistory = <String>{
      for (final layer in layers)
        if (!['opening', 'legacy_opening'].contains(layer.source))
          layer.productId,
      for (final movement in movements)
        if (!['initial_stock', 'opening_inventory_import']
            .contains(movement.reason))
          movement.productId,
      for (final allocation in allocations)
        if (layerProductById.containsKey(allocation.inventoryLayerId))
          layerProductById[allocation.inventoryLayerId]!,
      for (final stock in stocks)
        if (stock.quantityMilli > 0 &&
            !productIdsWithLayers.contains(stock.productId))
          stock.productId,
    };
    final priorOpening = <String>{
      for (final layer in layers)
        if (['opening', 'legacy_opening'].contains(layer.source))
          layer.productId,
    };
    final existingSerials = {
      for (final serial in serials) key(serial.serialNumber)
    };
    final seenSerials = <String>{}, seenBatches = <String>{};
    final rows = <ImportRow>[];
    final now = DateTime.now();
    for (var i = 1; i < csv.length; i++) {
      final values = <String, String>{};
      for (var col = 0; col < csv.first.length; col++) {
        final field = mapping[csv.first[col]];
        if (field != null) values[field] = csv[i][col].trim();
      }
      final row = ImportRow(i + 1, values);
      rows.add(row);
      Product? product;
      final suppliedMatches = <Product>[];
      for (final (field, index) in [
        ('sku', bySku),
        ('barcode', byBarcode),
        ('product', byName)
      ]) {
        final search = key(values[field]);
        if (search.isEmpty) continue;
        final matches = index[search] ?? <Product>[];
        if (matches.length > 1) {
          row.errors.add('Ambiguous $field; correct the identifier');
          break;
        }
        if (matches.length == 1) {
          product ??= matches.single;
          suppliedMatches.add(matches.single);
        }
      }
      if (suppliedMatches.map((p) => p.id).toSet().length > 1) {
        row.errors.add('Identifiers refer to different products');
        continue;
      }
      if (product == null) {
        row.errors.add('Product not found. Import Products first.');
        continue;
      }
      row.existingId = product.id;
      row.existingName = product.name;
      final config = configs[product.id] ?? const BusinessProduct();
      final quantity = Quantity.tryParse(values['quantity'] ?? '',
          fractional: config.fractional);
      if (quantity == null) {
        row.errors.add('Quantity must be positive with supported precision');
      }
      final cost = ImportRepository.cents(values['unit_cost'] ?? '');
      if (cost == null) row.errors.add('Valid unit cost is required');
      if (product.pricingPolicy == 'layer') {
        final selling =
            ImportRepository.cents(values['unit_selling_price'] ?? '');
        if (selling == null || selling <= 0) {
          row.errors
              .add('Unit selling price is required for layer-priced products');
        }
      } else if (values['unit_selling_price']?.isNotEmpty == true &&
          ImportRepository.cents(values['unit_selling_price']!) == null) {
        row.errors.add('Invalid unit selling price');
      }
      if (realHistory.contains(product.id)) {
        row.errors.add(
            'Product already has inventory activity. Use Receiving or stock adjustment.');
      }
      if (priorOpening.contains(product.id)) {
        row.action = ImportAction.skip;
        row.warnings.add(
            'Prior opening inventory exists. Choose Add another layer to continue.');
      }
      final batch = key(values['batch_lot']);
      final expiryText = values['expiry_date'] ?? '';
      final expiry = expiryText.isEmpty ? null : parseDate(expiryText);
      if (expiryText.isNotEmpty && expiry == null) {
        row.errors.add('Expiry must be a valid YYYY-MM-DD date');
      }
      if (expiry != null &&
          expiry.isBefore(DateTime(now.year, now.month, now.day))) {
        row.warnings.add('This batch is already expired.');
      }
      if (config.batch) {
        if (batch.isEmpty) row.errors.add('Batch/lot is required');
        if (batch.isNotEmpty && !seenBatches.add('${product.id}:$batch')) {
          row.errors
              .add('Duplicate batch in file; use separate batch identities');
        }
        if (existingLots.contains('${product.id}:$batch')) {
          row.errors.add('Batch already exists');
        }
      } else if (batch.isNotEmpty || expiryText.isNotEmpty) {
        row.errors.add('Product is not batch tracked');
      }
      final serial = key(values['serial_number']);
      if (product.serialTracking) {
        if (quantity != Quantity.scale) {
          row.errors.add('Serialized rows require quantity 1');
        }
        if (serial.isEmpty) row.errors.add('Serial number is required');
        if (serial.isNotEmpty && !seenSerials.add(serial)) {
          row.errors.add('Duplicate serial in file');
        }
        if (serial.isNotEmpty && existingSerials.contains(serial)) {
          row.errors.add('Serial already exists in inventory');
        }
      } else if (serial.isNotEmpty) {
        row.errors.add('Product is not serialized');
      }
      if (cost != null &&
          product.costCents != null &&
          cost != product.costCents) {
        row.warnings.add('Opening cost differs from product reference cost');
      }
    }
    return ImportPreview(rows, {});
  }

  Future<ImportResult> commit(
          ActiveUser actor,
          ImportPreview preview,
          List<List<String>> csv,
          Map<String, String> mapping,
          String fileName) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final fresh = await validate(csv, mapping);
        if (fresh.rows.length != preview.rows.length) {
          throw StateError('CSV changed; validate again');
        }
        for (var i = 0; i < preview.rows.length; i++) {
          final selected = preview.rows[i], current = fresh.rows[i];
          if (selected.existingId != current.existingId ||
              selected.values.toString() != current.values.toString() ||
              current.errors.isNotEmpty) {
            throw StateError(
                'Inventory changed or row ${selected.number} is invalid. Validate again.');
          }
          if (current.action == ImportAction.skip &&
              selected.action == ImportAction.create &&
              !current.warnings.any((w) => w.contains('Prior opening'))) {
            throw StateError('Validate row ${selected.number} again');
          }
        }
        final baseTime = DateTime.now();
        var layersCreated = 0, skipped = 0, serialsCreated = 0, totalValue = 0;
        final productIds = <String>{};
        final productsById = {
          for (final p in await db.select(db.products).get()) p.id: p
        };
        final configs =
            await BusinessFeatureRepository(db).allProductConfigurations();
        final stocksByProduct = {
          for (final stock in await db.select(db.inventory).get())
            stock.productId: stock.quantityMilli
        };
        for (final row in preview.rows) {
          if (!row.ready) {
            skipped++;
            continue;
          }
          if (row.action == ImportAction.update) {
            throw StateError('Opening layers cannot be updated');
          }
          final productId = row.existingId!;
          final product = productsById[productId]!;
          final config = configs[productId] ?? const BusinessProduct();
          final quantity = Quantity.tryParse(row.values['quantity']!,
              fractional: config.fractional)!;
          final cost = ImportRepository.cents(row.values['unit_cost']!)!;
          final batch = config.batch ? row.values['batch_lot'] : null;
          final expiry = row.values['expiry_date']?.isNotEmpty == true
              ? parseDate(row.values['expiry_date']!)
              : null;
          final at = baseTime;
          final layerId =
              '${baseTime.microsecondsSinceEpoch.toString().padLeft(20, '0')}-${layersCreated.toString().padLeft(6, '0')}-${const Uuid().v4()}';
          final layer = await db
              .into(db.inventoryLayers)
              .insertReturning(InventoryLayersCompanion.insert(
                id: Value(layerId),
                productId: productId,
                source: const Value('opening'),
                quantityReceivedMilli: quantity,
                quantityRemainingMilli: quantity,
                unitCostCents: cost,
                unitSellingPriceCents: Value(product.pricingPolicy == 'layer'
                    ? ImportRepository.cents(row.values['unit_selling_price']!)
                    : null),
                batchNumber: Value(batch),
                expiryDate: Value(expiry),
                receivedAt: Value(at),
              ));
          if (config.batch) {
            await db.into(db.productLots).insert(ProductLotsCompanion.insert(
                productId: productId,
                batchNumber: batch!,
                expiryDate: Value(expiry),
                quantityMilli: Value(quantity),
                receivedAt: Value(at)));
          }
          if (product.serialTracking) {
            await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
                productId: productId,
                serialNumber: row.values['serial_number']!,
                inventoryLayerId: Value(layer.id)));
            serialsCreated++;
          }
          final next = (stocksByProduct[productId] ?? 0) + quantity;
          if (!stocksByProduct.containsKey(productId)) {
            await db.into(db.inventory).insert(InventoryCompanion.insert(
                productId: productId,
                quantity: Value(next ~/ 1000),
                quantityMilli: Value(next)));
          } else {
            await (db.update(db.inventory)
                  ..where((s) => s.productId.equals(productId)))
                .write(InventoryCompanion(
                    quantity: Value(next ~/ 1000), quantityMilli: Value(next)));
          }
          stocksByProduct[productId] = next;
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: productId,
                  quantityDelta: quantity ~/ 1000,
                  quantityDeltaMilli: Value(quantity),
                  reason: 'opening_inventory_import',
                  referenceId: Value('Opening Inventory Import: $fileName'),
                  createdAt: Value(at)));
          productIds.add(productId);
          totalValue += valueCents(row);
          layersCreated++;
        }
        await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
            userId: Value(live.id),
            action: 'import.opening_inventory',
            details: Value(jsonEncode({
              'file': fileName,
              'rows': preview.rows.length,
              'products': productIds.length,
              'layers': layersCreated,
              'serials': serialsCreated,
              'valueCents': totalValue,
              'skipped': skipped
            }))));
        return ImportResult(layersCreated, 0, skipped,
            productsAffected: productIds.length,
            serialsCreated: serialsCreated,
            valueCents: totalValue);
      });
}
