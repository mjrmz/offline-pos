import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/global_search_repository.dart';
import '../../shared/widgets/app_workspace.dart';

class _MoveIntent extends Intent {
  const _MoveIntent(this.delta);
  final int delta;
}
class _ChooseIntent extends Intent { const _ChooseIntent(); }
class _CloseIntent extends Intent { const _CloseIntent(); }

class GlobalCommandPalette extends StatefulWidget {
  const GlobalCommandPalette({super.key, required this.repository,
      required this.user});
  final GlobalSearchRepository repository;
  final ActiveUser user;
  @override
  State<GlobalCommandPalette> createState() => _GlobalCommandPaletteState();
}

class _GlobalCommandPaletteState extends State<GlobalCommandPalette> {
  final _input = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  int _selected = 0;
  bool _loading = false;
  late List<GlobalSearchResult> _results = widget.repository.commands(widget.user);

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _query(String value) {
    _debounce?.cancel();
    final generation = ++_generation;
    final term = value.trim();
    if (term.length < 2) {
      setState(() {
        _results = widget.repository.commands(widget.user, term);
        _selected = 0;
        _loading = false;
      });
      return;
    }
    setState(() { _results = []; _selected = 0; _loading = true; });
    _debounce = Timer(const Duration(milliseconds: 275), () async {
      final next = await widget.repository.search(widget.user, term);
      if (!mounted || generation != _generation) return;
      setState(() { _results = next; _loading = false; _selected = 0; });
    });
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() => _selected = (_selected + delta) % _results.length);
  }

  void _choose() {
    if (_results.isEmpty) return;
    Navigator.pop(context, _results[_selected]);
  }

  String _group(GlobalSearchKind kind) => switch (kind) {
    GlobalSearchKind.command => 'Commands',
    GlobalSearchKind.product => 'Products',
    GlobalSearchKind.customer => 'Customers',
    GlobalSearchKind.supplier => 'Suppliers',
    GlobalSearchKind.sale => 'Sales',
    GlobalSearchKind.serial => 'Serials',
    GlobalSearchKind.quotation => 'Quotations',
    GlobalSearchKind.salesOrder => 'Sales Orders',
    GlobalSearchKind.layaway => 'Layaway',
    GlobalSearchKind.purchaseOrder => 'Purchase Orders',
    GlobalSearchKind.receiving => 'Receiving',
    GlobalSearchKind.rma => 'RMA',
  };

  IconData _icon(GlobalSearchKind kind) => switch (kind) {
    GlobalSearchKind.command => Icons.keyboard_command_key,
    GlobalSearchKind.product => Icons.inventory_2_outlined,
    GlobalSearchKind.customer => Icons.person_outline,
    GlobalSearchKind.supplier => Icons.local_shipping_outlined,
    GlobalSearchKind.sale => Icons.receipt_long_outlined,
    GlobalSearchKind.serial => Icons.qr_code_2_outlined,
    GlobalSearchKind.quotation => Icons.request_quote_outlined,
    GlobalSearchKind.salesOrder => Icons.assignment_outlined,
    GlobalSearchKind.layaway => Icons.inventory_outlined,
    GlobalSearchKind.purchaseOrder => Icons.shopping_cart_outlined,
    GlobalSearchKind.receiving => Icons.move_to_inbox_outlined,
    GlobalSearchKind.rma => Icons.assignment_return_outlined,
  };

  String _status(String raw) => raw.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ').split(' ').map((part) => part.isEmpty
          ? '' : '${part[0].toUpperCase()}${part.substring(1)}').join(' ');

  @override
  Widget build(BuildContext context) => Shortcuts(shortcuts: const {
    SingleActivator(LogicalKeyboardKey.escape): _CloseIntent(),
    SingleActivator(LogicalKeyboardKey.keyK, control: true): _CloseIntent(),
    SingleActivator(LogicalKeyboardKey.arrowDown): _MoveIntent(1),
    SingleActivator(LogicalKeyboardKey.arrowUp): _MoveIntent(-1),
    SingleActivator(LogicalKeyboardKey.enter): _ChooseIntent(),
  }, child: Actions(actions: {
    _CloseIntent: CallbackAction<_CloseIntent>(onInvoke: (_) {
      Navigator.pop(context); return null;
    }),
    _MoveIntent: CallbackAction<_MoveIntent>(onInvoke: (intent) {
      _move(intent.delta); return null;
    }),
    _ChooseIntent: CallbackAction<_ChooseIntent>(onInvoke: (_) {
      _choose(); return null;
    }),
  }, child: Dialog(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780, maxHeight: 620),
      child: Focus(autofocus: true, child: Column(
          mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            key: const Key('global-search-input'),
            controller: _input,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search products, customers, sales, serials…',
              border: InputBorder.none,
              suffixText: 'Esc',
            ),
            onChanged: _query,
            onSubmitted: (_) => _choose(),
          )),
        if (_loading) const LinearProgressIndicator(minHeight: 2)
        else const Divider(height: 1),
        Flexible(child: _results.isEmpty
            ? Center(child: Padding(padding: const EdgeInsets.all(24),
                child: Text(_loading ? 'Searching…' : 'No matches found\n'
                    'Try a name, reference, SKU, barcode, serial number, or customer.',
                    textAlign: TextAlign.center)))
            : ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final row = _results[index];
                  final heading = index == 0 ||
                      _results[index - 1].kind != row.kind;
                  final selected = index == _selected;
                  return Column(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (heading) Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 16, 4),
                        child: Text(_group(row.kind),
                            style: Theme.of(context).textTheme.labelMedium)),
                      MouseRegion(onEnter: (_) => setState(() => _selected = index),
                        child: Material(color: selected
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Colors.transparent,
                          child: ListTile(
                            dense: true,
                            leading: Icon(_icon(row.kind)),
                            title: Text(row.title, maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(row.subtitle, maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            trailing: row.status == null ? null :
                                AppSemanticStatusBadge(label: _status(row.status!)),
                            onTap: () => Navigator.pop(context, row),
                          ))),
                    ]);
                })),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            Text('↑ ↓ Navigate  ·  Enter Open  ·  Esc Close',
                style: Theme.of(context).textTheme.labelSmall),
            const Spacer(),
            Text('Ctrl K', style: Theme.of(context).textTheme.labelSmall),
          ])),
      ]))))));
}
