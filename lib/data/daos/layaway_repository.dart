import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'business_feature_repository.dart';
import 'pos_repository.dart';

class LayawayLineRequest {
  final String productId;
  final int quantityMilli;
  final List<String> serialIds;
  const LayawayLineRequest(this.productId, this.quantityMilli,
      {this.serialIds = const []});
}

class LayawayRepository {
  final AppDatabase db;
  final PosRepository pos;
  LayawayRepository(this.db, this.pos);

  Future<List<Layaway>> history() => (db.select(db.layaways)
        ..orderBy([
          (l) => OrderingTerm(expression: l.createdAt, mode: OrderingMode.desc)
        ]))
      .get();
  Future<List<LayawayItem>> items(String id) =>
      (db.select(db.layawayItems)..where((i) => i.layawayId.equals(id))).get();
  Future<List<LayawayPayment>> payments(String id) =>
      (db.select(db.layawayPayments)..where((p) => p.layawayId.equals(id)))
          .get();

  Future<int> balance(String id) async {
    final layaway = await (db.select(db.layaways)
          ..where((l) => l.id.equals(id)))
        .getSingle();
    return layaway.totalCents -
        (await payments(id)).fold<int>(0, (sum, row) => sum + row.amountCents);
  }

  Future<Layaway> create(ActiveUser actor, String customerId,
          List<LayawayLineRequest> lines, int depositCents, String method) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageLayaway);
        final customer = await (db.select(db.customers)
              ..where((c) => c.id.equals(customerId)))
            .getSingleOrNull();
        if (customer == null || !customer.isActive) {
          throw StateError('Select an active customer');
        }
        if (lines.isEmpty ||
            lines.map((l) => l.productId).toSet().length != lines.length) {
          throw StateError('Add unique layaway items');
        }
        var total = 0;
        final resolved = <(LayawayLineRequest, Product, String, int)>[];
        for (final line in lines) {
          final product = await (db.select(db.products)
                ..where((p) => p.id.equals(line.productId)))
              .getSingleOrNull();
          if (product == null || !product.isActive || line.quantityMilli <= 0) {
            throw StateError('Layaway product is invalid');
          }
          final config =
              await BusinessFeatureRepository(db).businessProduct(product.id);
          if (config.madeToOrder ||
              config.tank ||
              config.refill ||
              (!config.fractional &&
                  line.quantityMilli % Quantity.scale != 0)) {
            throw StateError('Product needs a different checkout flow');
          }
          if (await pos.stockMilli(product.id) -
                  await pos.reservedStockMilli(product.id) <
              line.quantityMilli) {
            throw StateError('Insufficient available stock');
          }
          if (product.serialTracking) {
            if (line.serialIds.length != line.quantityMilli ~/ Quantity.scale ||
                line.serialIds.toSet().length != line.serialIds.length) {
              throw StateError('Reserve one serial per unit');
            }
            for (final id in line.serialIds) {
              final serial = await (db.select(db.serialUnits)
                    ..where((s) => s.id.equals(id)))
                  .getSingleOrNull();
              if (serial == null ||
                  serial.productId != product.id ||
                  serial.status != 'available') {
                throw StateError('Serial is unavailable');
              }
            }
          } else if (line.serialIds.isNotEmpty) {
            throw StateError('Product is not serial tracked');
          }
          final lineTotal =
              Quantity.lineCents(product.priceCents, line.quantityMilli);
          total += lineTotal;
          resolved.add((line, product, config.unit.label, lineTotal));
        }
        if (depositCents <= 0 || depositCents > total) {
          throw StateError('Deposit must be within the layaway total');
        }
        final row = await db.into(db.layaways).insertReturning(
            LayawaysCompanion.insert(
                reference:
                    'L-${const Uuid().v4().substring(0, 8).toUpperCase()}',
                customerId: customerId,
                createdBy: live.id,
                totalCents: total));
        for (final (line, product, unit, lineTotal) in resolved) {
          await db.into(db.layawayItems).insert(LayawayItemsCompanion.insert(
              layawayId: row.id,
              productId: product.id,
              quantityMilli: line.quantityMilli,
              unitSnapshot: unit,
              unitPriceCents: product.priceCents,
              lineTotalCents: lineTotal));
          for (final id in line.serialIds) {
            final count = await (db.update(db.serialUnits)
                  ..where(
                      (s) => s.id.equals(id) & s.status.equals('available')))
                .write(const SerialUnitsCompanion(status: Value('reserved')));
            if (count != 1) throw StateError('Serial was reserved');
            await db.into(db.layawaySerials).insert(
                LayawaySerialsCompanion.insert(
                    layawayId: row.id,
                    serialUnitId: id,
                    productId: product.id));
          }
        }
        await _payment(live, row.id, depositCents, method);
        await AuthRepository(db).audit(live.id, 'layaway.created', row.id);
        return row;
      });

  Future<void> payment(
          ActiveUser actor, String id, int amountCents, String method) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageLayaway);
        final row = await (db.select(db.layaways)
              ..where((l) => l.id.equals(id)))
            .getSingleOrNull();
        if (row == null || row.status != 'active') {
          throw StateError('Layaway is not active');
        }
        if (amountCents <= 0 || amountCents > await balance(id)) {
          throw StateError('Payment exceeds layaway balance');
        }
        await _payment(live, id, amountCents, method);
      });

  Future<void> _payment(
      ActiveUser actor, String id, int amountCents, String method) async {
    if (method != 'cash' && method != 'gcash') {
      throw StateError('Choose cash or confirmed GCash');
    }
    CashSession? session;
    if (method == 'cash') {
      session = await (db.select(db.cashSessions)
            ..where((s) => s.closedAt.isNull()))
          .getSingleOrNull();
      if (session == null) throw StateError('Open a cash session first');
    }
    final entry = await db.into(db.layawayPayments).insertReturning(
        LayawayPaymentsCompanion.insert(
            layawayId: id,
            userId: actor.id,
            amountCents: amountCents,
            method: method));
    if (session != null) {
      await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
          sessionId: session.id,
          referenceId: Value(entry.id),
          amountCents: amountCents,
          kind: 'layaway_payment'));
    }
    await AuthRepository(db)
        .audit(actor.id, 'layaway.payment', '${entry.id}:$amountCents:$method');
  }

  Future<void> cancel(ActiveUser actor, String id) => db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageLayaway);
        final row = await (db.select(db.layaways)
              ..where((l) => l.id.equals(id)))
            .getSingleOrNull();
        if (row == null || row.status != 'active') {
          throw StateError('Layaway is not active');
        }
        await (db.update(db.layaways)..where((l) => l.id.equals(id)))
            .write(const LayawaysCompanion(status: Value('cancelled')));
        final serials = await (db.select(db.layawaySerials)
              ..where((s) => s.layawayId.equals(id)))
            .get();
        for (final serial in serials) {
          final updated = await (db.update(db.serialUnits)
                ..where((s) =>
                    s.id.equals(serial.serialUnitId) &
                    s.status.equals('reserved')))
              .write(const SerialUnitsCompanion(status: Value('available')));
          if (updated != 1) throw StateError('Reserved serial changed');
        }
        final paid = (await payments(id))
            .fold<int>(0, (sum, payment) => sum + payment.amountCents);
        if (paid > 0) {
          await db.into(db.customerRefundObligations).insert(
              CustomerRefundObligationsCompanion.insert(
                  customerId: row.customerId,
                  layawayId: Value(id),
                  userId: live.id,
                  amountCents: paid));
        }
        await AuthRepository(db).audit(live.id, 'layaway.cancelled', id);
      });

  Future<CommittedSale> complete(ActiveUser actor, String id,
      {Map<String, String> batchIds = const {}}) async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageLayaway);
    final remaining = await balance(id);
    final reservedItems = await items(id);
    if (reservedItems.isEmpty) throw StateError('Layaway has no items');
    final serialRows = await (db.select(db.layawaySerials)
          ..where((s) => s.layawayId.equals(id)))
        .get();
    return pos.completeCashSale([
      for (final item in reservedItems)
        SaleLineRequest(item.productId, 0,
            quantityMilli: item.quantityMilli,
            batchId: batchIds[item.productId],
            serialIds: [
              for (final serial in serialRows)
                if (serial.productId == item.productId) serial.serialUnitId
            ])
    ], remaining, live.id, layawayId: id);
  }
}
