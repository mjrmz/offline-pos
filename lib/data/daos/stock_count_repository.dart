import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'inventory_layer_repository.dart';
import 'pos_repository.dart';

class AdjustmentRequest {
  final String productId;
  final int deltaMilli;
  final String reason;
  final String? notes;
  final int? unitCostCents;
  final int? unitSellingPriceCents;
  final String? batchNumber;
  final DateTime? expiryDate;
  final List<String> serialNumbers;
  const AdjustmentRequest(this.productId, this.deltaMilli, this.reason,
      {this.notes,
      this.unitCostCents,
      this.unitSellingPriceCents,
      this.batchNumber,
      this.expiryDate,
      this.serialNumbers = const []});
}

class StockCountRepository {
  final AppDatabase db;
  StockCountRepository(this.db);

  Future<void> _requireLinkedAssignee(ActiveUser live, String countId) async {
    final schedule = await (db.select(db.cycleCountSchedules)
          ..where((s) => s.stockCountId.equals(countId)))
        .getSingleOrNull();
    if (schedule != null &&
        schedule.assigneeId != live.id &&
        live.role != UserRole.owner &&
        live.role != UserRole.manager) {
      throw StateError('Count is assigned to another employee');
    }
  }

  Future<String> _reference(String table, String prefix) async {
    final row = await db
        .customSelect(
            "SELECT COALESCE(MAX(CAST(SUBSTR(reference, INSTR(reference, '-') + 1) AS INTEGER)), 0) + 1 AS next FROM $table")
        .getSingle();
    return '$prefix-${row.read<int>('next').toString().padLeft(6, '0')}';
  }

  Future<int> _movementCount(String productId) async => (await db.customSelect(
        'SELECT COUNT(*) AS total FROM inventory_movements WHERE product_id = ?',
        variables: [Variable.withString(productId)],
      ).getSingle())
          .read<int>('total');

  Future<List<StockCount>> counts() => (db.select(db.stockCounts)
        ..orderBy([
          (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)
        ]))
      .get();
  Future<List<InventoryAdjustment>> adjustments() =>
      (db.select(db.inventoryAdjustments)
            ..orderBy([
              (t) =>
                  OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc)
            ]))
          .get();
  Future<List<StockCountLine>> lines(String countId) =>
      (db.select(db.stockCountLines)
            ..where((t) => t.stockCountId.equals(countId)))
          .get();

  Future<StockCount> createCount(ActiveUser actor,
          {String? categoryId, List<String>? productIds, String? notes}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockCount);
        final products = await (db.select(db.products)
              ..where((p) => p.isActive.equals(true) & p.productType.equals('standard')))
            .get();
        final configurations =
            await BusinessFeatureRepository(db).allProductConfigurations();
        final selected = products
            .where((p) =>
                !(configurations[p.id]?.madeToOrder ?? false) &&
                (categoryId == null || p.categoryId == categoryId) &&
                (productIds == null || productIds.contains(p.id)))
            .toList();
        if (selected.isEmpty) {
          throw StateError('No active products in this count');
        }
        final category = categoryId == null
            ? null
            : await (db.select(db.categories)
                  ..where((c) => c.id.equals(categoryId)))
                .getSingleOrNull();
        if (categoryId != null && category == null) {
          throw StateError('Category is unavailable');
        }
        final count = await db
            .into(db.stockCounts)
            .insertReturning(StockCountsCompanion.insert(
                reference: await _reference('stock_counts', 'SC'),
                scope: productIds != null
                    ? 'Selected products (${selected.length})'
                    : categoryId != null
                        ? 'Category: ${category!.name}'
                        : 'All active products',
                notes: Value(notes?.trim()),
                createdBy: live.id));
        for (final product in selected) {
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(product.id)))
              .getSingleOrNull();
          await db.into(db.stockCountLines).insert(
              StockCountLinesCompanion.insert(
                  stockCountId: count.id,
                  productId: product.id,
                  unitLabel: configurations[product.id]?.unit.label ?? 'pcs',
                  expectedMilli: stock?.quantityMilli ?? 0,
                  movementCount: await _movementCount(product.id)));
        }
        await AuthRepository(db)
            .audit(live.id, 'stock_count.created', count.reference);
        return count;
      });

  Future<void> setCount(ActiveUser actor, String lineId, int? countedMilli,
          {String? notes}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockCount);
        if (countedMilli != null && countedMilli < 0) {
          throw StateError('Count cannot be negative');
        }
        final line = await (db.select(db.stockCountLines)
              ..where((l) => l.id.equals(lineId)))
            .getSingle();
        final count = await (db.select(db.stockCounts)
              ..where((c) => c.id.equals(line.stockCountId)))
            .getSingle();
        await _requireLinkedAssignee(live, count.id);
        if (count.status != 'draft') throw StateError('Count is read-only');
        final product = await (db.select(db.products)
              ..where((p) => p.id.equals(line.productId)))
            .getSingle();
        final config =
            await BusinessFeatureRepository(db).businessProduct(product.id);
        if (countedMilli != null &&
            !config.fractional &&
            countedMilli % 1000 != 0) {
          throw StateError('This product requires whole units');
        }
        await (db.update(db.stockCountLines)..where((l) => l.id.equals(lineId)))
            .write(StockCountLinesCompanion(
                countedMilli: Value(countedMilli),
                notes: notes == null
                    ? const Value.absent()
                    : Value(notes.trim())));
        await AuthRepository(db)
            .audit(live.id, 'stock_count.edited', '${count.reference}:$lineId');
      });

  Future<void> refreshLine(ActiveUser actor, String lineId) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockCount);
        final line = await (db.select(db.stockCountLines)
              ..where((l) => l.id.equals(lineId)))
            .getSingle();
        final count = await (db.select(db.stockCounts)
              ..where((c) => c.id.equals(line.stockCountId)))
            .getSingle();
        await _requireLinkedAssignee(live, count.id);
        if (count.status != 'draft') throw StateError('Count is read-only');
        final stock = await (db.select(db.inventory)
              ..where((i) => i.productId.equals(line.productId)))
            .getSingleOrNull();
        await (db.update(db.stockCountLines)..where((l) => l.id.equals(lineId)))
            .write(StockCountLinesCompanion(
                expectedMilli: Value(stock?.quantityMilli ?? 0),
                movementCount: Value(await _movementCount(line.productId)),
                countedMilli: const Value(null)));
        await AuthRepository(db).audit(
            live.id, 'stock_count.refreshed', '${count.reference}:$lineId');
      });

  Future<void> cancel(ActiveUser actor, String id) => db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockCount);
        await _requireLinkedAssignee(live, id);
        final changed = await (db.update(db.stockCounts)
              ..where((c) => c.id.equals(id) & c.status.equals('draft')))
            .write(StockCountsCompanion(
                status: const Value('cancelled'),
                cancelledAt: Value(DateTime.now())));
        if (changed != 1) {
          throw StateError('Only draft counts can be cancelled');
        }
        await AuthRepository(db).audit(live.id, 'stock_count.cancelled', id);
        final linked = await (db.select(db.cycleCountSchedules)
              ..where((s) => s.stockCountId.equals(id)))
            .getSingleOrNull();
        if (linked != null) {
          await (db.update(db.cycleCountSchedules)
                ..where((s) => s.id.equals(linked.id)))
              .write(CycleCountSchedulesCompanion(
                  status: const Value('cancelled'),
                  updatedAt: Value(DateTime.now())));
          await AuthRepository(db)
              .audit(live.id, 'cycle_count.cancelled', linked.id);
        }
      });

  Future<InventoryAdjustment> adjust(
          ActiveUser actor, AdjustmentRequest request) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockAdjust);
        return _post(live, request);
      });

  Future<void> finalize(ActiveUser actor, String id,
          {Map<String, AdjustmentRequest> varianceDetails = const {}}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.finalizeStockCount);
        await _requireLinkedAssignee(live, id);
        final count = await (db.select(db.stockCounts)
              ..where((c) => c.id.equals(id)))
            .getSingle();
        if (count.status != 'draft') {
          throw StateError('Count already finalized or cancelled');
        }
        final countLines = await lines(id);
        if (countLines.every((l) => l.countedMilli == null)) {
          throw StateError('Enter at least one physical count');
        }
        for (final line in countLines.where((l) => l.countedMilli != null)) {
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(line.productId)))
              .getSingleOrNull();
          if ((stock?.quantityMilli ?? 0) != line.expectedMilli ||
              await _movementCount(line.productId) != line.movementCount) {
            throw StateError(
                'Stock changed during count. Refresh and recount affected lines.');
          }
        }
        for (final line in countLines.where((l) => l.countedMilli != null)) {
          final delta = line.countedMilli! - line.expectedMilli;
          if (delta == 0) continue;
          final detail = varianceDetails[line.id];
          await _post(
              live,
              AdjustmentRequest(line.productId, delta, 'Stock count variance',
                  notes: detail?.notes ?? count.notes,
                  unitCostCents: detail?.unitCostCents,
                  unitSellingPriceCents: detail?.unitSellingPriceCents,
                  batchNumber: detail?.batchNumber,
                  expiryDate: detail?.expiryDate,
                  serialNumbers: detail?.serialNumbers ?? const []),
              countLineId: line.id);
        }
        final changed = await (db.update(db.stockCounts)
              ..where((c) => c.id.equals(id) & c.status.equals('draft')))
            .write(StockCountsCompanion(
                status: const Value('finalized'),
                finalizedBy: Value(live.id),
                finalizedAt: Value(DateTime.now())));
        if (changed != 1) throw StateError('Count already finalized');
        await AuthRepository(db)
            .audit(live.id, 'stock_count.finalized', count.reference);
        final linked = await (db.select(db.cycleCountSchedules)
              ..where((s) => s.stockCountId.equals(id)))
            .getSingleOrNull();
        if (linked != null && linked.status != 'completed') {
          await (db.update(db.cycleCountSchedules)
                ..where((s) => s.id.equals(linked.id)))
              .write(CycleCountSchedulesCompanion(
                  status: const Value('completed'),
                  updatedAt: Value(DateTime.now())));
          await AuthRepository(db)
              .audit(live.id, 'cycle_count.completed', linked.id);
        }
      });

  Future<InventoryAdjustment> _post(ActiveUser live, AdjustmentRequest request,
      {String? countLineId}) async {
    const reasons = {
      'Damaged',
      'Expired',
      'Lost',
      'Shrinkage',
      'Stock found',
      'Count correction',
      'Breakage',
      'Other',
      'Stock count variance'
    };
    if (!reasons.contains(request.reason) || request.deltaMilli == 0) {
      throw StateError('Choose a valid reason and non-zero adjustment');
    }
    if (request.reason == 'Other' && (request.notes?.trim().isEmpty ?? true)) {
      throw StateError('Notes are required for Other');
    }
    final product = await (db.select(db.products)
          ..where((p) => p.id.equals(request.productId)))
        .getSingleOrNull();
    if (product == null || !product.isActive) {
      throw StateError('Product is unavailable');
    }
    final config =
        await BusinessFeatureRepository(db).businessProduct(product.id);
    if (config.madeToOrder) {
      throw StateError(
          'Made-to-order products have no finished stock to adjust');
    }
    if (!config.fractional && request.deltaMilli % 1000 != 0) {
      throw StateError('This product requires whole units');
    }
    final stock = await (db.select(db.inventory)
          ..where((i) => i.productId.equals(product.id)))
        .getSingleOrNull();
    final before = stock?.quantityMilli ?? 0;
    final after = before + request.deltaMilli;
    if (after < 0) {
      throw StateError('Adjustment would reduce stock below zero.');
    }
    if (request.deltaMilli < 0 &&
        after < await PosRepository(db).reservedStockMilli(product.id)) {
      throw StateError(
          'Adjustment would reduce stock reserved for an active order.');
    }
    final serials = request.serialNumbers.map((s) => s.trim()).toList();
    if (product.serialTracking &&
        (serials.length != request.deltaMilli.abs() ~/ 1000 ||
            serials.any((s) => s.isEmpty) ||
            serials.toSet().length != serials.length)) {
      throw StateError('Select each exact serial number');
    }
    if (!product.serialTracking && serials.isNotEmpty) {
      throw StateError('Product has no serial tracking');
    }
    if (config.batch && (request.batchNumber?.trim().isEmpty ?? true)) {
      throw StateError('Select the affected batch');
    }
    if (!config.batch && request.batchNumber != null) {
      throw StateError('Product has no batch tracking');
    }
    if (request.deltaMilli > 0 &&
        (request.unitCostCents == null ||
            request.unitCostCents! < 0 ||
            (request.unitSellingPriceCents != null &&
                request.unitSellingPriceCents! < 0) ||
            (product.pricingPolicy == 'layer' &&
                request.unitSellingPriceCents == null))) {
      throw StateError('Confirm unit cost and layer selling price if required');
    }
    final lot = config.batch
        ? await (db.select(db.productLots)
              ..where((l) =>
                  l.productId.equals(product.id) &
                  l.batchNumber.equals(request.batchNumber!)))
            .getSingleOrNull()
        : null;
    if (lot != null &&
        request.expiryDate != null &&
        lot.expiryDate != request.expiryDate) {
      throw StateError('Existing batch has a different expiry date');
    }
    if (config.batch && request.deltaMilli < 0 && lot == null) {
      throw StateError('Batch not found');
    }
    final adjustment = await db.into(db.inventoryAdjustments).insertReturning(
        InventoryAdjustmentsCompanion.insert(
            reference: await _reference('inventory_adjustments', 'ADJ'),
            productId: product.id,
            deltaMilli: request.deltaMilli,
            reason: request.reason,
            notes: Value(request.notes?.trim()),
            createdBy: live.id,
            stockCountLineId: Value(countLineId)));
    if (request.deltaMilli < 0) {
      final selectedSerials = <SerialUnit>[];
      for (final number in serials) {
        final row = await (db.select(db.serialUnits)
              ..where((s) =>
                  s.serialNumber.equals(number) &
                  s.productId.equals(product.id) &
                  s.status.equals('available')))
            .getSingleOrNull();
        if (row == null) throw StateError('Serial is unavailable: $number');
        selectedSerials.add(row);
      }
      final allocations = await InventoryLayerRepository(db).consume(
          product.id, -request.deltaMilli,
          batchNumber: request.batchNumber, serials: selectedSerials);
      for (final part in allocations) {
        await db.into(db.inventoryAdjustmentAllocations).insert(
            InventoryAdjustmentAllocationsCompanion.insert(
                adjustmentId: adjustment.id,
                inventoryLayerId: part.layer.id,
                serialUnitId: Value(part.serialUnitId),
                quantityMilli: part.quantityMilli,
                unitCostCents: part.layer.unitCostCents));
      }
      for (final serial in selectedSerials) {
        await (db.update(db.serialUnits)..where((s) => s.id.equals(serial.id)))
            .write(const SerialUnitsCompanion(status: Value('adjusted_out')));
      }
    } else {
      final layer = await db.into(db.inventoryLayers).insertReturning(
          InventoryLayersCompanion.insert(
              productId: product.id,
              source: const Value('adjustment'),
              quantityReceivedMilli: request.deltaMilli,
              quantityRemainingMilli: request.deltaMilli,
              unitCostCents: request.unitCostCents!,
              unitSellingPriceCents: Value(request.unitSellingPriceCents),
              batchNumber: Value(request.batchNumber),
              expiryDate: Value(request.expiryDate ?? lot?.expiryDate)));
      await db.into(db.inventoryAdjustmentAllocations).insert(
          InventoryAdjustmentAllocationsCompanion.insert(
              adjustmentId: adjustment.id,
              inventoryLayerId: layer.id,
              quantityMilli: request.deltaMilli,
              unitCostCents: request.unitCostCents!));
      for (final number in serials) {
        await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
            productId: product.id,
            serialNumber: number,
            inventoryLayerId: Value(layer.id)));
      }
    }
    if (config.batch) {
      if (lot == null) {
        await db.into(db.productLots).insert(ProductLotsCompanion.insert(
            productId: product.id,
            batchNumber: request.batchNumber!,
            expiryDate: Value(request.expiryDate),
            quantityMilli: Value(request.deltaMilli)));
      } else {
        final next = lot.quantityMilli + request.deltaMilli;
        if (next < 0) throw StateError('Batch would be negative');
        await (db.update(db.productLots)..where((l) => l.id.equals(lot.id)))
            .write(ProductLotsCompanion(quantityMilli: Value(next)));
      }
    }
    if (stock == null) {
      await db.into(db.inventory).insert(InventoryCompanion.insert(
          productId: product.id,
          quantity: Value(after ~/ 1000),
          quantityMilli: Value(after)));
    } else {
      await (db.update(db.inventory)
            ..where((i) => i.productId.equals(product.id)))
          .write(InventoryCompanion(
              quantity: Value(after ~/ 1000), quantityMilli: Value(after)));
    }
    await db
        .into(db.inventoryMovements)
        .insert(InventoryMovementsCompanion.insert(
            productId: product.id,
            quantityDelta: request.deltaMilli ~/ 1000,
            quantityDeltaMilli: Value(request.deltaMilli),
            reason: countLineId != null
                ? 'stock_count_variance'
                : request.deltaMilli > 0
                    ? 'stock_adjustment_increase'
                    : 'stock_adjustment_decrease',
            referenceId: Value(adjustment.id)));
    await AuthRepository(db)
        .audit(live.id, 'inventory_adjustment.posted', adjustment.reference);
    return adjustment;
  }
}
