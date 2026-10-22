import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/daos/supplier_analysis_repository.dart';
import '../../data/daos/supplier_procurement_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';

class SupplierProfileDrawer extends StatefulWidget {
  final Supplier supplier;
  final ActiveUser? user;
  final StockReceivingRepository repository;
  final Future<void> Function()? onEdit;
  const SupplierProfileDrawer(
      {super.key,
      required this.supplier,
      required this.repository,
      this.user,
      this.onEdit});

  @override
  State<SupplierProfileDrawer> createState() => _SupplierProfileDrawerState();
}

class _SupplierProfileDrawerState extends State<SupplierProfileDrawer> {
  late Supplier currentSupplier;
  int tab = 0;
  int page = 0;
  String period = 'This month';
  DateTimeRange? custom;
  String? productId;
  String? categoryId;
  String reference = '';
  String? detailProduct;
  bool preferredOnly = false;
  StockReceiving? detailReceiving;
  PurchaseOrder? detailOrder;
  late Future<SupplierProcurementSummary> headerSummary;

  @override
  void initState() {
    super.initState();
    currentSupplier = widget.supplier;
    headerSummary = SupplierProcurementRepository(widget.repository.db)
        .summary(widget.supplier.id);
  }

  @override
  void didUpdateWidget(covariant SupplierProfileDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.supplier.id != widget.supplier.id) {
      currentSupplier = widget.supplier;
      headerSummary = SupplierProcurementRepository(widget.repository.db)
          .summary(widget.supplier.id);
      tab = 0;
      page = 0;
      period = 'This month';
      custom = null;
      productId = null;
      categoryId = null;
      reference = '';
      detailProduct = null;
      detailReceiving = null;
      detailOrder = null;
      preferredOnly = false;
    }
  }

  Future<void> editSupplier() async {
    await widget.onEdit?.call();
    final updated =
        await (widget.repository.db.select(widget.repository.db.suppliers)
              ..where((s) => s.id.equals(widget.supplier.id)))
            .getSingle();
    if (mounted) setState(() => currentSupplier = updated);
  }

  SupplierAnalysisRepository get analysis =>
      SupplierAnalysisRepository(widget.repository.db);
  bool get canViewCost =>
      widget.user?.can(PosPermission.reports) == true ||
      widget.user?.can(PosPermission.stockReceiving) == true;
  DateTimeRange get range {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (period == 'Today') {
      return DateTimeRange(
          start: today, end: today.add(const Duration(days: 1)));
    }
    if (period == 'This week') {
      final start = today.subtract(Duration(days: today.weekday - 1));
      return DateTimeRange(
          start: start, end: start.add(const Duration(days: 7)));
    }
    if (period == 'This year') {
      return DateTimeRange(
          start: DateTime(now.year), end: DateTime(now.year + 1));
    }
    if (period == 'Custom' && custom != null) {
      return DateTimeRange(
          start: custom!.start, end: custom!.end.add(const Duration(days: 1)));
    }
    return DateTimeRange(
        start: DateTime(now.year, now.month),
        end: DateTime(now.year, now.month + 1));
  }

  String date(DateTime value) =>
      MaterialLocalizations.of(context).formatMediumDate(value);
  String days(double? value) =>
      value == null ? 'Not enough history' : '${value.toStringAsFixed(1)} days';
  Widget queryError(Object error) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(safeMessage(error), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        TextButton.icon(
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry')),
      ]));
  Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));
  Widget metrics(List<(String, String)> entries) =>
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final entry in entries)
          SizedBox(
              width: 160,
              child: Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(entry.$1,
                                style: Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 6),
                            Text(entry.$2,
                                style: Theme.of(context).textTheme.titleMedium),
                          ]))))
      ]);

  Widget periodPicker() => Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
                value: period,
                items: [
                  for (final value in const [
                    'Today',
                    'This week',
                    'This month',
                    'This year',
                    'Custom'
                  ])
                    DropdownMenuItem(value: value, child: Text(value))
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  if (value == 'Custom') {
                    final result = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDateRange: custom);
                    if (result == null) return;
                    custom = result;
                  }
                  setState(() {
                    period = value;
                    page = 0;
                    productId = null;
                    categoryId = null;
                    reference = '';
                  });
                }),
            Text(
                '${date(range.start)} – ${date(range.end.subtract(const Duration(days: 1)))}')
          ]);

  void back() => setState(() {
        detailProduct = null;
        detailReceiving = null;
        detailOrder = null;
      });

  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
          child: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Row(children: [
              if (detailProduct != null ||
                  detailReceiving != null ||
                  detailOrder != null)
                IconButton(
                    onPressed: back,
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back'),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(currentSupplier.name,
                        style: Theme.of(context).textTheme.titleLarge),
                    Text(
                        'Supplier · ${currentSupplier.isActive ? 'Active' : 'Inactive'}',
                        style: Theme.of(context).textTheme.bodySmall),
                    FutureBuilder<SupplierProcurementSummary>(
                        future: headerSummary,
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return const SizedBox(height: 18);
                          }
                          final summary = snapshot.data!;
                          return Text(
                              'Last receiving ${summary.lastReceiving == null ? '—' : date(summary.lastReceiving!.receivedAt)}  ·  ${summary.openOrders} open purchase orders',
                              style: Theme.of(context).textTheme.bodySmall);
                        }),
                  ])),
              if (widget.onEdit != null &&
                  widget.user?.can(PosPermission.manageContacts) == true)
                TextButton(onPressed: editSupplier, child: const Text('Edit')),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  tooltip: 'Close details'),
            ])),
        if (detailProduct == null &&
            detailReceiving == null &&
            detailOrder == null)
          AppWorkspaceTabs(
              labels: const [
                'Overview',
                'Purchases',
                'Products',
                'Purchase Orders',
                'Receiving',
                'Performance'
              ],
              selectedIndex: tab,
              onSelected: (index) => setState(() {
                    tab = index;
                    page = 0;
                    preferredOnly = false;
                  })),
        const Divider(height: 1),
        Expanded(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: !canViewCost &&
                        (detailProduct != null ||
                            detailReceiving != null ||
                            (detailOrder == null && tab != 3 && tab != 4))
                    ? const Center(
                        child: Text('Purchase cost access required.'))
                    : detailOrder != null
                        ? orderDetail(detailOrder!)
                        : detailReceiving != null
                            ? receivingDetail(detailReceiving!)
                            : detailProduct != null
                                ? productDetail(detailProduct!)
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                        if (tab == 0 ||
                                            tab == 1 ||
                                            tab == 2 ||
                                            tab == 5)
                                          periodPicker(),
                                        const SizedBox(height: 10),
                                        Expanded(
                                            child: KeyedSubtree(
                                                key: ValueKey(
                                                    '${widget.supplier.id}:$tab:$preferredOnly'),
                                                child: switch (tab) {
                                                  0 => overview(),
                                                  1 => purchases(),
                                                  2 => preferredOnly
                                                      ? preferredProducts()
                                                      : products(),
                                                  3 => orders(),
                                                  4 => receivings(),
                                                  _ => performance(),
                                                })),
                                      ]))),
      ])));

  Future<
      ({
        SupplierPurchaseTotals totals,
        SupplierProcurementSummary procurement,
        List<SupplierProductTotal> products,
        int productCount,
        int preferredCount,
        List<Product> preferred,
        List<StockReceiving> recentReceivings
      })> loadOverview() async {
    final supplierId = widget.supplier.id;
    final selectedRange = range;
    final totals =
        analysis.totals(supplierId, selectedRange.start, selectedRange.end);
    final procurement =
        SupplierProcurementRepository(widget.repository.db).summary(supplierId);
    final products = analysis
        .products(supplierId, selectedRange.start, selectedRange.end, page: 0);
    final productCount = analysis.productCount(
        supplierId, selectedRange.start, selectedRange.end);
    final preferredCount = analysis.preferredCount(supplierId);
    final preferred = analysis.preferredPage(supplierId, 0);
    final recentReceivings = analysis.receivingPage(supplierId, 0);
    return (
      totals: await totals,
      procurement: await procurement,
      products: await products,
      productCount: await productCount,
      preferredCount: await preferredCount,
      preferred: await preferred,
      recentReceivings: await recentReceivings
    );
  }

  Widget overview() => FutureBuilder<
          ({
            SupplierPurchaseTotals totals,
            SupplierProcurementSummary procurement,
            List<SupplierProductTotal> products,
            int productCount,
            int preferredCount,
            List<Product> preferred,
            List<StockReceiving> recentReceivings
          })>(
      future: loadOverview(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (
          :totals,
          :procurement,
          :products,
          :productCount,
          :preferredCount,
          :preferred,
          :recentReceivings
        ) = snapshot.data!;
        return ListView(children: [
          metrics([
            ('Purchased this month', formatPeso(totals.valueCents)),
            ('Open POs', '${procurement.openOrders}'),
            (
              'Last receiving',
              procurement.lastReceiving == null
                  ? 'None'
                  : date(procurement.lastReceiving!.receivedAt)
            ),
            ('Products supplied', '$productCount')
          ]),
          heading('Procurement performance'),
          Text(
              'Average first delivery: ${days(procurement.averageFirstDeliveryDays)}'),
          Text(
              'Average completion: ${days(procurement.averageCompletionDays)}'),
          Text(
              'On-time first delivery: ${procurement.onTimeRate == null ? 'Not enough history' : '${procurement.onTimeRate!.toStringAsFixed(0)}%'}'),
          heading('Recent activity'),
          if (recentReceivings.isEmpty)
            const Text('No receiving activity yet.'),
          for (final receipt in recentReceivings.take(5))
            ListTile(
                dense: true,
                title: Text(
                    '${StockReceivingRepository.number(receipt)} finalized'),
                subtitle: Text(date(receipt.finalizedAt ?? receipt.receivedAt)),
                onTap: () => setState(() => detailReceiving = receipt)),
          TextButton(
              onPressed: () => setState(() {
                    tab = 4;
                    page = 0;
                  }),
              child: const Text('View all receiving')),
          TextButton(
              onPressed: () => setState(() {
                    tab = 3;
                    page = 0;
                  }),
              child: const Text('View all purchase orders')),
          heading('Top supplied products'),
          if (products.isEmpty) const Text('No purchases for this period.'),
          for (final product in products.take(5))
            ListTile(
                title: Text(product.name),
                subtitle: Text(Quantity.format(product.quantityMilli)),
                trailing: Text(formatPeso(product.valueCents)),
                onTap: () => setState(() {
                      detailProduct = product.id;
                      page = 0;
                    })),
          heading('Preferred supplier for $preferredCount products'),
          if (preferred.isEmpty) const Text('No preferred-supplier products.'),
          for (final product in preferred.take(5))
            ListTile(
                title: Text(product.name),
                onTap: () => setState(() {
                      detailProduct = product.id;
                      page = 0;
                    })),
          if (preferredCount > 5)
            TextButton(
                onPressed: () => setState(() {
                      tab = 2;
                      page = 0;
                      preferredOnly = true;
                    }),
                child: const Text('View products')),
        ]);
      });

  Future<
      ({
        SupplierPurchaseTotals totals,
        int count,
        List<SupplierPurchaseLine> lines,
        List<SupplierProductTotal> products,
        List<(String, String)> categories
      })> loadPurchases() async {
    final supplierId = widget.supplier.id;
    final selectedRange = range;
    final selectedProduct = productId;
    final selectedCategory = categoryId;
    final selectedReference = reference;
    final selectedPage = page;
    final totals = analysis.totals(
        supplierId, selectedRange.start, selectedRange.end,
        productId: selectedProduct,
        categoryId: selectedCategory,
        reference: selectedReference);
    final count = analysis.lineCount(
        supplierId, selectedRange.start, selectedRange.end,
        productId: selectedProduct,
        categoryId: selectedCategory,
        reference: selectedReference);
    final lines = analysis.lines(
        supplierId, selectedRange.start, selectedRange.end, selectedPage,
        productId: selectedProduct,
        categoryId: selectedCategory,
        reference: selectedReference);
    final products =
        analysis.products(supplierId, selectedRange.start, selectedRange.end);
    final categories =
        analysis.categories(supplierId, selectedRange.start, selectedRange.end);
    return (
      totals: await totals,
      count: await count,
      lines: await lines,
      products: await products,
      categories: await categories
    );
  }

  Widget purchases() => FutureBuilder<
          ({
            SupplierPurchaseTotals totals,
            int count,
            List<SupplierPurchaseLine> lines,
            List<SupplierProductTotal> products,
            List<(String, String)> categories
          })>(
      future: loadPurchases(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:totals, :count, :lines, :products, :categories) =
            snapshot.data!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          metrics([
            ('Actual purchase value', formatPeso(totals.valueCents)),
            ('Qty received', Quantity.format(totals.quantityMilli)),
            ('Receiving count', '${totals.deliveries}'),
            if (productId != null && totals.averageActualUnitCostCents != null)
              (
                'Average actual unit cost',
                formatPeso(totals.averageActualUnitCostCents!)
              ),
            (
              'Cost variance · linked PO',
              totals.expectedCents == 0
                  ? 'Not enough history'
                  : formatPeso(
                      totals.comparableActualCents - totals.expectedCents)
            )
          ]),
          Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String?>(
                    value: productId,
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('All products')),
                      for (final product in products)
                        DropdownMenuItem(
                            value: product.id, child: Text(product.name))
                    ],
                    onChanged: (value) => setState(() {
                          productId = value;
                          page = 0;
                        })),
                DropdownButton<String?>(
                    value: categoryId,
                    items: [
                      const DropdownMenuItem<String?>(
                          value: null, child: Text('All categories')),
                      for (final category in categories)
                        DropdownMenuItem(
                            value: category.$1, child: Text(category.$2)),
                    ],
                    onChanged: (value) => setState(() {
                          categoryId = value;
                          page = 0;
                        })),
                SizedBox(
                    width: 220,
                    child: AppSearchField(
                        hintText: 'Receiving or supplier ref',
                        onChanged: (value) => setState(() {
                              reference = value;
                              page = 0;
                            }))),
              ]),
          Expanded(
              child: AppPagedListPanel(
                  title: 'Purchase history',
                  total: count,
                  count: lines.length,
                  page: page,
                  emptyTitle: 'No purchases for this period.',
                  onPrevious: () => setState(() => page--),
                  onNext: () => setState(() => page++),
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    return AppEntityRow(
                        title: line.product,
                        subtitle:
                            'RCV-${line.sequence.toString().padLeft(6, '0')} · ${date(line.date)} · ${Quantity.format(line.quantityMilli)} @ ${formatPeso(line.unitCostCents)}',
                        amount: formatPeso(line.actualCents),
                        onTap: () async {
                          final receipt = await (widget.repository.db
                                  .select(widget.repository.db.stockReceivings)
                                ..where((r) => r.id.equals(line.receivingId)))
                              .getSingle();
                          if (mounted) {
                            setState(() => detailReceiving = receipt);
                          }
                        });
                  }))
        ]);
      });

  Future<({int total, List<Product> rows})> loadPreferredProducts() async {
    final supplierId = widget.supplier.id;
    final selectedPage = page;
    final total = analysis.preferredCount(supplierId);
    final rows = analysis.preferredPage(supplierId, selectedPage);
    return (total: await total, rows: await rows);
  }

  Widget preferredProducts() => FutureBuilder<
          ({int total, List<Product> rows})>(
      future: loadPreferredProducts(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:total, :rows) = snapshot.data!;
        return Column(children: [
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  onPressed: () => setState(() {
                        preferredOnly = false;
                        page = 0;
                      }),
                  child: const Text('View purchased products'))),
          Expanded(
              child: AppPagedListPanel(
                  title: 'Preferred supplier products',
                  total: total,
                  count: rows.length,
                  page: page,
                  onPrevious: () => setState(() => page--),
                  onNext: () => setState(() => page++),
                  emptyTitle: 'No preferred-supplier products.',
                  itemBuilder: (context, index) => AppEntityRow(
                      title: rows[index].name,
                      subtitle: 'Preferred supplier: ${currentSupplier.name}',
                      onTap: () => setState(() {
                            detailProduct = rows[index].id;
                            page = 0;
                          }))))
        ]);
      });

  Future<({int total, List<SupplierProductTotal> rows})> loadProducts() async {
    final supplierId = widget.supplier.id;
    final selectedRange = range;
    final selectedPage = page;
    final total = analysis.productCount(
        supplierId, selectedRange.start, selectedRange.end);
    final rows = analysis.products(
        supplierId, selectedRange.start, selectedRange.end,
        page: selectedPage);
    return (total: await total, rows: await rows);
  }

  Widget products() =>
      FutureBuilder<({int total, List<SupplierProductTotal> rows})>(
          future: loadProducts(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return queryError(snapshot.error!);
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final (:total, :rows) = snapshot.data!;
            return AppPagedListPanel(
                title: 'Products supplied',
                total: total,
                count: rows.length,
                page: page,
                onPrevious: () => setState(() => page--),
                onNext: () => setState(() => page++),
                emptyTitle: 'No products for this period.',
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return AppEntityRow(
                      title: row.name,
                      subtitle:
                          '${row.category} · ${row.timesReceived} receivings · ${Quantity.format(row.quantityMilli)} units\nAvg ${formatPeso(row.averageCostCents)} · Last ${formatPeso(row.lastCostCents)} · Low ${formatPeso(row.minCostCents)} · High ${formatPeso(row.maxCostCents)}',
                      amount: formatPeso(row.valueCents),
                      onTap: () => setState(() {
                            detailProduct = row.id;
                            page = 0;
                          }));
                });
          });

  Future<({int total, List<SupplierPurchaseLine> lines})> loadProductDetail(
      String id) async {
    final supplierId = widget.supplier.id;
    final selectedRange = range;
    final selectedPage = page;
    final total = analysis.lineCount(
        supplierId, selectedRange.start, selectedRange.end,
        productId: id);
    final lines = analysis.lines(
        supplierId, selectedRange.start, selectedRange.end, selectedPage,
        productId: id);
    return (total: await total, lines: await lines);
  }

  Widget productDetail(String id) => FutureBuilder<
          ({int total, List<SupplierPurchaseLine> lines})>(
      future: loadProductDetail(id),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:total, :lines) = snapshot.data!;
        final maximum = lines.fold<int>(1,
            (max, line) => line.unitCostCents > max ? line.unitCostCents : max);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          heading('Actual unit cost trend · this page'),
          SizedBox(
              height: 130,
              child: lines.isEmpty
                  ? const Center(
                      child: Text('No cost history for this period.'))
                  : ListView(scrollDirection: Axis.horizontal, children: [
                      for (final line in lines.reversed)
                        Tooltip(
                            message:
                                '${date(line.date)}\nRCV-${line.sequence.toString().padLeft(6, '0')}\n${Quantity.format(line.quantityMilli)} units\n${formatPeso(line.unitCostCents)} / unit',
                            child: SizedBox(
                                width: 34,
                                child: Column(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Container(
                                          width: 20,
                                          height: 105 *
                                              line.unitCostCents /
                                              maximum,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary),
                                      const SizedBox(height: 4),
                                    ]))),
                    ])),
          Expanded(
              child: AppPagedListPanel(
                  title: 'Cost history',
                  total: total,
                  count: lines.length,
                  page: page,
                  onPrevious: () => setState(() => page--),
                  onNext: () => setState(() => page++),
                  emptyTitle: 'No cost history for this period.',
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    final previous =
                        index + 1 < lines.length ? lines[index + 1] : null;
                    final change = previous == null
                        ? null
                        : line.unitCostCents - previous.unitCostCents;
                    return AppEntityRow(
                        title:
                            'RCV-${line.sequence.toString().padLeft(6, '0')}',
                        subtitle:
                            '${date(line.date)} · ${Quantity.format(line.quantityMilli)} units'
                            '${change == null ? '' : ' · Cost change ${change >= 0 ? '+' : ''}${formatPeso(change)}'}',
                        amount: formatPeso(line.unitCostCents),
                        onTap: () async {
                          final receipt = await (widget.repository.db
                                  .select(widget.repository.db.stockReceivings)
                                ..where((r) => r.id.equals(line.receivingId)))
                              .getSingle();
                          if (mounted) {
                            setState(() {
                              detailProduct = null;
                              detailReceiving = receipt;
                            });
                          }
                        });
                  })),
        ]);
      });
  Future<
      ({
        int total,
        List<PurchaseOrder> rows,
        Map<String, SupplierOrderSummary> summaries
      })> loadOrders() async {
    final supplierId = widget.supplier.id;
    final selectedPage = page;
    final total = analysis.orderCount(supplierId);
    final rows = await analysis.orderPage(supplierId, selectedPage);
    final summaries = await analysis.orderSummaries(rows);
    return (total: await total, rows: rows, summaries: summaries);
  }

  Widget orders() => FutureBuilder<
          ({
            int total,
            List<PurchaseOrder> rows,
            Map<String, SupplierOrderSummary> summaries
          })>(
      future: loadOrders(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:total, :rows, :summaries) = snapshot.data!;
        return AppPagedListPanel(
            title: 'Purchase orders',
            total: total,
            count: rows.length,
            page: page,
            onPrevious: () => setState(() => page--),
            onNext: () => setState(() => page++),
            emptyTitle: 'No purchase orders for this supplier.',
            itemBuilder: (context, index) {
              final order = rows[index];
              final summary = summaries[order.id];
              final remaining = summary?.remainingMilli ?? 0;
              final status =
                  {'draft', 'cancelled', 'closed'}.contains(order.status)
                      ? order.status
                      : (summary?.receivedMilli ?? 0) == 0
                          ? 'sent'
                          : remaining == 0
                              ? 'fully received'
                              : 'partially received';
              final overdue = order.expectedDeliveryDate != null &&
                  order.expectedDeliveryDate!.isBefore(DateTime.now()) &&
                  remaining > 0 &&
                  {'sent', 'partially received'}.contains(status);
              return AppEntityRow(
                  title: PurchaseOrderRepository.number(order),
                  subtitle:
                      '${date(order.orderDate)} · Expected ${order.expectedDeliveryDate == null ? 'Not set' : date(order.expectedDeliveryDate!)} · ${overdue ? 'Overdue' : status}\nReceived ${Quantity.format(summary?.receivedMilli ?? 0)} · Remaining ${Quantity.format(remaining)}',
                  amount: canViewCost && summary != null
                      ? formatPeso(summary.expectedValueCents)
                      : null,
                  onTap: () => setState(() => detailOrder = order));
            });
      });

  Widget orderDetail(PurchaseOrder order) =>
      FutureBuilder<PurchaseOrderProgress>(
          future:
              PurchaseOrderRepository(widget.repository.db).detail(order.id),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return queryError(snapshot.error!);
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final progress = snapshot.data!;
            return ListView(children: [
              heading(PurchaseOrderRepository.number(order)),
              Text('${date(order.orderDate)} · ${progress.status}'),
              if (order.expectedDeliveryDate != null)
                Text('Expected ${date(order.expectedDeliveryDate!)}'),
              if (progress.isOverdue(DateTime.now()))
                const Text('Overdue', style: TextStyle(color: Colors.red)),
              if (canViewCost) ...[
                heading('Order value'),
                Text(formatPeso(progress.estimatedTotal)),
              ],
              heading('Quantity'),
              Text(
                  'Ordered ${Quantity.format(progress.ordered)} · Received ${Quantity.format(progress.receivedTotal)} · Remaining ${Quantity.format(progress.remainingTotal)}'),
              heading('Receiving'),
              for (final receipt in progress.receivings)
                ListTile(
                    title: Text(StockReceivingRepository.number(receipt)),
                    subtitle: Text(date(receipt.receivedAt)),
                    onTap: () => setState(() {
                          detailOrder = null;
                          detailReceiving = receipt;
                        })),
            ]);
          });

  Future<
      ({
        int total,
        List<StockReceiving> rows,
        Map<String, SupplierReceivingSummary> summaries
      })> loadReceivings() async {
    final supplierId = widget.supplier.id;
    final selectedPage = page;
    final total = analysis.receivingCount(supplierId);
    final rows = await analysis.receivingPage(supplierId, selectedPage);
    final summaries = await analysis.receivingSummaries(rows);
    return (total: await total, rows: rows, summaries: summaries);
  }

  Widget receivings() => FutureBuilder<
          ({
            int total,
            List<StockReceiving> rows,
            Map<String, SupplierReceivingSummary> summaries
          })>(
      future: loadReceivings(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:total, :rows, :summaries) = snapshot.data!;
        return AppPagedListPanel(
            title: 'Receiving',
            total: total,
            count: rows.length,
            page: page,
            onPrevious: () => setState(() => page--),
            onNext: () => setState(() => page++),
            emptyTitle: 'No receiving records found.',
            itemBuilder: (context, index) {
              final receipt = rows[index];
              final summary = summaries[receipt.id];
              return AppEntityRow(
                  title: StockReceivingRepository.number(receipt),
                  subtitle:
                      '${date(receipt.receivedAt)} · ${summary?.lineCount ?? 0} product lines · Supplier ref: ${receipt.externalReference ?? 'None'}\nReceived by ${summary?.actor ?? 'Unknown'}',
                  amount: canViewCost && summary != null
                      ? formatPeso(summary.actualCents)
                      : null,
                  onTap: () => setState(() => detailReceiving = receipt));
            });
      });

  Future<
      ({
        List<SupplierReceivingLine> items,
        String? actor,
        String? poReference
      })> loadReceivingDetail(String receivingId) async {
    final items = analysis.receivingLines(receivingId);
    final actor = analysis.receivingActor(receivingId);
    final poReference = analysis.receivingPoReference(receivingId);
    return (
      items: await items,
      actor: await actor,
      poReference: await poReference
    );
  }

  Widget receivingDetail(StockReceiving receipt) => FutureBuilder<
          ({
            List<SupplierReceivingLine> items,
            String? actor,
            String? poReference
          })>(
      future: loadReceivingDetail(receipt.id),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:items, :actor, :poReference) = snapshot.data!;
        final actual =
            items.fold<int>(0, (sum, item) => sum + item.actualCents);
        final linked = items.where((item) => item.expectedCents != null);
        final expected =
            linked.fold<int>(0, (sum, item) => sum + item.expectedCents!);
        final comparable =
            linked.fold<int>(0, (sum, item) => sum + item.actualCents);
        return ListView(children: [
          heading(StockReceivingRepository.number(receipt)),
          Text('Finalized ${date(receipt.finalizedAt ?? receipt.receivedAt)}'),
          heading('Supplier document'),
          Text(receipt.externalReference ?? 'No supplier reference'),
          heading('Linked PO'),
          Text(poReference ?? 'None'),
          heading('Received by'),
          Text(actor ?? 'Unknown'),
          heading('Items'),
          for (final item in items)
            ListTile(
                title: Text(item.product),
                subtitle: Text(
                    '${Quantity.format(item.quantityMilli)} units · Expected ${item.expectedUnitCostCents == null ? 'Not recorded' : formatPeso(item.expectedUnitCostCents!)} · Actual ${formatPeso(item.actualUnitCostCents)} / unit${item.batch == null ? '' : ' · Batch ${item.batch}'}${item.serials == null ? '' : '\nSerials: ${item.serials}'}'),
                trailing: Text(formatPeso(item.actualCents))),
          heading('Cost summary'),
          Text('Actual value: ${formatPeso(actual)}'),
          Text(expected == 0
              ? 'Expected comparison unavailable'
              : 'Linked PO expected: ${formatPeso(expected)} · Actual: ${formatPeso(comparable)} · Variance: ${formatPeso(comparable - expected)}'),
        ]);
      });
  Widget purchaseChart(List<SupplierMonthlyValue> values) {
    if (values.isEmpty) return const Text('No purchases for this period.');
    final maximum = values.fold<int>(1,
        (current, row) => row.valueCents > current ? row.valueCents : current);
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
        height: 190,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final row in values)
            Tooltip(
                message:
                    '${row.month}\nPurchase value ${formatPeso(row.valueCents)}\nDeliveries ${row.deliveries}\nUnits received ${Quantity.format(row.quantityMilli)}',
                child: SizedBox(
                    width: 76,
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(formatPeso(row.valueCents),
                              maxLines: 1,
                              style: Theme.of(context).textTheme.labelSmall),
                          const SizedBox(height: 6),
                          Container(
                              width: 38,
                              height: 120 * row.valueCents / maximum,
                              decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(5)))),
                          const SizedBox(height: 6),
                          Text(row.month,
                              style: Theme.of(context).textTheme.labelSmall),
                        ])))
        ]));
  }

  Future<
      ({
        SupplierProcurementSummary procurement,
        List<SupplierMonthlyValue> months,
        SupplierPurchaseTotals totals
      })> loadPerformance() async {
    final supplierId = widget.supplier.id;
    final selectedRange = range;
    final procurement =
        SupplierProcurementRepository(widget.repository.db).summary(supplierId);
    final months = analysis.monthlyValues(
        supplierId, selectedRange.start, selectedRange.end);
    final totals =
        analysis.totals(supplierId, selectedRange.start, selectedRange.end);
    return (
      procurement: await procurement,
      months: await months,
      totals: await totals
    );
  }

  Widget performance() => FutureBuilder<
          ({
            SupplierProcurementSummary procurement,
            List<SupplierMonthlyValue> months,
            SupplierPurchaseTotals totals
          })>(
      future: loadPerformance(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return queryError(snapshot.error!);
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:procurement, :months, :totals) = snapshot.data!;
        final value = procurement;
        return ListView(children: [
          metrics([
            ('Average first delivery', days(value.averageFirstDeliveryDays)),
            ('Average completion', days(value.averageCompletionDays)),
            (
              'On-time first delivery',
              value.onTimeRate == null
                  ? 'Not enough history'
                  : '${value.onTimeRate!.toStringAsFixed(0)}%'
            ),
            (
              'Partial delivery rate',
              value.partialDeliveryRate == null
                  ? 'Not enough history'
                  : '${value.partialDeliveryRate!.toStringAsFixed(0)}%'
            ),
            ('Completed POs', '${value.completedOrders}'),
            ('Open POs · current', '${value.openOrders}'),
            (
              'Cost variance · linked PO',
              totals.expectedCents == 0
                  ? 'Not enough history'
                  : formatPeso(
                      totals.comparableActualCents - totals.expectedCents)
            ),
          ]),
          heading('Purchase value over time'),
          purchaseChart(months),
          heading('Recent actual cost changes'),
          if (value.costChanges.isEmpty) const Text('Not enough history.'),
          for (final change in value.costChanges)
            ListTile(
                title: Text(change.productName),
                subtitle: Text(date(change.lastReceivedAt)),
                trailing: Text(
                    '${formatPeso(change.previousCostCents)} → ${formatPeso(change.lastCostCents)}')),
        ]);
      });
}
