import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../shared/theme/app_layout.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';

class ExpiryMonitorScreen extends StatefulWidget {
  const ExpiryMonitorScreen(
      {super.key,
      required this.repository,
      required this.user,
      this.onAdjust,
      this.embedded = false,
      this.onBack});
  final InventoryHealthRepository repository;
  final ActiveUser user;
  final void Function(ExpiryBatchSummary)? onAdjust;
  final bool embedded;
  final VoidCallback? onBack;

  @override
  State<ExpiryMonitorScreen> createState() => _ExpiryMonitorScreenState();
}

class _ExpiryMonitorScreenState extends State<ExpiryMonitorScreen> {
  late Future<InventoryHealthSnapshot> snapshot = widget.repository.load();
  String filter = 'Attention';
  String query = '';
  int page = 0;

  void refresh() => setState(() => snapshot = widget.repository.load());

  static String daysLabel(int days) {
    if (days < 0) return '${-days} ${days == -1 ? 'day' : 'days'} overdue';
    if (days == 0) return 'Expires today';
    return '$days ${days == 1 ? 'day' : 'days'} remaining';
  }

  List<ExpiryBatchSummary> visible(InventoryHealthSnapshot data) {
    final search = query.toLowerCase();
    return data.expiry.where((batch) {
      final status = switch (filter) {
        'Expired' => batch.daysRemaining < 0,
        'Near expiry' => batch.daysRemaining >= 0 &&
            batch.daysRemaining <= data.settings.nearExpiryDays,
        'Attention' => batch.daysRemaining <= data.settings.nearExpiryDays,
        _ => true,
      };
      return status &&
          (batch.productName.toLowerCase().contains(search) ||
              batch.batchNumber.toLowerCase().contains(search));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final content = FutureBuilder<InventoryHealthSnapshot>(
      future: snapshot,
      builder: (context, result) => LayoutBuilder(builder: (context, bounds) {
        final data = result.data;
        final rows = data == null ? <ExpiryBatchSummary>[] : visible(data);
        final attention = data?.expiry
                .where((batch) =>
                    batch.daysRemaining <= data.settings.nearExpiryDays)
                .toList() ??
            <ExpiryBatchSummary>[];
        final units =
            attention.fold<int>(0, (sum, batch) => sum + batch.quantityMilli);
        final cost =
            attention.fold<int>(0, (sum, batch) => sum + batch.costCents);
        final costComplete = attention.every((batch) => batch.costCents > 0);
        final showCost = widget.user.can(PosPermission.reports);
        final showAction = widget.onAdjust != null;
        final compact = bounds.maxWidth < 900;
        return Padding(
          padding: AppLayout.workspacePadding(bounds.maxWidth),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppPageHeader(
              title: 'Expiry Monitor',
              subtitle:
                  'Monitor remaining batch stock that is expired or approaching expiry.',
              action: Row(mainAxisSize: MainAxisSize.min, children: [
                if (widget.onBack != null)
                  TextButton.icon(
                      onPressed: widget.onBack,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Tools')),
                IconButton(
                    onPressed: refresh,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh expiry items'),
              ]),
            ),
            if (result.hasError)
              Expanded(
                  child: AppErrorState(
                      title: 'Unable to load expiry items', onRetry: refresh))
            else ...[
              AppMetricGrid(children: [
                AppMetricTile(
                    label: 'Expired batches',
                    value: '${data?.expiredCount ?? 0}'),
                AppMetricTile(
                    label: 'Near expiry',
                    value: '${data?.nearExpiryCount ?? 0}'),
                AppMetricTile(
                    label: 'Affected units', value: Quantity.format(units)),
                if (showCost)
                  AppMetricTile(
                      label: 'At-risk cost value',
                      value: data == null
                          ? '—'
                          : costComplete
                              ? formatPeso(cost)
                              : 'Incomplete',
                      detail: costComplete
                          ? 'Recorded layer costs'
                          : 'Some batches have no recorded cost'),
              ]),
              const SizedBox(height: AppLayout.sectionGap),
              AppSearchField(
                  hintText: 'Search product, batch / lot...',
                  onChanged: (value) => setState(() {
                        query = value.trim();
                        page = 0;
                      })),
              const SizedBox(height: AppLayout.controlGap),
              Wrap(
                  spacing: AppLayout.space8,
                  runSpacing: AppLayout.space8,
                  children: [
                    for (final value in const [
                      'Attention',
                      'Expired',
                      'Near expiry',
                      'All'
                    ])
                      AppFilterChip(
                          label: value,
                          selected: filter == value,
                          onSelected: () => setState(() {
                                filter = value;
                                page = 0;
                              }))
                  ]),
              const SizedBox(height: AppLayout.sectionGap),
              Expanded(
                  child: AppPagedListPanel(
                key: const Key('expiry-list-panel'),
                title: 'Expiry items',
                total: rows.length,
                count: (rows.length - page * 50).clamp(0, 50),
                page: page,
                loading: data == null,
                onPrevious: () => setState(() => page--),
                onNext: () => setState(() => page++),
                emptyTitle: filter == 'Attention' && query.isEmpty
                    ? 'No expiry issues'
                    : 'No expiry items found',
                emptyMessage: filter == 'Attention' && query.isEmpty
                    ? 'No remaining batches are expired or near expiry.'
                    : 'Try another search or status filter.',
                columnHeader: compact
                    ? null
                    : _ExpiryColumns(
                        showCost: showCost, showAction: showAction),
                itemBuilder: (context, index) {
                  final batch = rows[page * 50 + index];
                  return _ExpiryRow(
                      batch: batch,
                      compact: compact,
                      showCost: showCost,
                      showAction: showAction,
                      onAdjust: showAction && batch.daysRemaining < 0
                          ? () => widget.onAdjust!(batch)
                          : null);
                },
              )),
            ],
          ]),
        );
      }),
    );
    return widget.embedded ? content : Scaffold(body: content);
  }
}

class _ExpiryColumns extends StatelessWidget {
  const _ExpiryColumns({required this.showCost, required this.showAction});
  final bool showCost;
  final bool showAction;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppLayout.space16, vertical: AppLayout.space8),
        child: Row(children: [
          _label(context, 'PRODUCT', 2),
          _label(context, 'BATCH / LOT', 1),
          _label(context, 'AVAILABLE', 1),
          _label(context, 'EXPIRY', 1),
          _label(context, 'DAYS LEFT', 2),
          if (showCost) _label(context, 'COST VALUE', 1),
          _label(context, 'STATUS', 1),
          if (showAction) _label(context, 'ACTION', 1),
        ]),
      );
  Widget _label(BuildContext context, String value, int flex) => Expanded(
      flex: flex,
      child: Text(value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700)));
}

class _ExpiryRow extends StatelessWidget {
  const _ExpiryRow(
      {required this.batch,
      required this.compact,
      required this.showCost,
      required this.showAction,
      required this.onAdjust});
  final ExpiryBatchSummary batch;
  final bool compact;
  final bool showCost;
  final bool showAction;
  final VoidCallback? onAdjust;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final expired = batch.daysRemaining < 0;
    final status = expired
        ? 'Expired'
        : batch.status == 'Later'
            ? 'Later'
            : 'Near expiry';
    final tone = expired
        ? AppStatusTone.danger
        : status == 'Later'
            ? AppStatusTone.neutral
            : AppStatusTone.warning;
    final date =
        MaterialLocalizations.of(context).formatMediumDate(batch.expiryDate);
    final badge =
        AppStatusBadge(label: status, color: appStatusColor(context, tone));
    final action = onAdjust == null
        ? const SizedBox.shrink()
        : OutlinedButton(
            onPressed: onAdjust, child: const Text('Adjust stock'));
    return Container(
      constraints: const BoxConstraints(minHeight: AppLayout.rowMinHeight),
      padding: const EdgeInsets.symmetric(
          horizontal: AppLayout.space16, vertical: AppLayout.space8),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outlineVariant))),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                  Text(batch.productName,
                      style: Theme.of(context).textTheme.titleMedium),
                  Row(children: [
                    Text(batch.batchNumber),
                    Flexible(
                        child: Text(
                            ' · ${Quantity.format(batch.quantityMilli)} · $date',
                            overflow: TextOverflow.ellipsis)),
                  ]),
                  Text(
                      _ExpiryMonitorScreenState.daysLabel(batch.daysRemaining)),
                  Row(children: [
                    badge,
                    if (showCost) ...[
                      const SizedBox(width: AppLayout.space12),
                      Text(formatPeso(batch.costCents))
                    ],
                    const Spacer(),
                    action
                  ]),
                ])
          : Row(children: [
              _cell(context, batch.productName, 2, prominent: true),
              _cell(context, batch.batchNumber, 1),
              _cell(context, Quantity.format(batch.quantityMilli), 1),
              _cell(context, date, 1),
              _cell(context,
                  _ExpiryMonitorScreenState.daysLabel(batch.daysRemaining), 2),
              if (showCost) _cell(context, formatPeso(batch.costCents), 1),
              Expanded(
                  child: Align(alignment: Alignment.centerLeft, child: badge)),
              if (showAction)
                Expanded(
                    child:
                        Align(alignment: Alignment.centerLeft, child: action)),
            ]),
    );
  }

  Widget _cell(BuildContext context, String value, int flex,
          {bool prominent = false}) =>
      Expanded(
          flex: flex,
          child: Text(value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: prominent
                  ? Theme.of(context).textTheme.titleSmall
                  : Theme.of(context).textTheme.bodyMedium));
}
