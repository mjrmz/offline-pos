import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show Variable, OrderingTerm, OrderingMode;

import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/customer_credit_repository.dart';
import '../../data/daos/loyalty_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/quotation_repository.dart';
import '../../data/daos/sales_order_repository.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/customer_purchase_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../core/services/sales_service.dart';
import '../../hardware/printer/receipt_service.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';
import 'customer_credit_panel.dart';
import 'customer_purchases_panel.dart';
import 'customer_profile_ui.dart';
import 'rma_screen.dart';
import 'quotation_screen.dart';
import '../sales_history/sales_history_screen.dart';

class _CustomerProfileData {
  final CustomerSummary? summary;
  final LoyaltyLedgerSummary ledger;
  final int points;
  final String group;
  final int credit;
  final List<RmaCase> recentRmas;
  final List<Quotation> recentQuotes;
  final Map<String, int> quotationTotals;
  final Map<String, String> rmaItemNames;
  final Map<String, int> rmaCounts;
  final Map<String, int> quoteCounts;

  const _CustomerProfileData({
    required this.summary,
    required this.ledger,
    required this.points,
    required this.group,
    required this.credit,
    required this.recentRmas,
    required this.recentQuotes,
    required this.quotationTotals,
    required this.rmaItemNames,
    required this.rmaCounts,
    required this.quoteCounts,
  });
}

class CustomerProfileScreen extends StatefulWidget {
  final Customer customer;
  final CustomerCreditRepository repository;
  final ActiveUser user;
  final SalesService? sales;
  final PosRepository? pos;
  final ReceiptService? receipts;
  final Future<void> Function()? onEdit;
  const CustomerProfileScreen(
      {super.key,
      required this.customer,
      required this.repository,
      required this.user,
      this.sales,
      this.pos,
      this.receipts,
      this.onEdit});

  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  late Customer currentCustomer;
  late Future<String> headerGroup;
  late Future<_CustomerProfileData> profileData;
  late Future<List<Sale>> recentSales;
  String quoteStatus = 'All';
  int rmaPage = 0;
  int quotePage = 0;
  int salesOrderPage = 0;
  int rewardPage = 0;
  AppDatabase get db => widget.repository.db;
  LoyaltyRepository get loyalty => LoyaltyRepository(db);

  @override
  void initState() {
    super.initState();
    currentCustomer = widget.customer;
    headerGroup = loyalty.group(widget.customer.id);
    profileData = _load();
    recentSales =
        CustomerPurchaseRepository(db).recent(widget.customer.id, limit: 5);
  }

  @override
  void didUpdateWidget(covariant CustomerProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.customer.id != widget.customer.id) {
      currentCustomer = widget.customer;
      headerGroup = loyalty.group(widget.customer.id);
      profileData = _load();
      recentSales =
          CustomerPurchaseRepository(db).recent(widget.customer.id, limit: 5);
      quoteStatus = 'All';
      rmaPage = 0;
      quotePage = 0;
      salesOrderPage = 0;
      rewardPage = 0;
    }
  }

  Future<void> _edit() async {
    await widget.onEdit?.call();
    final updated = await (db.select(db.customers)
          ..where((c) => c.id.equals(currentCustomer.id)))
        .getSingle();
    if (mounted) {
      setState(() {
        currentCustomer = updated;
        profileData = _load();
        recentSales =
            CustomerPurchaseRepository(db).recent(currentCustomer.id, limit: 5);
      });
    }
  }

  Future<void> _adjust() async {
    final points = TextEditingController();
    final reason = TextEditingController();
    final notes = TextEditingController();
    var increase = true;
    try {
      final apply = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                      title: const Text('Adjust points'),
                      content: SizedBox(
                          width: 360,
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            SegmentedButton<bool>(
                                segments: const [
                                  ButtonSegment(
                                      value: true, label: Text('Increase')),
                                  ButtonSegment(
                                      value: false, label: Text('Decrease'))
                                ],
                                selected: {
                                  increase
                                },
                                onSelectionChanged: (v) =>
                                    update(() => increase = v.first)),
                            TextField(
                                controller: points,
                                keyboardType: TextInputType.number,
                                decoration:
                                    const InputDecoration(labelText: 'Points')),
                            TextField(
                                controller: reason,
                                decoration: const InputDecoration(
                                    labelText: 'Reason *')),
                            TextField(
                                controller: notes,
                                decoration:
                                    const InputDecoration(labelText: 'Notes'))
                          ])),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel')),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Apply'))
                      ])));
      if (apply != true) return;
      final value = int.tryParse(points.text);
      if (value == null || value <= 0 || reason.text.trim().isEmpty) {
        throw ArgumentError('Enter positive points and a reason');
      }
      await loyalty.adjust(currentCustomer.id, widget.user.id,
          increase ? value : -value, reason.text,
          note: notes.text);
      if (mounted) {
        setState(() {
          headerGroup = loyalty.group(currentCustomer.id);
          profileData = _load();
          rewardPage = 0;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeMessage(error))));
      }
    } finally {
      points.dispose();
      reason.dispose();
      notes.dispose();
    }
  }

  Future<void> _changeGroup(String current) async {
    final selected = await showDialog<String>(
        context: context,
        builder: (context) =>
            SimpleDialog(title: const Text('Customer group'), children: [
              for (final group in const [
                'Retail',
                'VIP',
                'Dealer',
                'Wholesale',
                'Employee'
              ])
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, group),
                    child: Text(group))
            ]));
    if (selected == null || selected == current) return;
    try {
      await loyalty.setGroup(currentCustomer.id, widget.user.id, selected);
      if (mounted) {
        setState(() {
          headerGroup = loyalty.group(currentCustomer.id);
          profileData = _load();
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeMessage(error))));
      }
    }
  }

  Future<_CustomerProfileData> _load() async {
    final customerId = currentCustomer.id;
    final summary =
        DirectoryRepository(db).customerSummaries(ids: [customerId]);
    final ledger = loyalty.ledgerSummary(customerId);
    final points = loyalty.balance(customerId);
    final group = loyalty.group(customerId);
    final credit = widget.repository.balance(customerId);
    final rmaCounts = _statusCounts(customerId, rma: true);
    final quoteCounts = _statusCounts(customerId, rma: false);
    final rmas = await (db.select(db.rmaCases)
          ..where((r) => r.customerId.equals(customerId))
          ..orderBy([
            (r) =>
                OrderingTerm(expression: r.createdAt, mode: OrderingMode.desc)
          ])
          ..limit(3))
        .get();
    final quotes = await (db.select(db.quotations)
          ..where((q) => q.customerId.equals(customerId))
          ..orderBy([
            (q) =>
                OrderingTerm(expression: q.createdAt, mode: OrderingMode.desc)
          ])
          ..limit(3))
        .get();
    final totals = _quotationTotals(customerId,
        ids: quotes.map((quote) => quote.id).toList());
    final names =
        _rmaItemNames(customerId, ids: rmas.map((rma) => rma.id).toList());
    return _CustomerProfileData(
      summary: (await summary)[customerId],
      ledger: await ledger,
      points: await points,
      group: await group,
      credit: await credit,
      recentRmas: rmas,
      recentQuotes: quotes,
      quotationTotals: await totals,
      rmaItemNames: await names,
      rmaCounts: await rmaCounts,
      quoteCounts: await quoteCounts,
    );
  }

  Future<Map<String, int>> _statusCounts(String customerId,
      {required bool rma}) async {
    final table = rma ? 'rma_cases' : 'quotations';
    final rows = await db.customSelect('''
      SELECT status, COUNT(*) AS total FROM $table
      WHERE customer_id=? GROUP BY status
    ''', variables: [Variable.withString(customerId)]).get();
    return {
      for (final row in rows) row.read<String>('status'): row.read<int>('total')
    };
  }

  Future<Map<String, int>> _quotationTotals(String customerId,
      {List<String>? ids}) async {
    if (ids?.isEmpty == true) return {};
    final marks = ids == null ? '' : List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''SELECT qi.quotation_id,
      COALESCE(SUM(qi.line_total_cents),0) AS total
      FROM quotation_items qi JOIN quotations q ON q.id=qi.quotation_id
      WHERE q.customer_id=? ${ids == null ? '' : 'AND q.id IN ($marks)'}
      GROUP BY qi.quotation_id''', variables: [
      Variable.withString(customerId),
      if (ids != null)
        for (final id in ids) Variable.withString(id)
    ]).get();
    return {
      for (final row in rows)
        row.read<String>('quotation_id'): row.read<int>('total')
    };
  }

  Future<Map<String, String>> _rmaItemNames(String customerId,
      {List<String>? ids}) async {
    if (ids?.isEmpty == true) return {};
    final marks = ids == null ? '' : List.filled(ids.length, '?').join(',');
    final rows = await db.customSelect('''SELECT r.id, si.product_name
      FROM rma_cases r LEFT JOIN sale_items si ON si.id=r.sale_item_id
      WHERE r.customer_id=? ${ids == null ? '' : 'AND r.id IN ($marks)'}''',
        variables: [
          Variable.withString(customerId),
          if (ids != null)
            for (final id in ids) Variable.withString(id)
        ]).get();
    return {
      for (final row in rows)
        row.read<String>('id'):
            row.readNullable<String>('product_name') ?? 'Item unavailable'
    };
  }

  Future<({int total, List<RmaCase> rows, Map<String, String> names})>
      _rmaListPage() async {
    final customerId = currentCustomer.id;
    final selectedPage = rmaPage;
    final countRow = await db.customSelect(
        'SELECT COUNT(*) AS total FROM rma_cases WHERE customer_id=?',
        variables: [Variable.withString(customerId)]).getSingle();
    final rows = await (db.select(db.rmaCases)
          ..where((r) => r.customerId.equals(customerId))
          ..orderBy([
            (r) =>
                OrderingTerm(expression: r.createdAt, mode: OrderingMode.desc)
          ])
          ..limit(50, offset: selectedPage * 50))
        .get();
    final names = await _rmaItemNames(customerId,
        ids: rows.map((row) => row.id).toList());
    return (total: countRow.read<int>('total'), rows: rows, names: names);
  }

  Future<({int total, List<Quotation> rows, Map<String, int> totals})>
      _quotationListPage() async {
    final customerId = currentCustomer.id;
    final selectedPage = quotePage;
    final selectedStatus = quoteStatus;
    final statusSql = selectedStatus == 'All' ? '' : ' AND status=?';
    final statusValue = selectedStatus.toLowerCase().replaceAll(' ', '_');
    final countRow = await db.customSelect(
        'SELECT COUNT(*) AS total FROM quotations WHERE customer_id=?$statusSql',
        variables: [
          Variable.withString(customerId),
          if (selectedStatus != 'All') Variable.withString(statusValue),
        ]).getSingle();
    final query = db.select(db.quotations)
      ..where((q) => q.customerId.equals(customerId))
      ..orderBy([
        (q) => OrderingTerm(expression: q.createdAt, mode: OrderingMode.desc)
      ])
      ..limit(50, offset: selectedPage * 50);
    if (selectedStatus != 'All') {
      query.where((q) => q.status.equals(statusValue));
    }
    final quotes = await query.get();
    final totals = await _quotationTotals(customerId,
        ids: quotes.map((quote) => quote.id).toList());
    return (total: countRow.read<int>('total'), rows: quotes, totals: totals);
  }

  Future<void> _openSale(Sale sale) async {
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

  Future<void> _openRma(RmaCase row) => Navigator.push(
      context,
      MaterialPageRoute<void>(
          builder: (_) => RmaScreen(
              repository: RmaRepository(db),
              user: widget.user,
              initialCaseId: row.id)));

  Future<void> _openQuote(Quotation row) {
    final pos = PosRepository(db);
    return Navigator.push(
        context,
        MaterialPageRoute<void>(
            builder: (_) => QuotationScreen(
                repository: QuotationRepository(db, pos),
                directory: DirectoryRepository(db),
                products: pos,
                user: widget.user,
                initialQuotationReference: row.reference)));
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
      key: ValueKey(currentCustomer.id),
      length: widget.user.can(PosPermission.viewSalesOrders) ? 8 : 7,
      child: Scaffold(
          appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: IconButton(
                  tooltip: 'Back to customers',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back)),
              titleSpacing: 4,
              title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(currentCustomer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge),
                    FutureBuilder<String>(
                        future: headerGroup,
                        builder: (context, snapshot) => Text(
                            'Customer · ${snapshot.data ?? 'Retail'}',
                            style: Theme.of(context).textTheme.bodySmall)),
                    if (currentCustomer.phone?.isNotEmpty == true)
                      Text(currentCustomer.phone!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                  ]),
              actions: [
                if (widget.onEdit != null &&
                    widget.user.can(PosPermission.manageContacts))
                  TextButton(onPressed: _edit, child: const Text('Edit')),
                if (widget.user.can(PosPermission.manageLoyalty))
                  PopupMenuButton<String>(
                      tooltip: 'More customer actions',
                      onSelected: (value) async {
                        if (value == 'group') {
                          final group = await loyalty.group(currentCustomer.id);
                          if (mounted) await _changeGroup(group);
                        } else if (value == 'points') {
                          await _adjust();
                        }
                      },
                      itemBuilder: (context) => [
                            if (widget.user
                                .can(PosPermission.manageLoyalty)) ...[
                              const PopupMenuItem(
                                  value: 'group', child: Text('Change group')),
                              const PopupMenuItem(
                                  value: 'points',
                                  child: Text('Adjust points')),
                            ],
                          ]),
                IconButton(
                    tooltip: 'Close customer',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ],
              bottom: TabBar(isScrollable: true, tabs: [
                Tab(text: 'Overview'),
                Tab(text: 'Purchases'),
                Tab(text: 'Rewards'),
                Tab(text: 'Credit'),
                Tab(text: 'RMA'),
                Tab(text: 'Quotations'),
                if (widget.user.can(PosPermission.viewSalesOrders))
                  Tab(text: 'Sales Orders'),
                Tab(text: 'Notes')
              ])),
          body: FutureBuilder<_CustomerProfileData>(
              future: profileData,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text(safeMessage(snapshot.error!)));
                }
                if (snapshot.connectionState != ConnectionState.done ||
                    !snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final data = snapshot.data!;
                final summary = data.summary;
                final ledger = data.ledger;
                final points = data.points;
                final group = data.group;
                final credit = data.credit;
                final rmas = data.recentRmas;
                final quotes = data.recentQuotes;
                final rmaCounts = data.rmaCounts;
                final quoteCounts = data.quoteCounts;
                final rmaTotal = rmaCounts.values.fold<int>(0, (a, b) => a + b);
                final quoteTotal =
                    quoteCounts.values.fold<int>(0, (a, b) => a + b);
                final quotationTotals = data.quotationTotals;
                final rmaItemNames = data.rmaItemNames;
                final net = summary?.lifetimeCents ?? 0;
                final completedCount = summary?.purchases ?? 0;
                return TabBarView(children: [
                  ListView(padding: const EdgeInsets.all(24), children: [
                    CustomerProfileKpis([
                      ('Lifetime net spend', formatPeso(net)),
                      ('Transactions', '$completedCount'),
                      (
                        'Average transaction',
                        formatPeso(
                            completedCount == 0 ? 0 : net ~/ completedCount)
                      ),
                      (
                        'Last purchase',
                        summary?.lastPurchase == null
                            ? '—'
                            : MaterialLocalizations.of(context)
                                .formatMediumDate(summary!.lastPurchase!)
                      ),
                      ('Rewards points', '$points pts'),
                      if (widget.user.can(PosPermission.customerCredit))
                        ('Outstanding credit', formatPeso(credit)),
                    ]),
                    if (points < 0)
                      const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                              'Future earnings will offset the negative points balance.')),
                    const SizedBox(height: 22),
                    CustomerProfilePanel(
                        title: 'Recent activity',
                        child: FutureBuilder<List<Sale>>(
                            future: recentSales,
                            builder: (context, recent) {
                              if (recent.hasError) {
                                return Text(safeMessage(recent.error!));
                              }
                              if (!recent.hasData) {
                                return const LinearProgressIndicator();
                              }
                              final activity = <({
                                DateTime at,
                                String title,
                                String detail,
                                VoidCallback open
                              })>[
                                for (final sale in recent.data!)
                                  (
                                    at: sale.createdAt,
                                    title: sale.receiptNumber ?? 'Legacy sale',
                                    detail:
                                        'Sale ${sale.status} · ${formatPeso(sale.totalCents)}',
                                    open: () => _openSale(sale)
                                  ),
                                for (final quote in quotes.take(3))
                                  (
                                    at: quote.createdAt,
                                    title: quote.reference,
                                    detail: 'Quotation ${quote.status}',
                                    open: () => _openQuote(quote)
                                  ),
                                for (final rma in rmas.take(3))
                                  (
                                    at: rma.createdAt,
                                    title: rma.reference,
                                    detail: 'RMA ${rma.status}',
                                    open: () => _openRma(rma)
                                  ),
                              ]..sort((a, b) => b.at.compareTo(a.at));
                              if (activity.isEmpty) {
                                return const CustomerProfileEmpty(
                                    'No recent activity',
                                    'Sales, quotations, and warranty cases will appear here.');
                              }
                              return Column(children: [
                                for (final item in activity.take(5))
                                  ListTile(
                                      dense: true,
                                      title: Text(item.title),
                                      subtitle: Text(
                                          '${MaterialLocalizations.of(context).formatMediumDate(item.at)} · ${item.detail}'),
                                      onTap: item.open),
                              ]);
                            })),
                    const SizedBox(height: 20),
                    CustomerProfilePanel(
                        title: 'Recent purchases',
                        action: TextButton(
                            onPressed: () =>
                                DefaultTabController.of(context).animateTo(1),
                            child: const Text('View all')),
                        child: FutureBuilder<List<Sale>>(
                            future: recentSales,
                            builder: (context, recent) {
                              if (recent.hasError) {
                                return Text(safeMessage(recent.error!));
                              }
                              if (!recent.hasData) {
                                return const LinearProgressIndicator();
                              }
                              if (recent.data!.isEmpty) {
                                return const CustomerProfileEmpty(
                                    'No recent purchases',
                                    'Completed sales for this customer will appear here.');
                              }
                              return Column(children: [
                                for (final sale in recent.data!)
                                  ListTile(
                                      dense: true,
                                      title: Text(
                                          sale.receiptNumber ?? 'Legacy sale'),
                                      subtitle: Text(
                                          '${MaterialLocalizations.of(context).formatMediumDate(sale.createdAt)} · ${sale.status}'),
                                      trailing:
                                          Text(formatPeso(sale.totalCents)),
                                      onTap: () => _openSale(sale)),
                              ]);
                            })),
                    const SizedBox(height: 20),
                    CustomerProfilePanel(
                        title: 'Quotations',
                        count: quoteTotal,
                        action: TextButton(
                            onPressed: () =>
                                DefaultTabController.of(context).animateTo(5),
                            child: const Text('View all')),
                        child: quotes.isEmpty
                            ? const CustomerProfileEmpty('No quotations',
                                'Quotes created for this customer will appear here.')
                            : Column(children: [
                                for (final quote in quotes.take(3))
                                  ListTile(
                                      dense: true,
                                      title: Text(quote.reference),
                                      subtitle: Text(quote.status),
                                      trailing: Text(formatPeso(
                                          quotationTotals[quote.id] ?? 0)),
                                      onTap: () => _openQuote(quote)),
                              ])),
                    const SizedBox(height: 20),
                    CustomerProfilePanel(
                        title: 'RMA / Warranty',
                        count: rmaTotal,
                        action: TextButton(
                            onPressed: () =>
                                DefaultTabController.of(context).animateTo(4),
                            child: const Text('View all')),
                        child: rmas.isEmpty
                            ? const CustomerProfileEmpty('No RMA cases',
                                'Warranty and service cases will appear here.')
                            : Column(children: [
                                for (final rma in rmas.take(3))
                                  ListTile(
                                      dense: true,
                                      title: Text(rma.reference),
                                      subtitle: Text(
                                          '${rmaItemNames[rma.id] ?? 'Item unavailable'} · ${rma.status}'),
                                      onTap: () => _openRma(rma)),
                              ])),
                    const SizedBox(height: 20),
                    CustomerProfilePanel(
                        title: 'Customer information',
                        child: Column(children: [
                          _info('Phone', currentCustomer.phone),
                          _info('Address', currentCustomer.address),
                          _info('Customer group', group),
                          _info(
                              'Customer since',
                              MaterialLocalizations.of(context)
                                  .formatMediumDate(currentCustomer.createdAt)),
                          if (summary?.lastPurchase != null)
                            _info(
                                'Last activity',
                                MaterialLocalizations.of(context)
                                    .formatMediumDate(summary!.lastPurchase!)),
                        ])),
                  ]),
                  CustomerPurchasesPanel(
                    customerId: currentCustomer.id,
                    repository: CustomerPurchaseRepository(db),
                    user: widget.user,
                    sales: widget.sales,
                    pos: widget.pos,
                    receipts: widget.receipts,
                  ),
                  _rewardsTab(ledger, points),
                  widget.user.can(PosPermission.customerCredit)
                      ? CustomerCreditPanel(
                          customer: currentCustomer,
                          repository: widget.repository,
                          user: widget.user)
                      : const Center(child: Text('Credit access required.')),
                  _rmaTab(rmaCounts),
                  _quotationTab(quoteCounts),
                  if (widget.user.can(PosPermission.viewSalesOrders))
                    FutureBuilder(
                      future: () async {
                        final repository = SalesOrderRepository(db);
                        final page = await repository.page(
                            customerId: currentCustomer.id,
                            page: salesOrderPage);
                        final states = await repository.fulfillmentStates(
                            page.items.map((order) => order.id));
                        return (page, states);
                      }(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Center(child: Text(safeMessage(snapshot.error!)));
                        }
                        if (!snapshot.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        final result = snapshot.data!.$1;
                        final states = snapshot.data!.$2;
                        return Padding(padding: const EdgeInsets.all(24),
                          child: AppPagedListPanel(title: 'Sales Orders',
                            total: result.totalCount,
                            count: result.items.length,
                            page: salesOrderPage,
                            onPrevious: salesOrderPage > 0 ? () =>
                                setState(() => salesOrderPage--) : null,
                            onNext: (salesOrderPage + 1) * 50 < result.totalCount
                                ? () => setState(() => salesOrderPage++) : null,
                            itemBuilder: (context, index) {
                              final order = result.items[index];
                              return ListTile(title: Text(order.reference),
                                subtitle: Text('${order.createdAt.toLocal().toString().split(' ').first}  •  ${order.status}  •  ${states[order.id] ?? 'Unfulfilled'}  •  ${order.fulfillmentMethod ?? 'No intent'}'),
                                trailing: Text(formatPeso(order.totalCents)));
                            }));
                      }),
                  ListView(padding: const EdgeInsets.all(24), children: [
                    CustomerProfilePanel(
                        title: 'Internal notes',
                        action: widget.onEdit != null &&
                                widget.user.can(PosPermission.manageContacts)
                            ? TextButton.icon(
                                onPressed: _edit,
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                label: const Text('Edit'))
                            : null,
                        child: currentCustomer.notes?.trim().isNotEmpty == true
                            ? Text(currentCustomer.notes!)
                            : const CustomerProfileEmpty('No notes',
                                'Add an internal note to keep customer context in one place.')),
                  ]),
                ]);
              })));

  Widget _rewardsTab(LoyaltyLedgerSummary summary, int points) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        CustomerProfileKpis([
          ('Available points', '$points'),
          ('Lifetime earned', '${summary.earned}'),
          ('Lifetime redeemed', '${summary.redeemed}'),
          ('Adjustments', '${summary.adjustments}'),
        ]),
        if (widget.user.can(PosPermission.manageLoyalty)) ...[
          const SizedBox(height: 10),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                  onPressed: _adjust,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Adjust points'))),
        ],
        const SizedBox(height: 14),
        Expanded(
            child: FutureBuilder<List<LoyaltyLedgerRow>>(
                key: ValueKey('${currentCustomer.id}:rewards:$rewardPage'),
                future: loyalty.ledgerPage(currentCustomer.id, rewardPage),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(safeMessage(snapshot.error!)));
                  }
                  if (snapshot.connectionState != ConnectionState.done ||
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final rows = snapshot.data!;
                  return AppPagedListPanel(
                      title: 'Rewards activity',
                      total: summary.count,
                      count: rows.length,
                      page: rewardPage,
                      emptyTitle: 'No rewards activity',
                      emptyMessage:
                          'Points earned, redeemed, returned, or adjusted will appear here.',
                      onPrevious: () => setState(() => rewardPage--),
                      onNext: () => setState(() => rewardPage++),
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final entry = row.entry;
                        return Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                                dense: true,
                                title: Text(_loyaltyKind(entry.kind)),
                                subtitle: Text(
                                    '${MaterialLocalizations.of(context).formatMediumDate(entry.createdAt)} · ${entry.sourceId ?? entry.reason ?? 'Manual activity'} · Balance ${row.balance} pts'),
                                trailing: Text(
                                    '${entry.points > 0 ? '+' : ''}${entry.points} pts')));
                      });
                }))
      ]));

  Widget _rmaTab(Map<String, int> counts) {
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    final completed = (counts['completed'] ?? 0) + (counts['closed'] ?? 0);
    return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          CustomerProfileKpis([
            ('Open', '${counts['pending'] ?? 0}'),
            ('In progress', '${total - (counts['pending'] ?? 0) - completed}'),
            ('Completed', '$completed'),
          ]),
          const SizedBox(height: 20),
          Expanded(
              child: FutureBuilder<
                      ({
                        int total,
                        List<RmaCase> rows,
                        Map<String, String> names
                      })>(
                  key: ValueKey('${currentCustomer.id}:rma:$rmaPage'),
                  future: _rmaListPage(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(child: Text(safeMessage(snapshot.error!)));
                    }
                    if (snapshot.connectionState != ConnectionState.done ||
                        !snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final (:total, :rows, :names) = snapshot.data!;
                    return AppPagedListPanel(
                        title: 'RMA cases',
                        total: total,
                        count: rows.length,
                        page: rmaPage,
                        emptyTitle: 'No RMA cases',
                        emptyMessage:
                            'Warranty and service cases for this customer will appear here.',
                        onPrevious: () => setState(() => rmaPage--),
                        onNext: () => setState(() => rmaPage++),
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          return AppEntityRow(
                              title: row.reference,
                              subtitle:
                                  '${names[row.id] ?? 'Item unavailable'} · Opened ${MaterialLocalizations.of(context).formatMediumDate(row.createdAt)}',
                              status: AppSemanticStatusBadge(label: row.status),
                              onTap: () => _openRma(row));
                        });
                  }))
        ]));
  }

  Widget _quotationTab(Map<String, int> counts) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        CustomerProfileKpis([
          ('Open', '${counts['open'] ?? 0}'),
          ('Awaiting stock', '${counts['awaiting_stock'] ?? 0}'),
          ('Ready', '${counts['ready'] ?? 0}'),
          ('Converted', '${counts['converted'] ?? 0}'),
        ]),
        const SizedBox(height: 16),
        SizedBox(
            height: 42,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final status in const [
                'All',
                'Open',
                'Awaiting stock',
                'Ready',
                'Converted',
                'Expired',
                'Cancelled'
              ])
                Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                        label: Text(status),
                        selected: quoteStatus == status,
                        onSelected: (_) => setState(() {
                              quoteStatus = status;
                              quotePage = 0;
                            }))),
            ])),
        const SizedBox(height: 12),
        Expanded(
            child: FutureBuilder<
                    ({
                      int total,
                      List<Quotation> rows,
                      Map<String, int> totals
                    })>(
                key: ValueKey(
                    '${currentCustomer.id}:quote:$quoteStatus:$quotePage'),
                future: _quotationListPage(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(safeMessage(snapshot.error!)));
                  }
                  if (snapshot.connectionState != ConnectionState.done ||
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final (:total, :rows, :totals) = snapshot.data!;
                  return AppPagedListPanel(
                      title: 'Quotations',
                      total: total,
                      count: rows.length,
                      page: quotePage,
                      emptyTitle: 'No quotations',
                      emptyMessage:
                          'Quotes created for this customer will appear here.',
                      onPrevious: () => setState(() => quotePage--),
                      onNext: () => setState(() => quotePage++),
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return AppEntityRow(
                            title: row.reference,
                            subtitle:
                                '${MaterialLocalizations.of(context).formatMediumDate(row.createdAt)}${row.validUntil == null ? '' : ' · Valid until ${MaterialLocalizations.of(context).formatMediumDate(row.validUntil!)}'}',
                            amount: formatPeso(totals[row.id] ?? 0),
                            status: AppSemanticStatusBadge(label: row.status),
                            onTap: () => _openQuote(row));
                      });
                }))
      ]));

  String _loyaltyKind(String kind) => switch (kind) {
        'earn' => 'Earned',
        'redeem' => 'Redeemed',
        'manual' => 'Manual adjustment',
        'return_reversal' => 'Return reversal',
        'void_reversal' => 'Void reversal',
        _ => kind.replaceAll('_', ' '),
      };

  Widget _info(String label, String? value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 150,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(
            child: Text(value?.isNotEmpty == true ? value! : 'Not provided')),
      ]));
}
