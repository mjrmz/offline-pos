import 'package:drift/drift.dart';
import '../../core/models/product.dart';
import '../../core/models/business_product.dart';
import '../../core/models/business_feature.dart';
import '../../core/models/quantity.dart';
import 'business_feature_repository.dart';
import 'inventory_layer_repository.dart';
import '../../core/models/active_user.dart';
import 'auth_repository.dart';
import '../database.dart';
import '../../backup/compliance_protection.dart';
import 'package:uuid/uuid.dart';

class SaleLineRequest {
  final String productId;
  final int quantity;
  final int? quantityMilli;
  final String mode;
  final String? batchId;
  final List<String> serialIds;
  const SaleLineRequest(this.productId, this.quantity,
      {this.quantityMilli,
      this.mode = 'ordinary',
      this.batchId,
      this.serialIds = const []});
}

class OpeningBatch {
  final int quantityMilli;
  final String number;
  final DateTime? expiry;
  const OpeningBatch(this.quantityMilli, this.number, this.expiry);
}

class _ResolvedLine {
  final Product product;
  final BusinessProduct config;
  final int quantityMilli;
  final String mode;
  final ProductLot? batch;
  final int extraCents;
  final int lineCents;
  final List<SerialUnit> serials;
  final List<LayerConsumption> layers;
  const _ResolvedLine(this.product, this.config, this.quantityMilli, this.mode,
      this.batch, this.extraCents, this.lineCents, this.serials, this.layers);
}

class CommittedSale {
  final String saleId;
  final int totalCents;
  final int? birInvoiceNumber;
  final bool protectionWarning;
  const CommittedSale(this.saleId, this.totalCents,
      [this.birInvoiceNumber, this.protectionWarning = false]);
}

class PosRepository {
  final AppDatabase db;
  final bool _birReady;
  final bool Function()? birEntitled;
  bool get birReady => birEntitled?.call() ?? _birReady;
  final ComplianceProtection? protection;
  PosRepository(this.db,
      {bool birReady = false, this.birEntitled, this.protection})
      : _birReady = birReady;
  PosProduct _product(Product row,
          [BusinessProduct business = const BusinessProduct()]) =>
      PosProduct(
          row.id,
          row.name,
          row.barcode,
          row.priceCents,
          row.isActive,
          row.sku,
          row.categoryId,
          row.costCents ?? 0,
          row.lowStockThreshold,
          business,
          row.serialTracking,
          row.pricingPolicy);

  Future<List<Category>> categories() => (db.select(db.categories)
        ..orderBy([(c) => OrderingTerm(expression: c.name)]))
      .get();
  Future<String> addCategory(String name, {String? parentId}) async {
    if (name.trim().isEmpty) throw ArgumentError('Category name is required');
    final row = await db.into(db.categories).insertReturning(
        CategoriesCompanion.insert(
            name: name.trim(), parentCategoryId: Value(parentId)));
    return row.id;
  }

  Future<List<PosProduct>> products() async {
    final rows = await (db.select(db.products)
          ..orderBy([(p) => OrderingTerm(expression: p.name)]))
        .get();
    final configs =
        await BusinessFeatureRepository(db).allProductConfigurations();
    return [
      for (final row in rows)
        _product(row, configs[row.id] ?? const BusinessProduct())
    ];
  }

  Future<List<InventoryLayer>> layersForProduct(String productId,
      {bool includeDepleted = true}) {
    final query = db.select(db.inventoryLayers)
      ..where((l) =>
          l.productId.equals(productId) &
          (includeDepleted
              ? const Constant(true)
              : l.quantityRemainingMilli.isBiggerThanValue(0)))
      ..orderBy([
        (l) => OrderingTerm(expression: l.receivedAt),
        (l) => OrderingTerm(
            expression: const CustomExpression<int>(
                "CASE WHEN source IN ('opening', 'legacy_opening') THEN 0 ELSE 1 END")),
        (l) => OrderingTerm(expression: l.id),
      ]);
    return query.get();
  }

  Future<Map<String, List<InventoryLayer>>> activeLayersByProduct() async {
    final rows = await (db.select(db.inventoryLayers)
          ..where((l) => l.quantityRemainingMilli.isBiggerThanValue(0)))
        .get();
    final result = <String, List<InventoryLayer>>{};
    for (final row in rows) {
      result.putIfAbsent(row.productId, () => []).add(row);
    }
    return result;
  }

  Future<Map<String, (int physical, int reserved)>> stockLevels() async {
    final inventory = await db.select(db.inventory).get();
    final reserved = await db.customSelect('''
      SELECT li.product_id, SUM(li.quantity_milli) AS reserved_milli
      FROM layaway_items li JOIN layaways l ON l.id = li.layaway_id
      WHERE l.status = 'active' GROUP BY li.product_id
    ''').get();
    final map = {
      for (final row in inventory) row.productId: (row.quantityMilli, 0)
    };
    for (final row in reserved) {
      final id = row.read<String>('product_id');
      map[id] = (map[id]?.$1 ?? 0, row.read<int>('reserved_milli'));
    }
    for (final serial in await (db.select(db.serialUnits)
          ..where((s) => s.status.equals('rma_reserved')))
        .get()) {
      final current = map[serial.productId] ?? (0, 0);
      map[serial.productId] = (current.$1, current.$2 + Quantity.scale);
    }
    return map;
  }

  Future<Map<String, String>> layerSupplierNames(String productId) async {
    final rows = await db.customSelect('''
      SELECT l.id AS layer_id, s.name AS supplier_name
      FROM inventory_layers l
      JOIN stock_receiving_items i ON i.id = l.receiving_item_id
      JOIN stock_receivings r ON r.id = i.receiving_id
      JOIN suppliers s ON s.id = r.supplier_id
      WHERE l.product_id = ?
    ''', variables: [Variable.withString(productId)]).get();
    return {
      for (final row in rows)
        row.read<String>('layer_id'): row.read<String>('supplier_name')
    };
  }

  Future<String?> layerReceivingReference(String layerId) async {
    final rows = await db.customSelect('''
      SELECT r.external_reference, r.id
      FROM inventory_layers l
      JOIN stock_receiving_items i ON i.id = l.receiving_item_id
      JOIN stock_receivings r ON r.id = i.receiving_id
      WHERE l.id = ?
    ''', variables: [Variable.withString(layerId)]).get();
    if (rows.isEmpty) return null;
    return rows.single.readNullable<String>('external_reference') ??
        rows.single.read<String>('id');
  }

  Future<List<SerialUnit>> serialsForLayer(String layerId) =>
      (db.select(db.serialUnits)
            ..where((s) => s.inventoryLayerId.equals(layerId))
            ..orderBy([(s) => OrderingTerm(expression: s.serialNumber)]))
          .get();

  Future<int> quoteLayerPrice(String productId, int quantityMilli,
      {String? batchId,
      List<String> serialIds = const [],
      int extraCents = 0}) async {
    final product = await (db.select(db.products)
          ..where((p) => p.id.equals(productId)))
        .getSingle();
    if (product.pricingPolicy != 'layer') {
      return Quantity.lineCents(product.priceCents + extraCents, quantityMilli);
    }
    final batch = batchId == null
        ? null
        : await (db.select(db.productLots)..where((b) => b.id.equals(batchId)))
            .getSingle();
    final serials = <SerialUnit>[];
    for (final id in serialIds) {
      serials.add(await (db.select(db.serialUnits)
            ..where((s) => s.id.equals(id)))
          .getSingle());
    }
    final parts = await InventoryLayerRepository(db).consume(
        productId, quantityMilli,
        batchNumber: batch?.batchNumber, serials: serials, commit: false);
    return parts.fold<int>(
        0,
        (sum, part) =>
            sum +
            Quantity.lineCents(
                part.layer.unitSellingPriceCents ?? product.priceCents,
                part.quantityMilli) +
            Quantity.lineCents(extraCents, part.quantityMilli));
  }

  Future<PosProduct?> barcode(String code) async {
    final row = await (db.select(db.products)
          ..where((p) => p.barcode.equals(code)))
        .getSingleOrNull();
    if (row == null) return null;
    if (!row.isActive) throw StateError('Product is inactive');
    return _product(
        row, await BusinessFeatureRepository(db).businessProduct(row.id));
  }

  Future<void> _validateCodes(
      String? sku, String? barcode, String? exceptId) async {
    final rows = await db.select(db.products).get();
    if (rows.any((p) =>
        p.id != exceptId && sku != null && sku.isNotEmpty && p.sku == sku)) {
      throw StateError('SKU already exists');
    }
    if (rows.any((p) =>
        p.id != exceptId &&
        barcode != null &&
        barcode.isNotEmpty &&
        p.barcode == barcode)) {
      throw StateError('Barcode already exists');
    }
  }

  Future<void> _validateBusinessAvailability(
      BusinessProduct next, BusinessProduct previous) async {
    final available = await BusinessFeatureRepository(db).availability();
    final nextMaps = next.toFeatureMaps();
    final previousMaps = previous.toFeatureMaps();
    for (final feature in BusinessFeature.values) {
      if (feature == BusinessFeature.unitOfMeasureVariety &&
          (next.weight || next.refill)) {
        continue;
      }
      if (nextMaps[feature]?['enabled'] == true &&
          available[feature] != true &&
          previousMaps[feature]?['enabled'] != true) {
        throw StateError('Enable ${feature.displayName} in Business Features');
      }
    }
  }

  Future<String> saveProduct(
      {String? id,
      required String name,
      String? sku,
      String? barcode,
      String? categoryId,
      required int priceCents,
      required int costCents,
      int startingStock = 0,
      int? startingStockMilli,
      int lowStockThreshold = 5,
      bool isActive = true,
      bool? serialTracking,
      List<String> openingSerials = const [],
      List<OpeningBatch> openingBatches = const [],
      String? pricingPolicy,
      BusinessProduct? business,
      String? batchNumber,
      DateTime? batchExpiry,
      String? actorId}) async {
    final initialMilli = startingStockMilli ?? startingStock * Quantity.scale;
    business?.validate(priceCents);
    if (business != null &&
        !business.fractional &&
        initialMilli % Quantity.scale != 0) {
      throw ArgumentError('Whole-unit product requires whole starting stock');
    }
    if (id == null && business?.madeToOrder == true && initialMilli > 0) {
      throw ArgumentError(
          'Made-to-order products cannot start with finished stock');
    }
    final normalizedSerials = openingSerials.map((s) => s.trim()).toList();
    final today = DateTime.now();
    final todayStart = DateTime(today.year, today.month, today.day);
    if (openingBatches.isNotEmpty) {
      if (id != null ||
          business?.batch != true ||
          openingBatches.any((b) =>
              b.quantityMilli <= 0 ||
              (business?.fractional != true &&
                  b.quantityMilli % Quantity.scale != 0) ||
              b.number.trim().isEmpty ||
              (b.expiry != null && b.expiry!.isBefore(todayStart))) ||
          openingBatches.map((b) => b.number.trim()).toSet().length !=
              openingBatches.length ||
          openingBatches.fold<int>(0, (total, b) => total + b.quantityMilli) !=
              initialMilli) {
        throw StateError(
            'Enter valid opening batches matching the opening quantity');
      }
    }
    if (id == null && serialTracking == true && initialMilli > 0) {
      if (initialMilli % Quantity.scale != 0 ||
          normalizedSerials.length != initialMilli ~/ Quantity.scale ||
          normalizedSerials.any((s) => s.isEmpty) ||
          normalizedSerials.toSet().length != normalizedSerials.length) {
        throw StateError(
            'Enter one unique serial number for each opening unit');
      }
    } else if (openingSerials.isNotEmpty) {
      throw StateError(
          'Opening serial numbers require serialized opening stock');
    }
    if (serialTracking == true &&
        (business?.fractional == true || business?.madeToOrder == true)) {
      throw StateError('Serialized products require whole stocked units');
    }
    if (name.trim().isEmpty ||
        (pricingPolicy != null &&
            !{'current', 'layer'}.contains(pricingPolicy)) ||
        priceCents < 0 ||
        costCents < 0 ||
        initialMilli < 0 ||
        lowStockThreshold < 0) {
      throw ArgumentError('Invalid product values');
    }
    final normalizedSku = sku?.trim().isEmpty == true ? null : sku?.trim();
    final normalizedBarcode =
        barcode?.trim().isEmpty == true ? null : barcode?.trim();
    return db.transaction(() async {
      await _validateCodes(normalizedSku, normalizedBarcode, id);
      for (final serial in normalizedSerials) {
        if (await (db.select(db.serialUnits)
                  ..where((s) => s.serialNumber.equals(serial)))
                .getSingleOrNull() !=
            null) {
          throw StateError('Serial $serial already exists.');
        }
      }
      if (id != null) {
        final oldProduct = await (db.select(db.products)
              ..where((p) => p.id.equals(id)))
            .getSingle();
        final previous =
            await BusinessFeatureRepository(db).businessProduct(id);
        final nextSerial = serialTracking ?? oldProduct.serialTracking;
        if (nextSerial != oldProduct.serialTracking) {
          if (await stockMilli(id) != 0 ||
              (await (db.select(db.serialUnits)
                        ..where((s) => s.productId.equals(id)))
                      .get())
                  .isNotEmpty) {
            throw StateError(
                'Clear stock and serial history before changing serial tracking');
          }
        }
        if (nextSerial &&
            ((business ?? previous).fractional ||
                (business ?? previous).madeToOrder)) {
          throw StateError('Serialized products require whole stocked units');
        }
        (business ?? previous).validate(priceCents);
        final count = await (db.update(db.products)
              ..where((p) => p.id.equals(id)))
            .write(ProductsCompanion(
                name: Value(name.trim()),
                sku: Value(normalizedSku),
                barcode: Value(normalizedBarcode),
                categoryId: Value(categoryId),
                priceCents: Value(priceCents),
                costCents: Value(costCents),
                pricingPolicy: Value(pricingPolicy ?? oldProduct.pricingPolicy),
                lowStockThreshold: Value(lowStockThreshold),
                isActive: Value(isActive)));
        await (db.update(db.products)..where((p) => p.id.equals(id)))
            .write(ProductsCompanion(serialTracking: Value(nextSerial)));
        if (count != 1) throw StateError('Product not found');
        if (oldProduct.priceCents != priceCents ||
            oldProduct.costCents != costCents) {
          await db.into(db.priceHistory).insert(PriceHistoryCompanion.insert(
                productId: id,
                userId: Value(actorId),
                oldPriceCents: oldProduct.priceCents,
                newPriceCents: priceCents,
                oldCostCents: Value(oldProduct.costCents),
                newCostCents: Value(costCents),
              ));
          if (actorId != null) {
            await AuthRepository(db)
                .audit(actorId, 'product.price_changed', id);
          }
        }
        if (business != null) {
          await _validateBusinessAvailability(business, previous);
          if (business.madeToOrder &&
              !previous.madeToOrder &&
              await stockMilli(id) > 0) {
            throw StateError(
                'Sell finished stock before making this product made-to-order');
          }
          if (!business.fractional &&
              (await stockMilli(id)) % Quantity.scale != 0) {
            throw StateError(
                'Fractional stock must be cleared before using a whole-unit mode');
          }
          if (previous.batch && !business.batch) {
            throw StateError(
                'Batch tracking cannot be removed from a stocked product');
          }
          await BusinessFeatureRepository(db)
              .writeProductConfiguration(id, business, priceCents);
          (await BusinessFeatureRepository(db).businessProduct(id))
              .validate(priceCents);
          if (actorId != null) {
            await AuthRepository(db)
                .audit(actorId, 'product.business_configuration_changed', id);
          }
          if (business.batch && !previous.batch) {
            final existing = await stockMilli(id);
            if (existing > 0) {
              if (batchNumber == null || batchNumber.trim().isEmpty) {
                throw StateError('Enter a batch for existing stock');
              }
              await db.into(db.productLots).insert(ProductLotsCompanion.insert(
                  productId: id,
                  batchNumber: batchNumber.trim(),
                  expiryDate: Value(batchExpiry),
                  quantityMilli: Value(existing)));
            }
          }
        }
        return id;
      }
      final row = await db.into(db.products).insertReturning(
          ProductsCompanion.insert(
              name: name.trim(),
              sku: Value(normalizedSku),
              barcode: Value(normalizedBarcode),
              categoryId: Value(categoryId),
              priceCents: priceCents,
              costCents: Value(costCents),
              pricingPolicy: Value(pricingPolicy ?? 'current'),
              lowStockThreshold: Value(lowStockThreshold),
              isActive: Value(isActive)));
      if (serialTracking == true) {
        await (db.update(db.products)..where((p) => p.id.equals(row.id)))
            .write(const ProductsCompanion(serialTracking: Value(true)));
      }
      await db
          .into(db.inventory)
          .insert(InventoryCompanion.insert(productId: row.id));
      if (initialMilli > 0) {
        final batches = openingBatches.isNotEmpty
            ? openingBatches
            : [
                OpeningBatch(
                    initialMilli, batchNumber?.trim() ?? '', batchExpiry)
              ];
        var serialOffset = 0;
        for (final openingBatch in batches) {
          final openingLayer = await db
              .into(db.inventoryLayers)
              .insertReturning(InventoryLayersCompanion.insert(
                  productId: row.id,
                  source: const Value('opening'),
                  quantityReceivedMilli: openingBatch.quantityMilli,
                  quantityRemainingMilli: openingBatch.quantityMilli,
                  unitCostCents: costCents,
                  unitSellingPriceCents: Value(
                      (pricingPolicy ?? 'current') == 'layer'
                          ? priceCents
                          : null),
                  batchNumber: Value(
                      business?.batch == true ? openingBatch.number : null),
                  expiryDate: Value(
                      business?.batch == true ? openingBatch.expiry : null)));
          for (final serial in normalizedSerials
              .skip(serialOffset)
              .take(openingBatch.quantityMilli ~/ Quantity.scale)) {
            await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
                productId: row.id,
                serialNumber: serial,
                receivingItemId: const Value(null),
                inventoryLayerId: Value(openingLayer.id)));
          }
          serialOffset += openingBatch.quantityMilli ~/ Quantity.scale;
        }
        await (db.update(db.inventory)
              ..where((i) => i.productId.equals(row.id)))
            .write(InventoryCompanion(
                quantity: Value(initialMilli ~/ Quantity.scale),
                quantityMilli: Value(initialMilli)));
        await db.into(db.inventoryMovements).insert(
            InventoryMovementsCompanion.insert(
                productId: row.id,
                quantityDelta: initialMilli ~/ Quantity.scale,
                quantityDeltaMilli: Value(initialMilli),
                reason: 'initial_stock'));
      }
      if (business != null) {
        await _validateBusinessAvailability(business, const BusinessProduct());
        await BusinessFeatureRepository(db)
            .writeProductConfiguration(row.id, business, priceCents);
        (await BusinessFeatureRepository(db).businessProduct(row.id))
            .validate(priceCents);
        if (actorId != null) {
          await AuthRepository(db)
              .audit(actorId, 'product.business_configuration_changed', row.id);
        }
        if (business.batch && initialMilli > 0) {
          if (openingBatches.isEmpty &&
              (batchNumber == null || batchNumber.trim().isEmpty)) {
            throw StateError('Starting batch number is required');
          }
          for (final openingBatch in openingBatches.isNotEmpty
              ? openingBatches
              : [
                  OpeningBatch(initialMilli, batchNumber!.trim(), batchExpiry)
                ]) {
            await db.into(db.productLots).insert(ProductLotsCompanion.insert(
                productId: row.id,
                batchNumber: openingBatch.number.trim(),
                expiryDate: Value(openingBatch.expiry),
                quantityMilli: Value(openingBatch.quantityMilli)));
          }
        }
      }
      return row.id;
    });
  }

  Future<List<SerialUnit>> availableSerials(String productId) =>
      (db.select(db.serialUnits)
            ..where((s) =>
                s.productId.equals(productId) & s.status.equals('available'))
            ..orderBy([(s) => OrderingTerm(expression: s.serialNumber)]))
          .get();

  Future<int> reservedStockMilli(String productId,
      {String? exceptLayawayId}) async {
    var total = (await (db.select(db.serialUnits)
                  ..where((s) =>
                      s.productId.equals(productId) &
                      s.status.equals('rma_reserved')))
                .get())
            .length *
        Quantity.scale;
    final items = await (db.select(db.layawayItems)
          ..where((i) => i.productId.equals(productId)))
        .get();
    for (final item in items) {
      if (item.layawayId == exceptLayawayId) continue;
      final layaway = await (db.select(db.layaways)
            ..where((l) => l.id.equals(item.layawayId)))
          .getSingle();
      if (layaway.status == 'active') total += item.quantityMilli;
    }
    return total;
  }

  Future<int> stock(String productId) async =>
      (await (db.select(db.inventory)
                ..where((i) => i.productId.equals(productId)))
              .getSingleOrNull())
          ?.quantity ??
      0;
  Future<int> stockMilli(String productId) async =>
      (await (db.select(db.inventory)
                ..where((i) => i.productId.equals(productId)))
              .getSingleOrNull())
          ?.quantityMilli ??
      0;
  Future<List<InventoryMovement>> movements(String productId) =>
      (db.select(db.inventoryMovements)
            ..where((m) => m.productId.equals(productId)))
          .get();

  Future<List<ProductLot>> batches(String productId) =>
      (db.select(db.productLots)
            ..where((b) => b.productId.equals(productId))
            ..orderBy([(b) => OrderingTerm(expression: b.receivedAt)]))
          .get();

  Future<int> sellableBatchStockMilli(String productId) async {
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    return (await batches(productId))
        .where((b) => b.expiryDate == null || !b.expiryDate!.isBefore(day))
        .fold<int>(0, (total, batch) => total + batch.quantityMilli);
  }

  Future<int> emptyTankCount(String productId) async =>
      (await (db.select(db.tankEmptyMovements)
                ..where((m) => m.productId.equals(productId)))
              .get())
          .fold<int>(0, (total, movement) => total + movement.quantityDelta);

  Future<void> receiveBatch(String productId, String number, DateTime? expiry,
          int quantityMilli, String actorId) =>
      db.transaction(() async {
        final actor = await AuthRepository(db).requireActive(actorId);
        if (!actor.can(PosPermission.manageCatalog)) {
          throw StateError('Not authorized to receive batches');
        }
        if (number.trim().isEmpty || quantityMilli <= 0) {
          throw ArgumentError('Invalid batch receipt');
        }
        final config =
            await BusinessFeatureRepository(db).businessProduct(productId);
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(productId)))
            .getSingle();
        if (product.serialTracking) {
          throw StateError(
              'Receive serialized stock through supplier receiving');
        }
        if (!config.batch) throw StateError('Product is not batch tracked');
        if (!config.fractional && quantityMilli % Quantity.scale != 0) {
          throw ArgumentError('Whole-unit batch requires whole quantity');
        }
        if ((await batches(productId))
            .any((b) => b.batchNumber == number.trim())) {
          throw StateError('Batch number already exists for this product');
        }
        final current = await stockMilli(productId);
        await db.into(db.inventoryLayers).insert(
            InventoryLayersCompanion.insert(
                productId: productId,
                source: const Value('batch_legacy_receipt'),
                quantityReceivedMilli: quantityMilli,
                quantityRemainingMilli: quantityMilli,
                unitCostCents: product.costCents ?? 0,
                batchNumber: Value(number.trim()),
                expiryDate: Value(expiry)));
        await db.into(db.productLots).insert(ProductLotsCompanion.insert(
            productId: productId,
            batchNumber: number.trim(),
            expiryDate: Value(expiry),
            quantityMilli: Value(quantityMilli)));
        await (db.update(db.inventory)
              ..where((i) => i.productId.equals(productId)))
            .write(InventoryCompanion(
                quantity: Value((current + quantityMilli) ~/ Quantity.scale),
                quantityMilli: Value(current + quantityMilli)));
        await db.into(db.inventoryMovements).insert(
            InventoryMovementsCompanion.insert(
                productId: productId,
                quantityDelta: quantityMilli ~/ Quantity.scale,
                quantityDeltaMilli: Value(quantityMilli),
                reason: 'batch_received'));
        await AuthRepository(db).audit(actor.id, 'batch.received', productId);
      });

  Future<CommittedSale> completeCashSale(
      List<SaleLineRequest> items, int cashReceivedCents, String cashierId,
      {String? quotationId, String? layawayId}) async {
    if (birReady) {
      if (protection == null) {
        throw StateError('Compliance protection is unavailable');
      }
      return protection!.exclusive(() => _completeCashSale(
          items, cashReceivedCents, cashierId,
          quotationId: quotationId, layawayId: layawayId));
    }
    return _completeCashSale(items, cashReceivedCents, cashierId,
        quotationId: quotationId, layawayId: layawayId);
  }

  Future<CommittedSale> completeCreditSale(List<SaleLineRequest> items,
      int cashPaidCents, String customerId, String cashierId,
      {String? quotationId}) async {
    if (birReady) {
      if (protection == null) {
        throw StateError('Compliance protection is unavailable');
      }
      return protection!.exclusive(() => _completeCashSale(
          items, cashPaidCents, cashierId,
          creditCustomerId: customerId, quotationId: quotationId));
    }
    return _completeCashSale(items, cashPaidCents, cashierId,
        creditCustomerId: customerId, quotationId: quotationId);
  }

  Future<CommittedSale> _completeCashSale(
      List<SaleLineRequest> items, int cashReceivedCents, String cashierId,
      {String? creditCustomerId,
      String? quotationId,
      String? layawayId}) async {
    if (birReady) {
      if (protection == null) {
        throw StateError('Compliance protection is unavailable');
      }
      await protection!.prepare(db);
    }
    String? reservedSaleId;
    late final CommittedSale committed;
    try {
      committed = await db.transaction(() async {
        final actor = await AuthRepository(db).requireActive(cashierId);
        if (!actor.can(PosPermission.sell)) {
          throw StateError('Not authorized to sell');
        }
        if (items.isEmpty) throw StateError('Cart is empty');
        final quotedPrices = <String, int>{};
        String? quotationCustomerId;
        var prepaidCents = 0;
        if (layawayId != null) {
          if (quotationId != null || creditCustomerId != null) {
            throw StateError(
                'Layaway completion cannot combine with credit or quotation');
          }
          final layaway = await (db.select(db.layaways)
                ..where((l) => l.id.equals(layawayId)))
              .getSingleOrNull();
          if (layaway == null || layaway.status != 'active') {
            throw StateError('Layaway is not active');
          }
          final reservedItems = await (db.select(db.layawayItems)
                ..where((i) => i.layawayId.equals(layawayId)))
              .get();
          if (reservedItems.length != items.length) {
            throw StateError('Layaway items changed');
          }
          for (final reserved in reservedItems) {
            final matches = items.where((i) =>
                i.productId == reserved.productId &&
                (i.quantityMilli ?? i.quantity * Quantity.scale) ==
                    reserved.quantityMilli);
            if (matches.length != 1) throw StateError('Layaway items changed');
            quotedPrices[reserved.productId] = reserved.unitPriceCents;
          }
          final priorPayments = await (db.select(db.layawayPayments)
                ..where((p) => p.layawayId.equals(layawayId)))
              .get();
          prepaidCents = priorPayments.fold<int>(
              0, (sum, payment) => sum + payment.amountCents);
          if (cashReceivedCents != layaway.totalCents - prepaidCents) {
            throw StateError('Pay the exact remaining layaway balance');
          }
        }
        if (quotationId != null) {
          final quote = await (db.select(db.quotations)
                ..where((q) => q.id.equals(quotationId)))
              .getSingleOrNull();
          if (quote == null ||
              quote.status != 'open' ||
              (quote.validUntil != null &&
                  quote.validUntil!.isBefore(DateTime(DateTime.now().year,
                      DateTime.now().month, DateTime.now().day)))) {
            throw StateError('Quotation is unavailable or expired');
          }
          quotationCustomerId = quote.customerId;
          if (quote.customerId != null &&
              creditCustomerId != null &&
              quote.customerId != creditCustomerId) {
            throw StateError('Quotation customer does not match checkout');
          }
          final quoteItems = await (db.select(db.quotationItems)
                ..where((i) => i.quotationId.equals(quotationId)))
              .get();
          if (quoteItems.length != items.length) {
            throw StateError('Quotation items changed');
          }
          for (final quoted in quoteItems) {
            final matches = items.where((i) =>
                i.productId == quoted.productId &&
                (i.quantityMilli ?? i.quantity * Quantity.scale) ==
                    quoted.quantityMilli);
            if (matches.length != 1) {
              throw StateError('Quotation items changed');
            }
            quotedPrices[quoted.productId] = quoted.unitPriceCents;
          }
        }
        final merged = <String, SaleLineRequest>{};
        for (final item in items) {
          final milli = item.quantityMilli ?? item.quantity * Quantity.scale;
          if (milli <= 0) throw StateError('Invalid quantity');
          final prior = merged[item.productId];
          if (prior == null) {
            merged[item.productId] = item;
          } else if (prior.mode == item.mode && prior.batchId == item.batchId) {
            merged[item.productId] = SaleLineRequest(item.productId, 0,
                quantityMilli:
                    (prior.quantityMilli ?? prior.quantity * Quantity.scale) +
                        milli,
                mode: item.mode,
                batchId: item.batchId,
                serialIds: [...prior.serialIds, ...item.serialIds]);
          } else {
            throw StateError('Use one transaction option per product');
          }
        }
        final configs =
            await BusinessFeatureRepository(db).allProductConfigurations();
        final details = <_ResolvedLine>[];
        var total = 0;
        for (final entry in merged.entries) {
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(entry.key)))
              .getSingleOrNull();
          if (product == null || !product.isActive) {
            throw StateError('Product is inactive or missing');
          }
          final config = configs[product.id] ?? const BusinessProduct();
          config.validate(product.priceCents);
          final request = entry.value;
          final milli =
              request.quantityMilli ?? request.quantity * Quantity.scale;
          if (!config.fractional && milli % Quantity.scale != 0) {
            throw StateError('Whole quantity required for ${product.name}');
          }
          final selectedSerials = <SerialUnit>[];
          if (product.serialTracking) {
            if (milli % Quantity.scale != 0 ||
                request.serialIds.length != milli ~/ Quantity.scale ||
                request.serialIds.toSet().length != request.serialIds.length) {
              throw StateError('Select one unique serial per sold unit');
            }
            for (final id in request.serialIds) {
              final serial = await (db.select(db.serialUnits)
                    ..where((s) => s.id.equals(id)))
                  .getSingleOrNull();
              if (serial == null ||
                  serial.productId != product.id ||
                  (serial.status != 'available' &&
                      !(layawayId != null &&
                          serial.status == 'reserved' &&
                          (await (db.select(db.layawaySerials)
                                    ..where((r) =>
                                        r.layawayId.equals(layawayId) &
                                        r.serialUnitId.equals(serial.id)))
                                  .get())
                              .isNotEmpty))) {
                throw StateError('Serial is unavailable for ${product.name}');
              }
              selectedSerials.add(serial);
            }
            final availableSerials = await (db.select(db.serialUnits)
                  ..where((s) =>
                      s.productId.equals(product.id) &
                      s.status.equals('available')))
                .get();
            final reservedSerials = await (db.select(db.serialUnits)
                  ..where((s) =>
                      s.productId.equals(product.id) &
                      (s.status.equals('reserved') |
                          s.status.equals('rma_reserved'))))
                .get();
            if ((availableSerials.length + reservedSerials.length) *
                    Quantity.scale !=
                await stockMilli(product.id)) {
              throw StateError('Serial stock does not match inventory');
            }
          } else if (request.serialIds.isNotEmpty) {
            throw StateError('Serial selection is invalid for ${product.name}');
          }
          String mode = request.mode;
          if (config.tank) {
            if (mode != 'exchange' && mode != 'deposit') {
              throw StateError('Choose tank exchange or deposit');
            }
          } else if (config.refill) {
            if (mode != 'refill' && mode != 'container') {
              throw StateError('Choose refill or container');
            }
          } else if (config.madeToOrder) {
            if (mode != 'made_order') throw StateError('Choose made-to-order');
          } else if (mode != 'ordinary') {
            throw StateError('Transaction mode is invalid for ${product.name}');
          }
          if (config.batch && config.madeToOrder) {
            throw StateError('Batch and made-to-order cannot overlap');
          }
          ProductLot? batch;
          if (config.batch) {
            final allLots = await batches(product.id);
            if (allLots.fold<int>(0, (sum, b) => sum + b.quantityMilli) !=
                await stockMilli(product.id)) {
              throw StateError('Batch stock does not match product stock');
            }
            final eligible = allLots
                .where((b) =>
                    b.quantityMilli > 0 &&
                    (b.expiryDate == null ||
                        !b.expiryDate!.isBefore(DateTime(DateTime.now().year,
                            DateTime.now().month, DateTime.now().day))))
                .toList();
            if (request.batchId == null && eligible.length != 1) {
              throw StateError('Choose an eligible batch for ${product.name}');
            }
            batch = eligible
                .where((b) => b.id == (request.batchId ?? eligible.first.id))
                .firstOrNull;
            if (batch == null || batch.quantityMilli < milli) {
              throw StateError(
                  'Insufficient eligible batch stock for ${product.name}');
            }
          } else if (request.batchId != null) {
            throw StateError('Batch is invalid for ${product.name}');
          }
          final current = await stockMilli(product.id);
          if (!config.madeToOrder &&
              current -
                      await reservedStockMilli(product.id,
                          exceptLayawayId: layawayId) <
                  milli) {
            throw StateError('Insufficient stock for ${product.name}');
          }
          final extra = mode == 'deposit'
              ? config.depositCents
              : mode == 'container'
                  ? config.containerPriceCents
                  : 0;
          final layers = config.madeToOrder
              ? <LayerConsumption>[]
              : await InventoryLayerRepository(db).consume(product.id, milli,
                  batchNumber: batch?.batchNumber,
                  serials: selectedSerials,
                  commit: false);
          final useLayerPrice = product.pricingPolicy == 'layer' &&
              !quotedPrices.containsKey(product.id);
          final line = !useLayerPrice
              ? Quantity.lineCents(
                      quotedPrices[product.id] ?? product.priceCents, milli) +
                  Quantity.lineCents(extra, milli)
              : layers.fold<int>(
                  0,
                  (sum, part) =>
                      sum +
                      Quantity.lineCents(
                          useLayerPrice
                              ? part.layer.unitSellingPriceCents ??
                                  product.priceCents
                              : quotedPrices[product.id] ?? product.priceCents,
                          part.quantityMilli) +
                      Quantity.lineCents(extra, part.quantityMilli));
          details.add(_ResolvedLine(product, config, milli, mode, batch, extra,
              line, selectedSerials, layers));
          total += line;
        }
        if (layawayId != null) {
          final layaway = await (db.select(db.layaways)
                ..where((l) => l.id.equals(layawayId)))
              .getSingle();
          if (total != layaway.totalCents) {
            throw StateError('Layaway total changed');
          }
        }
        if (creditCustomerId == null) {
          if (cashReceivedCents + prepaidCents < total) {
            throw StateError('Insufficient cash');
          }
        } else {
          if (cashReceivedCents < 0 || cashReceivedCents >= total) {
            throw StateError('Credit cash portion must be below sale total');
          }
          final customer = await (db.select(db.customers)
                ..where((c) => c.id.equals(creditCustomerId)))
              .getSingleOrNull();
          if (customer == null || !customer.isActive) {
            throw StateError('Select an active customer for credit');
          }
        }
        final session = await (db.select(db.cashSessions)
              ..where((s) => s.closedAt.isNull()))
            .getSingleOrNull();
        if (birReady && session == null) {
          throw StateError('Open a cash session before a BIR-ready sale');
        }
        if (layawayId != null && cashReceivedCents > 0 && session == null) {
          throw StateError('Open a cash session for the final payment');
        }
        int? invoiceNumber;
        if (birReady) {
          var state = await (db.select(db.birComplianceState)
                ..where((s) => s.id.equals(1)))
              .getSingleOrNull();
          if (state == null) {
            await db.into(db.birComplianceState).insert(
                BirComplianceStateCompanion.insert(
                    id: const Value(1), activatedAt: DateTime.now()));
            await AuthRepository(db)
                .audit(cashierId, 'bir.cutover', 'activated');
            state = await (db.select(db.birComplianceState)
                  ..where((s) => s.id.equals(1)))
                .getSingle();
          }
          invoiceNumber = state.highestInvoiceNumber + 1;
          reservedSaleId = const Uuid().v4();
          await protection!.reserveSale(
              db, reservedSaleId!, invoiceNumber, total, state.activatedAt);
          await (db.update(db.birComplianceState)..where((s) => s.id.equals(1)))
              .write(BirComplianceStateCompanion(
                  highestInvoiceNumber: Value(invoiceNumber),
                  grandTotalCents: Value(state.grandTotalCents + total)));
        }
        final nextReceipt = await db
            .customSelect(
                "SELECT COALESCE(MAX(CAST(SUBSTR(receipt_number, 5) AS INTEGER)), 0) + 1 AS next_number FROM sales WHERE receipt_number GLOB 'POS-[0-9]*'")
            .getSingle();
        final receiptNumber =
            'POS-${nextReceipt.read<int>('next_number').toString().padLeft(6, '0')}';
        final sale = await db.into(db.sales).insertReturning(
            SalesCompanion.insert(
                receiptNumber: Value(receiptNumber),
                id: reservedSaleId == null
                    ? const Value.absent()
                    : Value(reservedSaleId!),
                cashierId: cashierId,
                cashSessionId: Value(session?.id),
                customerId: Value(creditCustomerId ?? quotationCustomerId),
                totalCents: total,
                birInvoiceNumber: Value(invoiceNumber)));
        for (final detail in details) {
          final product = detail.product;
          final milli = detail.quantityMilli;
          final consumed = detail.config.madeToOrder
              ? <LayerConsumption>[]
              : await InventoryLayerRepository(db).consume(product.id, milli,
                  batchNumber: detail.batch?.batchNumber,
                  serials: detail.serials);
          final layerPrice = product.pricingPolicy == 'layer' &&
              !quotedPrices.containsKey(product.id);
          final groups =
              layerPrice ? consumed.map((part) => [part]).toList() : [consumed];
          if (groups.isEmpty) groups.add(<LayerConsumption>[]);
          for (final group in groups) {
            final groupMilli = layerPrice ? group.single.quantityMilli : milli;
            final unitPrice = layerPrice
                ? group.single.layer.unitSellingPriceCents ?? product.priceCents
                : quotedPrices[product.id] ?? product.priceCents;
            final groupTotal = layerPrice
                ? Quantity.lineCents(unitPrice, groupMilli) +
                    Quantity.lineCents(detail.extraCents, groupMilli)
                : detail.lineCents;
            final saleItem = await db.into(db.saleItems).insertReturning(
                SaleItemsCompanion.insert(
                    saleId: sale.id,
                    productId: product.id,
                    productName: Value(product.name),
                    quantity: groupMilli ~/ Quantity.scale,
                    quantityMilli: Value(groupMilli),
                    saleUnit: Value(detail.config.unit.label),
                    saleMode: Value(detail.mode),
                    batchId: Value(detail.batch?.id),
                    batchNumber: Value(detail.batch?.batchNumber),
                    extraCents: Value(detail.extraCents),
                    unitPriceCents: unitPrice,
                    lineTotalCents: Value(groupTotal)));
            for (final part in group) {
              await db
                  .into(db.saleItemInventoryAllocations)
                  .insert(SaleItemInventoryAllocationsCompanion.insert(
                    saleItemId: saleItem.id,
                    inventoryLayerId: part.layer.id,
                    serialUnitId: Value(part.serialUnitId),
                    quantityMilli: part.quantityMilli,
                    unitCostSnapshotCents: part.layer.unitCostCents,
                    unitSellingPriceSnapshotCents: unitPrice,
                  ));
            }
            for (final serial in detail.serials.where((s) =>
                !layerPrice || group.any((p) => p.serialUnitId == s.id))) {
              final updated = await (db.update(db.serialUnits)
                    ..where((s) =>
                        s.id.equals(serial.id) &
                        (s.status.equals('available') |
                            s.status.equals('reserved'))))
                  .write(SerialUnitsCompanion(
                      status: const Value('sold'),
                      saleItemId: Value(saleItem.id)));
              if (updated != 1) throw StateError('Serial was already sold');
              await db.into(db.serialSaleLinks).insert(
                  SerialSaleLinksCompanion.insert(
                      serialUnitId: serial.id, saleItemId: saleItem.id));
            }
            if (detail.config.madeToOrder) {
              await db
                  .into(db.madeOrders)
                  .insert(MadeOrdersCompanion.insert(saleItemId: saleItem.id));
            }
          }
          if (detail.config.madeToOrder) continue;
          final remaining = (await stockMilli(product.id)) - milli;
          final updated = await (db.update(db.inventory)
                ..where((i) =>
                    i.productId.equals(product.id) &
                    i.quantityMilli.isBiggerOrEqualValue(milli)))
              .write(InventoryCompanion(
                  quantity: Value(remaining ~/ Quantity.scale),
                  quantityMilli: Value(remaining)));
          if (updated != 1) {
            throw StateError('Insufficient stock for ${product.name}');
          }
          if (detail.batch != null) {
            final count = await (db.update(db.productLots)
                  ..where((b) =>
                      b.id.equals(detail.batch!.id) &
                      b.quantityMilli.isBiggerOrEqualValue(milli)))
                .write(ProductLotsCompanion(
                    quantityMilli: Value(detail.batch!.quantityMilli - milli)));
            if (count != 1) throw StateError('Batch stock changed');
          }
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: product.id,
                  quantityDelta: -(milli ~/ Quantity.scale),
                  quantityDeltaMilli: Value(-milli),
                  reason: 'sale',
                  referenceId: Value(sale.id)));
          if (detail.mode == 'exchange') {
            await db.into(db.tankEmptyMovements).insert(
                TankEmptyMovementsCompanion.insert(
                    productId: product.id,
                    quantityDelta: milli ~/ Quantity.scale,
                    reason: 'exchange_return',
                    referenceId: Value(sale.id)));
          }
        }
        final cashPortion =
            creditCustomerId == null ? total - prepaidCents : cashReceivedCents;
        if (prepaidCents > 0) {
          await db.into(db.payments).insert(PaymentsCompanion.insert(
              saleId: sale.id,
              method: 'layaway_prepaid',
              amountCents: prepaidCents));
        }
        if (cashPortion > 0) {
          await db.into(db.payments).insert(PaymentsCompanion.insert(
              saleId: sale.id, method: 'cash', amountCents: cashPortion));
        }
        if (creditCustomerId != null) {
          final creditPortion = total - cashPortion;
          await db.into(db.payments).insert(PaymentsCompanion.insert(
              saleId: sale.id, method: 'credit', amountCents: creditPortion));
          await db.into(db.customerCreditEntries).insert(
              CustomerCreditEntriesCompanion.insert(
                  customerId: creditCustomerId,
                  saleId: Value(sale.id),
                  userId: cashierId,
                  amountCents: creditPortion,
                  kind: 'credit_sale'));
        }
        if (session != null && cashPortion > 0) {
          await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: session.id,
              saleId: Value(sale.id),
              amountCents: cashPortion,
              kind: 'cash_sale'));
        }
        await AuthRepository(db).audit(cashierId, 'sale.completed', sale.id);
        if (quotationId != null) {
          final updated = await (db.update(db.quotations)
                ..where(
                    (q) => q.id.equals(quotationId) & q.status.equals('open')))
              .write(QuotationsCompanion(
                  status: const Value('converted'),
                  convertedSaleId: Value(sale.id)));
          if (updated != 1) throw StateError('Quotation already converted');
          await AuthRepository(db).audit(
              cashierId, 'quotation.converted', '$quotationId:${sale.id}');
        }
        if (layawayId != null) {
          final updated = await (db.update(db.layaways)
                ..where(
                    (l) => l.id.equals(layawayId) & l.status.equals('active')))
              .write(LayawaysCompanion(
                  status: const Value('completed'),
                  saleId: Value(sale.id),
                  completedAt: Value(DateTime.now())));
          if (updated != 1) throw StateError('Layaway already completed');
          await AuthRepository(db)
              .audit(cashierId, 'layaway.completed', '$layawayId:${sale.id}');
        }
        return CommittedSale(sale.id, total, invoiceNumber);
      });
    } catch (error) {
      if (reservedSaleId != null && error is! SimulatedComplianceCrash) {
        await protection!.abortSaleAfterRollback(db, reservedSaleId!);
      }
      rethrow;
    }
    if (committed.birInvoiceNumber != null) {
      try {
        await protection!.finalizeSale(committed.saleId);
      } catch (_) {
        return CommittedSale(committed.saleId, committed.totalCents,
            committed.birInvoiceNumber, true);
      }
    }
    return committed;
  }
}
