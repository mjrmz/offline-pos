import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/promotion_repository.dart';
import '../../data/daos/promotion_analytics_repository.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../shared/utils/money.dart';

String promotionTypeLabel(String type) => switch (type) {
      'percentage' => 'Percentage discount',
      'fixed' => 'Fixed amount discount',
      'minimum_spend' => 'Minimum spend discount',
      _ => 'Promotion',
    };

String promotionStatusLabel(String status) => status.isEmpty
    ? status
    : '${status[0].toUpperCase()}${status.substring(1)}';

class PromotionsScreen extends StatefulWidget {
  final PromotionRepository repository;
  final ActiveUser user;
  const PromotionsScreen(
      {super.key, required this.repository, required this.user});
  @override
  State<PromotionsScreen> createState() => _PromotionsScreenState();
}

class _PromotionsScreenState extends State<PromotionsScreen> {
  List<Promotion> rows = [];
  Map<String, int> counts = {};
  int total = 0, page = 0, generation = 0;
  String search = '', status = 'all', type = 'all';
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    final current = ++generation;
    setState(() => loading = true);
    try {
      final results = await Future.wait<dynamic>([
        widget.repository.listPromotions(widget.user,
            page: page, search: search, statusFilter: status, type: type),
        widget.repository.countPromotions(widget.user,
            search: search, statusFilter: status, type: type),
        widget.repository.statusCounts(widget.user),
      ]);
      if (!mounted || current != generation) return;
      setState(() {
        rows = results[0] as List<Promotion>;
        total = results[1] as int;
        counts = results[2] as Map<String, int>;
        error = null;
        loading = false;
      });
    } catch (e) {
      if (mounted && current == generation) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> edit([Promotion? row]) async {
    final changed = await showDialog<bool>(
        context: context,
        builder: (_) => _PromotionEditor(
            repository: widget.repository, user: widget.user, row: row));
    if (changed == true) refresh();
  }

  Future<void> detail(Promotion row) async {
    final action = await showDialog<String>(
        context: context,
        builder: (_) => _PromotionDetail(
            repository: widget.repository, user: widget.user, row: row));
    if (action == 'edit') {
      await edit(row);
    }
    if (action == 'duplicate') {
      await widget.repository.duplicatePromotion(widget.user, row.id);
      await refresh();
    }
    if (action == 'toggle') {
      await widget.repository.setActive(widget.user, row.id, !row.isActive);
      await refresh();
    }
  }

  @override
  Widget build(BuildContext context) => AppWorkspacePadding(
          child: Column(children: [
        AppPageHeader(
            title: 'Promotions',
            subtitle: 'Create and manage automatic pricing and discount rules.',
            action: widget.user.can(PosPermission.managePromotions)
                ? FilledButton.icon(
                    onPressed: () => edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('New promotion'))
                : null),
        AppMetricGrid(children: [
          for (final s in ['active', 'scheduled', 'draft', 'expired'])
            AppMetricTile(
                label: promotionStatusLabel(s), value: '${counts[s] ?? 0}')
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
              child: AppSearchField(
                  hintText: 'Search promotion name or reference...',
                  onChanged: (v) {
                    search = v;
                    page = 0;
                    refresh();
                  })),
          const SizedBox(width: 12),
          DropdownButton<String>(
              value: status,
              items: [
                for (final s in [
                  'all',
                  'active',
                  'scheduled',
                  'draft',
                  'expired',
                  'inactive'
                ])
                  DropdownMenuItem(
                      value: s, child: Text(promotionStatusLabel(s)))
              ],
              onChanged: (v) {
                setState(() {
                  status = v!;
                  page = 0;
                });
                refresh();
              }),
          const SizedBox(width: 12),
          DropdownButton<String>(
              value: type,
              items: [
                for (final s in ['all', 'percentage', 'fixed', 'minimum_spend'])
                  DropdownMenuItem(
                      value: s,
                      child: Text(
                          s == 'all' ? 'All types' : promotionTypeLabel(s)))
              ],
              onChanged: (v) {
                setState(() {
                  type = v!;
                  page = 0;
                });
                refresh();
              })
        ]),
        const SizedBox(height: 16),
        Expanded(
            child: AppPagedListPanel(
                title: 'Promotion rules',
                total: total,
                count: rows.length,
                page: page,
                loading: loading,
                error: error,
                onRetry: refresh,
                emptyTitle: 'No promotions yet',
                onPrevious: () {
                  setState(() => page--);
                  refresh();
                },
                onNext: () {
                  setState(() => page++);
                  refresh();
                },
                itemBuilder: (_, i) {
                  final row = rows[i];
                  return AppEntityRow(
                      title: row.name,
                      subtitle:
                          '${row.reference} · ${promotionTypeLabel(row.type)} · ${row.targetMode == 'all' ? 'All products' : row.targetMode == 'products' ? 'Selected products' : 'Selected categories'} · Priority ${row.priority}',
                      status: AppSemanticStatusBadge(
                          label: promotionStatusLabel(
                              widget.repository.status(row))),
                      onTap: () => detail(row));
                }))
      ]));
}

class _PromotionDetail extends StatefulWidget {
  final PromotionRepository repository;
  final ActiveUser user;
  final Promotion row;
  const _PromotionDetail(
      {required this.repository, required this.user, required this.row});
  @override
  State<_PromotionDetail> createState() => _PromotionDetailState();
}

class _PromotionDetailState extends State<_PromotionDetail> {
  late final PromotionAnalyticsRepository analytics =
      PromotionAnalyticsRepository(widget.repository.db);
  PromotionPeriod period = PromotionPeriod.named('This month', DateTime.now());
  int tab = 0, page = 0;
  Future<PromotionMetrics>? metrics;
  Future<List<PromotionSaleRow>>? sales;
  Future<List<PromotionProductRow>>? products;
  Future<List<PromotionActivityRow>>? activity;
  Future<List<String>>? targetNames;

  @override
  void initState() {
    super.initState();
    targetNames = widget.row.targetMode == 'products'
        ? widget.repository.productTargetNames(widget.user, widget.row.id)
        : widget.row.targetMode == 'categories'
            ? widget.repository.categoryTargetNames(widget.user, widget.row.id)
            : Future.value(const ['All products']);
    activity = analytics.activity(widget.user, widget.row.id);
    load();
  }

  void load() {
    metrics = analytics.metrics(widget.user, widget.row.id, period);
    sales = analytics.sales(widget.user, widget.row.id, period, page: page);
    products = analytics.topProducts(widget.user, widget.row.id, period);
  }

  Future<void> selectPeriod(String value) async {
    if (value == 'Custom') {
      final chosen = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: DateTime.now().add(const Duration(days: 1)),
          initialDateRange: DateTimeRange(
              start: period.start,
              end: period.end.subtract(const Duration(days: 1))));
      if (chosen == null || !mounted) return;
      period = PromotionPeriod.custom(chosen.start, chosen.end);
    } else {
      period = PromotionPeriod.named(value, DateTime.now());
    }
    setState(() {
      page = 0;
      load();
    });
  }

  String date(DateTime? value) => value == null
      ? '—'
      : MaterialLocalizations.of(context).formatMediumDate(value.toLocal());

  Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));

  Future<void> showSale(PromotionSaleRow sale) => showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            title: Text(sale.receipt),
            content: SizedBox(
                width: 500,
                height: 380,
                child: ListView(children: [
                  Text(date(sale.date)),
                  Text(sale.customer),
                  section('Saved sale lines'),
                  FutureBuilder<List<PromotionSaleLine>>(
                      future: analytics.saleLines(widget.user, sale.saleId),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) return Text('${snapshot.error}');
                        if (!snapshot.hasData) {
                          return const LinearProgressIndicator();
                        }
                        return Column(children: [
                          for (final line in snapshot.data!)
                            ListTile(
                                dense: true,
                                title: Text(line.name),
                                subtitle: Text(
                                    '${line.quantityMilli / 1000} ${line.unit} · saved ${formatPeso(line.discountCents)}'),
                                trailing: Text(formatPeso(line.netCents)))
                        ]);
                      }),
                  const Divider(),
                  Text('Gross line sales ${formatPeso(sale.grossCents)}'),
                  Text('Promotion discount ${formatPeso(sale.discountCents)}'),
                  Text('Net line sales ${formatPeso(sale.netCents)}'),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Close'))
            ],
          ));

  Widget performance() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Period  '),
          DropdownButton<String>(
              value: period.label,
              items: [
                for (final value in [
                  'Today',
                  'This week',
                  'This month',
                  'This year',
                  'Custom'
                ])
                  DropdownMenuItem(value: value, child: Text(value))
              ],
              onChanged: (value) {
                if (value != null) selectPeriod(value);
              })
        ]),
        FutureBuilder<PromotionMetrics>(
            future: metrics,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('${snapshot.error}');
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final m = snapshot.data!;
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppMetricGrid(children: [
                      AppMetricTile(
                          label: 'Promoted sales', value: '${m.sales}'),
                      AppMetricTile(
                          label: 'Gross line sales',
                          value: formatPeso(m.grossCents)),
                      AppMetricTile(
                          label: 'Promotion discounts',
                          value: formatPeso(m.discountCents)),
                      AppMetricTile(
                          label: 'Net line sales',
                          value: formatPeso(m.netCents)),
                      AppMetricTile(
                          label: 'Average discount',
                          value: formatPeso(m.averageDiscountCents)),
                    ]),
                    const SizedBox(height: 8),
                    Text(
                        'First use ${date(m.firstUse)}  ·  Last use ${date(m.lastUse)}'),
                    const Text(
                        'Sale line values before and after promotion; refunds are shown separately in Sales History.'),
                  ]);
            }),
        section('Sales using promotion'),
        FutureBuilder<List<PromotionSaleRow>>(
            future: sales,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('${snapshot.error}');
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final rows = snapshot.data!;
              return Column(children: [
                if (rows.isEmpty)
                  const ListTile(title: Text('No sales in this period')),
                for (final sale in rows)
                  ListTile(
                      dense: true,
                      title: Text('${sale.receipt}  ·  ${date(sale.date)}'),
                      subtitle: Text(
                          '${sale.customer}  ·  Gross ${formatPeso(sale.grossCents)}  ·  Discount ${formatPeso(sale.discountCents)}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(formatPeso(sale.netCents)),
                        const Icon(Icons.chevron_right)
                      ]),
                      onTap: () => showSale(sale)),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text('Page ${page + 1}'),
                  IconButton(
                      tooltip: 'Previous page',
                      onPressed: page == 0
                          ? null
                          : () => setState(() {
                                page--;
                                sales = analytics.sales(
                                    widget.user, widget.row.id, period,
                                    page: page);
                              }),
                      icon: const Icon(Icons.chevron_left)),
                  IconButton(
                      tooltip: 'Next page',
                      onPressed: rows.length < 50
                          ? null
                          : () => setState(() {
                                page++;
                                sales = analytics.sales(
                                    widget.user, widget.row.id, period,
                                    page: page);
                              }),
                      icon: const Icon(Icons.chevron_right)),
                ]),
              ]);
            }),
        section('Top promoted products'),
        const Text(
            'Single-promotion sales only; quantities stay grouped by unit.'),
        FutureBuilder<List<PromotionProductRow>>(
            future: products,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('${snapshot.error}');
              if (!snapshot.hasData) return const LinearProgressIndicator();
              if (snapshot.data!.isEmpty) {
                return const ListTile(
                    title:
                        Text('No attributable product lines in this period'));
              }
              return Column(children: [
                for (final product in snapshot.data!)
                  ListTile(
                      dense: true,
                      title: Text(product.name),
                      subtitle: Text(
                          '${product.quantityMilli / 1000} ${product.unit}  ·  Gross ${formatPeso(product.grossCents)}  ·  Discount ${formatPeso(product.discountCents)}'),
                      trailing: Text(formatPeso(product.netCents)))
              ]);
            }),
      ]);

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final status = widget.repository.status(row);
    return AlertDialog(
      title: Text(row.name),
      content: SizedBox(
          width: 760,
          height: 620,
          child: Column(children: [
            Align(alignment: Alignment.centerLeft, child: Text(row.reference)),
            const SizedBox(height: 8),
            Align(
                alignment: Alignment.centerLeft,
                child: AppSemanticStatusBadge(
                    label: promotionStatusLabel(status))),
            const SizedBox(height: 8),
            AppWorkspaceTabs(
                labels: const [
                  'Overview',
                  'Performance',
                  'Targets',
                  'Activity'
                ],
                selectedIndex: tab,
                onSelected: (index) => setState(() => tab = index)),
            const Divider(),
            Expanded(
                child: SingleChildScrollView(
                    child: switch (tab) {
              0 =>
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (row.description.isNotEmpty) Text(row.description),
                  section('Reward'),
                  Text(promotionTypeLabel(row.type)),
                  Text(row.rewardKind == 'percentage'
                      ? '${(row.rewardValue / 100).toStringAsFixed(2)}% off'
                      : '${formatPeso(row.rewardValue)} off'),
                  if (row.minimumSubtotalCents != null)
                    Text(
                        'Minimum spend ${formatPeso(row.minimumSubtotalCents!)}'),
                  section('Schedule'),
                  Text(
                      'Starts: ${row.startsAt == null ? 'Immediately' : date(row.startsAt)}'),
                  Text(
                      'Ends: ${row.endsAt == null ? 'No end date' : date(row.endsAt)}'),
                  if (status == 'expired')
                    const Text(
                        'Expired; historical performance remains available.'),
                  if (status == 'inactive')
                    const Text(
                        'Deactivated; new sales cannot use this promotion.'),
                  if (status == 'scheduled')
                    Text('Scheduled to start ${date(row.startsAt)}.'),
                  section('Behavior'),
                  Text('Priority ${row.priority}  ·  ${row.stackingMode}'),
                ]),
              1 => performance(),
              2 =>
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  section('Targets'),
                  FutureBuilder<List<String>>(
                      future: targetNames,
                      builder: (context, snapshot) => Text(snapshot.hasData
                          ? snapshot.data!.join(', ')
                          : 'Loading targets…')),
                ]),
              _ =>
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  section('Configuration changes'),
                  FutureBuilder<List<PromotionActivityRow>>(
                      future: activity,
                      builder: (context, snapshot) {
                        if (snapshot.hasError) return Text('${snapshot.error}');
                        if (!snapshot.hasData) {
                          return const LinearProgressIndicator();
                        }
                        if (snapshot.data!.isEmpty) {
                          return const Text(
                              'No configuration activity recorded.');
                        }
                        return Column(children: [
                          for (final event in snapshot.data!)
                            ListTile(
                                dense: true,
                                title: Text(
                                    '${event.actor} · ${event.action.replaceAll('promotion_', '').replaceAll('_', ' ')}'),
                                subtitle: Text(
                                    '${date(event.date)} ${TimeOfDay.fromDateTime(event.date.toLocal()).format(context)}'))
                        ]);
                      }),
                ]),
            }))
          ])),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
        if (widget.user.can(PosPermission.managePromotions)) ...[
          TextButton(
              onPressed: () => Navigator.pop(context, 'duplicate'),
              child: const Text('Duplicate promotion')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'toggle'),
              child: Text(row.isActive ? 'Deactivate' : 'Activate')),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'edit'),
              child: const Text('Edit')),
        ],
      ],
    );
  }
}

class _PromotionEditor extends StatefulWidget {
  final PromotionRepository repository;
  final ActiveUser user;
  final Promotion? row;
  const _PromotionEditor(
      {required this.repository, required this.user, this.row});
  @override
  State<_PromotionEditor> createState() => _PromotionEditorState();
}

class _PromotionEditorState extends State<_PromotionEditor> {
  int? scaled(String raw) {
    final text = raw.trim();
    if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(text)) return null;
    final parts = text.split('.');
    return int.parse(parts[0]) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  }

  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      description = TextEditingController(),
      value = TextEditingController(),
      minimum = TextEditingController(),
      priority = TextEditingController(text: '100');
  String type = 'percentage',
      reward = 'percentage',
      target = 'all',
      stacking = 'exclusive',
      productSearch = '';
  DateTime? start, end;
  bool active = false, draft = false, saving = false;
  List<Product> products = [];
  List<Category> categories = [];
  final selectedProducts = <String>{}, selectedCategories = <String>{};
  @override
  void initState() {
    super.initState();
    final row = widget.row;
    if (row != null) {
      name.text = row.name;
      description.text = row.description;
      type = row.type;
      reward = row.rewardKind;
      value.text = row.rewardKind == 'percentage'
          ? (row.rewardValue / 100).toString()
          : (row.rewardValue / 100).toStringAsFixed(2);
      minimum.text = row.minimumSubtotalCents == null
          ? ''
          : (row.minimumSubtotalCents! / 100).toStringAsFixed(2);
      priority.text = '${row.priority}';
      target = row.targetMode;
      stacking = row.stackingMode;
      start = row.startsAt;
      end = row.endsAt;
      active = row.isActive;
      draft = row.isDraft;
      widget.repository.productTargets(widget.user, row.id).then((v) {
        if (mounted) setState(() => selectedProducts.addAll(v));
      });
      widget.repository.categoryTargets(widget.user, row.id).then((v) {
        if (mounted) setState(() => selectedCategories.addAll(v));
      });
    }
    loadTargets();
  }

  Future<void> loadTargets() async {
    final c = await widget.repository.categories(widget.user);
    final p =
        await widget.repository.searchProducts(widget.user, productSearch);
    if (mounted) {
      setState(() {
        categories = c;
        products = p;
      });
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    if (start != null && end != null && !end!.isAfter(start!)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('End must be after start')));
      return;
    }
    if ((target == 'products' && selectedProducts.isEmpty) ||
        (target == 'categories' && selectedCategories.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one target')));
      return;
    }
    setState(() => saving = true);
    try {
      final input = PromotionInput(
          name: name.text,
          description: description.text,
          type: type,
          rewardKind: type == 'minimum_spend' ? reward : type,
          rewardValue: scaled(value.text)!,
          minimumSubtotalCents:
              type == 'minimum_spend' ? scaled(minimum.text) : null,
          targetMode: target,
          productIds: selectedProducts.toList(),
          categoryIds: selectedCategories.toList(),
          startsAt: start,
          endsAt: end,
          priority: int.parse(priority.text),
          stackingMode: stacking,
          active: active,
          draft: draft);
      if (widget.row == null) {
        await widget.repository.createPromotion(widget.user, input);
      } else {
        await widget.repository
            .updatePromotion(widget.user, widget.row!.id, input);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<DateTime?> pick(DateTime? initial) async {
    final date = await showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
        context: context,
        initialTime: initial == null
            ? TimeOfDay.now()
            : TimeOfDay.fromDateTime(initial));
    return time == null
        ? null
        : DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.row == null
              ? 'New promotion'
              : 'Edit ${widget.row!.reference}'),
          content: SizedBox(
              width: 620,
              height: 600,
              child: Form(
                  key: form,
                  child: ListView(children: [
                    const Text('BASIC INFORMATION'),
                    TextFormField(
                        controller: name,
                        decoration: const InputDecoration(labelText: 'Name'),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? 'Name required'
                            : null),
                    TextFormField(
                        controller: description,
                        decoration:
                            const InputDecoration(labelText: 'Description')),
                    const SizedBox(height: 12),
                    const Text('PROMOTION TYPE'),
                    DropdownButtonFormField<String>(
                        initialValue: type,
                        items: const [
                          DropdownMenuItem(
                              value: 'percentage',
                              child: Text('Percentage discount')),
                          DropdownMenuItem(
                              value: 'fixed',
                              child: Text('Fixed amount discount')),
                          DropdownMenuItem(
                              value: 'minimum_spend',
                              child: Text('Minimum spend discount'))
                        ],
                        onChanged: (v) => setState(() {
                              type = v!;
                              reward = v == 'minimum_spend' ? 'percentage' : v;
                            })),
                    if (type == 'minimum_spend') ...[
                      DropdownButtonFormField<String>(
                          initialValue: reward,
                          items: const [
                            DropdownMenuItem(
                                value: 'percentage',
                                child: Text('Percentage reward')),
                            DropdownMenuItem(
                                value: 'fixed',
                                child: Text('Fixed amount reward'))
                          ],
                          onChanged: (v) => setState(() => reward = v!)),
                      TextFormField(
                          controller: minimum,
                          decoration: const InputDecoration(
                              labelText: 'Minimum subtotal (₱)'),
                          keyboardType: TextInputType.number,
                          validator: (v) => (scaled(v ?? '') ?? 0) <= 0
                              ? 'Enter a positive amount'
                              : null)
                    ],
                    TextFormField(
                        controller: value,
                        decoration: InputDecoration(
                            labelText: reward == 'percentage'
                                ? 'Discount (%)'
                                : 'Discount (₱)'),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          final n = scaled(v ?? '');
                          return n == null ||
                                  n <= 0 ||
                                  (reward == 'percentage' && n > 10000)
                              ? 'Enter a valid discount'
                              : null;
                        }),
                    const SizedBox(height: 12),
                    const Text('TARGETING'),
                    DropdownButtonFormField<String>(
                        initialValue: target,
                        items: const [
                          DropdownMenuItem(
                              value: 'all', child: Text('All products')),
                          DropdownMenuItem(
                              value: 'products',
                              child: Text('Specific products')),
                          DropdownMenuItem(
                              value: 'categories',
                              child: Text('Specific categories'))
                        ],
                        onChanged: (v) => setState(() => target = v!)),
                    if (target == 'products') ...[
                      TextField(
                          decoration: const InputDecoration(
                              labelText: 'Search products'),
                          onChanged: (v) {
                            productSearch = v;
                            loadTargets();
                          }),
                      for (final p in products)
                        CheckboxListTile(
                            dense: true,
                            title: Text(p.name),
                            value: selectedProducts.contains(p.id),
                            onChanged: (v) => setState(() {
                                  if (v!) {
                                    selectedProducts.add(p.id);
                                  } else {
                                    selectedProducts.remove(p.id);
                                  }
                                })),
                      Text('${selectedProducts.length} selected')
                    ],
                    if (target == 'categories')
                      for (final c in categories)
                        CheckboxListTile(
                            dense: true,
                            title: Text(c.name),
                            value: selectedCategories.contains(c.id),
                            onChanged: (v) => setState(() {
                                  if (v!) {
                                    selectedCategories.add(c.id);
                                  } else {
                                    selectedCategories.remove(c.id);
                                  }
                                })),
                    const SizedBox(height: 12),
                    const Text('SCHEDULE'),
                    Material(
                        child: ListTile(
                            title: Text(start == null
                                ? 'Starts immediately'
                                : 'Starts $start'),
                            trailing: IconButton(
                                icon: const Icon(Icons.calendar_today),
                                onPressed: () async {
                                  final v = await pick(start);
                                  if (v != null) setState(() => start = v);
                                }))),
                    Material(
                        child: ListTile(
                            title:
                                Text(end == null ? 'No end date' : 'Ends $end'),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () => setState(() => end = null)),
                              IconButton(
                                  icon: const Icon(Icons.calendar_today),
                                  onPressed: () async {
                                    final v = await pick(end);
                                    if (v != null) setState(() => end = v);
                                  })
                            ]))),
                    if (start != null && end != null && !end!.isAfter(start!))
                      const Text('End must be after start',
                          style: TextStyle(color: Colors.red)),
                    const SizedBox(height: 12),
                    const Text('BEHAVIOR'),
                    TextFormField(
                        controller: priority,
                        decoration: const InputDecoration(
                            labelText: 'Priority',
                            helperText:
                                'Used later to determine promotion evaluation order.'),
                        keyboardType: TextInputType.number,
                        validator: (v) => int.tryParse(v ?? '') == null
                            ? 'Enter an integer'
                            : null),
                    DropdownButtonFormField<String>(
                        initialValue: stacking,
                        items: const [
                          DropdownMenuItem(
                              value: 'exclusive', child: Text('Exclusive')),
                          DropdownMenuItem(
                              value: 'stackable', child: Text('Stackable'))
                        ],
                        onChanged: (v) => setState(() => stacking = v!)),
                    SwitchListTile(
                        title: const Text('Save as draft'),
                        value: draft,
                        onChanged: (v) => setState(() {
                              draft = v;
                              if (v) active = false;
                            })),
                    SwitchListTile(
                        title: const Text('Active'),
                        value: active,
                        onChanged:
                            draft ? null : (v) => setState(() => active = v)),
                    const Text(
                        'Active promotions are applied automatically to eligible sales.'),
                  ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: saving ? null : save,
                child: const Text('Save promotion'))
          ]);
}
