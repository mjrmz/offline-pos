import '../../core/models/quantity.dart';
import '../database.dart';
import 'customer_credit_repository.dart';
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

  Future<OperationalSummary> load() async {
    final products = await PosRepository(db).products();
    final stockRows = await db.select(db.inventory).get();
    final byProduct = {
      for (final row in stockRows) row.productId: row.quantityMilli
    };
    final lowAlerts = <StockAlert>[];
    final outAlerts = <StockAlert>[];
    final low = <String>[];
    final out = <String>[];
    for (final product
        in products.where((p) => p.isActive && !p.business.madeToOrder)) {
      final amount = byProduct[product.id] ?? 0;
      final available =
          amount - await PosRepository(db).reservedStockMilli(product.id);
      final label =
          '${product.name}: ${Quantity.format(available)} available / ${Quantity.format(amount)} physical ${product.business.unit.label}';
      final alert = StockAlert(product.id, product.name, available, amount,
          product.business.unit.label, product.lowStockThreshold);
      if (available <= 0) {
        out.add(label);
        outAlerts.add(alert);
      } else if (available <= product.lowStockThreshold * Quantity.scale) {
        low.add(label);
        lowAlerts.add(alert);
      }
    }
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    final soon = day.add(const Duration(days: 30));
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
    final credit = CustomerCreditRepository(db);
    for (final customer in await db.select(db.customers).get()) {
      final balance = await credit.balance(customer.id);
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
      final customer = await (db.select(db.customers)
            ..where((c) => c.id.equals(obligation.customerId)))
          .getSingle();
      refunds.add((customer.name, due));
    }
    final openRma = (await db.select(db.rmaCases).get())
        .where((r) => r.status != 'resolved' && r.status != 'rejected')
        .length;
    final activeLayaway = (await db.select(db.layaways).get())
        .where((l) => l.status == 'active')
        .length;
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
}
