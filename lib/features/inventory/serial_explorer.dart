import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/serial_lifecycle_repository.dart';

class SerialExplorer extends StatefulWidget {
  const SerialExplorer(
      {super.key,
      required this.repository,
      required this.user,
      this.initialSerialId,
      this.productId,
      this.embedded = false,
      this.onBack,
      this.onOpenRecord,
      this.canOpenRecord});
  final SerialLifecycleRepository repository;
  final ActiveUser user;
  final String? initialSerialId, productId;
  final bool embedded;
  final VoidCallback? onBack;
  final ValueChanged<SerialLifecycleEvent>? onOpenRecord;
  final bool Function(SerialLifecycleEvent)? canOpenRecord;
  @override
  State<SerialExplorer> createState() => _SerialExplorerState();
}

class _SerialExplorerState extends State<SerialExplorer> {
  String _status(String value) => value
      .replaceAll('_', ' ')
      .split(' ')
      .map((word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final search = TextEditingController();
  List<SerialSearchRow> rows = [];
  SerialLifecycle? detail;
  int page = 0;
  bool loading = false;
  String? error;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.initialSerialId != null) _open(widget.initialSerialId!);
  }

  @override
  void dispose() {
    generation++;
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = ++generation;
    setState(() { loading = true; error = null; });
    try {
      final found = await widget.repository.search(widget.user, search.text,
          productId: widget.productId, page: page);
      if (!mounted || token != generation) return;
      setState(() { rows = found; loading = false; });
    } catch (_) {
      if (!mounted || token != generation) return;
      setState(() { loading = false; error = 'Could not load serials. Try again.'; });
    }
  }

  Future<void> _open(String id) async {
    try {
      final result = await widget.repository.load(widget.user, id);
      if (!mounted || result == null) return;
      setState(() => detail = result);
      WidgetsBinding.instance.addPostFrameCallback((_) =>
          scaffoldKey.currentState?.openEndDrawer());
    } catch (_) {
      if (mounted) setState(() => error = 'Could not load serial history. Try again.');
    }
  }

  bool _openable(SerialLifecycleEvent event) => event.sourceId != null &&
      (event.source == 'serial' ||
          (widget.onOpenRecord != null &&
           (widget.canOpenRecord?.call(event) ?? true)));

  void _openEvent(SerialLifecycleEvent event) {
    if (event.source == 'serial') {
      _open(event.sourceId!);
    } else {
      widget.onOpenRecord?.call(event);
    }
  }

  String _date(BuildContext context, DateTime timestamp) {
    final local = timestamp.toLocal();
    final l10n = MaterialLocalizations.of(context);
    return '${l10n.formatMediumDate(local)}, '
        '${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  List<SerialLifecycleEvent> _related() {
    final records = <String, SerialLifecycleEvent>{};
    for (final event in detail?.events ?? <SerialLifecycleEvent>[]) {
      if (event.source == 'serial') continue;
      records.putIfAbsent('${event.source}:${event.reference}', () => event);
    }
    return records.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: scaffoldKey,
      appBar:
          widget.embedded ? null : AppBar(title: const Text('Serial Explorer')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.embedded)
            Row(children: [
              if (widget.onBack != null)
                IconButton(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back)),
              Text('Serial Explorer', style: theme.textTheme.headlineSmall),
            ]),
          const SizedBox(height: 12),
          TextField(
              controller: search,
              decoration: InputDecoration(
                  labelText: 'Search serial number',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: () {
                        page = 0;
                        _load();
                      }),
                  border: const OutlineInputBorder()),
              onSubmitted: (_) {
                page = 0;
                _load();
              }),
          const SizedBox(height: 12),
          if (loading) const LinearProgressIndicator(),
          if (error != null) Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(error!, style: TextStyle(color: theme.colorScheme.error))),
          Expanded(
              child: rows.isEmpty && !loading
                  ? const Center(
                      child: Text(
                          'No matching serial number\nCheck the serial and try again.',
                          textAlign: TextAlign.center))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        return ListTile(
                            title: Text(row.serial),
                            subtitle: Text([
                              row.product,
                              if (row.reference != null) row.reference!
                            ].join(' · ')),
                            trailing: Chip(label: Text(_status(row.status))),
                            onTap: () => _open(row.id));
                      })),
          Row(children: [
            TextButton(
                onPressed: page == 0
                    ? null
                    : () {
                        page--;
                        _load();
                      },
                child: const Text('Previous')),
            Text('Page ${page + 1}'),
            TextButton(
                onPressed: rows.length < 50
                    ? null
                    : () {
                        page++;
                        _load();
                      },
                child: const Text('Next')),
          ]),
        ]),
      ),
      endDrawer: detail == null
          ? null
          : Drawer(
              width: (MediaQuery.sizeOf(context).width * 0.7)
                  .clamp(320, 620).toDouble(),
              child: SafeArea(
                  child: ListView(padding: const EdgeInsets.all(20), children: [
                Row(children: [
                  Expanded(
                      child: Text(detail!.serial,
                          style: theme.textTheme.headlineSmall)),
                  IconButton(
                      onPressed: () => setState(() => detail = null),
                      icon: const Icon(Icons.close)),
                ]),
                Text(detail!.product, style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text('Current state', style: theme.textTheme.titleSmall),
                Wrap(spacing: 8, children: [
                  Chip(label: Text(_status(detail!.status))),
                  if (detail!.sku != null)
                    Chip(label: Text('SKU ${detail!.sku}')),
                  if (detail!.barcode != null)
                    Chip(label: Text(detail!.barcode!)),
                ]),
                if (detail!.supplier != null)
                  Text('Received from ${detail!.supplier}'),
                if (detail!.warning != null)
                  Card(
                      child: ListTile(
                          leading: const Icon(Icons.warning_amber),
                          title: Text(detail!.warning!))),
                const Divider(),
                Text('Lifecycle timeline', style: theme.textTheme.titleLarge),
                if (detail!.events.isEmpty)
                  const ListTile(title: Text('History incomplete')),
                for (final event in detail!.events)
                  ListTile(
                    leading: const Icon(Icons.circle_outlined, size: 18),
                    title: Text(_status(event.title)),
                    subtitle: Text([
                      _date(context, event.occurredAt),
                      event.reference,
                      if (event.description?.isNotEmpty == true)
                        event.description!
                    ].join(' · ')),
                    trailing: _openable(event)
                        ? const Icon(Icons.open_in_new, size: 18) : null,
                    onTap: _openable(event) ? () => _openEvent(event) : null,
                  ),
                if (_related().isNotEmpty) ...[
                  const Divider(),
                  Text('Related records', style: theme.textTheme.titleLarge),
                  for (final event in _related())
                    ListTile(dense: true,
                      title: Text(event.reference),
                      subtitle: Text(_status(event.source)),
                      trailing: _openable(event)
                          ? const Icon(Icons.open_in_new, size: 18) : null,
                      onTap: _openable(event) ? () => _openEvent(event) : null),
                ],
              ])),
            ),
    );
  }
}
