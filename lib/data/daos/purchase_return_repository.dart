import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'paged_result.dart';
import 'pos_repository.dart';

enum PurchaseReturnReason {
  damaged,
  defective,
  wrongItem,
  excessQuantity,
  incorrectBatch,
  qualityIssue,
  other
}

extension PurchaseReturnReasonLabel on PurchaseReturnReason {
  String get label => switch (this) {
        PurchaseReturnReason.damaged => 'Damaged',
        PurchaseReturnReason.defective => 'Defective',
        PurchaseReturnReason.wrongItem => 'Wrong item',
        PurchaseReturnReason.excessQuantity => 'Excess quantity',
        PurchaseReturnReason.incorrectBatch => 'Incorrect batch',
        PurchaseReturnReason.qualityIssue => 'Quality issue',
        PurchaseReturnReason.other => 'Other',
      };
}

enum PurchaseReturnResolution {
  unresolved,
  supplierCredit,
  replacementExpected,
  replacementReceived
}

extension PurchaseReturnResolutionLabel on PurchaseReturnResolution {
  String get label => switch (this) {
        PurchaseReturnResolution.unresolved => 'Unresolved',
        PurchaseReturnResolution.supplierCredit => 'Supplier credit',
        PurchaseReturnResolution.replacementExpected => 'Replacement expected',
        PurchaseReturnResolution.replacementReceived => 'Replacement received',
      };
}

class PurchaseReturnLineInput {
  final String receivingItemId;
  final int quantityMilli;
  final PurchaseReturnReason reason;
  final String? condition;
  final List<String> serialUnitIds;
  const PurchaseReturnLineInput(
      this.receivingItemId, this.quantityMilli, this.reason,
      {this.condition, this.serialUnitIds = const []});
}

class PurchaseReturnSource {
  final StockReceivingItem item;
  final InventoryLayer layer;
  final Product product;
  final List<SerialUnit> serials;
  const PurchaseReturnSource(this.item, this.layer, this.product, this.serials);
}

class PurchaseReturnRepository {
  final AppDatabase db;
  const PurchaseReturnRepository(this.db);

  static String number(PurchaseReturn row) =>
      'PRT-${row.sequence.toString().padLeft(6, '0')}';

  Future<String> _auditLabel(PurchaseReturn row) async {
    final supplier = await (db.select(db.suppliers)
          ..where((s) => s.id.equals(row.supplierId)))
        .getSingle();
    return '${number(row)}:${supplier.name}';
  }

  Future<List<PurchaseReturnSource>> sources(String receivingId) async {
    final items = await (db.select(db.stockReceivingItems)
          ..where((i) => i.receivingId.equals(receivingId)))
        .get();
    final result = <PurchaseReturnSource>[];
    for (final item in items) {
      final layer = await (db.select(db.inventoryLayers)
            ..where((l) => l.receivingItemId.equals(item.id)))
          .getSingleOrNull();
      final product = await (db.select(db.products)
            ..where((p) => p.id.equals(item.productId)))
          .getSingleOrNull();
      if (layer == null || product == null) continue;
      final serials = await (db.select(db.serialUnits)
            ..where((s) =>
                s.inventoryLayerId.equals(layer.id) &
                s.status.equals('available')))
          .get();
      result.add(PurchaseReturnSource(item, layer, product, serials));
    }
    return result;
  }

  Future<PurchaseReturn> createDraft(ActiveUser actor, String receivingId,
          List<PurchaseReturnLineInput> lines,
          {String? notes,
          String? supplierReturnReference,
          PurchaseReturnResolution resolution =
              PurchaseReturnResolution.unresolved,
          String? existingId}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final receipt = await (db.select(db.stockReceivings)
              ..where((r) => r.id.equals(receivingId)))
            .getSingle();
        if (lines.isEmpty) {
          throw StateError('Select at least one received item');
        }
        if (resolution == PurchaseReturnResolution.replacementReceived) {
          throw StateError('Link a replacement receiving after finalization');
        }
        final sourceRows = {
          for (final source in await sources(receivingId))
            source.item.id: source
        };
        final seenItems = <String>{};
        final seenSerials = <String>{};
        final units = <String, String>{};
        for (final line in lines) {
          final source = sourceRows[line.receivingItemId];
          if (source == null || !seenItems.add(line.receivingItemId)) {
            throw StateError('Select each item from this receiving once');
          }
          final config = await BusinessFeatureRepository(db)
              .businessProduct(source.product.id);
          units[line.receivingItemId] = config.unit.label;
          if (line.quantityMilli > source.layer.quantityRemainingMilli) {
            throw StateError(
                'Only ${Quantity.format(source.layer.quantityRemainingMilli)} units remain available from this receiving layer.');
          }
          if (line.quantityMilli <= 0 ||
              (!config.fractional &&
                  line.quantityMilli % Quantity.scale != 0)) {
            throw StateError('Invalid return quantity');
          }
          if (source.product.serialTracking) {
            if (line.quantityMilli !=
                    line.serialUnitIds.length * Quantity.scale ||
                line.serialUnitIds.any((id) =>
                    !seenSerials.add(id) ||
                    !source.serials.any((s) => s.id == id))) {
              throw StateError(
                  'Select available serials from the source receiving');
            }
          } else if (line.serialUnitIds.isNotEmpty) {
            throw StateError('This product does not use serials');
          }
        }
        late final PurchaseReturn row;
        if (existingId == null) {
          final next = (await db
                  .customSelect(
                      'SELECT COALESCE(MAX(sequence), 0) + 1 AS next FROM purchase_returns')
                  .getSingle())
              .read<int>('next');
          row = await db.into(db.purchaseReturns).insertReturning(
              PurchaseReturnsCompanion.insert(
                  sequence: next,
                  supplierId: receipt.supplierId,
                  receivingId: receipt.id,
                  purchaseOrderId: Value(receipt.purchaseOrderId),
                  returnDate: DateTime.now(),
                  notes: Value(notes),
                  supplierReturnReference: Value(supplierReturnReference),
                  resolution: Value(resolution.name),
                  createdBy: live.id));
        } else {
          row = await (db.select(db.purchaseReturns)
                ..where((r) => r.id.equals(existingId)))
              .getSingle();
          if (row.status != 'draft' || row.receivingId != receivingId) {
            throw StateError(
                'Only a draft from the same receiving can be edited');
          }
          await (db.delete(db.purchaseReturnLines)
                ..where((l) => l.purchaseReturnId.equals(existingId)))
              .go();
          await (db.update(db.purchaseReturns)
                ..where((r) => r.id.equals(existingId)))
              .write(PurchaseReturnsCompanion(
                  notes: Value(notes),
                  supplierReturnReference: Value(supplierReturnReference),
                  resolution: Value(resolution.name)));
        }
        for (final line in lines) {
          final source = sourceRows[line.receivingItemId]!;
          final selected = source.product.serialTracking
              ? line.serialUnitIds
              : <String?>[null];
          for (final serialId in selected) {
            final serial =
                source.serials.where((s) => s.id == serialId).firstOrNull;
            final qty = serialId == null ? line.quantityMilli : Quantity.scale;
            await db.into(db.purchaseReturnLines).insert(
                PurchaseReturnLinesCompanion.insert(
                    purchaseReturnId: row.id,
                    productId: source.product.id,
                    receivingItemId: source.item.id,
                    inventoryLayerId: source.layer.id,
                    serialUnitId: Value(serialId),
                    quantityMilli: qty,
                    unit: Value(units[line.receivingItemId]!),
                    unitCostCents: source.layer.unitCostCents,
                    returnValueCents:
                        Quantity.lineCents(source.layer.unitCostCents, qty),
                    batchNumber: Value(source.layer.batchNumber),
                    serialNumber: Value(serial?.serialNumber),
                    reason: line.reason.name,
                    condition: Value(line.condition)));
          }
        }
        await AuthRepository(db).audit(
            live.id,
            existingId == null
                ? 'purchase_return.created'
                : 'purchase_return.edited',
            await _auditLabel(row));
        return row;
      });

  Future<void> finalize(ActiveUser actor, String id) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.finalizePurchaseReturn);
        final row = await (db.select(db.purchaseReturns)
              ..where((r) => r.id.equals(id)))
            .getSingle();
        if (row.status != 'draft') {
          throw StateError('Only a draft can be finalized');
        }
        final lines = await (db.select(db.purchaseReturnLines)
              ..where((l) => l.purchaseReturnId.equals(id)))
            .get();
        if (lines.isEmpty) throw StateError('Return has no items');
        final byLayer = <String, int>{};
        final byProduct = <String, int>{};
        final byBatch = <String, int>{};
        for (final line in lines) {
          byLayer.update(line.inventoryLayerId, (n) => n + line.quantityMilli,
              ifAbsent: () => line.quantityMilli);
          byProduct.update(line.productId, (n) => n + line.quantityMilli,
              ifAbsent: () => line.quantityMilli);
          if (line.batchNumber != null) {
            final key = '${line.productId}:${line.batchNumber}';
            byBatch.update(key, (n) => n + line.quantityMilli,
                ifAbsent: () => line.quantityMilli);
          }
          if (line.serialUnitId != null) {
            final serial = await (db.select(db.serialUnits)
                  ..where((s) => s.id.equals(line.serialUnitId!)))
                .getSingleOrNull();
            if (serial == null ||
                serial.status != 'available' ||
                serial.inventoryLayerId != line.inventoryLayerId ||
                serial.receivingItemId != line.receivingItemId) {
              throw StateError('A selected serial is no longer available');
            }
          }
        }
        for (final entry in byLayer.entries) {
          final layer = await (db.select(db.inventoryLayers)
                ..where((l) => l.id.equals(entry.key)))
              .getSingle();
          if (entry.value > layer.quantityRemainingMilli) {
            throw StateError(
                'Only ${Quantity.format(layer.quantityRemainingMilli)} units remain available from this receiving layer.');
          }
          final changed = await (db.update(db.inventoryLayers)
                ..where((l) =>
                    l.id.equals(entry.key) &
                    l.quantityRemainingMilli.isBiggerOrEqualValue(entry.value)))
              .write(InventoryLayersCompanion(
                  quantityRemainingMilli:
                      Value(layer.quantityRemainingMilli - entry.value)));
          if (changed != 1) throw StateError('Source layer stock changed');
        }
        for (final entry in byProduct.entries) {
          final stock = await (db.select(db.inventory)
                ..where((i) => i.productId.equals(entry.key)))
              .getSingle();
          final reserved = await PosRepository(db).reservedStockMilli(entry.key);
          if (stock.quantityMilli - entry.value < reserved) {
            throw StateError('Purchase return would reduce stock below active reservations');
          }
          await (db.update(db.inventory)
                ..where((i) => i.productId.equals(entry.key)))
              .write(InventoryCompanion(
                  quantityMilli: Value(stock.quantityMilli - entry.value),
                  quantity: Value(
                      (stock.quantityMilli - entry.value) ~/ Quantity.scale)));
        }
        for (final entry in byBatch.entries) {
          final split = entry.key.split(':');
          final lot = await (db.select(db.productLots)
                ..where((l) =>
                    l.productId.equals(split.first) &
                    l.batchNumber.equals(split.sublist(1).join(':'))))
              .getSingle();
          if (lot.quantityMilli < entry.value) {
            throw StateError('Batch stock changed');
          }
          await (db.update(db.productLots)..where((l) => l.id.equals(lot.id)))
              .write(ProductLotsCompanion(
                  quantityMilli: Value(lot.quantityMilli - entry.value)));
        }
        for (final line in lines) {
          if (line.serialUnitId != null) {
            final changed = await (db.update(db.serialUnits)
                  ..where((s) =>
                      s.id.equals(line.serialUnitId!) &
                      s.status.equals('available')))
                .write(const SerialUnitsCompanion(
                    status: Value('supplier_returned')));
            if (changed != 1) throw StateError('Serial stock changed');
          }
          await db.into(db.inventoryMovements).insert(
              InventoryMovementsCompanion.insert(
                  productId: line.productId,
                  quantityDelta: -(line.quantityMilli ~/ Quantity.scale),
                  quantityDeltaMilli: Value(-line.quantityMilli),
                  reason: 'purchase_return',
                  referenceId: Value(row.id),
                  inventoryLayerId: Value(line.inventoryLayerId)));
        }
        await (db.update(db.purchaseReturns)..where((r) => r.id.equals(id)))
            .write(PurchaseReturnsCompanion(
                status: const Value('finalized'),
                finalizedBy: Value(live.id),
                finalizedAt: Value(DateTime.now())));
        await AuthRepository(db).audit(
            live.id, 'purchase_return.finalized', await _auditLabel(row));
      });

  Future<void> cancel(ActiveUser actor, String id) => db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final row = await (db.select(db.purchaseReturns)
              ..where((r) => r.id.equals(id)))
            .getSingle();
        if (row.status != 'draft') {
          throw StateError('Only a draft can be cancelled');
        }
        await (db.update(db.purchaseReturns)..where((r) => r.id.equals(id)))
            .write(const PurchaseReturnsCompanion(status: Value('cancelled')));
        await AuthRepository(db).audit(
            live.id, 'purchase_return.cancelled', await _auditLabel(row));
      });

  Future<void> setResolution(
          ActiveUser actor, String id, PurchaseReturnResolution resolution,
          {String? creditReference,
          int? creditAmountCents,
          String? replacementReceivingId}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.stockReceiving);
        final row = await (db.select(db.purchaseReturns)
              ..where((r) => r.id.equals(id)))
            .getSingle();
        if (row.status != 'finalized') {
          throw StateError('Finalize the return first');
        }
        if (creditAmountCents != null && creditAmountCents < 0) {
          throw StateError('Invalid credit amount');
        }
        if (resolution != PurchaseReturnResolution.supplierCredit &&
            (creditReference != null || creditAmountCents != null)) {
          throw StateError('Credit details require supplier credit resolution');
        }
        if (resolution != PurchaseReturnResolution.replacementReceived &&
            replacementReceivingId != null) {
          throw StateError('Replacement link requires received resolution');
        }
        if (resolution == PurchaseReturnResolution.replacementReceived) {
          if (replacementReceivingId == null) {
            throw StateError('Select a replacement receiving');
          }
          final receipt = await (db.select(db.stockReceivings)
                ..where((r) => r.id.equals(replacementReceivingId)))
              .getSingle();
          if (receipt.supplierId != row.supplierId ||
              receipt.id == row.receivingId ||
              receipt.receivedAt.isBefore(row.returnDate)) {
            throw StateError('Select a later receiving from this supplier');
          }
        }
        await (db.update(db.purchaseReturns)..where((r) => r.id.equals(id)))
            .write(PurchaseReturnsCompanion(
                resolution: Value(resolution.name),
                creditReference: Value(creditReference),
                creditAmountCents: Value(creditAmountCents),
                replacementReceivingId: Value(replacementReceivingId)));
        await AuthRepository(db).audit(
            live.id,
            resolution == PurchaseReturnResolution.replacementReceived
                ? 'purchase_return.replacement_linked'
                : 'purchase_return.resolution_changed',
            await _auditLabel(row));
      });

  Future<PagedResult<PurchaseReturn>> page(
      {int page = 0,
      String search = '',
      String status = 'All',
      String resolution = 'All',
      String? supplierId,
      DateTime? from,
      DateTime? through}) async {
    final terms = <String>[];
    final args = <Variable>[];
    if (search.trim().isNotEmpty) {
      terms.add('''(instr(lower(printf('PRT-%06d', r.sequence)), ?) > 0 OR
        instr(lower(s.name), ?) > 0 OR instr(lower(COALESCE(r.supplier_return_reference, '')), ?) > 0 OR
        instr(lower(printf('RCV-%06d', COALESCE(rcv.sequence, 0))), ?) > 0 OR
        instr(lower(printf('PO-%06d', COALESCE(po.sequence, 0))), ?) > 0 OR
        EXISTS (SELECT 1 FROM purchase_return_lines l JOIN products p ON p.id = l.product_id
          WHERE l.purchase_return_id = r.id AND instr(lower(p.name), ?) > 0))''');
      args.addAll(List.generate(
          6, (_) => Variable.withString(search.trim().toLowerCase())));
    }
    if (status != 'All') {
      terms.add('r.status = ?');
      args.add(Variable.withString(status));
    }
    if (resolution != 'All') {
      terms.add('r.resolution = ?');
      args.add(Variable.withString(resolution));
    }
    if (supplierId != null) {
      terms.add('r.supplier_id = ?');
      args.add(Variable.withString(supplierId));
    }
    if (from != null) {
      terms.add('r.return_date >= ?');
      args.add(Variable.withInt(
          DateTime(from.year, from.month, from.day).millisecondsSinceEpoch ~/
              1000));
    }
    if (through != null) {
      terms.add('r.return_date < ?');
      args.add(Variable.withInt(
          DateTime(through.year, through.month, through.day + 1)
                  .millisecondsSinceEpoch ~/
              1000));
    }
    final where = terms.isEmpty ? '' : 'WHERE ${terms.join(' AND ')}';
    final joins =
        'FROM purchase_returns r JOIN suppliers s ON s.id = r.supplier_id '
        'JOIN stock_receivings rcv ON rcv.id = r.receiving_id '
        'LEFT JOIN purchase_orders po ON po.id = r.purchase_order_id';
    final count = (await db
            .customSelect('SELECT COUNT(*) AS n $joins $where', variables: args)
            .getSingle())
        .read<int>('n');
    final ids = (await db.customSelect(
            'SELECT r.id $joins $where ORDER BY r.return_date DESC, r.id DESC LIMIT 50 OFFSET ?',
            variables: [...args, Variable.withInt(page * 50)]).get())
        .map((r) => r.read<String>('id'))
        .toList();
    final rows = ids.isEmpty
        ? <PurchaseReturn>[]
        : await (db.select(db.purchaseReturns)..where((r) => r.id.isIn(ids)))
            .get();
    final map = {for (final row in rows) row.id: row};
    return PagedResult(
        items: [for (final id in ids) map[id]!], totalCount: count, page: page);
  }

  Future<List<PurchaseReturnLine>> lines(String id) =>
      (db.select(db.purchaseReturnLines)
            ..where((l) => l.purchaseReturnId.equals(id)))
          .get();

  Future<List<PurchaseReturn>> forReceiving(String id) =>
      (db.select(db.purchaseReturns)..where((r) => r.receivingId.equals(id)))
          .get();

  Future<List<PurchaseReturn>> forPurchaseOrder(String id) =>
      (db.select(db.purchaseReturns)
            ..where((r) => r.purchaseOrderId.equals(id)))
          .get();

  Future<Map<String, ({int items, int valueCents})>> summaries(
      Iterable<String> ids) async {
    final keys = ids.toList();
    if (keys.isEmpty) return {};
    final rows = await db.customSelect('''SELECT purchase_return_id,
      COUNT(*) AS items, SUM(return_value_cents) AS value_cents
      FROM purchase_return_lines
      WHERE purchase_return_id IN (${List.filled(keys.length, '?').join(',')})
      GROUP BY purchase_return_id''',
        variables: keys.map(Variable.withString).toList()).get();
    return {
      for (final row in rows)
        row.read<String>('purchase_return_id'): (
          items: row.read<int>('items'),
          valueCents: row.read<int>('value_cents')
        )
    };
  }

  Future<({int draft, int finalized, int unresolved, int replacementExpected})>
      metrics() async {
    final row = await db.customSelect('''SELECT
      SUM(CASE WHEN status = 'draft' THEN 1 ELSE 0 END) AS draft,
      SUM(CASE WHEN status = 'finalized' THEN 1 ELSE 0 END) AS finalized,
      SUM(CASE WHEN status = 'finalized' AND resolution = 'unresolved' THEN 1 ELSE 0 END) AS unresolved,
      SUM(CASE WHEN status = 'finalized' AND resolution = 'replacementExpected' THEN 1 ELSE 0 END) AS replacement_expected
      FROM purchase_returns''').getSingle();
    return (
      draft: row.read<int?>('draft') ?? 0,
      finalized: row.read<int?>('finalized') ?? 0,
      unresolved: row.read<int?>('unresolved') ?? 0,
      replacementExpected: row.read<int?>('replacement_expected') ?? 0
    );
  }
}
