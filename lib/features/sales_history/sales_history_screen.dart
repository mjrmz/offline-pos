import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show Variable;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../core/models/active_user.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/sales_repository.dart';
import '../../data/daos/sale_return_repository.dart';
import '../../data/daos/sale_lifecycle_repository.dart';
import '../../data/daos/pos_repository.dart';
import 'return_exchange_dialog.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/utils/money.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../core/models/quantity.dart';
import '../../core/models/sale_line_format.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/quotation_repository.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/customer_credit_repository.dart';
import '../contacts/new_customer_rma_page.dart';
import '../contacts/rma_screen.dart';
import '../contacts/quotation_screen.dart';
import '../contacts/customer_profile_screen.dart';

String saleReference(SaleSummary row) => row.sale.receiptNumber == null
    ? 'Legacy sale'
    : 'Receipt #${row.sale.receiptNumber}';

String _compactMoney(int cents) => cents % 100 == 0
    ? formatPeso(cents).replaceFirst(RegExp(r'\.00$'), '')
    : formatPeso(cents);

String _listDate(DateTime value) {
  final now = DateTime.now();
  final day = DateTime(value.year, value.month, value.day);
  final today = DateTime(now.year, now.month, now.day);
  final prefix = day == today
      ? 'Today'
      : day == today.subtract(const Duration(days: 1))
          ? 'Yesterday'
          : _saleDate(value)
              .split(' · ')
              .first
              .replaceFirst(', ${value.year}', '');
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  return '$prefix · $hour:${value.minute.toString().padLeft(2, '0')} ${value.hour < 12 ? 'AM' : 'PM'}';
}

String _paymentLabel(String value) => switch (value.toLowerCase()) {
      'cash' => 'Cash',
      'credit' => 'Credit / Utang',
      'mixed' => 'Mixed',
      'gcash' => 'GCash',
      'card' => 'Card',
      _ => value.isEmpty
          ? 'Unknown'
          : '${value[0].toUpperCase()}${value.substring(1)}',
    };

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
  final PosRepository? pos;
  final String? initialSaleId;
  const SalesHistoryScreen(
      {super.key,
      required this.sales,
      required this.user,
      this.active = true,
      this.receipts,
      this.pos,
      this.initialSaleId});
  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  final TextEditingController searchController = TextEditingController();
  List<SaleSummary> rows = [];
  List<MadeOrderSummary> orders = [];
  Map<String, SaleLifecycleSummary> lifecycle = {};
  String? error;
  String search = '';
  Set<String> itemMatches = {};
  int searchGeneration = 0;
  String dateFilter = 'All dates';
  String statusFilter = 'All statuses';
  String paymentFilter = 'All payments';
  String complianceFilter = 'All';
  String cashierFilter = 'All';
  String customerFilter = 'All';
  DateTimeRange? customRange;
  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      refresh().then((_) {
        if (mounted && widget.initialSaleId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) open(widget.initialSaleId!);
          });
        }
      });
    }
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
      final summaries =
          await SaleLifecycleRepository(widget.sales.repository.db).summaries();
      if (mounted) {
        setState(() {
          rows = result;
          orders = currentOrders;
          lifecycle = summaries;
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
        final summary =
            lifecycle[row.sale.id] ?? const SaleLifecycleSummary(0, 0, 0, 0, 0);
        final displayStatus =
            summary.status(row.sale.status, row.sale.totalCents);
        return (query.isEmpty ||
                saleReference(row).toLowerCase().contains(query) ||
                '${row.sale.birInvoiceNumber ?? ''}'.contains(query) ||
                itemMatches.contains(row.sale.id) ||
                row.customerName.toLowerCase().contains(query) ||
                (row.sale.walkInName ?? '').toLowerCase().contains(query) ||
                (row.sale.walkInContact ?? '').toLowerCase().contains(query) ||
                row.cashierName.toLowerCase().contains(query)) &&
            (statusFilter == 'All statuses' ||
                displayStatus == statusFilter ||
                (statusFilter == 'RMA active' && summary.activeRmaCount > 0)) &&
            (paymentFilter == 'All payments' ||
                row.paymentMethod == paymentFilter.toLowerCase()) &&
            (cashierFilter == 'All' || row.cashierName == cashierFilter) &&
            (customerFilter == 'All' || row.customerName == customerFilter) &&
            (complianceFilter == 'All' ||
                (row.sale.birInvoiceNumber != null ? 'BIR' : 'Non-BIR') ==
                    complianceFilter);
      }).toList();

  Widget _chip(String label, Color color) =>
      AppStatusBadge(label: label, color: color);

  Widget _filter(String label, String value, List<String> options,
          ValueChanged<String> change) =>
      Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8)),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: value,
              isDense: true,
              borderRadius: BorderRadius.circular(8),
              items: options
                  .map((option) => DropdownMenuItem(
                      value: option,
                      child: Text(
                          label.isEmpty
                              ? option
                              : '$label: ${option.startsWith('All') ? 'All' : option}',
                          style: const TextStyle(fontSize: 13))))
                  .toList(),
              onChanged: (next) {
                if (next != null) change(next);
              },
            ),
          ));

  Widget _transactionRow(SaleSummary row, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final summary =
        lifecycle[row.sale.id] ?? const SaleLifecycleSummary(0, 0, 0, 0, 0);
    final statusLabel = summary.status(row.sale.status, row.sale.totalCents);
    final statusColor = statusLabel == 'Completed'
        ? AppStatusColors.of(context).success
        : statusLabel == 'Voided'
            ? scheme.error
            : AppStatusColors.of(context).warning;
    final compliance = row.sale.birInvoiceNumber == null ? 'Non-BIR' : 'BIR';
    Widget receipt() => Tooltip(
          message: row.sale.receiptNumber == null
              ? 'No historical receipt reference'
              : saleReference(row),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(saleReference(row),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                if (row.sale.receiptNumber == null)
                  Text('No historical receipt reference',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
              ]),
        );
    Widget badges() => Wrap(spacing: 4, runSpacing: 3, children: [
          _chip(statusLabel, statusColor),
          if (summary.activeRmaCount > 0)
            _chip('RMA active', AppStatusColors.of(context).warning),
          _chip(compliance, AppStatusColors.of(context).info),
        ]);
    Widget customer() => Tooltip(
        message: row.sale.walkInName ?? row.customerName,
        child: Text(row.sale.walkInName ?? row.customerName,
            maxLines: 1, overflow: TextOverflow.ellipsis));
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('sale-row-${row.sale.id}'),
        hoverColor: scheme.primary.withValues(alpha: .06),
        focusColor: scheme.primary.withValues(alpha: .12),
        onTap: () => open(row.sale.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          child: wide
              ? Row(children: [
                  Expanded(
                      flex: 27,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          receipt(),
                          const SizedBox(height: 4),
                          Text(_listDate(row.sale.createdAt),
                              style: TextStyle(
                                  fontSize: 12, color: scheme.onSurfaceVariant))
                        ],
                      )),
                  Expanded(
                      flex: 34,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          customer(),
                          const SizedBox(height: 4),
                          Text(
                              '${_paymentLabel(row.paymentMethod)} · ${row.cashierName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: scheme.onSurfaceVariant))
                        ],
                      )),
                  Expanded(flex: 25, child: badges()),
                  Expanded(
                      flex: 22,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('Gross ${_compactMoney(row.sale.totalCents)}'),
                          Text(
                              'Returned -${_compactMoney(summary.returnedCents + summary.itemRefundCents)}'),
                          Text(
                              'Retained ${_compactMoney(row.sale.status == 'completed' ? summary.netRetained(row.sale.totalCents) : 0)}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                        ],
                      )),
                  const SizedBox(width: 10),
                  Icon(Icons.chevron_right,
                      size: 20, color: scheme.onSurfaceVariant),
                ])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                      Row(children: [
                        Expanded(child: receipt()),
                        Text(_compactMoney(row.sale.totalCents),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        const Icon(Icons.chevron_right, size: 20)
                      ]),
                      Text(_listDate(row.sale.createdAt),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                      Row(children: [Expanded(child: customer())]),
                      Text(
                          '${_paymentLabel(row.paymentMethod)} · ${row.cashierName}',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      badges(),
                    ]),
        ),
      ),
    );
  }

  Future<void> open(String saleId) async {
    try {
      final detail = await widget.sales.detail(saleId);
      final lifecycleRepository =
          SaleLifecycleRepository(widget.sales.repository.db);
      final summary = (await lifecycleRepository.summaries())[saleId] ??
          const SaleLifecycleSummary(0, 0, 0, 0, 0);
      final returns = await lifecycleRepository.returns(saleId);
      final returnLines = await lifecycleRepository.returnLines(saleId);
      final rmas = await lifecycleRepository.rmas(saleId);
      final rmaDetails = await lifecycleRepository.rmaDetails(saleId);
      final returnedQuantities =
          await lifecycleRepository.returnedQuantities(saleId);
      final returnedSerials = await lifecycleRepository.returnedSerials(saleId);
      final exchangeOrigin = await lifecycleRepository.exchangeOrigin(saleId);
      final originReceipt = exchangeOrigin == null
          ? null
          : await SaleReturnRepository(widget.sales.repository.db)
              .replacementReceipt(exchangeOrigin.saleId);
      final sourceQuotation = await (widget.sales.repository.db
              .select(widget.sales.repository.db.quotations)
            ..where((q) => q.convertedSaleId.equals(saleId)))
          .getSingleOrNull();
      final customer = detail.summary.sale.customerId == null
          ? null
          : await (widget.sales.repository.db
                  .select(widget.sales.repository.db.customers)
                ..where((c) => c.id.equals(detail.summary.sale.customerId!)))
              .getSingleOrNull();
      final reward = await widget.sales.repository.db.customSelect(
          'SELECT * FROM sale_loyalty WHERE sale_id=?',
          variables: [Variable.withString(saleId)]).getSingleOrNull();
      final loyaltyAdjustments = await widget.sales.repository.db.customSelect(
          '''
        SELECT l.kind, l.points_delta, r.reference FROM loyalty_ledger l
        JOIN sale_returns r ON r.id=l.source_id
        WHERE r.original_sale_id=? AND l.kind IN ('return_reversal','return_restore')
        ORDER BY l.created_at, l.id''',
          variables: [Variable.withString(saleId)]).get();
      final manualDiscounts = await widget.sales.repository.db.customSelect('''
        SELECT d.*, u.name AS authorized_name, requester.name AS requested_name
        FROM sale_manual_discounts d JOIN users u ON u.id=d.authorized_by
        LEFT JOIN users requester ON requester.id=d.requested_by
        WHERE d.sale_id=?''', variables: [Variable.withString(saleId)]).get();
      final returnRepository = SaleReturnRepository(widget.sales.repository.db);
      final returnableLines = await returnRepository.returnable(saleId);
      final canReturn = returnableLines
          .any((line) => line.remainingMilli > 0 && line.limitation == null);
      final timeline = <(DateTime, Widget)>[
        (
          detail.summary.sale.createdAt,
          ListTile(
            leading: const Icon(Icons.shopping_bag_outlined),
            title: const Text('Sale completed'),
            subtitle: Text('Sold by ${detail.summary.cashierName}'),
            trailing: Text(formatPeso(detail.summary.sale.totalCents)),
          )
        ),
        for (final event in returns)
          (
            event.createdAt,
            ListTile(
              leading: Icon(event.kind == 'exchange'
                  ? Icons.swap_horiz
                  : Icons.assignment_return_outlined),
              title: Text(
                  '${event.kind == 'exchange' ? 'Exchange' : 'Return'} · ${event.reference}'),
              subtitle: Text(
                  'Returned ${formatPeso(event.refundValueCents)}${event.cashEffectCents < 0 ? ' · Refunded ${formatPeso(-event.cashEffectCents)}' : ''}'),
              trailing: event.replacementSaleId == null
                  ? null
                  : TextButton(
                      onPressed: () async {
                        Navigator.pop(context);
                        await open(event.replacementSaleId!);
                      },
                      child: const Text('View replacement'),
                    ),
            )
          ),
        for (final refund in detail.itemRefunds)
          (
            refund.createdAt,
            ListTile(
              leading: const Icon(Icons.currency_exchange),
              title: const Text('RMA item refund'),
              trailing: Text(formatPeso(refund.amountCents)),
            )
          ),
        if (detail.reversal != null)
          (
            detail.reversal!.createdAt,
            ListTile(
              leading: const Icon(Icons.undo),
              title: Text(detail.reversal!.kind == 'void'
                  ? 'Sale voided'
                  : 'Legacy full refund'),
              trailing: Text(formatPeso(detail.reversal!.amountCents)),
            )
          ),
        for (final rma in rmas)
          (
            rma.createdAt,
            ListTile(
              leading: const Icon(Icons.build_outlined),
              title: Text('RMA opened · ${rma.reference}'),
              subtitle: Text([
                rmaDetails[rma.id]?.productName ?? 'Item unavailable',
                if (rmaDetails[rma.id]?.serial != null)
                  'Serial ${rmaDetails[rma.id]!.serial}',
                'Status: ${rma.status.replaceAll('_', ' ')}',
                if (rma.customerResolution != null)
                  'Outcome: ${rma.customerResolution!.replaceAll('_', ' ')}',
              ].join(' · ')),
              onTap: () async {
                Navigator.pop(context);
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => RmaScreen(
                    repository: RmaRepository(widget.sales.repository.db),
                    user: widget.user,
                    initialCaseId: rma.id,
                  ),
                ));
              },
            )
          ),
      ];
      final replacementReceipts = <String, String>{};
      for (final event in returns.where((r) => r.replacementSaleId != null)) {
        final replacement = await (widget.sales.repository.db
                .select(widget.sales.repository.db.sales)
              ..where((s) => s.id.equals(event.replacementSaleId!)))
            .getSingleOrNull();
        if (replacement == null) continue;
        replacementReceipts[event.id] =
            replacement.receiptNumber ?? 'Legacy sale';
        timeline.add((
          replacement.createdAt,
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: Text(
                'Replacement sale · ${replacement.receiptNumber ?? 'Legacy sale'}'),
            subtitle: Text(
                'Exchange ${event.reference} · ${event.cashEffectCents > 0 ? 'Customer paid ${formatPeso(event.cashEffectCents)}' : event.cashEffectCents < 0 ? 'Customer refunded ${formatPeso(-event.cashEffectCents)}' : 'No cash difference'}'),
            trailing: Text(formatPeso(replacement.totalCents)),
            onTap: () async {
              Navigator.pop(context);
              await open(replacement.id);
            },
          )
        ));
      }
      for (final rma in rmas) {
        final events = await (widget.sales.repository.db
                .select(widget.sales.repository.db.rmaEvents)
              ..where((e) => e.caseId.equals(rma.id)))
            .get();
        for (final event in events.where((e) => e.status != 'pending')) {
          timeline.add((
            event.createdAt,
            ListTile(
              leading: const Icon(Icons.build_circle_outlined),
              title: Text(
                  'RMA ${event.status.replaceAll('_', ' ')} · ${rma.reference}'),
              subtitle: event.note == null ? null : Text(event.note!),
            )
          ));
        }
      }
      timeline.sort((a, b) => a.$1.compareTo(b.$1));
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                  width: MediaQuery.sizeOf(context).width < 900
                      ? MediaQuery.sizeOf(context).width - 16
                      : 820,
                  height: MediaQuery.sizeOf(context).height,
                  child: AlertDialog(
                      insetPadding: const EdgeInsets.all(8),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      title: Row(children: [
                        Expanded(
                            child: Text(saleReference(detail.summary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 23,
                                    fontWeight: FontWeight.w700))),
                        IconButton(
                            tooltip: 'Close',
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(context)),
                      ]),
                      content: SizedBox(
                          width: 780,
                          child: ListView(shrinkWrap: true, children: [
                            Wrap(spacing: 8, children: [
                              _chip(
                                  summary.status(detail.summary.sale.status,
                                      detail.summary.sale.totalCents),
                                  detail.summary.sale.status == 'completed'
                                      ? AppStatusColors.of(context).success
                                      : detail.summary.sale.status == 'voided'
                                          ? Theme.of(context).colorScheme.error
                                          : AppStatusColors.of(context)
                                              .warning),
                              _chip(
                                  detail.summary.sale.birInvoiceNumber == null
                                      ? 'Non-BIR'
                                      : 'BIR',
                                  AppStatusColors.of(context).info),
                              if (summary.activeRmaCount > 0)
                                _chip('RMA active',
                                    AppStatusColors.of(context).warning),
                            ]),
                            const SizedBox(height: 8),
                            Text(_saleDate(detail.summary.sale.createdAt),
                                style: Theme.of(context).textTheme.bodySmall),
                            Text(
                                '${detail.summary.customerName} · ${_paymentLabel(detail.summary.paymentMethod)} · ${detail.summary.cashierName}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 12),
                            Text('SALE DETAILS',
                                style: Theme.of(context).textTheme.labelMedium),
                            const SizedBox(height: 4),
                            if (detail.summary.sale.receiptNumber != null)
                              Text(
                                  'Receipt reference: ${detail.summary.sale.receiptNumber}'),
                            if (detail.summary.sale.birInvoiceNumber != null)
                              Text(
                                  'Invoice #${detail.summary.sale.birInvoiceNumber}'),
                            if (detail.summary.sale.receiptNumber == null)
                              const Text('No historical receipt reference'),
                            if (detail.summary.sale.heldReference != null)
                              Text(
                                  'Resumed from ${detail.summary.sale.heldReference}'),
                            if (customer != null)
                              TextButton.icon(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await Navigator.of(this.context).push(
                                    MaterialPageRoute(
                                        builder: (_) => CustomerProfileScreen(
                                              customer: customer,
                                              repository:
                                                  CustomerCreditRepository(
                                                      widget
                                                          .sales.repository.db),
                                              user: widget.user,
                                            )),
                                  );
                                },
                                icon: const Icon(Icons.person_outline),
                                label: Text(
                                    'Customer: ${customer.name}${customer.phone == null ? '' : ' · ${customer.phone}'}'),
                              ),
                            if (detail.summary.sale.customerId == null)
                              Text(
                                  'Customer: ${detail.summary.sale.walkInName ?? 'Walk-in'}${detail.summary.sale.walkInContact == null ? '' : ' · ${detail.summary.sale.walkInContact}'}'),
                            const Divider(),
                            if (exchangeOrigin != null)
                              TextButton.icon(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await open(exchangeOrigin.saleId);
                                },
                                icon: const Icon(Icons.call_made),
                                label: Text(
                                    'View original sale · ${originReceipt ?? 'Legacy sale'}'),
                              ),
                            if (sourceQuotation != null && widget.pos != null)
                              TextButton.icon(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  await Navigator.of(this.context).push(
                                    MaterialPageRoute(
                                        builder: (_) => QuotationScreen(
                                              repository: QuotationRepository(
                                                  widget.sales.repository.db,
                                                  widget.pos!),
                                              directory: DirectoryRepository(
                                                  widget.sales.repository.db),
                                              products: widget.pos!,
                                              user: widget.user,
                                              initialQuotationReference:
                                                  sourceQuotation.reference,
                                            )),
                                  );
                                },
                                icon: const Icon(Icons.description_outlined),
                                label: Text(
                                    'Source quotation · ${sourceQuotation.reference}'),
                              ),
                            Text('LIFECYCLE SUMMARY',
                                style: Theme.of(context).textTheme.labelMedium),
                            ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Gross sale'),
                                trailing: Text(formatPeso(
                                    detail.summary.sale.totalCents))),
                            ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Returned / refunded'),
                                trailing: Text(
                                    '-${formatPeso(summary.returnedCents + summary.itemRefundCents)}')),
                            ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Net retained sale value'),
                                trailing: Text(formatPeso(
                                    detail.summary.sale.status == 'completed'
                                        ? summary.netRetained(
                                            detail.summary.sale.totalCents)
                                        : 0))),
                            Text(
                                '${returns.length} returns · ${summary.exchangeCount} exchanges · ${rmas.length} RMAs'),
                            const Divider(),
                            Text('ITEMS',
                                style: Theme.of(context).textTheme.labelMedium),
                            for (var i = 0; i < detail.items.length; i++)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(detail.productNames[i]),
                                subtitle: Text(
                                    '${saleQuantityLabel(detail.items[i].quantityMilli == 0 ? detail.items[i].quantity * Quantity.scale : detail.items[i].quantityMilli, detail.items[i].saleUnit)} sold · ${saleQuantityLabel(returnedQuantities[detail.items[i].id] ?? 0, detail.items[i].saleUnit)} returned · ${saleQuantityLabel(((detail.items[i].quantityMilli == 0 ? detail.items[i].quantity * Quantity.scale : detail.items[i].quantityMilli) - (returnedQuantities[detail.items[i].id] ?? 0)).clamp(0, 1 << 31), detail.items[i].saleUnit)} retained\n${formatPeso(detail.items[i].unitPriceCents)} each${(detail.serialNumbersByItem[detail.items[i].id] ?? const <String>[]).isEmpty ? '' : '\nSold serials: ${detail.serialNumbersByItem[detail.items[i].id]!.join(', ')}'}${(returnedSerials[detail.items[i].id] ?? const <String>[]).isEmpty ? '' : '\nReturned serials: ${returnedSerials[detail.items[i].id]!.join(', ')}'}${(detail.serialNumbersByItem[detail.items[i].id] ?? const <String>[]).isEmpty ? '' : '\nStill retained: ${detail.serialNumbersByItem[detail.items[i].id]!.where((serial) => !(returnedSerials[detail.items[i].id] ?? const <String>[]).contains(serial)).join(', ')}'}'),
                                trailing: Text(
                                    formatPeso(detail.items[i].lineTotalCents)),
                              ),
                            const Divider(),
                            Text('TOTALS',
                                style: Theme.of(context).textTheme.labelMedium),
                            const SizedBox(height: 6),
                            Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primaryContainer
                                      .withValues(alpha: .4),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(children: [
                                  const Text('TOTAL',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700)),
                                  const Spacer(),
                                  Text(
                                      _compactMoney(
                                          detail.summary.sale.totalCents),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                              fontWeight: FontWeight.w700))
                                ])),
                            const SizedBox(height: 8),
                            if (manualDiscounts.isNotEmpty) ...[
                              Text('MANUAL DISCOUNT',
                                  style:
                                      Theme.of(context).textTheme.labelMedium),
                              for (final discount in manualDiscounts)
                                Text(
                                    '${discount.read<String>('scope') == 'line' ? 'Line' : 'Order'} ${discount.read<String>('kind') == 'percent' ? '${discount.read<int>('value')}%' : formatPeso(discount.read<int>('value'))} · -${formatPeso(discount.read<int>('effect_cents'))}\n${discount.read<String>('reason')} · Requested by ${discount.readNullable<String>('requested_name') ?? 'Unknown'} · Authorized by ${discount.read<String>('authorized_name')}'),
                              const Divider(),
                            ],
                            if (reward != null &&
                                (reward.read<int>('earned_points') != 0 ||
                                    reward.read<int>('redeemed_points') !=
                                        0)) ...[
                              Text('REWARDS',
                                  style:
                                      Theme.of(context).textTheme.labelMedium),
                              Text(
                                  'Earned +${reward.read<int>('earned_points')} pts'),
                              Text(
                                  'Redeemed -${reward.read<int>('redeemed_points')} pts'),
                              if (reward.read<int>('discount_cents') > 0)
                                Text(
                                    'Discount ${formatPeso(reward.read<int>('discount_cents'))}'),
                              for (final adjustment in loyaltyAdjustments)
                                Text(
                                    '${adjustment.read<String>('kind') == 'return_restore' ? 'Restored' : 'Return adjustment'} ${adjustment.read<int>('points_delta') > 0 ? '+' : ''}${adjustment.read<int>('points_delta')} pts · ${adjustment.read<String>('reference')}'),
                              const Divider(),
                            ],
                            Text('PAYMENT',
                                style: Theme.of(context).textTheme.labelMedium),
                            for (final payment in detail.payments)
                              Row(children: [
                                Text(_paymentLabel(payment.method)),
                                const Spacer(),
                                Text(_compactMoney(payment.amountCents))
                              ]),
                            if (detail.payments.isNotEmpty)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Payment received'),
                                trailing:
                                    Text(formatPeso(detail.paymentAmountCents)),
                              ),
                            if (detail.reversal != null ||
                                detail.itemRefunds.isNotEmpty) ...[
                              const Divider(),
                              Text('REVERSALS',
                                  style:
                                      Theme.of(context).textTheme.labelMedium),
                              if (detail.reversal != null)
                                Text(
                                    '${detail.reversal!.kind} · ${formatPeso(detail.reversal!.amountCents)} · ${_saleDate(detail.reversal!.createdAt)}'),
                              for (final refund in detail.itemRefunds)
                                Text(
                                    'Item refund · ${formatPeso(refund.amountCents)} · ${_saleDate(refund.createdAt)}'),
                            ],
                            if (returns.isNotEmpty) ...[
                              const Divider(),
                              Text('RETURN HISTORY',
                                  style:
                                      Theme.of(context).textTheme.labelMedium),
                              for (final row in returns)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                      '${row.reference} · ${row.kind == 'exchange' ? 'Exchange' : 'Return'}'),
                                  subtitle: Text([
                                    'Returned ${formatPeso(row.refundValueCents)}${row.cashEffectCents < 0 ? ' · Refunded ${formatPeso(-row.cashEffectCents)}' : row.cashEffectCents > 0 ? ' · Customer paid ${formatPeso(row.cashEffectCents)}' : ''}',
                                    for (final line in returnLines[row.id] ??
                                        const <SaleReturnLineSummary>[])
                                      '${line.productName} · ${saleQuantityLabel(line.quantityMilli, line.unit)} · ${line.disposition.replaceAll('_', ' ')}${line.serials.isEmpty ? '' : ' · ${line.serials.join(', ')}'}',
                                    if (row.replacementSaleId != null)
                                      'Replacement receipt: ${replacementReceipts[row.id] ?? 'Legacy sale'}',
                                  ].join('\n')),
                                  trailing: widget.receipts == null
                                      ? null
                                      : IconButton(
                                          tooltip: 'Reprint ${row.reference}',
                                          icon: const Icon(Icons.print),
                                          onPressed: () async {
                                            final ok = await widget.receipts!
                                                .reprintReturn(row.id);
                                            if (mounted && !ok) {
                                              setState(() => error =
                                                  'Return receipt could not be printed. Check printer settings and connection.');
                                            }
                                          },
                                        ),
                                  onTap: row.replacementSaleId == null
                                      ? null
                                      : () async {
                                          Navigator.pop(context);
                                          await open(row.replacementSaleId!);
                                        },
                                ),
                            ],
                            const Divider(),
                            Text('LIFECYCLE',
                                style: Theme.of(context).textTheme.labelMedium),
                            for (final event in timeline)
                              Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_saleDate(event.$1),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                    event.$2,
                                  ]),
                            if (detail.reversal != null)
                              Text(detail.reversal!.stockRestored
                                  ? 'Stock restored to sellable inventory'
                                  : 'Stock not returned to sellable inventory'),
                          ])),
                      actions: [
                        Tooltip(
                            message: detail.summary.sale.status != 'completed'
                                ? 'Only completed sales can be returned.'
                                : !canReturn
                                    ? 'No safely returnable quantity remains.'
                                    : !widget.user
                                            .can(PosPermission.reverseSale)
                                        ? 'Manager or Owner authorization is required.'
                                        : 'Return selected sale items',
                            child: OutlinedButton.icon(
                                onPressed:
                                    detail.summary.sale.status == 'completed' &&
                                            canReturn &&
                                            widget.user
                                                .can(PosPermission.reverseSale)
                                        ? () async {
                                            Navigator.pop(context);
                                            final result = await showDialog<
                                                    CommercialReturn>(
                                                context: this.context,
                                                builder: (_) =>
                                                    ReturnExchangeDialog(
                                                        repository:
                                                            SaleReturnRepository(
                                                                widget
                                                                    .sales
                                                                    .repository
                                                                    .db),
                                                        actor: widget.user,
                                                        pos: widget.pos,
                                                        saleId: saleId,
                                                        receipt: detail
                                                                .summary
                                                                .sale
                                                                .receiptNumber ??
                                                            'Legacy sale'));
                                            if (result != null) {
                                              await refresh();
                                              await widget.receipts
                                                  ?.reprintReturn(result.id);
                                            }
                                          }
                                        : null,
                                icon: const Icon(Icons.assignment_return),
                                label: const Text('Return / Exchange'))),
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
                        FilledButton.icon(
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
                            icon: const Icon(Icons.print, size: 18),
                            label: const Text('Reprint receipt')),
                        if (widget.user.can(PosPermission.reverseSale) &&
                            detail.summary.sale.status == 'completed') ...[
                          TextButton(
                              style: TextButton.styleFrom(
                                  foregroundColor:
                                      Theme.of(context).colorScheme.error),
                              onPressed: () async {
                                Navigator.pop(context);
                                await reverse(saleId, false);
                              },
                              child: const Text('Void')),
                          TextButton(
                              style: TextButton.styleFrom(
                                  foregroundColor:
                                      Theme.of(context).colorScheme.error),
                              onPressed: () async {
                                Navigator.pop(context);
                                await reverse(saleId, true);
                              },
                              child: const Text('Record full refund')),
                        ],
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
    final net = dated.where((row) => row.sale.status == 'completed').fold<int>(
        0,
        (sum, row) =>
            sum +
            (lifecycle[row.sale.id] ??
                    const SaleLifecycleSummary(0, 0, 0, 0, 0))
                .netRetained(row.sale.totalCents));
    final scheme = Theme.of(context).colorScheme;
    final metrics = <(String, String)>[
      ('Gross sales', _compactMoney(gross)),
      ('Net sales', _compactMoney(net)),
      ('Transactions', '${dated.length}'),
      ('Refunded / voided', _compactMoney(gross - net)),
    ];
    Widget metric((String, String) item) =>
        AppMetricTile(label: item.$1, value: item.$2);
    return Scaffold(
      body: Center(
          child: SizedBox(
              width: 1500,
              height: double.infinity,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppPageHeader(
                        title: 'Sales History',
                        subtitle:
                            'Review completed, refunded, and voided transactions.',
                        action: IconButton(
                          tooltip: 'Refresh sales',
                          onPressed: refresh,
                          icon: const Icon(Icons.refresh),
                        ),
                      ),
                      SizedBox(
                        key: const Key('sales-kpi-strip'),
                        width: double.infinity,
                        child: LayoutBuilder(
                            builder: (context, constraints) => GridView.count(
                                  crossAxisCount:
                                      constraints.maxWidth >= 700 ? 4 : 2,
                                  crossAxisSpacing: 10,
                                  mainAxisSpacing: 10,
                                  childAspectRatio: constraints.maxWidth >= 700
                                      ? (constraints.maxWidth - 30) / 4 / 96
                                      : (constraints.maxWidth - 10) / 2 / 96,
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: [
                                    for (final item in metrics) metric(item)
                                  ],
                                )),
                      ),
                      const SizedBox(height: 16),
                      AppSearchField(
                        key: const Key('sales-search'),
                        controller: searchController,
                        hintText:
                            'Search receipt, invoice, customer, product, serial...',
                        onChanged: updateSearch,
                      ),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(spacing: 8, children: [
                            _filter('', dateFilter, const [
                              'All dates',
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
                                'Status',
                                statusFilter,
                                const [
                                  'All statuses',
                                  'Completed',
                                  'Partially returned',
                                  'Fully returned',
                                  'Exchanged',
                                  'Partially exchanged',
                                  'Refunded',
                                  'Voided',
                                  'RMA active'
                                ],
                                (value) =>
                                    setState(() => statusFilter = value)),
                            _filter(
                                'Payment',
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
                                (value) =>
                                    setState(() => paymentFilter = value)),
                            _filter(
                                'Cashier',
                                cashierFilter,
                                [
                                  'All',
                                  ...rows
                                      .map((row) => row.cashierName)
                                      .toSet()
                                      .toList()
                                    ..sort()
                                ],
                                (value) =>
                                    setState(() => cashierFilter = value)),
                            _filter(
                                'Customer',
                                customerFilter,
                                [
                                  'All',
                                  ...rows
                                      .map((row) => row.customerName)
                                      .toSet()
                                      .toList()
                                    ..sort()
                                ],
                                (value) =>
                                    setState(() => customerFilter = value)),
                            _filter(
                                'Compliance',
                                complianceFilter,
                                const ['All', 'BIR', 'Non-BIR'],
                                (value) =>
                                    setState(() => complianceFilter = value)),
                          ])),
                      const SizedBox(height: 16),
                      if (error != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                              color: scheme.errorContainer,
                              borderRadius: BorderRadius.circular(8)),
                          child: Row(children: [
                            Icon(Icons.warning_amber, color: scheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(error!,
                                    style: TextStyle(
                                        color: scheme.onErrorContainer))),
                            IconButton(
                                tooltip: 'Dismiss error',
                                icon: const Icon(Icons.close),
                                onPressed: () => setState(() => error = null))
                          ]),
                        ),
                      if (widget.user.can(PosPermission.manageCatalog) &&
                          orders.any((o) =>
                              o.order.status != 'completed' &&
                              o.order.status != 'cancelled'))
                        ExpansionTile(
                            title: const Text('Made-to-order queue'),
                            children: [
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
                                            await widget.sales.advanceMadeOrder(
                                                order.order.id);
                                            await refresh();
                                          } catch (e) {
                                            if (mounted) {
                                              setState(
                                                  () => error = safeMessage(e));
                                            }
                                          }
                                        },
                                        child:
                                            Text(switch (order.order.status) {
                                          'ordered' => 'Start preparing',
                                          'preparing' => 'Mark ready',
                                          _ => 'Complete',
                                        }))),
                            ]),
                      Expanded(
                          child: LayoutBuilder(builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 900;
                        return Container(
                          key: const Key('sales-transaction-workspace'),
                          decoration: BoxDecoration(
                              color: scheme.surface,
                              border: Border.all(color: scheme.outlineVariant),
                              borderRadius: BorderRadius.circular(14)),
                          clipBehavior: Clip.antiAlias,
                          child: Column(children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 12),
                              child: Row(children: [
                                Text('Transactions',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.w700)),
                                const Spacer(),
                                Text('${visible.length} results',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant)),
                              ]),
                            ),
                            Divider(height: 1, color: scheme.outlineVariant),
                            Expanded(
                                child: visible.isEmpty
                                    ? Center(
                                        child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                            Icon(Icons.receipt_long_outlined,
                                                size: 42,
                                                color: scheme.primary),
                                            const SizedBox(height: 12),
                                            Text('No sales found',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleLarge),
                                            const SizedBox(height: 4),
                                            Text(
                                                rows.isEmpty
                                                    ? 'Completed sales will appear here after checkout.'
                                                    : 'No transactions match your current filters.',
                                                textAlign: TextAlign.center),
                                            const SizedBox(height: 12),
                                            if (rows.isNotEmpty)
                                              OutlinedButton.icon(
                                                onPressed: () => setState(() {
                                                  searchController.clear();
                                                  search = '';
                                                  searchGeneration++;
                                                  dateFilter = 'All dates';
                                                  statusFilter = 'All statuses';
                                                  paymentFilter =
                                                      'All payments';
                                                  cashierFilter = 'All';
                                                  customerFilter = 'All';
                                                  complianceFilter = 'All';
                                                  itemMatches = {};
                                                }),
                                                icon: const Icon(Icons
                                                    .filter_alt_off_outlined),
                                                label:
                                                    const Text('Reset filters'),
                                              ),
                                          ]))
                                    : ListView.separated(
                                        padding: const EdgeInsets.all(10),
                                        itemCount: visible.length,
                                        separatorBuilder: (_, __) =>
                                            const SizedBox(height: 8),
                                        itemBuilder: (context, index) =>
                                            _transactionRow(
                                                visible[index], wide))),
                          ]),
                        );
                      })),
                    ]),
              ))),
    );
  }
}
