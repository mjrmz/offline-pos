import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/services/sales_service.dart';
import '../../data/database.dart';
import '../../data/daos/customer_purchase_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';
import '../sales_history/sales_history_screen.dart';
import 'customer_profile_ui.dart';

class CustomerPurchasesPanel extends StatefulWidget {
  final String customerId;
  final CustomerPurchaseRepository repository;
  final ActiveUser user;
  final SalesService? sales;
  final PosRepository? pos;
  final ReceiptService? receipts;
  const CustomerPurchasesPanel(
      {super.key,
      required this.customerId,
      required this.repository,
      required this.user,
      this.sales,
      this.pos,
      this.receipts});

  @override
  State<CustomerPurchasesPanel> createState() => _CustomerPurchasesPanelState();
}

class _CustomerPurchasesPanelState extends State<CustomerPurchasesPanel> {
  String period = 'This month';
  DateTimeRange? custom;
  int page = 0;

  @override
  void didUpdateWidget(covariant CustomerPurchasesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customerId != widget.customerId) {
      period = 'This month';
      custom = null;
      page = 0;
    }
  }

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

  Future<
      ({
        CustomerPurchaseSummary summary,
        List<Sale> sales,
        Map<String, String> methods,
        Map<String, int> returns
      })> load() async {
    final selectedRange = range;
    final selectedPage = page;
    final customerId = widget.customerId;
    final summary = widget.repository
        .summary(customerId, selectedRange.start, selectedRange.end);
    final sales = await widget.repository
        .page(customerId, selectedRange.start, selectedRange.end, selectedPage);
    final methods = widget.repository.paymentMethods(sales);
    final returns = widget.repository.returnedValues(sales);
    return (
      summary: await summary,
      sales: sales,
      methods: await methods,
      returns: await returns
    );
  }

  Future<void> openSale(Sale sale) async {
    if (widget.sales == null) return;
    await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
            child: SizedBox(
                width: 900,
                height: 730,
                child: SalesHistoryScreen(
                    sales: widget.sales!,
                    user: widget.user,
                    pos: widget.pos,
                    receipts: widget.receipts,
                    initialSaleId: sale.id))));
  }

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
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
                    });
                  }),
              Text(
                  '${date(range.start)} – ${date(range.end.subtract(const Duration(days: 1)))}')
            ]),
        const SizedBox(height: 12),
        Expanded(
            child: FutureBuilder<
                    ({
                      CustomerPurchaseSummary summary,
                      List<Sale> sales,
                      Map<String, String> methods,
                      Map<String, int> returns
                    })>(
                key: ValueKey('$period:$page:${custom?.start}:${custom?.end}'),
                future: load(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(safeMessage(snapshot.error!)));
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final (:summary, :sales, :methods, :returns) = snapshot.data!;
                  return Column(children: [
                    CustomerProfileKpis([
                      ('Net spend', formatPeso(summary.netCents)),
                      ('Transactions', '${summary.completedCount}'),
                      ('Average sale', formatPeso(summary.averageCents)),
                      ('Returned value', formatPeso(summary.returnedCents)),
                    ]),
                    const SizedBox(height: 20),
                    Expanded(
                        child: AppPagedListPanel(
                            title: 'Purchases',
                            total: summary.count,
                            count: sales.length,
                            page: page,
                            onPrevious: () => setState(() => page--),
                            onNext: () => setState(() => page++),
                            emptyTitle: 'No purchases for this period.',
                            emptyMessage:
                                'Completed sales for this customer will appear here.',
                            itemBuilder: (context, index) {
                              final sale = sales[index];
                              final returned = returns[sale.id] ?? 0;
                              return AppEntityRow(
                                  title: sale.receiptNumber ?? 'Legacy sale',
                                  subtitle:
                                      '${date(sale.createdAt)} · ${methods[sale.id] ?? 'No payment'} · ${sale.status}\nGross ${formatPeso(sale.totalCents)} · Returned ${formatPeso(returned)}',
                                  amount:
                                      formatPeso(sale.totalCents - returned),
                                  onTap: () => openSale(sale));
                            }))
                  ]);
                }))
      ]));
}
