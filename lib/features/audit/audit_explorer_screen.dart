import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/sales_service.dart';
import '../../data/daos/audit_explorer_repository.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/purchase_return_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/daos/sales_order_repository.dart';
import '../../data/daos/sales_repository.dart';
import '../../data/daos/stock_count_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../shared/widgets/record_details_drawer.dart';
import '../contacts/rma_screen.dart';
import '../contacts/sales_orders_screen.dart';
import '../inventory/inventory_workspace.dart';
import '../inventory/purchase_returns_screen.dart';
import '../inventory/stock_counts_screen.dart';
import '../inventory/stock_receiving_screen.dart';
import '../sales_history/sales_history_screen.dart';
import 'audit_event_presenter.dart';

class AuditExplorerScreen extends StatefulWidget {
  const AuditExplorerScreen(
      {super.key,
      required this.repository,
      required this.user,
      required this.auth,
      required this.products});
  final AuditExplorerRepository repository;
  final ActiveUser user;
  final AuthService auth;
  final PosRepository products;
  @override
  State<AuditExplorerScreen> createState() => _AuditExplorerScreenState();
}

class _AuditExplorerScreenState extends State<AuditExplorerScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  AuditExplorerPage? _data;
  Object? _error;
  bool _loading = true;
  int _revision = 0, _page = 0, _range = 1;
  DateTime? _customFrom, _customUntil;
  String? _actor, _module, _action;
  List<(String, String)> _actors = [];
  List<String> _actions = [];

  @override
  void initState() {
    super.initState();
    if (widget.user.can(PosPermission.manageUsers)) {
      _loadOptions();
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final actors = await widget.repository.actors(widget.user);
      final actions = await widget.repository.actions(widget.user);
      if (mounted) {
        setState(() {
          _actors = actors;
          _actions = actions;
        });
      }
    } catch (_) {}
  }

  DateTime _day(DateTime date) => DateTime(date.year, date.month, date.day);
  AuditExplorerFilter _filter() {
    final today = _day(DateTime.now());
    final from = switch (_range) {
      0 => today,
      1 => today.subtract(const Duration(days: 6)),
      2 => today.subtract(const Duration(days: 29)),
      _ => _customFrom,
    };
    final until = _range == 3
        ? _customUntil?.add(const Duration(days: 1))
        : today.add(const Duration(days: 1));
    return AuditExplorerFilter(
        from: from,
        until: until,
        actorId: _actor,
        module: _module,
        action: _action,
        search: _search.text,
        page: _page);
  }

  Future<void> _load() async {
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.repository.page(widget.user, _filter());
      if (mounted && revision == _revision) {
        setState(() {
          _data = data;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  void _changed() {
    _page = 0;
    _load();
  }

  void _clear() {
    setState(() {
      _range = 1;
      _customFrom = null;
      _customUntil = null;
      _actor = null;
      _module = null;
      _action = null;
      _search.clear();
    });
    _changed();
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final result = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime(now.year + 1),
        initialDateRange: DateTimeRange(
            start: _customFrom ?? now.subtract(const Duration(days: 6)),
            end: _customUntil ?? now));
    if (result == null) return;
    setState(() {
      _range = 3;
      _customFrom = _day(result.start);
      _customUntil = _day(result.end);
    });
    _changed();
  }

  void _open(AuditEventItem item) {
    showRecordDetailsDrawer<void>(
        context: context,
        builder: (drawerContext) => RecordDetailsDrawer(
            width: 760,
            title: Text(item.action),
            subtitle: Text(item.reference),
            content:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _heading('Event'),
              _detail('Action', item.action),
              _detail('Module', item.module),
              _detail('When', _when(item.row.log.createdAt)),
              _detail('Actor', item.row.actor),
              const SizedBox(height: 22),
              _heading('Affected record'),
              _detail('Reference', item.reference),
              if (item.fields
                  .where((f) => f.label != 'Selling price')
                  .isNotEmpty) ...[
                const SizedBox(height: 22),
                _heading('Details'),
                for (final field
                    in item.fields.where((f) => f.label != 'Selling price'))
                  _detail(field.label, field.value),
              ],
              if (item.fields
                  .where((f) => f.label == 'Selling price')
                  .isNotEmpty) ...[
                const SizedBox(height: 22),
                _heading('Changes'),
                for (final field
                    in item.fields.where((f) => f.label == 'Selling price'))
                  _detail(field.label, field.value),
              ],
              if (_canOpen(item)) ...[
                const SizedBox(height: 22),
                TextButton.icon(
                    onPressed: () {
                      Navigator.pop(drawerContext);
                      _openSource(item);
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open source record')),
              ],
            ])));
  }

  Widget _heading(String label) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.titleMedium));
  String _when(DateTime time, {bool dateOnly = false}) {
    final local = time.toLocal();
    final l10n = MaterialLocalizations.of(context);
    return dateOnly
        ? l10n.formatMediumDate(local)
        : '${l10n.formatMediumDate(local)} • ${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  Widget _detail(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 148,
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(child: SelectableText(value))
      ]));

  bool _canOpen(AuditEventItem item) {
    if (item.sourceId == null) return false;
    return switch (item.source) {
      'sale' => widget.user.can(PosPermission.viewAllSales),
      'product' => widget.user.can(PosPermission.manageCatalog),
      'receiving' ||
      'purchase_order' ||
      'purchase_return' =>
        widget.user.can(PosPermission.stockReceiving),
      'stock_count' => widget.user.can(PosPermission.stockCount),
      'sales_order' => widget.user.can(PosPermission.viewSalesOrders),
      'rma' => widget.user.can(PosPermission.manageRma),
      _ => false,
    };
  }

  void _openSource(AuditEventItem item) {
    final id = item.sourceId!;
    final db = widget.products.db;
    final Widget target = switch (item.source) {
      'sale' => SalesHistoryScreen(
          sales: SalesService(SalesRepository(db), widget.auth),
          user: widget.user,
          pos: widget.products,
          initialSaleId: id),
      'product' => InventoryWorkspace(
          repository: widget.products,
          auth: widget.auth,
          user: widget.user,
          initialCatalogProductId: id,
          initialView: 1),
      'receiving' => StockReceivingScreen(
          repository: StockReceivingRepository(db),
          directory: DirectoryRepository(db),
          products: widget.products,
          user: widget.user,
          auth: widget.auth,
          initialReceiptId: id),
      'purchase_order' => InventoryWorkspace(
          repository: widget.products,
          auth: widget.auth,
          user: widget.user,
          initialPurchaseViewOrderId: id,
          initialView: widget.user.can(PosPermission.manageCatalog) ? 2 : 1),
      'purchase_return' => PurchaseReturnsScreen(
          repository: PurchaseReturnRepository(db),
          user: widget.user,
          initialReturnId: id),
      'stock_count' => StockCountsScreen(
          repository: StockCountRepository(db),
          user: widget.user,
          initialCountId: id),
      'sales_order' => SalesOrdersScreen(
          repository: SalesOrderRepository(db),
          directory: DirectoryRepository(db),
          products: widget.products,
          user: widget.user,
          auth: widget.auth,
          initialReference: item.reference),
      'rma' => RmaScreen(
          repository: RmaRepository(db), user: widget.user, initialCaseId: id),
      _ => const SizedBox.shrink(),
    };
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => target));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.user.can(PosPermission.manageUsers)) {
      return const Center(
          child: Text('Audit access is not available for this account.'));
    }
    final modules = _actions.map(AuditEventPresenter.module).toSet().toList()
      ..sort();
    final items = _data?.rows
            .map((r) => AuditEventPresenter.present(r, widget.user))
            .toList() ??
        [];
    final colors = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('Audit Explorer',
                      style: Theme.of(context).textTheme.headlineSmall),
                  Text('Investigate recorded activity across the business.',
                      style: TextStyle(color: colors.onSurfaceVariant))
                ])),
            IconButton(
                tooltip: 'Refresh activity',
                onPressed: _load,
                icon: const Icon(Icons.refresh))
          ]),
          const SizedBox(height: 18),
          Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                    width: 260,
                    child: TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            labelText: 'Search activity',
                            isDense: true),
                        onChanged: (_) {
                          _debounce?.cancel();
                          _debounce = Timer(
                              const Duration(milliseconds: 300), _changed);
                        })),
                SizedBox(
                    width: 145,
                    child: DropdownButtonFormField<int>(
                        key: ValueKey(('range', _range)),
                        initialValue: _range,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Date range', isDense: true),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('Today')),
                          DropdownMenuItem(
                              value: 1, child: Text('Last 7 days')),
                          DropdownMenuItem(
                              value: 2, child: Text('Last 30 days')),
                          DropdownMenuItem(value: 3, child: Text('Custom'))
                        ],
                        onChanged: (v) {
                          if (v == 3) {
                            _pickCustom();
                          } else if (v != null) {
                            setState(() => _range = v);
                            _changed();
                          }
                        })),
                SizedBox(
                    width: 165,
                    child: DropdownButtonFormField<String>(
                        key: ValueKey(('actor', _actor)),
                        initialValue: _actor,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Actor', isDense: true),
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('All actors')),
                          for (final a in _actors)
                            DropdownMenuItem(
                                value: a.$1,
                                child:
                                    Text(a.$2, overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (v) {
                          setState(() => _actor = v == '' ? null : v);
                          _changed();
                        })),
                SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<String>(
                        key: ValueKey(('module', _module)),
                        initialValue: _module,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Module', isDense: true),
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('All modules')),
                          for (final m in modules)
                            DropdownMenuItem(
                                value: m,
                                child: Text(m, overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (v) {
                          setState(() => _module = v == '' ? null : v);
                          _changed();
                        })),
                SizedBox(
                    width: 185,
                    child: DropdownButtonFormField<String>(
                        key: ValueKey(('action', _action)),
                        initialValue: _action,
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Action', isDense: true),
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('All actions')),
                          for (final a in _actions)
                            DropdownMenuItem(
                                value: a,
                                child: Text(AuditEventPresenter.actionLabel(a),
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (v) {
                          setState(() => _action = v == '' ? null : v);
                          _changed();
                        })),
                TextButton(
                    onPressed: _clear, child: const Text('Clear filters')),
              ]),
          if (_range == 3 && _customFrom != null)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton.icon(
                    onPressed: _pickCustom,
                    icon: const Icon(Icons.date_range),
                    label: Text(
                        '${_when(_customFrom!, dateOnly: true)} – ${_when(_customUntil!, dateOnly: true)}'))),
          const SizedBox(height: 16),
          Expanded(
              child: Container(
                  decoration: BoxDecoration(
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(12)),
                  child: _error != null
                      ? Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('Could not load activity.'),
                          TextButton(
                              onPressed: _load, child: const Text('Retry'))
                        ]))
                      : _loading && _data == null
                          ? const Center(child: CircularProgressIndicator())
                          : items.isEmpty
                              ? const Center(
                                  child: Text(
                                      'No matching activity\nTry adjusting your filters or date range.',
                                      textAlign: TextAlign.center))
                              : Column(children: [
                                  Container(
                                      color: colors.surfaceContainerLow,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 12),
                                      child: const Row(children: [
                                        SizedBox(
                                            width: 155, child: Text('TIME')),
                                        SizedBox(
                                            width: 160, child: Text('ACTOR')),
                                        Expanded(
                                            flex: 2, child: Text('ACTION')),
                                        Expanded(child: Text('MODULE')),
                                        Expanded(child: Text('REFERENCE'))
                                      ])),
                                  const Divider(height: 1),
                                  Expanded(
                                      child: ListView.separated(
                                          itemCount: items.length,
                                          separatorBuilder: (_, __) =>
                                              const Divider(height: 1),
                                          itemBuilder: (context, index) {
                                            final item = items[index];
                                            return InkWell(
                                                onTap: () => _open(item),
                                                child: Padding(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 16,
                                                        vertical: 11),
                                                    child: Row(children: [
                                                      SizedBox(
                                                          width: 155,
                                                          child: Text(_when(item
                                                              .row
                                                              .log
                                                              .createdAt))),
                                                      SizedBox(
                                                          width: 160,
                                                          child: Text(
                                                              item.row.actor,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis)),
                                                      Expanded(
                                                          flex: 2,
                                                          child: Text(
                                                              item.action,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis)),
                                                      Expanded(
                                                          child: Text(
                                                              item.module,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis)),
                                                      Expanded(
                                                          child: Text(
                                                              item.reference,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis)),
                                                    ])));
                                          })),
                                ]))),
          const SizedBox(height: 10),
          Row(children: [
            Text('${_data?.total ?? 0} events'),
            const Spacer(),
            Text('Page ${_page + 1}'),
            IconButton(
                tooltip: 'Previous page',
                onPressed: _page > 0
                    ? () {
                        _page--;
                        _load();
                      }
                    : null,
                icon: const Icon(Icons.chevron_left)),
            IconButton(
                tooltip: 'Next page',
                onPressed: (_page + 1) * AuditExplorerRepository.pageSize <
                        (_data?.total ?? 0)
                    ? () {
                        _page++;
                        _load();
                      }
                    : null,
                icon: const Icon(Icons.chevron_right))
          ]),
        ]));
  }
}
