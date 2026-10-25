import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import '../../shared/theme/app_layout.dart';
import '../../shared/theme/app_theme.dart';

import '../../core/models/product.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';

String inventoryMovementLabel(String reason) => switch (reason) {
      'initial_stock' => 'Opening stock',
      'opening_inventory_import' => 'Opening Inventory',
      'supplier_receiving' ||
      'batch_received' ||
      'receiving' =>
        'Stock received',
      'sale' => 'Sale',
      'void' => 'Sale voided · stock restored',
      'refund' || 'item_refund' => 'Refund restock',
      'adjustment' => 'Stock adjustment',
      'stock_adjustment_increase' => 'Stock adjustment increase',
      'stock_adjustment_decrease' => 'Stock adjustment decrease',
      'stock_count_variance' => 'Stock count variance',
      'exchange_return' => 'Empty tank returned',
      'inbound_rma' => 'Sent for supplier RMA',
      'rma_replacement' => 'RMA replacement',
      'rma_restock' => 'RMA restock',
      _ => _titleCase(reason),
    };

String _titleCase(String value) {
  final words =
      value.replaceAll(RegExp(r'[_-]+'), ' ').trim().split(RegExp(r'\s+'));
  if (words.isEmpty || words.first.isEmpty) return 'Stock movement';
  return words
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

String inventoryMovementWhen(BuildContext context, DateTime at,
    {DateTime? now}) {
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final date = DateUtils.dateOnly(local);
  final current = DateUtils.dateOnly(today);
  final yesterday = current.subtract(const Duration(days: 1));
  final localization = MaterialLocalizations.of(context);
  final day = date == current
      ? 'Today'
      : date == yesterday
          ? 'Yesterday'
          : local.year == today.year ||
                  localization.formatMediumDate(local).contains('${local.year}')
              ? localization.formatMediumDate(local)
              : '${localization.formatMediumDate(local)}, ${local.year}';
  final time = localization.formatTimeOfDay(TimeOfDay.fromDateTime(local),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
  return '$day · $time';
}

String inventoryMovementQuantity(int milli, PosProduct? product) {
  final magnitude = milli.abs();
  final unit = product?.business.unit.label ?? 'units';
  final readableUnit =
      unit == 'pcs' && magnitude == Quantity.scale ? 'pc' : unit;
  return '${milli >= 0 ? '+' : '-'}${Quantity.format(magnitude)} $readableUnit';
}

class InventoryOverview extends StatefulWidget {
  final PosRepository repository;
  final ValueChanged<String>? onProducts;
  final VoidCallback? onReceive;
  final VoidCallback? onPurchaseOrders;
  final VoidCallback? onExpiry;
  final bool showCosts;
  final VoidCallback onMovements;

  const InventoryOverview(
      {super.key,
      required this.repository,
      required this.onProducts,
      required this.onReceive,
      this.onPurchaseOrders,
      this.onExpiry,
      this.showCosts = true,
      required this.onMovements});

  @override
  State<InventoryOverview> createState() => _InventoryOverviewState();
}

class _OverviewData {
  final List<PosProduct> products;
  final int? low;
  final int? out;
  final int? expiring;
  final int? serials;
  final int openOrders;
  final int awaitingDelivery;
  final int reorder;
  final InventoryHealthSnapshot health;
  const _OverviewData(
      this.products,
      this.low,
      this.out,
      this.expiring,
      this.serials,
      this.openOrders,
      this.awaitingDelivery,
      this.reorder,
      this.health);
}

class _InventoryOverviewState extends State<InventoryOverview> {
  late final Future<_OverviewData> overview = _loadOverview();
  late final Future<List<InventoryMovement>> activity = _loadActivity();

  Future<_OverviewData> _loadOverview() async {
    final products = await widget.repository.products();
    final health = await InventoryHealthRepository(widget.repository.db).load();
    Map<String, (int physical, int reserved)>? levels;
    try {
      levels = await widget.repository.stockLevels();
    } catch (_) {
      levels = null;
    }
    final expiring = health.nearExpiryCount;
    int? serialCount;
    try {
      serialCount =
          (await (widget.repository.db.select(widget.repository.db.serialUnits)
                    ..where((row) => row.status.equals('available')))
                  .get())
              .length;
    } catch (_) {
      serialCount = null;
    }
    var low = 0;
    var out = 0;
    if (levels != null) {
      for (final product in products.where((p) => p.isActive)) {
        final available =
            (levels[product.id]?.$1 ?? 0) - (levels[product.id]?.$2 ?? 0);
        if (available <= 0) {
          out++;
        } else if (available <= product.lowStockThreshold * Quantity.scale) {
          low++;
        }
      }
    }
    final purchaseOrders = PurchaseOrderRepository(widget.repository.db);
    var openOrders = 0;
    var awaitingDelivery = 0;
    for (final order in await purchaseOrders.list()) {
      final progress = await purchaseOrders.detail(order.id);
      if (progress.remainingTotal > 0 &&
          {'sent', 'partially_received'}.contains(progress.status)) {
        openOrders++;
        if (progress.receivedTotal == 0) awaitingDelivery++;
      }
    }
    return _OverviewData(
        products,
        levels == null ? null : low,
        levels == null ? null : out,
        expiring,
        serialCount,
        openOrders,
        awaitingDelivery,
        products
            .where((p) =>
                p.isActive &&
                (health.products[p.id]?.planning.belowReorderLevel ?? false))
            .length,
        health);
  }

  Future<List<InventoryMovement>> _loadActivity() =>
      (widget.repository.db.select(widget.repository.db.inventoryMovements)
            ..orderBy([
              (row) => OrderingTerm(
                  expression: row.createdAt, mode: OrderingMode.desc)
            ])
            ..limit(8))
          .get();

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        return ListView(padding: AppLayout.workspacePadding(width), children: [
          ConstrainedBox(
            constraints: const BoxConstraints(),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    Text('Overview',
                        style: Theme.of(context).textTheme.headlineSmall),
                    Wrap(spacing: 8, children: [
                      if (widget.onProducts != null)
                        FilledButton.icon(
                            onPressed: () => widget.onProducts!('All'),
                            icon: const Icon(Icons.add),
                            label: const Text('Add product')),
                      if (widget.onReceive != null)
                        OutlinedButton.icon(
                            onPressed: widget.onReceive,
                            icon: const Icon(Icons.inventory_2_outlined),
                            label: const Text('Receive stock')),
                    ]),
                  ]),
              const SizedBox(height: 18),
              FutureBuilder<_OverviewData>(
                  future: overview,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Text(
                          'Inventory totals are unavailable right now.');
                    }
                    if (!snapshot.hasData) {
                      return const LinearProgressIndicator();
                    }
                    final data = snapshot.data!;
                    final columns = width >= 1080
                        ? 5
                        : width >= 720
                            ? 3
                            : width >= 360
                                ? 2
                                : 1;
                    final cardWidth =
                        (width - 40 - (columns - 1) * 10) / columns;
                    return Wrap(spacing: 10, runSpacing: 10, children: [
                      _Metric('Products', '${data.products.length}',
                          Icons.inventory_2_outlined,
                          width: cardWidth,
                          onTap: widget.onProducts == null
                              ? null
                              : () => widget.onProducts!('All')),
                      _Metric('Low stock', '${data.low ?? '—'}',
                          Icons.trending_down,
                          width: cardWidth,
                          onTap: widget.onProducts == null || data.low == null
                              ? null
                              : () => widget.onProducts!('Low stock')),
                      _Metric('Out of stock', '${data.out ?? '—'}',
                          Icons.remove_circle_outline,
                          width: cardWidth,
                          onTap: widget.onProducts == null || data.out == null
                              ? null
                              : () => widget.onProducts!('Out of stock')),
                      _Metric('Expiring soon', '${data.expiring ?? '—'}',
                          Icons.event_outlined,
                          width: cardWidth,
                          detail:
                              'Next ${data.health.settings.nearExpiryDays} days',
                          onTap: widget.onExpiry),
                      _Metric('Serialized units', '${data.serials ?? '—'}',
                          Icons.qr_code,
                          width: cardWidth,
                          detail: 'Available',
                          onTap: widget.onProducts == null
                              ? null
                              : () => widget.onProducts!('Serialized')),
                      _Metric('Reorder needed', '${data.reorder}',
                          Icons.shopping_cart_outlined,
                          width: cardWidth,
                          onTap: widget.onProducts == null
                              ? null
                              : () => widget.onProducts!('Reorder')),
                      _Metric('Slow moving', '${data.health.slowCount}',
                          Icons.hourglass_bottom_outlined,
                          width: cardWidth,
                          onTap: widget.onProducts == null
                              ? null
                              : () => widget.onProducts!('Slow moving')),
                      _Metric('Expired batches', '${data.health.expiredCount}',
                          Icons.warning_amber_outlined,
                          width: cardWidth, onTap: widget.onExpiry),
                      if (widget.showCosts)
                        _Metric(
                            'Dead stock value',
                            formatPeso(data.health.deadStockValueCents),
                            Icons.inventory_outlined,
                            width: cardWidth,
                            onTap: widget.onProducts == null
                                ? null
                                : () => widget.onProducts!('Dead stock')),
                      _Metric('Open purchase orders', '${data.openOrders}',
                          Icons.shopping_bag_outlined,
                          width: cardWidth, onTap: widget.onPurchaseOrders),
                      _Metric('Awaiting delivery', '${data.awaitingDelivery}',
                          Icons.local_shipping_outlined,
                          width: cardWidth, onTap: widget.onPurchaseOrders),
                    ]);
                  }),
              const SizedBox(height: 20),
              if (width >= 850)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 7, child: _activityPanel(context)),
                  const SizedBox(width: 16),
                  Expanded(flex: 3, child: _attentionPanel(context)),
                ])
              else ...[
                _attentionPanel(context),
                const SizedBox(height: 16),
                _activityPanel(context),
              ],
            ]),
          ),
        ]);
      });

  Widget _attentionPanel(BuildContext context) => Card(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Needs attention',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          FutureBuilder<_OverviewData>(
              future: overview,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text(
                      'Attention counts are unavailable right now.');
                }
                if (!snapshot.hasData) return const LinearProgressIndicator();
                final data = snapshot.data!;
                if (data.out == 0 &&
                    data.low == 0 &&
                    data.expiring == 0 &&
                    data.reorder == 0 &&
                    data.health.expiredCount == 0 &&
                    data.health.slowCount == 0 &&
                    data.health.deadCount == 0) {
                  return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Inventory looks healthy.'));
                }
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (data.health.expiredCount > 0)
                        TextButton.icon(
                            onPressed: widget.onExpiry,
                            icon: const Icon(Icons.chevron_right),
                            label: Text(
                                '${data.health.expiredCount} expired batches')),
                      if (data.health.nearExpiryCount > 0)
                        TextButton.icon(
                            onPressed: widget.onExpiry,
                            icon: const Icon(Icons.chevron_right),
                            label: Text(
                                '${data.health.nearExpiryCount} batches near expiry')),
                      if ((data.out ?? 0) > 0)
                        _attentionRow(
                            context,
                            '${data.out} ${data.out == 1 ? 'product' : 'products'} out of stock',
                            'Out of stock'),
                      if ((data.low ?? 0) > 0)
                        _attentionRow(
                            context,
                            '${data.low} ${data.low == 1 ? 'product' : 'products'} low on stock',
                            'Low stock'),
                      if (data.reorder > 0)
                        _attentionRow(
                            context,
                            '${data.reorder} ${data.reorder == 1 ? 'product needs' : 'products need'} reorder',
                            'Reorder'),
                      if (data.health.deadCount > 0)
                        _attentionRow(
                            context,
                            widget.showCosts
                                ? '${data.health.deadCount} dead-stock products · ${formatPeso(data.health.deadStockValueCents)} at cost'
                                : '${data.health.deadCount} dead-stock products',
                            'Dead stock'),
                      if (data.health.slowCount > 0)
                        _attentionRow(
                            context,
                            '${data.health.slowCount} slow-moving products',
                            'Slow moving'),
                      if (data.out == null ||
                          data.low == null ||
                          data.expiring == null)
                        const Text(
                            'Some attention counts are unavailable right now.'),
                    ]);
              }),
        ]),
      ));

  Widget _attentionRow(BuildContext context, String text, String filter) =>
      widget.onProducts == null
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(text))
          : TextButton.icon(
              onPressed: () => widget.onProducts!(filter),
              icon: const Icon(Icons.chevron_right),
              label: Text(text));

  Widget _activityPanel(BuildContext context) => Card(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('Recent inventory activity',
                    style: Theme.of(context).textTheme.titleLarge)),
            TextButton(
                onPressed: widget.onMovements,
                child: const Text('View all movements')),
          ]),
          FutureBuilder<List<InventoryMovement>>(
              future: activity,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Recent activity is unavailable right now.'));
                }
                if (!snapshot.hasData) return const LinearProgressIndicator();
                if (snapshot.data!.isEmpty) {
                  return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                          'No inventory activity yet.\nInventory changes from receiving, sales, returns, and adjustments will appear here.'));
                }
                return FutureBuilder<_OverviewData>(
                    future: overview,
                    builder: (context, productsSnapshot) {
                      final byId = {
                        for (final p in productsSnapshot.data?.products ??
                            <PosProduct>[])
                          p.id: p
                      };
                      return Column(children: [
                        for (final movement in snapshot.data!) ...[
                          const Divider(height: 1),
                          InventoryMovementRow(
                              movement: movement,
                              product: byId[movement.productId]),
                        ]
                      ]);
                    });
              }),
        ]),
      ));
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String? detail;
  final IconData icon;
  final double width;
  final VoidCallback? onTap;
  const _Metric(this.label, this.value, this.icon,
      {required this.width, this.detail, this.onTap});

  @override
  Widget build(BuildContext context) => AppMetricTile(
        label: label,
        value: value,
        icon: icon,
        width: width,
        detail: detail,
        onTap: onTap,
      );
}

class InventoryMovementRow extends StatelessWidget {
  final InventoryMovement movement;
  final PosProduct? product;
  final String? reference;
  const InventoryMovementRow(
      {super.key, required this.movement, this.product, this.reference});

  @override
  Widget build(BuildContext context) {
    final positive = movement.quantityDeltaMilli >= 0;
    final status = AppStatusColors.of(context);
    final color = positive ? status.success : status.warning;
    final quantity = Text(
        inventoryMovementQuantity(movement.quantityDeltaMilli, product),
        style: TextStyle(color: color, fontWeight: FontWeight.w700));
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 650) {
        return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(product?.name ?? 'Product',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                quantity
              ]),
              Text(inventoryMovementLabel(movement.reason)),
              if (reference != null) Text(reference!),
              Text(inventoryMovementWhen(context, movement.createdAt)),
            ]));
      }
      return Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(children: [
            SizedBox(
                width: 190,
                child:
                    Text(inventoryMovementWhen(context, movement.createdAt))),
            Expanded(
                flex: 3,
                child: Text(product?.name ?? 'Product',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            Expanded(
                flex: 2, child: Text(inventoryMovementLabel(movement.reason))),
            if (reference != null)
              SizedBox(
                  width: 190,
                  child: Text(reference!,
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
            SizedBox(
                width: 130,
                child:
                    Align(alignment: Alignment.centerRight, child: quantity)),
          ]));
    });
  }
}
