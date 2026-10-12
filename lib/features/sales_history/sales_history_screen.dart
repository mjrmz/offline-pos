import 'package:flutter/material.dart';
import '../../shared/theme/app_theme.dart';
import '../../core/models/active_user.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/sales_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../core/models/quantity.dart';
import '../../core/models/sale_line_format.dart';
import '../../data/daos/rma_repository.dart';
import '../contacts/new_customer_rma_page.dart';

String saleReference(SaleSummary row) =>
    'Receipt #${row.sale.receiptNumber ?? 'Legacy sale'}';

String _saleDate(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  return '${months[value.month - 1]} ${value.day}, ${value.year} · '
      '$hour:${value.minute.toString().padLeft(2, '0')} ${value.hour < 12 ? 'AM' : 'PM'}';
}

class SalesHistoryScreen extends StatefulWidget {
  final SalesService sales;
  final ActiveUser user;
  final bool active;
  final ReceiptService? receipts;
  const SalesHistoryScreen(
      {super.key,
      required this.sales,
      required this.user,
      this.active = true,
      this.receipts});
  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  List<SaleSummary> rows = [];
  List<MadeOrderSummary> orders = [];
  String? error;
  String search = '';
  Set<String> itemMatches = {};
  int searchGeneration = 0;
  String dateFilter = 'Today';
  String statusFilter = 'All statuses';
  String paymentFilter = 'All payments';
  String complianceFilter = 'All';
  DateTimeRange? customRange;
  @override
  void initState() {
    super.initState();
    if (widget.active) refresh();
  }

  @override
  void didUpdateWidget(covariant SalesHistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) refresh();
  }

  Future<void> refresh() async {
    try {
      final result = await widget.sales.history();
      final currentOrders = widget.user.can(PosPermission.manageCatalog)
          ? await widget.sales.madeOrders()
          : <MadeOrderSummary>[];
      if (mounted) {
        setState(() {
          rows = result;
          orders = currentOrders;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  String _orderReference(String saleId) {
    final row = rows.where((entry) => entry.sale.id == saleId).firstOrNull;
    return row == null ? 'Sale' : saleReference(row);
  }

  Future<void> updateSearch(String value) async {
    final generation = ++searchGeneration;
    setState(() => search = value);
    if (value.trim().isEmpty) {
      setState(() => itemMatches = {});
      return;
    }
    try {
      final found = await widget.sales.searchSaleIds(value);
      if (mounted && generation == searchGeneration) {
        setState(() => itemMatches = found);
      }
    } catch (failure) {
      if (mounted && generation == searchGeneration) {
        setState(() => error = safeMessage(failure));
      }
    }
  }

  bool _inRange(DateTime date) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    return switch (dateFilter) {
      'Today' => !date.isBefore(start),
      'Yesterday' => !date.isBefore(start.subtract(const Duration(days: 1))) &&
          date.isBefore(start),
      'Last 7 days' => !date.isBefore(start.subtract(const Duration(days: 6))),
      'This month' => date.year == today.year && date.month == today.month,
      'Custom range' => customRange != null &&
          !date.isBefore(customRange!.start) &&
          date.isBefore(customRange!.end.add(const Duration(days: 1))),
      _ => true,
    };
  }

  List<SaleSummary> get datedRows =>
      rows.where((row) => _inRange(row.sale.createdAt)).toList();

  List<SaleSummary> get filteredRows => datedRows.where((row) {
        final query = search.trim().toLowerCase();
        return (query.isEmpty ||
                saleReference(row).toLowerCase().contains(query) ||
                '${row.sale.birInvoiceNumber ?? ''}'.contains(query) ||
                itemMatches.contains(row.sale.id) ||
                row.customerName.toLowerCase().contains(query) ||
                row.cashierName.toLowerCase().contains(query)) &&
            (statusFilter == 'All statuses' ||
                row.sale.status == statusFilter.toLowerCase()) &&
            (paymentFilter == 'All payments' ||
                row.paymentMethod == paymentFilter.toLowerCase()) &&
            (complianceFilter == 'All' ||
                (row.sale.birInvoiceNumber != null ? 'BIR' : 'Non-BIR') ==
                    complianceFilter);
      }).toList();

  Widget _chip(String label, Color color) => Chip(
      visualDensity: VisualDensity.compact,
      label: Text(label),
      backgroundColor: color.withValues(alpha: .12),
      side: BorderSide(color: color.withValues(alpha: .3)));

  Widget _filter(
          String value, List<String> options, ValueChanged<String> change) =>
      DropdownButton<String>(
          value: value,
          items: options
              .map((option) =>
                  DropdownMenuItem(value: option, child: Text(option)))
              .toList(),
          onChanged: (next) {
            if (next != null) change(next);
          });

  Future<void> open(String saleId) async {
    try {
      final detail = await widget.sales.detail(saleId);
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                  width: 560,
                  height: MediaQuery.sizeOf(context).height,
                  child: AlertDialog(
                      insetPadding: const EdgeInsets.all(8),
                      title: Text(saleReference(detail.summary)),
                      content: SizedBox(
                          width: 500,
                          child: ListView(shrinkWrap: true, children: [
                            Wrap(spacing: 8, children: [
                              _chip(detail.summary.sale.status,
                                  AppStatusColors.of(context).warning),
                              _chip(
                                  detail.summary.sale.birInvoiceNumber == null
                                      ? 'Non-BIR'
                                      : 'BIR',
                                  AppStatusColors.of(context).info),
                            ]),
                            Text('Cashier: ${detail.summary.cashierName}'),
                            Text('Customer: ${detail.summary.customerName}'),
                            Text(
                                'Date: ${_saleDate(detail.summary.sale.createdAt)}'),
                            Text(detail.summary.sale.birInvoiceNumber == null
                                ? 'Pre-BIR / Non-BIR sale'
                                : 'BIR invoice ${detail.summary.sale.birInvoiceNumber}'),
                            const Divider(),
                            Text('Items',
                                style: Theme.of(context).textTheme.titleMedium),
                            for (var i = 0; i < detail.items.length; i++)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(detail.productNames[i]),
                                subtitle: Text(
                                    '${saleQuantityLabel(detail.items[i].quantityMilli == 0 ? detail.items[i].quantity * Quantity.scale : detail.items[i].quantityMilli, detail.items[i].saleUnit)} × ${formatPeso(detail.items[i].unitPriceCents)}${saleModeLabel(detail.items[i].saleMode, batchNumber: detail.items[i].batchNumber).isEmpty ? '' : ' · ${saleModeLabel(detail.items[i].saleMode, batchNumber: detail.items[i].batchNumber)}'}${(detail.serialNumbersByItem[detail.items[i].id] ?? const <String>[]).isEmpty ? '' : ' · Serial: ${detail.serialNumbersByItem[detail.items[i].id]!.join(', ')}'}'),
                                trailing: Text(
                                    formatPeso(detail.items[i].lineTotalCents)),
                              ),
                            const Divider(),
                            Text(
                                'Total: ${formatPeso(detail.summary.sale.totalCents)}',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 8),
                            Text('Payment',
                                style: Theme.of(context).textTheme.titleMedium),
                            for (final payment in detail.payments)
                              Text(
                                  '${payment.method}: ${formatPeso(payment.amountCents)}'),
                            if (detail.reversal != null ||
                                detail.itemRefunds.isNotEmpty) ...[
                              const Divider(),
                              Text('Refund / reversal history',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              if (detail.reversal != null)
                                Text(
                                    '${detail.reversal!.kind} · ${formatPeso(detail.reversal!.amountCents)} · ${_saleDate(detail.reversal!.createdAt)}'),
                              for (final refund in detail.itemRefunds)
                                Text(
                                    'Item refund · ${formatPeso(refund.amountCents)} · ${_saleDate(refund.createdAt)}'),
                            ],
                            ExpansionTile(
                                title: const Text('Technical details'),
                                children: [
                                  SelectableText(
                                      'Sale ID: ${detail.summary.sale.id}'),
                                  if (detail.reversal != null)
                                    SelectableText(
                                        'Reversal actor ID: ${detail.reversal!.actorId}'),
                                ]),
                            if (detail.reversal != null)
                              Text(detail.reversal!.stockRestored
                                  ? 'Stock restored to sellable inventory'
                                  : 'Stock not returned to sellable inventory'),
                          ])),
                      actions: [
                        if (detail.summary.sale.status == 'completed')
                          OutlinedButton.icon(
                              onPressed: () async {
                                Navigator.pop(context);
                                await Navigator.of(this.context).push(
                                    MaterialPageRoute(
                                        builder: (_) => NewCustomerRmaPage(
                                            repository: RmaRepository(
                                                widget.sales.repository.db),
                                            user: widget.user,
                                            initialReceipt: detail
                                                .summary.sale.receiptNumber)));
                              },
                              icon: const Icon(Icons.assignment_return),
                              label: const Text('Create RMA / Warranty')),
                        TextButton(
                            onPressed: () async {
                              final ok =
                                  await widget.receipts?.reprint(saleId) ??
                                      false;
                              if (context.mounted) Navigator.pop(context);
                              if (mounted) {
                                setState(() => error = ok
                                    ? null
                                    : 'Receipt could not be printed. Check printer settings and connection.');
                              }
                            },
                            child: const Text('Reprint receipt')),
                        if (widget.user.can(PosPermission.reverseSale) &&
                            detail.summary.sale.status == 'completed') ...[
                          TextButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                await reverse(saleId, false);
                              },
                              child: const Text('Void')),
                          TextButton(
                              onPressed: () async {
                                Navigator.pop(context);
                                await reverse(saleId, true);
                              },
                              child: const Text('Record full refund')),
                        ],
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close')),
                      ]))));
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> reverse(String saleId, bool refund) async {
    SaleDetail detail;
    try {
      detail = await widget.sales.detail(saleId);
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
      return;
    }
    if (!mounted) return;
    final cashToReturn =
        detail.summary.sale.customerId == null ? 0 : detail.cashAmountCents;
    final decision = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(refund ? 'Record full refund' : 'Void sale'),
                content: Text((refund
                        ? 'Return items to sellable stock?'
                        : 'Void this sale and restore all sold stock?') +
                    (cashToReturn > 0
                        ? '\n\nConfirm cash of ${formatPeso(cashToReturn)} was returned to the customer. This will reduce the current drawer.'
                        : '')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  if (refund)
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(cashToReturn > 0
                            ? 'Keep stock and confirm cash returned'
                            : 'No')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(cashToReturn > 0
                          ? 'Restore stock and confirm cash returned'
                          : refund
                              ? 'Yes'
                              : 'Confirm'))
                ]));
    if (decision == null) return;
    try {
      if (refund) {
        await widget.sales.refundSale(saleId,
            returnToSellableStock: decision,
            cashRefundConfirmed: cashToReturn > 0);
      } else {
        await widget.sales
            .voidSale(saleId, cashRefundConfirmed: cashToReturn > 0);
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dated = datedRows;
    final visible = filteredRows;
    final gross = dated.fold<int>(0, (sum, row) => sum + row.sale.totalCents);
    final net = dated
        .where((row) => row.sale.status == 'completed')
        .fold<int>(0, (sum, row) => sum + row.sale.totalCents);
    Widget metric(String title, String value) => SizedBox(
        width: 155,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 2),
              Text(value, style: Theme.of(context).textTheme.titleMedium),
            ])));
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Sales History',
                style: Theme.of(context).textTheme.headlineSmall),
            const Spacer(),
            IconButton(
                tooltip: 'Refresh sales',
                onPressed: refresh,
                icon: const Icon(Icons.refresh)),
          ]),
          const Text('Review completed, refunded, and voided transactions.'),
          const SizedBox(height: 12),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                metric('Gross sales', formatPeso(gross)),
                metric('Net sales', formatPeso(net)),
                metric('Transactions', '${dated.length}'),
                metric('Refunded / voided', formatPeso(gross - net)),
              ])),
          const SizedBox(height: 6),
          TextField(
              key: const Key('sales-search'),
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  labelText:
                      'Search receipt, invoice, customer, product, serial...'),
              onChanged: updateSearch),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(spacing: 16, children: [
                _filter(dateFilter, const [
                  'Today',
                  'Yesterday',
                  'Last 7 days',
                  'This month',
                  'Custom range'
                ], (value) async {
                  if (value == 'Custom range') {
                    final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDateRange: customRange);
                    if (picked == null || !mounted) return;
                    setState(() => customRange = picked);
                  }
                  setState(() => dateFilter = value);
                }),
                _filter(
                    statusFilter,
                    const ['All statuses', 'Completed', 'Refunded', 'Voided'],
                    (value) => setState(() => statusFilter = value)),
                _filter(
                    paymentFilter,
                    const [
                      'All payments',
                      'Cash',
                      'Credit',
                      'Mixed',
                      'Gcash',
                      'Card',
                      'Other'
                    ],
                    (value) => setState(() => paymentFilter = value)),
                _filter(complianceFilter, const ['All', 'BIR', 'Non-BIR'],
                    (value) => setState(() => complianceFilter = value)),
              ])),
          if (error != null)
            Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (widget.user.can(PosPermission.manageCatalog) &&
              orders.any((o) =>
                  o.order.status != 'completed' &&
                  o.order.status != 'cancelled'))
            ExpansionTile(title: const Text('Made-to-order queue'), children: [
              for (final order in orders.where((o) =>
                  o.order.status != 'completed' &&
                  o.order.status != 'cancelled'))
                ListTile(
                    title: Text(order.productName),
                    subtitle: Text(
                        '${_orderReference(order.saleId)} · ${order.order.status}'),
                    trailing: FilledButton(
                        onPressed: () async {
                          try {
                            await widget.sales.advanceMadeOrder(order.order.id);
                            await refresh();
                          } catch (e) {
                            if (mounted) setState(() => error = safeMessage(e));
                          }
                        },
                        child: Text(switch (order.order.status) {
                          'ordered' => 'Start preparing',
                          'preparing' => 'Mark ready',
                          _ => 'Complete',
                        }))),
            ]),
          Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(rows.isEmpty ? 'No sales yet' : 'No matching sales',
                          style: Theme.of(context).textTheme.titleLarge),
                      Text(rows.isEmpty
                          ? 'Completed sales will appear here after checkout.'
                          : 'Try changing your search or filters.'),
                    ]))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final row = visible[index];
                        final status = AppStatusColors.of(context);
                        final color = row.sale.status == 'completed'
                            ? status.success
                            : status.warning;
                        return Column(children: [
                          ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            onTap: () => open(row.sale.id),
                            title: Row(children: [
                              Expanded(
                                  child: Text(saleReference(row),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis)),
                              Text(formatPeso(row.sale.totalCents),
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                            ]),
                            subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      '${row.customerName} · ${row.paymentMethod} · ${row.cashierName} · ${_saleDate(row.sale.createdAt)}'),
                                  Text(
                                      '${row.sale.status} · ${row.sale.birInvoiceNumber == null ? 'Non-BIR' : 'BIR'}',
                                      style: TextStyle(color: color)),
                                ]),
                          ),
                          const Divider(height: 1)
                        ]);
                      })),
        ]),
      ),
    );
  }
}
