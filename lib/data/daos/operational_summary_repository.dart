import '../../core/models/quantity.dart';
import '../../core/models/product.dart';
import '../database.dart';
import 'inventory_health_repository.dart';
import 'pos_repository.dart';

class StockAlert {
  final String productId;
  final String name;
  final int availableMilli;
  final int physicalMilli;
  final String unit;
  final int threshold;
  const StockAlert(this.productId, this.name, this.availableMilli,
      this.physicalMilli, this.unit, this.threshold);
}

class StockAlertSummary {
  final List<StockAlert> low, out;
  const StockAlertSummary(this.low, this.out);
}

class OperationalSummary {
  final List<StockAlert> lowStockAlerts;
  final List<StockAlert> outOfStockAlerts;
  final List<String> lowStock;
  final List<String> outOfStock;
  final List<String> expiredBatches;
  final List<String> expiringBatches;
  final List<(String, int)> outstandingCredit;
  final int pendingMadeOrders;
  final List<(String, int)> refundsDue;
  final int openRma;
  final int activeLayaway;
  final int openQuotations;
  const OperationalSummary(this.lowStock, this.outOfStock, this.expiredBatches,
      this.expiringBatches, this.outstandingCredit, this.pendingMadeOrders,
      {this.lowStockAlerts = const [],
      this.outOfStockAlerts = const [],
      this.refundsDue = const [],
      this.openRma = 0,
      this.activeLayaway = 0,
      this.openQuotations = 0});
}

class OperationalSummaryRepository {
  final AppDatabase db;
  OperationalSummaryRepository(this.db);

  Future<List<RmaCase>> openCases() async =>
      (await db.select(db.rmaCases).get())
          .where((r) => r.status != 'resolved' && r.status != 'rejected')
          .toList();

  Future<StockAlertSummary> stockAlerts() async =>
      _stockAlerts(await PosRepository(db).products());

  Future<OperationalSummary> load() async {
    final products = await PosRepository(db).products();
    final alerts = await _stockAlerts(products);
    final lowAlerts = alerts.low;
    final outAlerts = alerts.out;
    final low = [for (final a in lowAlerts) _stockLabel(a)];
    final out = [for (final a in outAlerts) _stockLabel(a)];
    final activeLayawayIds = {
      for (final row in await db.select(db.layaways).get())
        if (row.status == 'active') row.id,
    };
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    final nearExpiryDays =
        (await InventoryHealthRepository(db).settings()).nearExpiryDays;
    final soon = day.add(Duration(days: nearExpiryDays));
    final names = {for (final p in products) p.id: p.name};
    final expired = <String>[];
    final expiring = <String>[];
    for (final lot in await db.select(db.productLots).get()) {
      if (lot.quantityMilli <= 0 || lot.expiryDate == null) continue;
      final label =
          '${names[lot.productId] ?? 'Product'} · ${lot.batchNumber} · ${Quantity.format(lot.quantityMilli)}';
      if (lot.expiryDate!.isBefore(day)) {
        expired.add(label);
      } else if (!lot.expiryDate!.isAfter(soon)) {
        expiring.add(label);
      }
    }
    final owed = <(String, int)>[];
    final customers = await db.select(db.customers).get();
    final customerNames = {for (final c in customers) c.id: c.name};
    final creditBalances = <String, int>{};
    for (final entry in await db.select(db.customerCreditEntries).get()) {
      creditBalances.update(entry.customerId, (n) => n + entry.amountCents,
          ifAbsent: () => entry.amountCents);
    }
    for (final customer in customers) {
      final balance = creditBalances[customer.id] ?? 0;
      if (balance > 0) owed.add((customer.name, balance));
    }
    final pending = (await db.select(db.madeOrders).get())
        .where((o) => o.status != 'completed' && o.status != 'cancelled')
        .length;
    final refunds = <(String, int)>[];
    for (final obligation
        in await db.select(db.customerRefundObligations).get()) {
      final due = obligation.amountCents - obligation.settledCents;
      if (due <= 0) continue;
      refunds.add((customerNames[obligation.customerId]!, due));
    }
    final openRma = (await db.select(db.rmaCases).get())
        .where((r) => r.status != 'resolved' && r.status != 'rejected')
        .length;
    final activeLayaway = activeLayawayIds.length;
    final openQuotations = (await db.select(db.quotations).get())
        .where((q) =>
            q.status == 'open' &&
            (q.validUntil == null || !q.validUntil!.isBefore(DateTime.now())))
        .length;
    return OperationalSummary(low, out, expired, expiring, owed, pending,
        lowStockAlerts: lowAlerts,
        outOfStockAlerts: outAlerts,
        refundsDue: refunds,
        openRma: openRma,
        activeLayaway: activeLayaway,
        openQuotations: openQuotations);
  }

  String _stockLabel(StockAlert a) =>
      '${a.name}: ${Quantity.format(a.availableMilli)} available / ${Quantity.format(a.physicalMilli)} physical ${a.unit}';

  Future<StockAlertSummary> _stockAlerts(List<PosProduct> products) async {
    final stockRows = await db.select(db.inventory).get();
    final byProduct = {
      for (final row in stockRows) row.productId: row.quantityMilli
    };
    final reservations = <String, int>{};
    for (final serial in await db.select(db.serialUnits).get()) {
      if (serial.status == 'rma_reserved') {
        reservations.update(serial.productId, (n) => n + Quantity.scale,
            ifAbsent: () => Quantity.scale);
      }
    }
    final layaways = await db.select(db.layaways).get();
    final activeLayawayIds = {
      for (final row in layaways)
        if (row.status == 'active') row.id,
    };
    for (final item in await db.select(db.layawayItems).get()) {
      if (activeLayawayIds.contains(item.layawayId)) {
        reservations.update(item.productId, (n) => n + item.quantityMilli,
            ifAbsent: () => item.quantityMilli);
      }
    }
    final orderReservations = await db.customSelect('''
      SELECT product_id, SUM(quantity_milli) AS quantity
      FROM stock_reservations WHERE status = 'active'
      GROUP BY product_id
    ''').get();
    for (final row in orderReservations) {
      final productId = row.read<String>('product_id');
      final quantity = row.read<int>('quantity');
      reservations.update(productId, (n) => n + quantity,
          ifAbsent: () => quantity);
    }
    final lowAlerts = <StockAlert>[];
    final outAlerts = <StockAlert>[];
    for (final product
        in products.where((p) => p.isActive && !p.business.madeToOrder)) {
      final amount = byProduct[product.id] ?? 0;
      final available = amount - (reservations[product.id] ?? 0);
      final alert = StockAlert(product.id, product.name, available, amount,
          product.business.unit.label, product.lowStockThreshold);
      if (available <= 0) {
        outAlerts.add(alert);
      } else if (available <= product.lowStockThreshold * Quantity.scale) {
        lowAlerts.add(alert);
      }
    }
    return StockAlertSummary(lowAlerts, outAlerts);
  }
}
