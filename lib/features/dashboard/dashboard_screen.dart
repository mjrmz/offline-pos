import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../data/daos/cash_session_repository.dart';
import '../../shared/utils/money.dart';
import 'dashboard_repository.dart';

class DashboardScreen extends StatefulWidget {
  final ActiveUser user;
  final DashboardRepository repository;
  final CashSessionSummary? shift;
  final void Function(String) navigate;
  const DashboardScreen(
      {super.key,
      required this.user,
      required this.repository,
      required this.shift,
      required this.navigate});
  @override
  DashboardScreenState createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  late Future<DashboardSnapshot> snapshot;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      snapshot = widget.repository.load(widget.user);
    });
  }

  void refresh() => _refresh();

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final now = DateTime.now();
    final greeting = now.hour < 12
        ? 'Good morning'
        : now.hour < 17
            ? 'Good afternoon'
            : 'Good evening';
    final date = MaterialLocalizations.of(context).formatMediumDate(now);
    final ownShift = widget.shift?.session.openedByUserId == user.id;
    final actions = <(String, IconData, String)>[
      if (user.can(PosPermission.manageCashSession) && !ownShift)
        ('Cash session', Icons.lock_open_outlined, 'Cash session'),
      if (user.can(PosPermission.sell) && ownShift)
        ('New sale', Icons.point_of_sale, 'POS'),
      if (user.can(PosPermission.stockReceiving))
        ('Receive stock', Icons.move_to_inbox_outlined, 'Receiving'),
      if (user.can(PosPermission.viewSalesOrders) &&
          user.can(PosPermission.manageSalesOrders))
        ('Sales orders', Icons.assignment_outlined, 'Sales Orders'),
      if (user.can(PosPermission.stockCount))
        ('Stock count', Icons.fact_check_outlined, 'Stock Counts'),
      if (user.can(PosPermission.manageQuotations))
        ('Quotation', Icons.request_quote_outlined, 'Quotations'),
      if (user.can(PosPermission.viewContacts) &&
          user.can(PosPermission.customerCredit))
        (
          'Customer credit',
          Icons.account_balance_wallet_outlined,
          'Customers & Suppliers'
        ),
      if (user.can(PosPermission.manageExpenseFunds) &&
          user.can(PosPermission.viewContacts))
        ('Supplier payables', Icons.payments_outlined, 'Customers & Suppliers'),
      if (user.can(PosPermission.manageRma))
        ('RMA cases', Icons.assignment_return_outlined, 'RMA / Warranty'),
      if (user.can(PosPermission.reports))
        ('Reports', Icons.bar_chart_outlined, 'Reports'),
      if (user.can(PosPermission.sell) && !ownShift)
        ('Go to POS', Icons.point_of_sale, 'POS'),
    ];
    return LayoutBuilder(
        builder: (context, bounds) => RefreshIndicator(
            onRefresh: () async {
              _refresh();
              await snapshot;
            },
            child: ListView(
                padding: EdgeInsets.fromLTRB(
                    math.max(20, (bounds.maxWidth - 1280) / 2),
                    20,
                    math.max(20, (bounds.maxWidth - 1280) / 2),
                    24),
                children: [
                  Row(children: [
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('$greeting, ${user.name.split(' ').first}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 4),
                          Text(
                              bounds.maxWidth < 680
                                  ? 'Your workspace · $date'
                                  : 'Your workspace for today',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ])),
                    if (bounds.maxWidth >= 680) ...[
                      Text(date, style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(width: 8),
                    ],
                    IconButton(
                        tooltip: 'Refresh dashboard',
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh))
                  ]),
                  const SizedBox(height: 24),
                  Text('Quick actions',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final action in actions.take(4))
                      OutlinedButton.icon(
                          onPressed: () => widget.navigate(action.$3),
                          icon: Icon(action.$2, size: 18),
                          label: Text(action.$1)),
                    if (actions.length > 4)
                      PopupMenuButton<String>(
                          tooltip: 'More actions',
                          onSelected: widget.navigate,
                          itemBuilder: (_) => [
                                for (final action in actions.skip(4))
                                  PopupMenuItem(
                                      value: action.$3, child: Text(action.$1))
                              ],
                          child: Container(
                              height: 40,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Theme.of(context).dividerColor),
                                  borderRadius: BorderRadius.circular(24)),
                              child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.more_horiz, size: 18),
                                    SizedBox(width: 8),
                                    Text('More')
                                  ]))),
                  ]),
                  if (user.can(PosPermission.manageCashSession)) ...[
                    const SizedBox(height: 18),
                    _DashboardPanel(
                        title: 'Cash session',
                        child: ListTile(
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -2),
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(ownShift
                                ? Icons.check_circle_outline
                                : Icons.circle_outlined),
                            title: Text(ownShift
                                ? 'Cash session open'
                                : widget.shift == null
                                    ? 'No open cash session'
                                    : 'Another user has an open session'),
                            subtitle: ownShift
                                ? Text(
                                    'Opened ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(widget.shift!.session.openedAt.toLocal()))}')
                                : null,
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => widget.navigate('Cash session'))),
                  ],
                  const SizedBox(height: 20),
                  FutureBuilder<DashboardSnapshot>(
                      future: snapshot,
                      builder: (context, state) {
                        if (state.hasError) {
                          return _DashboardPanel(
                              title: 'Summary unavailable',
                              child: TextButton.icon(
                                  onPressed: _refresh,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry')));
                        }
                        if (!state.hasData) {
                          return const LinearProgressIndicator(minHeight: 3);
                        }
                        final data = state.data!;
                        final colors = Theme.of(context).colorScheme;
                        final canInventory =
                            user.can(PosPermission.manageCatalog) ||
                                user.can(PosPermission.stockCount) ||
                                user.can(PosPermission.stockReceiving);
                        final attention = <(String, String, Color)>[
                          if (user.can(PosPermission.viewSalesOrders) &&
                              (data.failedDeliveries ?? 0) > 0)
                            (
                              '${data.failedDeliveries} ${data.failedDeliveries == 1 ? 'delivery needs' : 'deliveries need'} attention',
                              'Sales Orders',
                              colors.error
                            ),
                          if (user.can(
                                  PosPermission.acknowledgeShiftHandover) &&
                              (data.pendingHandovers ?? 0) > 0)
                            (
                              '${data.pendingHandovers} ${data.pendingHandovers == 1 ? 'handover awaits' : 'handovers await'} acknowledgment',
                              'Cash session',
                              colors.error
                            ),
                          if (user.can(PosPermission.sell) &&
                              user.can(PosPermission.resumeSale) &&
                              (data.heldSales ?? 0) > 0)
                            (
                              '${data.heldSales} held ${data.heldSales == 1 ? 'sale' : 'sales'} to resume',
                              'POS',
                              colors.primary
                            ),
                          if (canInventory && (data.outOfStock ?? 0) > 0)
                            (
                              '${data.outOfStock} ${data.outOfStock == 1 ? 'product' : 'products'} out of stock',
                              'Out of stock',
                              colors.error
                            ),
                          if (canInventory && (data.lowStock ?? 0) > 0)
                            (
                              '${data.lowStock} ${data.lowStock == 1 ? 'product' : 'products'} low on stock',
                              'Low stock',
                              Colors.orange.shade700
                            ),
                          if (canInventory && (data.nearExpiry ?? 0) > 0)
                            (
                              '${data.nearExpiry} ${data.nearExpiry == 1 ? 'batch' : 'batches'} near expiry',
                              'Expiry Monitor',
                              Colors.orange.shade700
                            ),
                        ];
                        final operations = <(String, int, String)>[
                          if (canInventory && data.outOfStock != null)
                            ('Out of stock', data.outOfStock!, 'Out of stock'),
                          if (canInventory && data.lowStock != null)
                            ('Low stock', data.lowStock!, 'Low stock'),
                          if (canInventory && data.nearExpiry != null)
                            ('Near expiry', data.nearExpiry!, 'Expiry Monitor'),
                          if (user.can(PosPermission.viewSalesOrders) &&
                              data.openSalesOrders != null)
                            (
                              'Orders to fulfill',
                              data.openSalesOrders!,
                              'Sales Orders'
                            ),
                          if (user.can(PosPermission.stockReceiving) &&
                              data.openPurchaseOrders != null)
                            (
                              'Open purchase orders',
                              data.openPurchaseOrders!,
                              'Purchase Orders'
                            ),
                          if (user.can(PosPermission.manageRma) &&
                              data.openRmas != null)
                            ('Open RMAs', data.openRmas!, 'RMA / Warranty'),
                        ];
                        final metrics = <Widget>[
                          if (user.can(PosPermission.viewOwnSales) &&
                              data.salesCents != null)
                            _MetricTile(
                                label: user.can(PosPermission.viewAllSales)
                                    ? 'Completed sales today'
                                    : 'My completed sales today',
                                value: formatPeso(data.salesCents!),
                                onTap: () => widget.navigate('Sales History')),
                          if (user.can(PosPermission.viewOwnSales) &&
                              data.transactions != null)
                            _MetricTile(
                                label: 'Transactions today',
                                value: '${data.transactions}',
                                onTap: () => widget.navigate('Sales History')),
                          if (user.can(PosPermission.sell) &&
                              user.can(PosPermission.resumeSale) &&
                              data.heldSales != null)
                            _MetricTile(
                                label: 'My held sales',
                                value: '${data.heldSales}',
                                onTap: () => widget.navigate('POS')),
                          if (user.can(PosPermission.viewContacts) &&
                              user.can(PosPermission.customerCredit) &&
                              data.receivablesCents != null)
                            _MetricTile(
                                label: 'Receivables',
                                value: formatPeso(data.receivablesCents!),
                                onTap: () =>
                                    widget.navigate('Customers & Suppliers')),
                          if (user.can(PosPermission.viewContacts) &&
                              user.can(PosPermission.reports) &&
                              data.payablesCents != null)
                            _MetricTile(
                                label: 'Payables',
                                value: formatPeso(data.payablesCents!),
                                onTap: () =>
                                    widget.navigate('Customers & Suppliers')),
                        ];
                        return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (attention.isNotEmpty) ...[
                                _DashboardPanel(
                                    title: 'Needs attention',
                                    child: Column(children: [
                                      for (var i = 0;
                                          i < attention.length;
                                          i++) ...[
                                        if (i > 0) const Divider(height: 1),
                                        ListTile(
                                            contentPadding: EdgeInsets.zero,
                                            dense: true,
                                            visualDensity: const VisualDensity(
                                                vertical: -2),
                                            leading: Icon(Icons.error_outline,
                                                size: 19,
                                                color: attention[i].$3),
                                            title: Text(attention[i].$1),
                                            trailing:
                                                const Icon(Icons.chevron_right),
                                            onTap: () => widget
                                                .navigate(attention[i].$2)),
                                      ],
                                    ])),
                                const SizedBox(height: 20),
                              ],
                              if (metrics.isNotEmpty) ...[
                                Text('At a glance',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                const SizedBox(height: 10),
                                LayoutBuilder(builder: (context, constraints) {
                                  final columns = constraints.maxWidth >= 1150
                                      ? 4
                                      : constraints.maxWidth >= 680
                                          ? 3
                                          : constraints.maxWidth >= 420
                                              ? 2
                                              : 1;
                                  final width = (constraints.maxWidth -
                                          (columns - 1) * 12) /
                                      columns;
                                  return Wrap(
                                      spacing: 12,
                                      runSpacing: 12,
                                      children: [
                                        for (final metric in metrics)
                                          SizedBox(width: width, child: metric),
                                      ]);
                                }),
                              ],
                              if (operations.isNotEmpty) ...[
                                const SizedBox(height: 20),
                                _DashboardPanel(
                                    title: 'Operations',
                                    child: Column(children: [
                                      for (var i = 0;
                                          i < operations.length;
                                          i++) ...[
                                        if (i > 0) const Divider(height: 1),
                                        ListTile(
                                            dense: true,
                                            contentPadding: EdgeInsets.zero,
                                            title: Text(operations[i].$1),
                                            trailing: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text('${operations[i].$2}',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium),
                                                  const SizedBox(width: 8),
                                                  const Icon(
                                                      Icons.chevron_right),
                                                ]),
                                            onTap: () => widget
                                                .navigate(operations[i].$3)),
                                      ],
                                    ])),
                              ],
                              if (metrics.isEmpty &&
                                  operations.isEmpty &&
                                  attention.isEmpty)
                                _DashboardPanel(
                                    title: 'Your workspace',
                                    child: const Text(
                                        'Choose an action above to get started.')),
                            ]);
                      }),
                ])));
  }
}

class _DashboardPanel extends StatelessWidget {
  final String title;
  final Widget child;
  const _DashboardPanel({required this.title, required this.child});
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        child,
      ]));
}

class _MetricTile extends StatelessWidget {
  final String label, value;
  final VoidCallback onTap;
  const _MetricTile(
      {required this.label, required this.value, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
          height: 112,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const Spacer(),
            Text(value, style: Theme.of(context).textTheme.headlineSmall),
          ])));
}
