import 'package:drift/drift.dart';
import '../../core/models/quantity.dart';
import '../database.dart';
import 'business_feature_repository.dart';
import 'pos_repository.dart';

/// Local calendar dates, with an exclusive end. Stored timestamps are unchanged.
class ReportPeriod {
  final DateTime start;
  final DateTime end;
  final String label;
  const ReportPeriod(this.start, this.end, this.label);

  bool contains(DateTime value) {
    final local = value.toLocal();
    return !local.isBefore(start) && local.isBefore(end);
  }

  static ReportPeriod named(String key, DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return switch (key) {
      'Today' => ReportPeriod(day, day.add(const Duration(days: 1)), key),
      'Yesterday' =>
        ReportPeriod(day.subtract(const Duration(days: 1)), day, key),
      'This week' => ReportPeriod(day.subtract(Duration(days: day.weekday - 1)),
          day.add(Duration(days: 8 - day.weekday)), key),
      'This month' => ReportPeriod(DateTime(day.year, day.month),
          DateTime(day.year, day.month + 1), key),
      'Last month' => ReportPeriod(DateTime(day.year, day.month - 1),
          DateTime(day.year, day.month), key),
      _ => throw ArgumentError('Unknown report period'),
    };
  }

  factory ReportPeriod.custom(DateTime first, DateTime last) {
    final start = DateTime(first.year, first.month, first.day);
    final end = DateTime(last.year, last.month, last.day + 1);
    if (!start.isBefore(end)) throw ArgumentError('Invalid date range');
    return ReportPeriod(start, end, 'Custom range');
  }
}

class ReportGroup {
  final String label;
  int quantityMilli = 0;
  int grossCents = 0;
  int refundsCents = 0;
  int cogsCents = 0;
  int transactions = 0;
  String unit = '';
  ReportGroup(this.label);
  int get netCents => grossCents - refundsCents;
  int get profitCents => netCents - cogsCents;
}

class ReportExpense {
  final DateTime date;
  final String category;
  final String payee;
  final String source;
  final String user;
  final int amountCents;
  final bool legacy;
  const ReportExpense(this.date, this.category, this.payee, this.source,
      this.user, this.amountCents,
      {this.legacy = false});
}

class InventoryReportRow {
  final String product;
  final String category;
  final String unit;
  final int quantityMilli;
  final int availableMilli;
  final int thresholdMilli;
  final int? costCents;
  final int? retailCents;
  const InventoryReportRow(
      this.product,
      this.category,
      this.unit,
      this.quantityMilli,
      this.availableMilli,
      this.thresholdMilli,
      this.costCents,
      this.retailCents);
  bool get low => availableMilli <= thresholdMilli;
  bool get out => availableMilli <= 0;
}

class AdjustmentReportGroup {
  final String label;
  final int events;
  final int knownImpactCents;
  final int incompleteEvents;
  const AdjustmentReportGroup(
      this.label, this.events, this.knownImpactCents, this.incompleteEvents);
}

class ManagementReport {
  final ReportPeriod period;
  final int grossSalesCents;
  final int reversalCents;
  final int itemRefundCents;
  final int cogsCents;
  final bool cogsComplete;
  final int incompleteCostItems;
  final int incompleteCostRevenueCents;
  final List<String> incompleteCostItemIds;
  final int transactions;
  final Map<String, ReportGroup> products;
  final Map<String, ReportGroup> categories;
  final Map<String, ReportGroup> cashiers;
  final Map<String, int> payments;
  final Map<DateTime, int> dailySales;
  final Map<DateTime, int> dailyGrossSales;
  final Map<DateTime, int> dailyRefunds;
  final List<ReportExpense> expenses;
  final Map<String, int> expensesByCategory;
  final Map<String, int> expensesBySource;
  final Map<String, int> expensesByUser;
  final Map<String, int> expensesByPayee;
  final List<InventoryReportRow> inventory;
  final List<AdjustmentReportGroup> adjustments;
  const ManagementReport({
    required this.period,
    required this.grossSalesCents,
    required this.reversalCents,
    required this.itemRefundCents,
    required this.cogsCents,
    required this.cogsComplete,
    this.incompleteCostItems = 0,
    this.incompleteCostRevenueCents = 0,
    this.incompleteCostItemIds = const [],
    required this.transactions,
    required this.products,
    required this.categories,
    required this.cashiers,
    required this.payments,
    required this.dailySales,
    this.dailyGrossSales = const {},
    this.dailyRefunds = const {},
    required this.expenses,
    required this.expensesByCategory,
    required this.expensesBySource,
    required this.expensesByUser,
    required this.expensesByPayee,
    required this.inventory,
    required this.adjustments,
  });
  int get refundsCents => reversalCents + itemRefundCents;
  int get netSalesCents => grossSalesCents - refundsCents;
  int get grossProfitCents => netSalesCents - cogsCents;
  int get expenseCents => expenses.fold(0, (sum, row) => sum + row.amountCents);
  Map<DateTime, int> get dailyExpenses {
    final values = <DateTime, int>{};
    for (final row in expenses) {
      final local = row.date.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      values.update(day, (value) => value + row.amountCents,
          ifAbsent: () => row.amountCents);
    }
    return values;
  }

  int get adjustmentImpactCents =>
      adjustments.fold(0, (sum, row) => sum + row.knownImpactCents);
  int get incompleteAdjustmentEvents =>
      adjustments.fold(0, (sum, row) => sum + row.incompleteEvents);
  bool get adjustmentsComplete => incompleteAdjustmentEvents == 0;
  int get operatingProfitCents =>
      grossProfitCents + adjustmentImpactCents - expenseCents;
  int get averageSaleCents =>
      transactions == 0 ? 0 : netSalesCents ~/ transactions;
}

/// Read-only management queries. COGS uses immutable allocation snapshots.
class ManagementReportRepository {
  final AppDatabase db;
  const ManagementReportRepository(this.db);

  static String adjustmentLabel(String reason, int deltaMilli) {
    if (reason == 'Stock count variance') {
      return deltaMilli < 0 ? 'Stock count shortage' : 'Stock count overage';
    }
    const labels = {
      'Damaged': 'Damaged',
      'Expired': 'Expired',
      'Lost': 'Lost',
      'Shrinkage': 'Shrinkage',
      'Stock found': 'Stock found',
      'Count correction': 'Count correction',
      'Breakage': 'Breakage',
      'Other': 'Other',
    };
    return labels[reason] ?? 'Other';
  }

  Future<List<AdjustmentReportGroup>> _adjustments(ReportPeriod period) async {
    // One row per posted adjustment. Allocation costs are immutable snapshots.
    final rows = await db.customSelect('''
      SELECT a.reason, a.delta_milli,
             COALESCE(SUM(x.quantity_milli), 0) AS allocated_milli,
             COALESCE(SUM(CAST((x.quantity_milli * x.unit_cost_cents + 500)
               / 1000 AS INTEGER)), 0) AS cost_cents
      FROM inventory_adjustments a
      LEFT JOIN inventory_adjustment_allocations x ON x.adjustment_id = a.id
      WHERE a.created_at >= ? AND a.created_at < ?
      GROUP BY a.id, a.reason, a.delta_milli
    ''', variables: [
      Variable.withDateTime(period.start),
      Variable.withDateTime(period.end),
    ]).get();
    final groups = <String, (int, int, int)>{};
    for (final row in rows) {
      final delta = row.read<int>('delta_milli');
      final label = adjustmentLabel(row.read<String>('reason'), delta);
      final complete = row.read<int>('allocated_milli') == delta.abs();
      final impact =
          complete ? row.read<int>('cost_cents') * (delta < 0 ? -1 : 1) : 0;
      final old = groups[label] ?? (0, 0, 0);
      groups[label] =
          (old.$1 + 1, old.$2 + impact, old.$3 + (complete ? 0 : 1));
    }
    return [
      for (final entry in groups.entries)
        AdjustmentReportGroup(
            entry.key, entry.value.$1, entry.value.$2, entry.value.$3),
    ]..sort((a, b) => a.label.compareTo(b.label));
  }

  Future<ManagementReport> load(ReportPeriod period) async {
    final periodSales = await (db.select(db.sales)
          ..where((s) =>
              s.createdAt.isBiggerOrEqualValue(period.start) &
              s.createdAt.isSmallerThanValue(period.end)))
        .get();
    final reversals = await (db.select(db.saleReversals)
          ..where((r) =>
              r.createdAt.isBiggerOrEqualValue(period.start) &
              r.createdAt.isSmallerThanValue(period.end)))
        .get();
    final itemRefunds = await (db.select(db.saleItemRefunds)
          ..where((r) =>
              r.createdAt.isBiggerOrEqualValue(period.start) &
              r.createdAt.isSmallerThanValue(period.end)))
        .get();
    final commercialRows = await db.customSelect('''
      SELECT r.id AS return_id, r.original_sale_id, r.created_at,
             r.refund_value_cents, rl.sale_item_id,
             rl.quantity_milli, rl.refund_cents, rl.cost_cents, rl.disposition
      FROM sale_returns r JOIN sale_return_lines rl ON rl.return_id=r.id
      WHERE r.status='finalized' AND r.created_at>=? AND r.created_at<?
      ORDER BY r.created_at, r.id, rl.id''', variables: [
      Variable.withInt(period.start.millisecondsSinceEpoch),
      Variable.withInt(period.end.millisecondsSinceEpoch)
    ]).get();
    final saleIds = <String>{
      ...periodSales.map((s) => s.id),
      ...reversals.map((r) => r.saleId),
      ...itemRefunds.map((r) => r.saleId),
      ...commercialRows.map((r) => r.read<String>('original_sale_id')),
    };
    final sales = saleIds.isEmpty
        ? <Sale>[]
        : await (db.select(db.sales)..where((s) => s.id.isIn(saleIds))).get();
    final saleById = {for (final s in sales) s.id: s};
    final items = saleIds.isEmpty
        ? <SaleItem>[]
        : await (db.select(db.saleItems)..where((i) => i.saleId.isIn(saleIds)))
            .get();
    final itemById = {for (final i in items) i.id: i};
    final itemIds = items.map((i) => i.id).toList();
    final allocations = itemIds.isEmpty
        ? <SaleItemInventoryAllocation>[]
        : await (db.select(db.saleItemInventoryAllocations)
              ..where((a) => a.saleItemId.isIn(itemIds)))
            .get();
    final costs = <String, int>{};
    final allocatedMilli = <String, int>{};
    for (final a in allocations) {
      costs.update(
          a.saleItemId,
          (v) =>
              v + Quantity.lineCents(a.unitCostSnapshotCents, a.quantityMilli),
          ifAbsent: () =>
              Quantity.lineCents(a.unitCostSnapshotCents, a.quantityMilli));
      allocatedMilli.update(a.saleItemId, (v) => v + a.quantityMilli,
          ifAbsent: () => a.quantityMilli);
    }
    final users = await db.select(db.users).get();
    final userNames = {for (final u in users) u.id: u.name};
    final products = await db.select(db.products).get();
    final productConfigs =
        await BusinessFeatureRepository(db).allProductConfigurations();
    final productById = {for (final p in products) p.id: p};
    final categoryRows = await db.select(db.categories).get();
    final categoryNames = {for (final c in categoryRows) c.id: c.name};
    final productGroups = <String, ReportGroup>{};
    final categoryGroups = <String, ReportGroup>{};
    final cashierGroups = <String, ReportGroup>{};
    final daily = <DateTime, int>{};
    final dailyGross = <DateTime, int>{};
    final dailyRefunds = <DateTime, int>{};
    var gross = 0, reversed = 0, refunded = 0, cogs = 0, count = 0;
    var cogsComplete = true;
    final incompleteIds = <String>[];
    var incompleteRevenue = 0;
    final periodIds = periodSales.map((s) => s.id).toSet();

    ReportGroup group(Map<String, ReportGroup> map, String key) =>
        map.putIfAbsent(key, () => ReportGroup(key));
    void applyItem(SaleItem item, Sale sale, int revenue, int cost,
        int quantityMilli, bool original) {
      final product = productById[item.productId];
      final label = item.productName.isNotEmpty
          ? item.productName
          : product?.name ?? 'Legacy product';
      final category = product?.categoryId == null
          ? 'Uncategorized'
          : categoryNames[product!.categoryId] ?? 'Uncategorized';
      final cashier = userNames[sale.cashierId] ?? 'Historical cashier';
      for (final g in [
        group(productGroups, label),
        group(categoryGroups, category),
        group(cashierGroups, cashier),
      ]) {
        g.quantityMilli += quantityMilli;
        if (original) {
          g.grossCents += revenue;
          g.transactions += 1;
        } else {
          g.refundsCents += revenue;
        }
        g.cogsCents += cost;
      }
      group(productGroups, label).unit = item.saleUnit;
    }

    for (final sale in periodSales) {
      gross += sale.totalCents;
      count++;
      final day = DateTime(sale.createdAt.toLocal().year,
          sale.createdAt.toLocal().month, sale.createdAt.toLocal().day);
      daily.update(day, (v) => v + sale.totalCents,
          ifAbsent: () => sale.totalCents);
      dailyGross.update(day, (v) => v + sale.totalCents,
          ifAbsent: () => sale.totalCents);
    }
    for (final item in items) {
      if (!periodIds.contains(item.saleId)) continue;
      final sale = saleById[item.saleId]!;
      final milli = item.quantityMilli == 0
          ? item.quantity * Quantity.scale
          : item.quantityMilli;
      final cost = costs[item.id] ?? 0;
      // Every sold item needs exact persisted cost provenance. Made-to-order
      // sales currently have no allocation, so their cost cannot be inferred.
      if (milli > 0 && allocatedMilli[item.id] != milli) {
        cogsComplete = false;
        incompleteIds.add(item.id);
        incompleteRevenue += item.lineTotalCents;
      }
      cogs += cost;
      applyItem(item, sale, item.lineTotalCents, cost, milli, true);
    }
    for (final reversal in reversals) {
      reversed += reversal.amountCents;
      final sale = saleById[reversal.saleId];
      if (sale == null) continue;
      final day = DateTime(reversal.createdAt.toLocal().year,
          reversal.createdAt.toLocal().month, reversal.createdAt.toLocal().day);
      daily.update(day, (v) => v - reversal.amountCents,
          ifAbsent: () => -reversal.amountCents);
      dailyRefunds.update(day, (v) => v + reversal.amountCents,
          ifAbsent: () => reversal.amountCents);
      for (final item in items.where((i) => i.saleId == sale.id)) {
        final milli = item.quantityMilli == 0
            ? item.quantity * Quantity.scale
            : item.quantityMilli;
        final cost = reversal.stockRestored ? costs[item.id] ?? 0 : 0;
        if (reversal.stockRestored &&
            milli > 0 &&
            allocatedMilli[item.id] != milli) {
          cogsComplete = false;
        }
        cogs -= cost;
        applyItem(item, sale, item.lineTotalCents, -cost, -milli, false);
      }
    }
    for (final refund in itemRefunds) {
      refunded += refund.amountCents;
      final item = itemById[refund.saleItemId];
      final sale = saleById[refund.saleId];
      if (item == null || sale == null) continue;
      final day = DateTime(refund.createdAt.toLocal().year,
          refund.createdAt.toLocal().month, refund.createdAt.toLocal().day);
      daily.update(day, (v) => v - refund.amountCents,
          ifAbsent: () => -refund.amountCents);
      dailyRefunds.update(day, (v) => v + refund.amountCents,
          ifAbsent: () => refund.amountCents);
      // RMA item refunds do not restore sellable inventory or its COGS.
      applyItem(
          item, sale, refund.amountCents, 0, -refund.quantityMilli, false);
    }
    final commercialLineTotals = <String, int>{};
    final commercialAllocated = <String, int>{};
    for (final row in commercialRows) {
      final id = row.read<String>('return_id');
      commercialLineTotals.update(
          id, (value) => value + row.read<int>('refund_cents'),
          ifAbsent: () => row.read<int>('refund_cents'));
    }
    for (final row in commercialRows) {
      final id = row.read<String>('return_id');
      final before = commercialAllocated[id] ?? 0;
      final after = before + row.read<int>('refund_cents');
      commercialAllocated[id] = after;
      final lineTotal = commercialLineTotals[id] ?? 0;
      final finalizedValue = row.read<int>('refund_value_cents');
      // Cumulative allocation preserves the finalized total after loyalty
      // restoration while keeping product and category subtotals additive.
      final amount = lineTotal == 0
          ? 0
          : finalizedValue * after ~/ lineTotal -
              finalizedValue * before ~/ lineTotal;
      final cost = row.read<String>('disposition') == 'sellable'
          ? row.read<int>('cost_cents')
          : 0;
      final item = itemById[row.read<String>('sale_item_id')];
      final sale = saleById[row.read<String>('original_sale_id')];
      refunded += amount;
      cogs -= cost;
      final date =
          DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at'));
      final day = DateTime(date.year, date.month, date.day);
      daily.update(day, (v) => v - amount, ifAbsent: () => -amount);
      dailyRefunds.update(day, (v) => v + amount, ifAbsent: () => amount);
      if (item != null && sale != null) {
        applyItem(
            item, sale, amount, -cost, -row.read<int>('quantity_milli'), false);
      }
    }

    final salePayments = periodIds.isEmpty
        ? <Payment>[]
        : await (db.select(db.payments)..where((p) => p.saleId.isIn(periodIds)))
            .get();
    final byPayment = <String, int>{};
    for (final p in salePayments) {
      byPayment.update(p.method, (v) => v + p.amountCents,
          ifAbsent: () => p.amountCents);
    }

    final movementRows = await (db.select(db.businessCashMovements)
          ..where((m) =>
              m.createdAt.isBiggerOrEqualValue(period.start) &
              m.createdAt.isSmallerThanValue(period.end)))
        .get();
    final reversalIds = movementRows
        .where((m) => m.type == 'reversal' && m.reversalOfId != null)
        .map((m) => m.reversalOfId!)
        .toSet();
    final originalMovements = reversalIds.isEmpty
        ? <BusinessCashMovement>[]
        : await (db.select(db.businessCashMovements)
              ..where((m) => m.id.isIn(reversalIds)))
            .get();
    final movementById = {
      for (final m in [...movementRows, ...originalMovements]) m.id: m
    };
    final legacy = await (db.select(db.pettyCashEntries)
          ..where((e) =>
              e.createdAt.isBiggerOrEqualValue(period.start) &
              e.createdAt.isSmallerThanValue(period.end)))
        .get();
    final expenseRows = <ReportExpense>[];
    for (final m in movementRows) {
      final original = m.type == 'expense'
          ? m
          : m.type == 'reversal'
              ? movementById[m.reversalOfId]
              : null;
      if (original == null || original.type != 'expense') continue;
      expenseRows.add(ReportExpense(
        m.createdAt,
        original.categoryName ?? 'Uncategorized',
        original.payee ?? '—',
        original.source ?? 'Unknown',
        userNames[original.recordedByUserId] ?? 'Historical user',
        m.type == 'reversal' ? -m.amountCents : m.amountCents,
      ));
    }
    for (final e in legacy) {
      expenseRows.add(ReportExpense(
          e.createdAt,
          e.category,
          '—',
          'historical_drawer',
          userNames[e.userId] ?? 'Historical user',
          e.amountCents,
          legacy: true));
    }
    expenseRows.sort((a, b) => b.date.compareTo(a.date));
    Map<String, int> expenseGroup(String Function(ReportExpense) key) {
      final map = <String, int>{};
      for (final row in expenseRows) {
        map.update(key(row), (v) => v + row.amountCents,
            ifAbsent: () => row.amountCents);
      }
      return map;
    }

    final stockByProduct = await PosRepository(db).stockLevels();
    final layers = await db.select(db.inventoryLayers).get();
    final layersByProduct = <String, List<InventoryLayer>>{};
    for (final layer in layers) {
      layersByProduct.putIfAbsent(layer.productId, () => []).add(layer);
    }
    final inventory = <InventoryReportRow>[];
    for (final p in products.where((p) => p.isActive)) {
      final stock = stockByProduct[p.id] ?? (0, 0);
      final quantity = stock.$1;
      final available = quantity - stock.$2;
      final availableLayers = layersByProduct[p.id] ?? [];
      final layerQuantity = availableLayers.fold<int>(
          0, (sum, l) => sum + l.quantityRemainingMilli);
      final knownCost = availableLayers.fold<int>(
          0,
          (sum, l) =>
              sum +
              Quantity.lineCents(l.unitCostCents, l.quantityRemainingMilli));
      final int? cost = layerQuantity == quantity ? knownCost : null;
      int? retail;
      if (quantity == 0) {
        retail = 0;
      } else if (p.pricingPolicy == 'layer') {
        if (layerQuantity == quantity) {
          retail = availableLayers.every((l) => l.unitSellingPriceCents != null)
              ? availableLayers.fold<int>(
                  0,
                  (sum, l) =>
                      sum +
                      Quantity.lineCents(
                          l.unitSellingPriceCents!, l.quantityRemainingMilli))
              : null;
        }
      } else {
        retail = Quantity.lineCents(p.priceCents, quantity);
      }
      inventory.add(InventoryReportRow(
          p.name,
          p.categoryId == null
              ? 'Uncategorized'
              : categoryNames[p.categoryId] ?? 'Uncategorized',
          productConfigs[p.id]?.unit.label ?? 'pcs',
          quantity,
          available,
          p.lowStockThreshold * Quantity.scale,
          cost,
          retail));
    }
    inventory.sort((a, b) => a.product.compareTo(b.product));
    return ManagementReport(
      period: period,
      grossSalesCents: gross,
      reversalCents: reversed,
      itemRefundCents: refunded,
      cogsCents: cogs,
      cogsComplete: cogsComplete,
      incompleteCostItems: incompleteIds.length,
      incompleteCostRevenueCents: incompleteRevenue,
      incompleteCostItemIds: incompleteIds,
      transactions: count,
      products: productGroups,
      categories: categoryGroups,
      cashiers: cashierGroups,
      payments: byPayment,
      dailySales: daily,
      dailyGrossSales: dailyGross,
      dailyRefunds: dailyRefunds,
      expenses: expenseRows,
      expensesByCategory: expenseGroup((e) => e.category),
      expensesBySource: expenseGroup((e) => e.source),
      expensesByUser: expenseGroup((e) => e.user),
      expensesByPayee: expenseGroup((e) => e.payee),
      inventory: inventory,
      adjustments: await _adjustments(period),
    );
  }
}
