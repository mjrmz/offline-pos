import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/operational_summary_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/theme/app_layout.dart';
import '../../shared/widgets/app_workspace.dart';
import '../contacts/rma_screen.dart';
import '../../data/daos/rma_repository.dart';

class OperationalSummaryScreen extends StatefulWidget {
  final OperationalSummaryRepository repository;
  final ActiveUser user;
  final ValueChanged<String>? onInventory;
  final VoidCallback? onRma;
  final VoidCallback? onExpiry;
  final VoidCallback? onLayaway;
  final VoidCallback? onCustomers;
  const OperationalSummaryScreen(
      {super.key,
      required this.repository,
      required this.user,
      this.onInventory,
      this.onRma,
      this.onExpiry,
      this.onLayaway,
      this.onCustomers});

  @override
  State<OperationalSummaryScreen> createState() =>
      _OperationalSummaryScreenState();
}

class _OperationalSummaryScreenState extends State<OperationalSummaryScreen> {
  late Future<OperationalSummary> summary;
  late Future<List<RmaCase>> cases;
  bool refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    summary = widget.repository.load();
    cases = widget.repository.openCases();
  }

  void _retry() {
    if (refreshing) return;
    setState(() {
      refreshing = true;
      _refresh();
    });
    Future.wait<dynamic>([summary, cases]).then(
      (_) {
        if (mounted) setState(() => refreshing = false);
      },
      onError: (Object _) {
        if (mounted) setState(() => refreshing = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: AppPageHeader(
              title: 'Operations',
              subtitle: 'Current operational issues across your business.',
              action: IconButton(
                  tooltip: 'Refresh dashboard',
                  onPressed: refreshing ? null : _retry,
                  icon: const Icon(Icons.refresh)),
            )),
        if (refreshing) const LinearProgressIndicator(minHeight: 2),
        Expanded(
            child: FutureBuilder<OperationalSummary>(
                future: summary,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return _error('Could not load operations.', _retry);
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final data = snapshot.data!;
                  final healthy = data.outOfStock.isEmpty &&
                      data.lowStock.isEmpty &&
                      data.expiredBatches.isEmpty &&
                      data.expiringBatches.isEmpty &&
                      data.outstandingCredit.isEmpty &&
                      data.refundsDue.isEmpty &&
                      data.openRma == 0 &&
                      data.activeLayaway == 0;
                  return LayoutBuilder(builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 780;
                    final contentWidth = constraints.maxWidth - 48;
                    return ListView(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        children: [
                          Wrap(spacing: 12, runSpacing: 12, children: [
                            _kpi(
                                'Out of stock',
                                data.outOfStock.length,
                                Icons.remove_shopping_cart_outlined,
                                () => widget.onInventory?.call('Out of stock'),
                                contentWidth,
                                narrow),
                            _kpi(
                                'Low stock',
                                data.lowStock.length,
                                Icons.inventory_2_outlined,
                                () => widget.onInventory?.call('Low stock'),
                                contentWidth,
                                narrow),
                            _kpi(
                                'Expiring soon',
                                data.expiringBatches.length,
                                Icons.event_outlined,
                                widget.onExpiry,
                                contentWidth,
                                narrow),
                            _kpi(
                                'Open RMA',
                                data.openRma,
                                Icons.assignment_return_outlined,
                                widget.onRma,
                                contentWidth,
                                narrow),
                          ]),
                          if (healthy)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: AppStatusColors.of(context)
                                        .success
                                        .withValues(alpha: .08),
                                    border: Border.all(
                                        color: AppStatusColors.of(context)
                                            .success
                                            .withValues(alpha: .3)),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Row(children: [
                                    Icon(Icons.check_circle_outline,
                                        size: 19,
                                        color: AppStatusColors.of(context)
                                            .success),
                                    const SizedBox(width: 10),
                                    const Expanded(
                                        child: Text(
                                            'Operations are clear — no urgent issues require attention.')),
                                  ]),
                                )),
                          const SizedBox(height: 16),
                          if (narrow) ...[
                            _inventoryChart(data),
                            _workloadChart(data),
                          ] else
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: _inventoryChart(data)),
                                  const SizedBox(width: 16),
                                  Expanded(child: _workloadChart(data)),
                                ]),
                          const SizedBox(height: 16),
                          if (narrow) ...[
                            _attention(data),
                            _financial(data),
                            _expiry(data),
                            _rma(data),
                          ] else ...[
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 13, child: _attention(data)),
                                  const SizedBox(width: 16),
                                  Expanded(flex: 7, child: _financial(data)),
                                ]),
                            const SizedBox(height: 12),
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 13, child: _expiry(data)),
                                  const SizedBox(width: 16),
                                  Expanded(flex: 7, child: _rma(data)),
                                ]),
                          ],
                        ]);
                  });
                }))
      ]);

  Widget _kpi(String label, int value, IconData icon, VoidCallback? action,
      double width, bool narrow) {
    final columns = narrow && width < 350
        ? 1
        : narrow
            ? 2
            : 4;
    final cardWidth = (width - (columns - 1) * 12) / columns;
    return AppMetricTile(
      key: Key('operations-kpi-${label.toLowerCase().replaceAll(' ', '-')}'),
      label: label,
      value: '$value',
      icon: icon,
      onTap: action,
      width: cardWidth,
    );
  }

  Widget _panel(String title, Widget body, {Widget? action, IconData? icon}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                  borderRadius: AppLayout.panelRadius,
                  side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant)),
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          if (icon != null) ...[
                            Icon(icon,
                                size: 19,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                              child: Text(title,
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                          if (action != null) action
                        ]),
                        const SizedBox(height: 10),
                        body,
                      ]))));

  Widget _inventoryChart(OperationalSummary data) {
    final values = [
      data.outOfStock.length,
      data.lowStock.length,
      data.expiringBatches.length
    ];
    return _panel(
        'Inventory attention',
        Column(children: [
          _bar('Out of stock', values[0], values, AppStatusTone.danger,
              () => widget.onInventory?.call('Out of stock')),
          _bar('Low stock', values[1], values, AppStatusTone.warning,
              () => widget.onInventory?.call('Low stock')),
          _bar('Expiring soon', values[2], values, AppStatusTone.info,
              widget.onExpiry),
        ]));
  }

  Widget _workloadChart(OperationalSummary data) {
    final values = [
      data.openRma,
      data.activeLayaway,
      data.outstandingCredit.length,
      data.refundsDue.length
    ];
    return _panel(
        'Operational workload',
        Column(children: [
          _bar('Open RMA', values[0], values, AppStatusTone.info, widget.onRma),
          _bar('Active layaways', values[1], values, AppStatusTone.info,
              widget.onLayaway),
          _bar('Credit customers', values[2], values, AppStatusTone.info,
              widget.onCustomers),
          _bar('Refunds due', values[3], values, AppStatusTone.info,
              widget.onCustomers),
        ]));
  }

  Widget _bar(String label, int value, List<int> values, AppStatusTone tone,
      VoidCallback? action) {
    final maximum = values.fold<int>(0, (a, b) => a > b ? a : b);
    final color = appStatusColor(context, tone);
    return InkWell(
      key: Key('operations-bar-${label.toLowerCase().replaceAll(' ', '-')}'),
      onTap: action,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          SizedBox(
              width: 125,
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 8),
          Expanded(
              child: LayoutBuilder(
                  builder: (context, box) => Container(
                      height: 12,
                      decoration: BoxDecoration(
                          color: color.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(6)),
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width:
                            maximum == 0 ? 0 : box.maxWidth * value / maximum,
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(6))),
                      )))),
          const SizedBox(width: 8),
          SizedBox(width: 28, child: Text('$value', textAlign: TextAlign.end)),
          if (action != null) const Icon(Icons.chevron_right, size: 18),
        ]),
      ),
    );
  }

  Widget _attention(OperationalSummary data) => _panel(
      'Needs attention',
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Items requiring action.',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        _stockGroup('Out of stock', data.outOfStockAlerts, 'Out of stock'),
        if (data.outOfStockAlerts.isNotEmpty && data.lowStockAlerts.isNotEmpty)
          const Divider(height: 24),
        _stockGroup('Low stock', data.lowStockAlerts, 'Low stock'),
        if (data.outOfStockAlerts.isEmpty && data.lowStockAlerts.isEmpty)
          const Text('No stock issues need review.'),
      ]),
      icon: Icons.priority_high_rounded);

  Widget _stockGroup(String title, List<StockAlert> rows, String filter) =>
      rows.isEmpty
          ? const SizedBox.shrink()
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Builder(builder: (context) {
                final color = filter == 'Out of stock'
                    ? Theme.of(context).colorScheme.error
                    : AppStatusColors.of(context).warning;
                return Row(children: [
                  Icon(
                      filter == 'Out of stock'
                          ? Icons.error_outline
                          : Icons.warning_amber_rounded,
                      size: 16,
                      color: color),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(title.toUpperCase(),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: .6))),
                  if (widget.onInventory != null)
                    TextButton(
                      onPressed: () => widget.onInventory!(filter),
                      child: Text('View all ${rows.length}'),
                    )
                  else
                    Text('${rows.length}',
                        style: Theme.of(context).textTheme.labelMedium),
                ]);
              }),
              for (final row in rows.take(4))
                ListTile(
                    dense: true,
                    leading: Icon(
                        filter == 'Out of stock'
                            ? Icons.error_outline
                            : Icons.warning_amber_rounded,
                        color: filter == 'Out of stock'
                            ? Theme.of(context).colorScheme.error
                            : AppStatusColors.of(context).warning),
                    contentPadding: EdgeInsets.zero,
                    title: Text(row.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(_stockDetail(row, filter == 'Low stock')),
                    trailing: widget.onInventory == null
                        ? null
                        : const Icon(Icons.chevron_right, size: 18),
                    onTap: widget.onInventory == null
                        ? null
                        : () => widget.onInventory!(filter)),
            ]);

  String _stockDetail(StockAlert row, bool low) {
    final available =
        '${Quantity.format(row.availableMilli)} ${row.unit} available';
    final difference = row.physicalMilli - row.availableMilli;
    final reservation = difference > 0
        ? ' · Physical: ${Quantity.format(row.physicalMilli)} ${row.unit} · Reserved: ${Quantity.format(difference)} ${row.unit}'
        : '';
    final threshold = low ? ' · Alert at ${row.threshold}' : '';
    return '$available$reservation$threshold';
  }

  Widget _financial(OperationalSummary data) {
    final credit =
        data.outstandingCredit.fold<int>(0, (sum, row) => sum + row.$2);
    final refunds = data.refundsDue.fold<int>(0, (sum, row) => sum + row.$2);
    return _panel(
        'Financial & customer',
        Column(children: [
          _valueRow('Outstanding credit', formatPeso(credit),
              '${data.outstandingCredit.length} customers'),
          const Divider(height: 1),
          _valueRow('Refunds due', formatPeso(refunds),
              '${data.refundsDue.length} customers'),
          const Divider(height: 1),
          _valueRow('Active layaways', '${data.activeLayaway}', null),
          if (credit == 0 && refunds == 0 && data.activeLayaway == 0)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Icon(Icons.check_circle_outline,
                      size: 17, color: AppStatusColors.of(context).success),
                  const SizedBox(width: 8),
                  const Expanded(
                      child: Text('No urgent customer financial issues.')),
                ])),
          if (widget.onCustomers != null || widget.onLayaway != null)
            Align(
                alignment: Alignment.centerLeft,
                child: Wrap(children: [
                  if (widget.onCustomers != null)
                    TextButton(
                        onPressed: widget.onCustomers,
                        child: const Text('Review customers')),
                  if (widget.onLayaway != null)
                    TextButton(
                        onPressed: widget.onLayaway,
                        child: const Text('Review layaways')),
                ])),
        ]),
        icon: Icons.account_balance_wallet_outlined);
  }

  Widget _valueRow(String label, String value, String? detail) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label),
          if (detail != null)
            Text(detail, style: Theme.of(context).textTheme.bodySmall),
        ])),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]));

  Widget _expiry(OperationalSummary data) => _panel(
      'Expiry',
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _valueRow('Expired', '${data.expiredBatches.length} batches', null),
        const Divider(height: 1),
        _valueRow(
            'Near expiry', '${data.expiringBatches.length} batches', null),
        if (data.expiredBatches.isEmpty && data.expiringBatches.isEmpty)
          Row(children: [
            Icon(Icons.check_circle_outline,
                size: 17, color: AppStatusColors.of(context).success),
            const SizedBox(width: 8),
            const Text('No expiry issues'),
          ]),
        for (final item in data.expiredBatches.take(2))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.event_busy_outlined,
                color: Theme.of(context).colorScheme.error),
            title: Text(item, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('Expired batch'),
            trailing: widget.onExpiry == null
                ? null
                : const Icon(Icons.chevron_right),
            onTap: widget.onExpiry,
          ),
        for (final item in data.expiringBatches.take(2))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.event_outlined,
                color: AppStatusColors.of(context).warning),
            title: Text(item, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('Near expiry'),
            trailing: widget.onExpiry == null
                ? null
                : const Icon(Icons.chevron_right),
            onTap: widget.onExpiry,
          ),
        if (widget.onExpiry != null)
          TextButton(
              onPressed: widget.onExpiry,
              child: const Text('Open Expiry Monitor')),
      ]),
      icon: Icons.event_outlined);

  Widget _rma(OperationalSummary data) => _panel(
      'RMA / service',
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _valueRow('Open RMA', '${data.openRma}', null),
        FutureBuilder<List<RmaCase>>(
            future: cases,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _error('Could not load RMA cases.', _retry);
              }
              if (!snapshot.hasData) return const LinearProgressIndicator();
              if (snapshot.data!.isEmpty) return const Text('No open cases.');
              final rows = [...snapshot.data!]
                ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
              final counts = <String, int>{};
              for (final row in rows) {
                counts.update(row.status, (n) => n + 1, ifAbsent: () => 1);
              }
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final entry in counts.entries)
                        AppStatusBadge(
                          label:
                              '${entry.key.replaceAll('_', ' ')} ${entry.value}',
                          color: appStatusColor(context, AppStatusTone.info),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    Text('Oldest open cases',
                        style: Theme.of(context).textTheme.labelLarge),
                    for (final row in rows.take(3))
                      ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(row.reference),
                          subtitle: Text(
                              '${row.status.replaceAll('_', ' ')} · ${DateTime.now().difference(row.createdAt).inDays} days open'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => RmaScreen(
                                      repository:
                                          RmaRepository(widget.repository.db),
                                      user: widget.user,
                                      initialCaseId: row.id)))),
                  ]);
            }),
        if (widget.onRma != null)
          TextButton(
              onPressed: widget.onRma, child: const Text('Review all RMA')),
      ]),
      icon: Icons.assignment_return_outlined);

  Widget _error(String message, VoidCallback retry) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(message),
        TextButton(onPressed: retry, child: const Text('Retry'))
      ]));
}
