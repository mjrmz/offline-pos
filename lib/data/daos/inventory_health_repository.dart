import 'package:drift/drift.dart';

import '../../core/models/quantity.dart';
import '../database.dart';
import 'inventory_planning_repository.dart';

class InventoryHealthSettings {
  final int slowMovingDays;
  final int deadStockDays;
  final int nearExpiryDays;
  const InventoryHealthSettings(
      this.slowMovingDays, this.deadStockDays, this.nearExpiryDays);
}

class InventoryAgingBucket {
  final String label;
  int quantityMilli = 0;
  int costCents = 0;
  InventoryAgingBucket(this.label);
}

class ExpiryBatchSummary {
  final String productId;
  final String productName;
  final String batchNumber;
  final DateTime expiryDate;
  int quantityMilli;
  int costCents;
  final int daysRemaining;
  final String status;
  ExpiryBatchSummary(
      this.productId,
      this.productName,
      this.batchNumber,
      this.expiryDate,
      this.quantityMilli,
      this.costCents,
      this.daysRemaining,
      this.status);
}

class InventoryProductHealth {
  final InventoryPlanningRow planning;
  final String name;
  final String category;
  final DateTime? lastSoldAt;
  final DateTime? firstSoldAt;
  final DateTime? newestStockAt;
  final int netSold30Milli;
  final int netSold90Milli;
  final List<InventoryAgingBucket> aging;
  final int nearExpiryMilli;
  final int expiredMilli;
  final bool slowMoving;
  final bool deadStock;
  final int? estimatedStockCoverDays;
  final String coverLabel;

  const InventoryProductHealth(
      {required this.planning,
      required this.name,
      required this.category,
      required this.lastSoldAt,
      required this.firstSoldAt,
      required this.newestStockAt,
      required this.netSold30Milli,
      required this.netSold90Milli,
      required this.aging,
      required this.nearExpiryMilli,
      required this.expiredMilli,
      required this.slowMoving,
      required this.deadStock,
      required this.estimatedStockCoverDays,
      required this.coverLabel});

  bool get neverSold => lastSoldAt == null;
  int get costValueCents => planning.costValueCents;
}

class InventoryHealthSnapshot {
  final InventoryHealthSettings settings;
  final Map<String, InventoryProductHealth> products;
  final List<ExpiryBatchSummary> expiry;
  final List<InventoryAgingBucket> aging;
  const InventoryHealthSnapshot(
      this.settings, this.products, this.expiry, this.aging);

  int get slowCount => products.values.where((p) => p.slowMoving).length;
  int get deadCount => products.values.where((p) => p.deadStock).length;
  int get deadStockValueCents => products.values
      .where((p) => p.deadStock)
      .fold(0, (total, p) => total + p.costValueCents);
  int get nearExpiryCount => expiry
      .where((b) =>
          b.daysRemaining >= 0 && b.daysRemaining <= settings.nearExpiryDays)
      .length;
  int get expiredCount => expiry.where((b) => b.daysRemaining < 0).length;
  int get inventoryValueCents =>
      products.values.fold(0, (total, p) => total + p.costValueCents);
}

class InventoryHealthRepository {
  final AppDatabase db;
  const InventoryHealthRepository(this.db);

  Future<InventoryHealthSettings> settings() async {
    final row = await db
        .customSelect('SELECT slow_moving_days, dead_stock_days, '
            'near_expiry_days FROM inventory_health_settings WHERE id=1')
        .getSingle();
    return InventoryHealthSettings(row.read<int>('slow_moving_days'),
        row.read<int>('dead_stock_days'), row.read<int>('near_expiry_days'));
  }

  /// Counts the same remaining, dated batch groups shown by Expiry Monitor.
  /// This keeps Home's read narrow while using Inventory Health thresholds.
  Future<int> nearExpiryCount({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final today = DateTime(at.year, at.month, at.day);
    final threshold = (await settings()).nearExpiryDays;
    final end = today.add(Duration(days: threshold + 1));
    final row = await db.customSelect('''
      SELECT COUNT(*) AS total FROM (
        SELECT l.product_id, l.batch_number, l.expiry_date
        FROM inventory_layers l
        WHERE l.quantity_remaining_milli > 0
          AND l.batch_number IS NOT NULL
          AND l.expiry_date >= ? AND l.expiry_date < ?
        GROUP BY l.product_id, l.batch_number, l.expiry_date
      )
    ''', variables: [
      Variable.withInt(today.millisecondsSinceEpoch ~/ 1000),
      Variable.withInt(end.millisecondsSinceEpoch ~/ 1000),
    ]).getSingle();
    return row.read<int>('total');
  }

  Future<void> saveSettings(InventoryHealthSettings value) async {
    if (value.slowMovingDays < 1 ||
        value.slowMovingDays > 3650 ||
        value.deadStockDays < value.slowMovingDays ||
        value.deadStockDays > 3650 ||
        value.nearExpiryDays < 1 ||
        value.nearExpiryDays > 3650) {
      throw ArgumentError(
          'Enter positive thresholds; dead stock must be at least slow moving');
    }
    await db.customStatement(
        'UPDATE inventory_health_settings SET '
        'slow_moving_days=?, dead_stock_days=?, near_expiry_days=? WHERE id=1',
        [value.slowMovingDays, value.deadStockDays, value.nearExpiryDays]);
  }

  /// Batched planning, sales, and remaining-layer reads. No per-product SQL.
  Future<InventoryHealthSnapshot> load({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final today = DateTime(at.year, at.month, at.day);
    final config = await settings();
    final planning = await InventoryPlanningRepository(db).load();
    final productRows = await db.customSelect('''
      SELECT p.id, p.name, COALESCE(c.name, 'Uncategorized') AS category
      FROM products p LEFT JOIN categories c ON c.id=p.category_id
    ''').get();
    final sales = await db.customSelect('''
      WITH events AS (
        SELECT i.product_id, s.created_at AS at, i.quantity_milli AS qty,
          1 AS is_sale FROM sale_items i JOIN sales s ON s.id=i.sale_id
        WHERE s.status='completed'
        UNION ALL
        SELECT i.product_id, r.created_at AS at, -rl.quantity_milli AS qty,
          0 AS is_sale FROM sale_return_lines rl
        JOIN sale_returns r ON r.id=rl.return_id
        JOIN sale_items i ON i.id=rl.sale_item_id
        JOIN sales s ON s.id=i.sale_id
        WHERE r.status='finalized' AND s.status='completed'
        UNION ALL
        SELECT i.product_id, f.created_at AS at, -f.quantity_milli AS qty,
          0 AS is_sale FROM sale_item_refunds f
        JOIN sale_items i ON i.id=f.sale_item_id
        JOIN sales s ON s.id=i.sale_id WHERE s.status='completed'
      )
      SELECT product_id,
        MAX(CASE WHEN is_sale=1 THEN at END) AS last_sold,
        MIN(CASE WHEN is_sale=1 THEN at END) AS first_sold,
        COALESCE(SUM(CASE WHEN at>=? THEN qty ELSE 0 END),0) AS sold_30,
        COALESCE(SUM(CASE WHEN at>=? THEN qty ELSE 0 END),0) AS sold_90
      FROM events GROUP BY product_id
    ''', variables: [
      Variable.withInt(
          at.subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000),
      Variable.withInt(
          at.subtract(const Duration(days: 90)).millisecondsSinceEpoch ~/ 1000)
    ]).get();
    final salesById = {
      for (final row in sales) row.read<String>('product_id'): row
    };
    final layers = await db.customSelect('''
      SELECT l.product_id, p.name, l.batch_number, l.expiry_date,
        l.received_at, l.quantity_remaining_milli, l.unit_cost_cents
      FROM inventory_layers l JOIN products p ON p.id=l.product_id
      WHERE l.quantity_remaining_milli>0
    ''').get();
    final bucketNames = [
      '0–30 days',
      '31–60 days',
      '61–90 days',
      '91–180 days',
      '180+ days'
    ];
    List<InventoryAgingBucket> buckets() =>
        [for (final label in bucketNames) InventoryAgingBucket(label)];
    final totalAging = buckets();
    final agingByProduct = <String, List<InventoryAgingBucket>>{};
    final newestByProduct = <String, DateTime>{};
    final expiryByKey = <String, ExpiryBatchSummary>{};
    final nearQty = <String, int>{};
    final expiredQty = <String, int>{};
    for (final row in layers) {
      final id = row.read<String>('product_id');
      final received = _date(row.read<int>('received_at'));
      final age = _days(today, received);
      final index = age <= 30
          ? 0
          : age <= 60
              ? 1
              : age <= 90
                  ? 2
                  : age <= 180
                      ? 3
                      : 4;
      final qty = row.read<int>('quantity_remaining_milli');
      final value = Quantity.lineCents(row.read<int>('unit_cost_cents'), qty);
      final productBuckets = agingByProduct.putIfAbsent(id, buckets);
      productBuckets[index].quantityMilli += qty;
      productBuckets[index].costCents += value;
      totalAging[index].quantityMilli += qty;
      totalAging[index].costCents += value;
      final newest = newestByProduct[id];
      if (newest == null || received.isAfter(newest)) {
        newestByProduct[id] = received;
      }
      final expiryValue = row.readNullable<int>('expiry_date');
      final batch = row.readNullable<String>('batch_number');
      if (expiryValue == null || batch == null) continue;
      final expiryDate = _date(expiryValue);
      final remaining = -_days(today, expiryDate);
      final status = remaining < 0
          ? 'Expired'
          : remaining <= 7
              ? 'Expires within 7 days'
              : remaining <= config.nearExpiryDays
                  ? 'Near expiry'
                  : 'Later';
      final key = '$id\u0000$batch\u0000$expiryValue';
      final summary = expiryByKey.putIfAbsent(
          key,
          () => ExpiryBatchSummary(id, row.read<String>('name'), batch,
              expiryDate, 0, 0, remaining, status));
      summary.quantityMilli += qty;
      summary.costCents += value;
      if (remaining < 0) {
        expiredQty.update(id, (old) => old + qty, ifAbsent: () => qty);
      } else if (remaining <= config.nearExpiryDays) {
        nearQty.update(id, (old) => old + qty, ifAbsent: () => qty);
      }
    }
    final products = <String, InventoryProductHealth>{};
    for (final product in productRows) {
      final id = product.read<String>('id');
      final plan = planning[id];
      if (plan == null) continue;
      final sale = salesById[id];
      final last = _optionalDate(sale?.readNullable<int>('last_sold'));
      final first = _optionalDate(sale?.readNullable<int>('first_sold'));
      final ageSource = last ?? plan.oldestStockAt;
      final age = ageSource == null ? null : _days(today, ageSource);
      final stocked = plan.availableMilli > 0;
      final slow = stocked && age != null && age >= config.slowMovingDays;
      final dead = stocked && age != null && age >= config.deadStockDays;
      final net30 = sale?.read<int>('sold_30') ?? 0;
      final net90 = sale?.read<int>('sold_90') ?? 0;
      final enough = first != null &&
          !first.isAfter(at.subtract(const Duration(days: 30)));
      final cover = !enough || net30 <= 0 || !stocked
          ? null
          : (plan.availableMilli * 30 + net30 - 1) ~/ net30;
      final coverLabel = !enough
          ? 'Insufficient sales history'
          : net30 <= 0
              ? 'No recent sales'
              : !stocked
                  ? 'Out of stock'
                  : '$cover days';
      products[id] = InventoryProductHealth(
          planning: plan,
          name: product.read<String>('name'),
          category: product.read<String>('category'),
          lastSoldAt: last,
          firstSoldAt: first,
          newestStockAt: newestByProduct[id],
          netSold30Milli: net30,
          netSold90Milli: net90,
          aging: agingByProduct[id] ?? buckets(),
          nearExpiryMilli: nearQty[id] ?? 0,
          expiredMilli: expiredQty[id] ?? 0,
          slowMoving: slow,
          deadStock: dead,
          estimatedStockCoverDays: cover,
          coverLabel: coverLabel);
    }
    final expiry = expiryByKey.values.toList()
      ..sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
    return InventoryHealthSnapshot(config, products, expiry, totalAging);
  }

  static DateTime _date(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
  static DateTime? _optionalDate(int? seconds) =>
      seconds == null ? null : _date(seconds);
  static int _days(DateTime today, DateTime date) =>
      today.difference(DateTime(date.year, date.month, date.day)).inDays;
}
