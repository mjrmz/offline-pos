import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';

class ReceivingLineRequest {
  final String productId;
  final int quantityMilli;
  final int unitCostCents;
  final int? unitSellingPriceCents;
  final String? batchNumber;
  final DateTime? expiryDate;
  final List<String> serialNumbers;
  const ReceivingLineRequest(
      this.productId, this.quantityMilli, this.unitCostCents,
      {this.unitSellingPriceCents, this.batchNumber, this.expiryDate, this.serialNumbers = const []});
}

class StockReceivingRepository {
  final AppDatabase db;
  StockReceivingRepository(this.db);

  Future<List<StockReceiving>> history({String? supplierId}) {
    final query = db.select(db.stockReceivings)
      ..orderBy([
        (r) => OrderingTerm(expression: r.receivedAt, mode: OrderingMode.desc)
      ]);
    if (supplierId != null) {
      query.where((r) => r.supplierId.equals(supplierId));
    }
    return query.get();
  }

  Future<List<StockReceivingItem>> items(String receivingId) =>
      (db.select(db.stockReceivingItems)
            ..where((i) => i.receivingId.equals(receivingId)))
          .get();

  Future<List<SerialUnit>> serialsForItem(String itemId) =>
      (db.select(db.serialUnits)
            ..where((s) => s.receivingItemId.equals(itemId)))
          .get();

  Future<bool> serialNumberExists(String number) async =>
      (await (db.select(db.serialUnits)
            ..where((s) => s.serialNumber.equals(number.trim())))
          .getSingleOrNull()) !=
      null;

  Future<void> correctUnsoldSerial(
          ActiveUser actor, String serialId, String newNumber) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final normalized = newNumber.trim();
        if (normalized.isEmpty) throw StateError('Enter a serial number');
        final row = await (db.select(db.serialUnits)
              ..where((s) => s.id.equals(serialId)))
            .getSingleOrNull();
        if (row == null || row.status != 'available') {
          throw StateError('Only unsold serials can be corrected');
        }
        if ((await (db.select(db.serialSaleLinks)
                  ..where((s) => s.serialUnitId.equals(serialId)))
                .get())
            .isNotEmpty) {
          throw StateError('Historical serial identity cannot be changed');
        }
        await (db.update(db.serialUnits)..where((s) => s.id.equals(serialId)))
            .write(SerialUnitsCompanion(serialNumber: Value(normalized)));
        await AuthRepository(db).audit(live.id, 'serial.corrected',
            '$serialId:${row.serialNumber}:$normalized');
      });

  Future<StockReceiving> receive(
          ActiveUser actor, String supplierId, List<ReceivingLineRequest> lines,
          {String? externalReference, String? notes, DateTime? receivedAt}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        if (lines.isEmpty) throw StateError('Add at least one item');
        final supplier = await (db.select(db.suppliers)
              ..where((s) => s.id.equals(supplierId)))
            .getSingleOrNull();
        if (supplier == null || !supplier.isActive) {
          throw StateError('Select an active supplier');
        }
        final header = await db.into(db.stockReceivings).insertReturning(
            StockReceivingsCompanion.insert(
                supplierId: supplierId,
                userId: live.id,
                receivedAt: Value(receivedAt ?? DateTime.now()),
                externalReference: Value(_clean(externalReference)),
                notes: Value(_clean(notes))));
        for (final line in lines) {
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(line.productId)))
              .getSingleOrNull();
          if (product == null || !product.isActive) {
            throw StateError('Receiving product is inactive or missing');
          }
          if (product.pricingPolicy == 'layer' &&
              line.unitSellingPriceCents == null) {
            throw StateError('Selling price is required for this stock layer');
          }
          final config =
              await BusinessFeatureRepository(db).businessProduct(product.id);
          if (config.madeToOrder) {
            throw StateError(
                'Made-to-order products have no finished stock to receive');
          }
          if (product.serialTracking &&
              (config.fractional || line.quantityMilli % Quantity.scale != 0)) {
            throw StateError('Serialized products require whole units');
          }
          final serials = line.serialNumbers.map((s) => s.trim()).toList();
          if (product.serialTracking) {
            if (serials.length != line.quantityMilli ~/ Quantity.scale ||
                serials.any((s) => s.isEmpty) ||
                serials.toSet().length != serials.length) {
              throw StateError('Enter one unique serial per received unit');
            }
          } else if (serials.isNotEmpty) {
            throw StateError('Serials are not enabled for ${product.name}');
          }
          if (line.quantityMilli <= 0 ||
              line.unitCostCents < 0 ||
              (line.unitSellingPriceCents != null && line.unitSellingPriceCents! < 0) ||
              (!config.fractional &&
                  line.quantityMilli % Quantity.scale != 0)) {
            throw StateError(
                'Invalid receiving quantity or cost for ${product.name}');
          }
          final batchNumber = _clean(line.batchNumber);
          if (config.batch && batchNumber == null) {
            throw StateError('Batch number is required for ${product.name}');
          }
          if (!config.batch &&
              (batchNumber != null || line.expiryDate != null)) {
            throw StateError('Batch data is not enabled for ${product.name}');
          }
          if (line.expiryDate != null) {
            final now = DateTime.now();
            if (line.expiryDate!
                .isBefore(DateTime(now.year, now.month, now.day))) {
              throw StateError('Cannot receive an expired batch');
            }
          }
          final receivedItem = await db
              .into(db.stockReceivingItems)
              .insertReturning(StockReceivingItemsCompanion.insert(
                receivingId: header.id,
                productId: product.id,
                quantityMilli: line.quantityMilli,
                unitCostCents: line.unitCostCents,
                unitSellingPriceCents: Value(line.unitSellingPriceCents),
                batchNumber: Value(batchNumber),
                expiryDate: Value(line.expiryDate),
              ));
          final layer = await db.into(db.inventoryLayers).insertReturning(
              InventoryLayersCompanion.insert(
                productId: product.id,
                receivingItemId: Value(receivedItem.id),
                quantityReceivedMilli: line.quantityMilli,
                quantityRemainingMilli: line.quantityMilli,
                unitCostCents: line.unitCostCents,
                unitSellingPriceCents: Value(line.unitSellingPriceCents),
                batchNumber: Value(batchNumber),
                expiryDate: Value(line.expiryDate),
                receivedAt: Value(header.receivedAt),
              ));
          for (final serial in serials) {
            await db.into(db.serialUnits).insert(SerialUnitsCompanion.insert(
                productId: product.id,
                serialNumber: serial,
                receivingItemId: Value(receivedItem.id),
                inventoryLayerId: Value(layer.id)));
          }
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(product.id)))
              .getSingle();
          final next = stock.quantityMilli + line.quantityMilli;
          await (db.update(db.inventory)
                ..where((i) => i.productId.equals(product.id)))
              .write(InventoryCompanion(
                  quantityMilli: Value(next),
                  quantity: Value(next ~/ Quantity.scale)));
          if (config.batch) {
            final lot = await (db.select(db.productLots)
                  ..where((b) =>
                      b.productId.equals(product.id) &
                      b.batchNumber.equals(batchNumber!)))
                .getSingleOrNull();
            if (lot == null) {
              await db.into(db.productLots).insert(ProductLotsCompanion.insert(
                  productId: product.id,
                  batchNumber: batchNumber!,
                  expiryDate: Value(line.expiryDate),
                  quantityMilli: Value(line.quantityMilli)));
            } else {
              if (lot.expiryDate != line.expiryDate) {
                throw StateError('Existing batch has a different expiry date');
              }
              await (db.update(db.productLots)
                    ..where((b) => b.id.equals(lot.id)))
                  .write(ProductLotsCompanion(
                      quantityMilli:
                          Value(lot.quantityMilli + line.quantityMilli)));
            }
          }
          await db
              .into(db.inventoryMovements)
              .insert(InventoryMovementsCompanion.insert(
                productId: product.id,
                quantityDelta: line.quantityMilli ~/ Quantity.scale,
                quantityDeltaMilli: Value(line.quantityMilli),
                reason: 'supplier_receiving',
                referenceId: Value(header.id),
              ));
        }
        await AuthRepository(db)
            .audit(live.id, 'stock_receiving.finalized', header.id);
        return header;
      });

  String? _clean(String? text) =>
      text == null || text.trim().isEmpty ? null : text.trim();
}
