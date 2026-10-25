import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'pos_repository.dart';
import 'sales_order_repository.dart';

typedef ReservationStock = ({int onHand, int reserved, int available});

class StockReservationRepository {
  const StockReservationRepository(this.db);
  final AppDatabase db;

  Future<Map<String, int>> activeByProduct() async {
    final rows = await db.customSelect('''
      SELECT product_id, SUM(quantity_milli) AS reserved
      FROM stock_reservations WHERE status = 'active'
      GROUP BY product_id
    ''').get();
    return {for (final row in rows)
      row.read<String>('product_id'): row.read<int>('reserved')};
  }

  Future<int> activeForProduct(String productId) async {
    final row = await db.customSelect('''
      SELECT COALESCE(SUM(quantity_milli), 0) AS reserved
      FROM stock_reservations WHERE product_id = ? AND status = 'active'
    ''', variables: [Variable.withString(productId)]).getSingle();
    return row.read<int>('reserved');
  }

  Future<Map<String, int>> activeByLine(String orderId) async {
    final rows = await db.customSelect('''
      SELECT sales_order_line_id, SUM(quantity_milli) AS reserved
      FROM stock_reservations
      WHERE sales_order_id = ? AND status = 'active'
      GROUP BY sales_order_line_id
    ''', variables: [Variable.withString(orderId)]).get();
    return {for (final row in rows)
      row.read<String>('sales_order_line_id'): row.read<int>('reserved')};
  }

  Future<List<StockReservation>> forOrder(String orderId) =>
      (db.select(db.stockReservations)
        ..where((r) => r.salesOrderId.equals(orderId))
        ..orderBy([(r) => OrderingTerm(expression: r.createdAt,
            mode: OrderingMode.desc)])).get();

  Future<ReservationStock> stock(String productId) async {
    final pos = PosRepository(db);
    final onHand = await pos.stockMilli(productId);
    final reserved = await pos.reservedStockMilli(productId);
    return (onHand: onHand, reserved: reserved,
        available: onHand - reserved);
  }

  /// The caller supplies the exact quantity after seeing availability. A
  /// smaller quantity is an explicit partial reservation.
  Future<StockReservation> reserve(ActiveUser actor, String orderLineId,
      int quantityMilli) => db.transaction(() async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageStockReservations);
    if (quantityMilli <= 0) throw StateError('Enter a positive quantity');
    final line = await (db.select(db.salesOrderLines)
      ..where((l) => l.id.equals(orderLineId))).getSingleOrNull();
    if (line == null || line.productId == null) {
      throw StateError('Choose a linked Sales Order product');
    }
    final order = await (db.select(db.salesOrders)
      ..where((o) => o.id.equals(line.salesOrderId))).getSingle();
    if (order.status != 'confirmed') {
      throw StateError('Only confirmed Sales Orders can reserve stock');
    }
    final already = (await activeByLine(order.id))[line.id] ?? 0;
    final fulfilled = (await SalesOrderRepository(db)
        .fulfilledByLine(order.id))[line.id] ?? 0;
    final unreserved = line.quantityMilli - fulfilled - already;
    if (unreserved <= 0 || quantityMilli > unreserved) {
      throw StateError('Only ${Quantity.format(unreserved)} remains unreserved');
    }
    final product = await (db.select(db.products)
      ..where((p) => p.id.equals(line.productId!))).getSingleOrNull();
    if (product == null || !product.isActive) {
      throw StateError('Product is unavailable');
    }
    final levels = await stock(product.id);
    if (quantityMilli > levels.available) {
      throw StateError('Requested ${Quantity.format(quantityMilli)}, '
          'available ${Quantity.format(levels.available)}, '
          'shortfall ${Quantity.format(quantityMilli - levels.available)}');
    }
    final next = (await db.customSelect(
      "SELECT COALESCE(MAX(CAST(SUBSTR(reference, 5) AS INTEGER)), 0) + 1 AS n FROM stock_reservations"
    ).getSingle()).read<int>('n');
    final row = await db.into(db.stockReservations).insertReturning(
      StockReservationsCompanion.insert(
        reference: 'RSV-${next.toString().padLeft(6, '0')}',
        salesOrderId: order.id,
        salesOrderLineId: line.id,
        sourceReference: order.reference,
        productId: product.id,
        quantityMilli: quantityMilli,
        createdBy: live.id));
    await AuthRepository(db).audit(live.id, 'stock_reservation.created',
        '${order.reference}:${product.id}:${Quantity.format(quantityMilli)}');
    return row;
  });

  Future<void> release(ActiveUser actor, String reservationId,
      {String? reason}) => db.transaction(() async {
    final live = await AuthRepository(db).requireActive(actor.id);
    live.require(PosPermission.manageStockReservations);
    final row = await (db.select(db.stockReservations)
      ..where((r) => r.id.equals(reservationId))).getSingleOrNull();
    if (row == null || row.status != 'active') {
      throw StateError('Only an active reservation can be released');
    }
    await (db.update(db.stockReservations)
      ..where((r) => r.id.equals(reservationId) &
          r.status.equals('active'))).write(StockReservationsCompanion(
        status: const Value('released'),
        releasedBy: Value(live.id),
        releasedAt: Value(DateTime.now()),
        releaseReason: Value(reason?.trim())));
    await AuthRepository(db).audit(live.id, 'stock_reservation.released',
        '${row.sourceReference}:${row.productId}:${Quantity.format(row.quantityMilli)}:${reason ?? ''}');
  });
}
