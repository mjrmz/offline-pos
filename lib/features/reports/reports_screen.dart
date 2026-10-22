import 'package:flutter/material.dart';
import '../../core/models/quantity.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/management_report_repository.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';
import 'report_widgets.dart';
import 'overview_charts.dart';

class ReportsScreen extends StatefulWidget {
  final SalesService sales;
  final bool active;
  const ReportsScreen({super.key, required this.sales, this.active = true});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late ReportPeriod period = ReportPeriod.named('This month', DateTime.now());
  Future<ManagementReport>? report;
  Future<InventoryHealthSnapshot>? inventoryHealth;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) refresh();
  }

  @override
  void didUpdateWidget(covariant ReportsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) refresh();
  }

  void refresh() => setState(() {
        report =
            ManagementReportRepository(widget.sales.repository.db).load(period);
        inventoryHealth =
            InventoryHealthRepository(widget.sales.repository.db).load();
      });

  Future<void> selectPeriod(String value) async {
    if (value == 'Custom range') {
      final selected = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 1)),
          initialDateRange: DateTimeRange(
              start: period.start,
              end: period.end.subtract(const Duration(days: 1))));
      if (selected == null || !mounted) return;
      period = ReportPeriod.custom(selected.start, selected.end);
    } else {
      period = ReportPeriod.named(value, DateTime.now());
    }
    refresh();
  }

  String date(DateTime v) =>
      MaterialLocalizations.of(context).formatMediumDate(v);

  @override
  Widget build(BuildContext context) => Scaffold(
          body: ListView(padding: const EdgeInsets.all(20), children: [
        const AppPageHeader(
          title: 'Reports',
          subtitle: 'Business performance and operational insights.',
        ),
        Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PopupMenuButton<String>(
                  tooltip: 'Report period',
                  onSelected: selectPeriod,
                  itemBuilder: (_) => [
                        for (final value in [
                          'Today',
                          'Yesterday',
                          'This week',
                          'This month',
                          'Last month',
                          'Custom range'
                        ])
                          PopupMenuItem(value: value, child: Text(value)),
                      ],
                  child: Chip(
                      avatar: const Icon(Icons.date_range, size: 18),
                      label: Text(period.label))),
              Text(
                  '${date(period.start)} – ${date(period.end.subtract(const Duration(days: 1)))}'),
              IconButton(
                  tooltip: 'Refresh report',
                  onPressed: refresh,
                  icon: const Icon(Icons.refresh)),
            ]),
        const SizedBox(height: 14),
        AppWorkspaceTabs(
          labels: const [
            'Overview',
            'Sales',
            'Profit & Loss',
            'Expenses',
            'Inventory'
          ],
          selectedIndex: tab,
          onSelected: (index) => setState(() => tab = index),
        ),
        const Divider(),
        FutureBuilder<ManagementReport>(
            future: report,
            builder: (context, snapshot) {
              if (report == null) return const SizedBox.shrink();
              if (snapshot.hasError) {
                return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(safeMessage(snapshot.error!)));
              }
              if (!snapshot.hasData) {
                return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()));
              }
              final d = snapshot.data!;
              return switch (tab) {
                0 => overview(d),
                1 => sales(d),
                2 => profitLoss(d),
                3 => expenses(d),
                _ => inventory(d),
              };
            }),
      ]));

  Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));

  String adjustmentMoney(int cents) =>
      cents > 0 ? '+${formatPeso(cents)}' : formatPeso(cents);

  String adjustmentTotal(ManagementReport d) => d.adjustmentsComplete
      ? adjustmentMoney(d.adjustmentImpactCents)
      : 'Partial · ${adjustmentMoney(d.adjustmentImpactCents)} known';

  Widget metrics(List<(String, String)> values) =>
      ReportMetricGrid(values: values);

  Widget pair(Widget left, Widget right) =>
      LayoutBuilder(builder: (context, limits) {
        if (limits.maxWidth < 860) {
          return Column(children: [left, const SizedBox(height: 12), right]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ]);
      });

  Widget trend(ManagementReport d,
      {bool salesOnly = false, bool expenseOnly = false}) {
    final scheme = Theme.of(context).colorScheme;
    return ReportChartCard(
      title: expenseOnly
          ? 'EXPENSE TREND'
          : salesOnly
              ? 'SALES TREND'
              : 'BUSINESS TREND',
      subtitle: 'Daily values for the selected period',
      child: ReportTrendChart(
        emptyMessage: expenseOnly
            ? 'No expenses in this period.'
            : 'No sales in this period.',
        series: expenseOnly
            ? [ReportSeries('Expenses', ReportColors.expenses, d.dailyExpenses)]
            : [
                ReportSeries('Gross sales', ReportColors.gross(scheme),
                    d.dailyGrossSales),
                ReportSeries(
                    'Net sales', ReportColors.net(scheme), d.dailySales),
                ReportSeries('Refunds', ReportColors.refunds, d.dailyRefunds),
                if (!salesOnly)
                  ReportSeries(
                      'Expenses', ReportColors.expenses, d.dailyExpenses),
              ],
      ),
    );
  }

  Widget bars(String title, Map<String, int> values,
          {Color? color, String? empty}) =>
      ReportChartCard(
          title: title,
          child: ReportBars(
              values: values,
              color: color,
              emptyMessage: empty ?? 'No data in this period.'));

  Widget donut(String title, Map<String, int> values, String empty) =>
      ReportChartCard(
          title: title,
          child: ReportDonut(values: values, emptyMessage: empty));

  Widget line(String label, String value, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(children: [
        Expanded(
            child: Text(label,
                style: TextStyle(fontWeight: strong ? FontWeight.bold : null))),
        Text(value,
            textAlign: TextAlign.right,
            style: TextStyle(fontWeight: strong ? FontWeight.bold : null)),
      ]));

  Widget ranked(Map<String, int> values) {
    final entries = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return const Text('No entries for this period.');
    return Column(
        children: [for (final e in entries) line(e.key, formatPeso(e.value))]);
  }

  Widget daily(ManagementReport d) => Column(children: [
        for (final e
            in (d.dailySales.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key))))
          line(date(e.key), formatPeso(e.value)),
      ]);

  Widget overview(ManagementReport d) {
    final topProduct = d.products.entries
        .where((e) => e.value.netCents > 0)
        .toList()
      ..sort((a, b) => b.value.netCents.compareTo(a.value.netCents));
    final topCategory = d.categories.entries
        .where((e) => e.value.netCents > 0)
        .toList()
      ..sort((a, b) => b.value.netCents.compareTo(a.value.netCents));
    final bestDay = d.dailySales.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final expenseCategories = d.expensesByCategory.entries
        .where((e) => e.value > 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    Widget highlight(String title, String value, String detail) => Container(
          width: 240,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 3),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Text(detail, style: Theme.of(context).textTheme.bodySmall),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ReportMetricGrid(overview: true, values: [
        ('Net sales', formatPeso(d.netSalesCents)),
        ('Gross sales', formatPeso(d.grossSalesCents)),
        ('Transactions', '${d.transactions}'),
        ('Average sale', formatPeso(d.averageSaleCents)),
        ('Expenses', formatPeso(d.expenseCents)),
        (
          'Gross profit',
          d.cogsComplete ? formatPeso(d.grossProfitCents) : 'Partial data'
        ),
      ]),
      const SizedBox(height: 12),
      ReportChartCard(
          title: 'Business performance',
          subtitle: 'Daily activity for the selected period',
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            OverviewPerformanceChart(report: d),
            TextButton.icon(
                onPressed: () => _showDailyDetails(d),
                icon: const Icon(Icons.table_rows_outlined, size: 17),
                label: const Text('View daily details')),
          ])),
      const SizedBox(height: 12),
      pair(
          ReportChartCard(
              title: 'Payment method mix',
              subtitle: 'Original tender',
              child: OverviewDonut(
                  values: d.payments,
                  centerLabel: 'Total tender',
                  emptyMessage: 'No payments in this period.')),
          ReportChartCard(
              title: 'Top products by net sales',
              child: OverviewBars(values: {
                for (final e in d.products.entries) e.key: e.value.netCents
              }, emptyMessage: 'No product sales in this period.'))),
      const SizedBox(height: 12),
      pair(
          ReportChartCard(
              title: 'Expense mix',
              child: OverviewDonut(
                  values: d.expensesByCategory,
                  centerLabel: 'Expenses',
                  emptyMessage: 'No expenses in this period.')),
          ReportChartCard(
              title: 'Sales by category',
              child: OverviewBars(values: {
                for (final e in d.categories.entries) e.key: e.value.netCents
              }, emptyMessage: 'No category sales in this period.'))),
      const SizedBox(height: 12),
      ReportChartCard(
          title: 'Business highlights',
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            highlight(
                'Best-selling product',
                topProduct.isEmpty ? '—' : topProduct.first.key,
                topProduct.isEmpty
                    ? 'No sales'
                    : formatPeso(topProduct.first.value.netCents)),
            highlight(
                'Top category',
                topCategory.isEmpty ? '—' : topCategory.first.key,
                topCategory.isEmpty
                    ? 'No sales'
                    : formatPeso(topCategory.first.value.netCents)),
            highlight(
                'Best sales day',
                bestDay.isEmpty ? '—' : date(bestDay.first.key),
                bestDay.isEmpty ? 'No sales' : formatPeso(bestDay.first.value)),
            highlight(
                'Largest expense category',
                expenseCategories.isEmpty ? '—' : expenseCategories.first.key,
                expenseCategories.isEmpty
                    ? 'No expenses'
                    : formatPeso(expenseCategories.first.value)),
            highlight(
                'Refund total', formatPeso(d.refundsCents), 'Selected period'),
            highlight(
                'Inventory adjustments', adjustmentTotal(d), 'Net cost impact'),
          ])),
      if (!d.cogsComplete)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ReportInfoBanner(
                title: 'Historical cost data incomplete',
                message:
                    '${d.incompleteCostItems} sale items lack complete historical cost provenance. Known COGS: ${formatPeso(d.cogsCents)}. Gross profit is not fully determined.')),
    ]);
  }

  Future<void> _showDailyDetails(ManagementReport d) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Daily sales details'),
          content: SizedBox(
              width: 720,
              height: 480,
              child: ListView(children: [
                SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Gross'), numeric: true),
                      DataColumn(label: Text('Refunds'), numeric: true),
                      DataColumn(label: Text('Net'), numeric: true),
                    ], rows: [
                      for (var day = d.period.start;
                          day.isBefore(d.period.end);
                          day = DateTime(day.year, day.month, day.day + 1))
                        DataRow(cells: [
                          DataCell(Text(date(day))),
                          DataCell(
                              Text(formatPeso(d.dailyGrossSales[day] ?? 0))),
                          DataCell(Text(formatPeso(d.dailyRefunds[day] ?? 0))),
                          DataCell(Text(formatPeso(d.dailySales[day] ?? 0))),
                        ]),
                    ])),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'))
          ],
        ),
      );

  Widget sales(ManagementReport d) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        metrics([
          ('Gross sales', formatPeso(d.grossSalesCents)),
          ('Refunds', formatPeso(d.itemRefundCents)),
          ('Voids / reversals', formatPeso(d.reversalCents)),
          ('Net sales', formatPeso(d.netSalesCents)),
          ('Transactions', '${d.transactions}'),
          ('Average sale', formatPeso(d.averageSaleCents)),
        ]),
        const SizedBox(height: 12),
        trend(d, salesOnly: true),
        const SizedBox(height: 12),
        pair(
            bars('TOP PRODUCTS BY NET SALES',
                {for (final e in d.products.entries) e.key: e.value.netCents}),
            bars('SALES BY CATEGORY', {
              for (final e in d.categories.entries) e.key: e.value.netCents
            })),
        const SizedBox(height: 12),
        pair(
            donut('PAYMENT METHOD MIX · ORIGINAL TENDER', d.payments,
                'No payments in this period.'),
            bars('SALES BY CASHIER',
                {for (final e in d.cashiers.entries) e.key: e.value.netCents})),
        heading('SALES BY PRODUCT'),
        groupTable(d.products, profit: false),
        heading('SALES BY DAY'),
        daily(d),
      ]);

  Widget profitLoss(ManagementReport d) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Management Profit & Loss'),
        metrics([
          ('Net revenue', formatPeso(d.netSalesCents)),
          (
            'COGS',
            d.cogsComplete
                ? formatPeso(d.cogsCents)
                : '${formatPeso(d.cogsCents)} known'
          ),
          (
            'Gross profit',
            d.cogsComplete ? formatPeso(d.grossProfitCents) : 'Unavailable'
          ),
          (
            'Gross margin',
            d.cogsComplete && d.netSalesCents != 0
                ? '${(100 * d.grossProfitCents / d.netSalesCents).toStringAsFixed(2)}%'
                : 'Unavailable'
          ),
          ('Operating expenses', formatPeso(d.expenseCents)),
          (
            'Operating profit',
            d.cogsComplete && d.adjustmentsComplete
                ? formatPeso(d.operatingProfitCents)
                : 'Unavailable'
          ),
        ]),
        if (!d.cogsComplete)
          ReportInfoBanner(
              title: 'Historical cost data incomplete',
              message:
                  '${d.incompleteCostItems} sale item(s) with ${formatPeso(d.incompleteCostRevenueCents)} in original line revenue lack complete inventory allocations. COGS shows only persisted historical costs; gross and operating profit are not fully determined.'),
        if (!d.adjustmentsComplete)
          const ReportInfoBanner(
              title: 'Inventory adjustment cost incomplete',
              message:
                  'Some historical adjustments lack complete cost allocations. Operating profit is unavailable.'),
        const SizedBox(height: 12),
        ReportChartCard(
            title: 'PROFIT BRIDGE',
            child: ReportBars(values: {
              'Gross sales': d.grossSalesCents,
              'Refunds and reversals': -d.refundsCents,
              'Net revenue': d.netSalesCents,
              if (d.cogsComplete) 'COGS': -d.cogsCents,
              if (d.cogsComplete) 'Gross profit': d.grossProfitCents,
              if (d.adjustmentsComplete)
                'Inventory adjustments': d.adjustmentImpactCents,
              'Operating expenses': -d.expenseCents,
              if (d.cogsComplete && d.adjustmentsComplete)
                'Operating profit': d.operatingProfitCents,
            })),
        heading('REVENUE'),
        line('Gross sales', formatPeso(d.grossSalesCents)),
        line(
            'Less full sale reversals',
            d.reversalCents == 0
                ? formatPeso(0)
                : '-${formatPeso(d.reversalCents)}'),
        line(
            'Less item refunds',
            d.itemRefundCents == 0
                ? formatPeso(0)
                : '-${formatPeso(d.itemRefundCents)}'),
        const Divider(),
        line('Net revenue', formatPeso(d.netSalesCents), strong: true),
        heading('COST OF GOODS SOLD'),
        line(
            'Historical allocated inventory cost',
            d.cogsComplete
                ? (d.cogsCents == 0
                    ? formatPeso(0)
                    : '-${formatPeso(d.cogsCents)}')
                : '—'),
        const Divider(),
        line('Gross profit',
            d.cogsComplete ? formatPeso(d.grossProfitCents) : '—',
            strong: true),
        line(
            'Gross margin',
            d.cogsComplete && d.netSalesCents != 0
                ? '${(100 * d.grossProfitCents / d.netSalesCents).toStringAsFixed(2)}%'
                : '—'),
        heading('INVENTORY ADJUSTMENTS'),
        if (d.adjustments.isEmpty)
          const Text('No inventory adjustments in this period.'),
        for (final adjustment in d.adjustments)
          line(
              adjustment.label,
              adjustment.incompleteEvents == 0
                  ? adjustmentMoney(adjustment.knownImpactCents)
                  : 'Partial · ${adjustmentMoney(adjustment.knownImpactCents)} known'),
        const Divider(),
        line('Net inventory adjustment', adjustmentTotal(d), strong: true),
        if (!d.adjustmentsComplete)
          Text(
              '${d.incompleteAdjustmentEvents} historical adjustment(s) have incomplete cost allocations.'),
        heading('OPERATING EXPENSES'),
        ranked(d.expensesByCategory),
        const Divider(),
        line('Total operating expenses', formatPeso(d.expenseCents),
            strong: true),
        const Divider(),
        line(
            'OPERATING PROFIT',
            d.cogsComplete && d.adjustmentsComplete
                ? formatPeso(d.operatingProfitCents)
                : '—',
            strong: true),
        heading('PRODUCT PROFITABILITY'),
        groupTable(d.products, profit: true, complete: d.cogsComplete),
        heading('CATEGORY PROFITABILITY'),
        groupTable(d.categories,
            profit: true, complete: d.cogsComplete, showQuantity: false),
      ]);

  Widget groupTable(Map<String, ReportGroup> groups,
      {required bool profit, bool complete = true, bool showQuantity = true}) {
    if (groups.isEmpty) return const Text('No rows for this period.');
    final sorted = groups.values.toList()
      ..sort((a, b) => b.netCents.compareTo(a.netCents));
    return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(columnSpacing: 24, columns: [
          const DataColumn(label: Text('Product / Category')),
          if (showQuantity)
            const DataColumn(label: Text('Qty sold'), numeric: true),
          DataColumn(
              label: Text(profit ? 'Net sales' : 'Gross sales'), numeric: true),
          if (!profit) const DataColumn(label: Text('Refunds'), numeric: true),
          if (!profit)
            const DataColumn(label: Text('Net sales'), numeric: true),
          if (profit) const DataColumn(label: Text('COGS'), numeric: true),
          if (profit)
            const DataColumn(label: Text('Gross profit'), numeric: true),
          if (profit) const DataColumn(label: Text('Margin'), numeric: true),
        ], rows: [
          for (final g in sorted)
            DataRow(cells: [
              DataCell(Text(g.label)),
              if (showQuantity)
                DataCell(Text('${Quantity.format(g.quantityMilli)} ${g.unit}')),
              DataCell(Text(formatPeso(profit ? g.netCents : g.grossCents))),
              if (!profit) DataCell(Text(formatPeso(g.refundsCents))),
              if (!profit) DataCell(Text(formatPeso(g.netCents))),
              if (profit)
                DataCell(Text(complete ? formatPeso(g.cogsCents) : '—')),
              if (profit)
                DataCell(Text(complete ? formatPeso(g.profitCents) : '—')),
              if (profit)
                DataCell(Text(complete && g.netCents != 0
                    ? '${(100 * g.profitCents / g.netCents).toStringAsFixed(2)}%'
                    : '—')),
            ])
        ]));
  }

  String source(String key) => switch (key) {
        'drawer' => 'Current cash drawer',
        'petty' => 'Petty cash',
        'company' => 'Company cash',
        'personal' => 'Paid personally',
        'historical_drawer' => 'Historical drawer',
        _ => 'Unknown source',
      };

  Widget expenses(ManagementReport d) {
    final top = d.expensesByCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final actual = d.expenses.where((e) => e.amountCents > 0).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      metrics([
        ('Total expenses', formatPeso(d.expenseCents)),
        ('Expense count', '${actual.length}'),
        (
          'Average expense',
          formatPeso(actual.isEmpty
              ? 0
              : actual.fold<int>(0, (s, e) => s + e.amountCents) ~/
                  actual.length)
        ),
        ('Top category', top.isEmpty ? '—' : top.first.key),
      ]),
      const SizedBox(height: 12),
      trend(d, expenseOnly: true),
      const SizedBox(height: 12),
      d.expensesByCategory.values.any((value) => value < 0)
          ? bars('EXPENSE BY CATEGORY', d.expensesByCategory,
              color: ReportColors.expenses,
              empty: 'No expenses in this period.')
          : donut('EXPENSE BY CATEGORY', d.expensesByCategory,
              'No expenses in this period.'),
      const SizedBox(height: 12),
      pair(
          bars('EXPENSE BY USER', d.expensesByUser,
              color: ReportColors.expenses),
          bars(
              'PAID FROM',
              {
                for (final e in d.expensesBySource.entries)
                  source(e.key): e.value
              },
              color: ReportColors.expenses)),
      heading('EXPENSE RECORDS'),
      if (d.expenses.isEmpty) const Text('No expenses in this period.'),
      if (d.expenses.isNotEmpty)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(columnSpacing: 22, columns: const [
              DataColumn(label: Text('Date')),
              DataColumn(label: Text('Category')),
              DataColumn(label: Text('Payee')),
              DataColumn(label: Text('Paid from')),
              DataColumn(label: Text('Recorded by')),
              DataColumn(label: Text('Amount'), numeric: true),
            ], rows: [
              for (final e in d.expenses)
                DataRow(cells: [
                  DataCell(Text(date(e.date.toLocal()))),
                  DataCell(
                      Text(e.legacy ? '${e.category} · Legacy' : e.category)),
                  DataCell(Text(e.payee)),
                  DataCell(Text(source(e.source))),
                  DataCell(Text(e.user)),
                  DataCell(Text(formatPeso(e.amountCents))),
                ])
            ])),
    ]);
  }

  Widget _healthReport(InventoryHealthSnapshot health) {
    final products = health.products.values.toList();
    final top = [...products]
      ..sort((a, b) => b.costValueCents.compareTo(a.costValueCents));
    final dead = products.where((p) => p.deadStock).toList();
    final categories = <String, int>{};
    for (final product in products) {
      categories.update(product.category, (v) => v + product.costValueCents,
          ifAbsent: () => product.costValueCents);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading('CURRENT INVENTORY HEALTH'),
      const Text(
          'Present state as of now. The selected report period does not change these stock values.'),
      metrics([
        ('Slow moving', '${health.slowCount}'),
        ('Dead-stock cost value', formatPeso(health.deadStockValueCents)),
        ('Near expiry batches', '${health.nearExpiryCount}'),
        ('Expired batches', '${health.expiredCount}'),
        (
          'Reorder needed',
          '${products.where((p) => p.planning.belowReorderLevel).length}'
        ),
      ]),
      const SizedBox(height: 12),
      pair(
          bars('INVENTORY VALUE BY CATEGORY', categories,
              color: ReportColors.inventory(Theme.of(context).colorScheme),
              empty: 'No inventory in this category.'),
          bars('TOP INVENTORY VALUE',
              {for (final p in top.take(8)) p.name: p.costValueCents},
              color: ReportColors.inventory(Theme.of(context).colorScheme),
              empty: 'No inventory value available.')),
      const SizedBox(height: 12),
      pair(
          bars(
              'CURRENT INVENTORY AGING',
              {
                for (final bucket in health.aging)
                  bucket.label: bucket.costCents
              },
              color: ReportColors.inventory(Theme.of(context).colorScheme),
              empty: 'No inventory aging data.'),
          ReportChartCard(
              title: 'CURRENT EXPIRY',
              child: Column(children: [
                line('Expired batches', '${health.expiredCount}'),
                line('Near expiry batches', '${health.nearExpiryCount}'),
                line('Later expiry batches',
                    '${health.expiry.length - health.expiredCount - health.nearExpiryCount}'),
              ]))),
      heading('CURRENT INVENTORY AGING'),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(columns: const [
            DataColumn(label: Text('Age bucket')),
            DataColumn(label: Text('Remaining qty')),
            DataColumn(label: Text('Cost value')),
          ], rows: [
            for (final bucket in health.aging)
              DataRow(cells: [
                DataCell(Text(bucket.label)),
                DataCell(Text(Quantity.format(bucket.quantityMilli))),
                DataCell(Text(formatPeso(bucket.costCents))),
              ])
          ])),
      heading('SLOW AND DEAD STOCK'),
      Text(
          '${health.slowCount} slow-moving products · ${health.deadCount} dead-stock products'),
      if (dead.isNotEmpty)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(columns: const [
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('Available')),
              DataColumn(label: Text('Oldest stock')),
              DataColumn(label: Text('Last sold')),
              DataColumn(label: Text('Cost value')),
            ], rows: [
              for (final product in dead)
                DataRow(cells: [
                  DataCell(Text(product.name)),
                  DataCell(
                      Text(Quantity.format(product.planning.availableMilli))),
                  DataCell(Text(product.planning.oldestStockAt == null
                      ? 'Unknown'
                      : MaterialLocalizations.of(context)
                          .formatMediumDate(product.planning.oldestStockAt!))),
                  DataCell(Text(product.lastSoldAt == null
                      ? 'Never sold'
                      : MaterialLocalizations.of(context)
                          .formatMediumDate(product.lastSoldAt!))),
                  DataCell(Text(formatPeso(product.costValueCents))),
                ])
            ])),
      heading('CURRENT EXPIRY'),
      Text(
          '${health.nearExpiryCount} near expiry · ${health.expiredCount} expired batches. No automatic write-off.'),
      if (health.expiry.isNotEmpty)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(columns: const [
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('Batch')),
              DataColumn(label: Text('Remaining')),
              DataColumn(label: Text('Expiry')),
              DataColumn(label: Text('Cost value')),
              DataColumn(label: Text('Status')),
            ], rows: [
              for (final batch in health.expiry.where(
                  (b) => b.daysRemaining <= health.settings.nearExpiryDays))
                DataRow(cells: [
                  DataCell(Text(batch.productName)),
                  DataCell(Text(batch.batchNumber)),
                  DataCell(Text(Quantity.format(batch.quantityMilli))),
                  DataCell(Text(MaterialLocalizations.of(context)
                      .formatMediumDate(batch.expiryDate))),
                  DataCell(Text(formatPeso(batch.costCents))),
                  DataCell(Text(batch.status)),
                ])
            ])),
      heading('TOP INVENTORY VALUE'),
      if (top.isNotEmpty)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(columns: const [
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('Available')),
              DataColumn(label: Text('Cost value')),
              DataColumn(label: Text('% of total')),
            ], rows: [
              for (final product in top.take(10))
                DataRow(cells: [
                  DataCell(Text(product.name)),
                  DataCell(
                      Text(Quantity.format(product.planning.availableMilli))),
                  DataCell(Text(formatPeso(product.costValueCents))),
                  DataCell(Text(health.inventoryValueCents == 0
                      ? '0%'
                      : '${(product.costValueCents * 1000 ~/ health.inventoryValueCents) / 10}%')),
                ])
            ])),
      heading('INVENTORY VALUE BY CATEGORY'),
      for (final category in categories.entries)
        line(category.key, formatPeso(category.value)),
      heading('REORDER NEEDS'),
      for (final product in products.where((p) => p.planning.belowReorderLevel))
        Text(
            '${product.name}: ${Quantity.format(product.planning.suggestedReorderMilli)} suggested; '
            '${Quantity.format(product.planning.incomingMilli)} incoming'),
    ]);
  }

  Widget inventory(ManagementReport d) {
    final complete =
        d.inventory.every((i) => i.retailCents != null && i.costCents != null);
    final cost = d.inventory.fold<int>(0, (s, i) => s + (i.costCents ?? 0));
    final retail = d.inventory.fold<int>(0, (s, i) => s + (i.retailCents ?? 0));
    final low = d.inventory.where((i) => i.low).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Current inventory snapshot · not filtered by sales period'),
      metrics([
        (
          'Inventory cost value',
          d.inventory.every((i) => i.costCents != null)
              ? formatPeso(cost)
              : 'Partial / unavailable'
        ),
        (
          'Retail value',
          complete ? formatPeso(retail) : 'Partial / unavailable'
        ),
        (
          'Potential gross profit',
          complete ? formatPeso(retail - cost) : 'Unavailable'
        ),
        ('Low stock', '${low.length}'),
        ('Out of stock', '${low.where((i) => i.out).length}'),
      ]),
      const SizedBox(height: 12),
      bars('INVENTORY ADJUSTMENT IMPACT',
          {for (final a in d.adjustments) a.label: a.knownImpactCents},
          empty: 'No adjustment impact to chart.'),
      FutureBuilder<InventoryHealthSnapshot>(
          future: inventoryHealth,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(
                  'Current health unavailable: ${safeMessage(snapshot.error!)}');
            }
            if (!snapshot.hasData) return const LinearProgressIndicator();
            return _healthReport(snapshot.data!);
          }),
      heading('INVENTORY ADJUSTMENT IMPACT'),
      if (d.adjustments.isEmpty)
        const Text('No inventory adjustments in this period.'),
      if (d.adjustments.isNotEmpty)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(columns: const [
              DataColumn(label: Text('Reason')),
              DataColumn(label: Text('Events'), numeric: true),
              DataColumn(label: Text('Cost impact'), numeric: true),
            ], rows: [
              for (final a in d.adjustments)
                DataRow(cells: [
                  DataCell(Text(a.label)),
                  DataCell(Text('${a.events}')),
                  DataCell(Text(a.incompleteEvents == 0
                      ? adjustmentMoney(a.knownImpactCents)
                      : 'Partial · ${adjustmentMoney(a.knownImpactCents)} known')),
                ]),
            ])),
      line('Net inventory impact', adjustmentTotal(d), strong: true),
      if (!d.adjustmentsComplete)
        Text(
            '${d.incompleteAdjustmentEvents} historical adjustment(s) have incomplete cost allocations.'),
      heading('LOW STOCK'),
      if (low.isEmpty) const Text('No low stock products.'),
      if (low.isNotEmpty)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(columns: const [
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('Available')),
              DataColumn(label: Text('Threshold')),
              DataColumn(label: Text('Status')),
            ], rows: [
              for (final i in low)
                DataRow(cells: [
                  DataCell(Text(i.product)),
                  DataCell(
                      Text('${Quantity.format(i.availableMilli)} ${i.unit}')),
                  DataCell(
                      Text('${Quantity.format(i.thresholdMilli)} ${i.unit}')),
                  DataCell(Text(i.out ? 'Out of stock' : 'Low stock')),
                ])
            ])),
      heading('INVENTORY BY PRODUCT'),
      if (d.inventory.isEmpty) const Text('No inventory products.'),
      if (d.inventory.isNotEmpty)
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(columns: const [
              DataColumn(label: Text('Product')),
              DataColumn(label: Text('Category')),
              DataColumn(label: Text('On hand')),
              DataColumn(label: Text('Cost value'), numeric: true),
              DataColumn(label: Text('Retail value'), numeric: true),
            ], rows: [
              for (final i in d.inventory)
                DataRow(cells: [
                  DataCell(Text(i.product)),
                  DataCell(Text(i.category)),
                  DataCell(
                      Text('${Quantity.format(i.quantityMilli)} ${i.unit}')),
                  DataCell(Text(i.costCents == null
                      ? 'Unavailable'
                      : formatPeso(i.costCents!))),
                  DataCell(Text(i.retailCents == null
                      ? 'Unavailable'
                      : formatPeso(i.retailCents!))),
                ])
            ])),
    ]);
  }
}
