import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;

import '../../core/models/active_user.dart';
import '../../core/models/product.dart';
import '../../core/services/auth_service.dart';
import '../../data/database.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../pos_checkout/checkout_screen.dart';
import 'inventory_overview.dart';
import 'stock_receiving_screen.dart';

class InventoryWorkspace extends StatefulWidget {
  final PosRepository repository;
  final AuthService auth;
  final ActiveUser user;
  final String? initialProductId;
  final int initialView;
  final String initialFilter;
  const InventoryWorkspace(
      {super.key,
      required this.repository,
      required this.auth,
      required this.user,
      this.initialProductId,
      this.initialView = 0,
      this.initialFilter = 'All'});

  @override
  State<InventoryWorkspace> createState() => _InventoryWorkspaceState();
}

class _InventoryWorkspaceState extends State<InventoryWorkspace> {
  late int view = widget.initialView;
  String? receivingProductId;
  late String productFilter = widget.initialFilter;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      'Overview',
      if (widget.user.can(PosPermission.manageCatalog)) 'Products',
      if (widget.user.can(PosPermission.stockReceiving)) 'Receiving',
      'Movements',
    ];
    final selected = view.clamp(0, labels.length - 1);
    final label = labels[selected];
    return Column(children: [
      Center(
          child: SizedBox(
              width: MediaQuery.sizeOf(context).width.clamp(0.0, 1280.0),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<String>(
                        segments: [
                          for (final name in labels)
                            ButtonSegment(value: name, label: Text(name))
                        ],
                        selected: {label},
                        onSelectionChanged: (next) => setState(() {
                          view = labels.indexOf(next.first);
                          if (next.first == 'Products') productFilter = 'All';
                        }),
                      ),
                    ),
                  )))),
      const Divider(height: 1),
      const SizedBox(height: 8),
      Expanded(
          child: switch (label) {
        'Products' => ProductScreen(
            key: ValueKey(productFilter),
            repository: widget.repository,
            auth: widget.auth,
            initialFilter: productFilter,
            onReceiveStock: widget.user.can(PosPermission.stockReceiving)
                ? (id) => setState(() {
                      receivingProductId = id;
                      view = labels.indexOf('Receiving');
                    })
                : null),
        'Receiving' => StockReceivingScreen(
            key: ValueKey(receivingProductId ?? widget.initialProductId),
            initialProductId: receivingProductId ?? widget.initialProductId,
            repository: StockReceivingRepository(widget.repository.db),
            directory: DirectoryRepository(widget.repository.db),
            products: widget.repository,
            auth: widget.auth,
            user: widget.user),
        'Movements' => _Movements(repository: widget.repository),
        _ => InventoryOverview(
            repository: widget.repository,
            onProducts: labels.contains('Products')
                ? (filter) => setState(() {
                      productFilter = filter;
                      view = labels.indexOf('Products');
                    })
                : null,
            onReceive: labels.contains('Receiving')
                ? () => setState(() => view = labels.indexOf('Receiving'))
                : null,
            onMovements: () =>
                setState(() => view = labels.indexOf('Movements'))),
      }),
    ]);
  }
}

class _Movements extends StatefulWidget {
  final PosRepository repository;
  const _Movements({required this.repository});
  @override
  State<_Movements> createState() => _MovementsState();
}

class _MovementsState extends State<_Movements> {
  String query = '';
  String filter = 'All';
  late final Future<
      (
        List<InventoryMovement>,
        Map<String, PosProduct>,
        Map<String, String>
      )> rows = _load();

  Future<
      (
        List<InventoryMovement>,
        Map<String, PosProduct>,
        Map<String, String>
      )> _load() async {
    final movements = await (widget.repository.db
            .select(widget.repository.db.inventoryMovements)
          ..orderBy([
            (m) =>
                OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc)
          ])
          ..limit(100))
        .get();
    final products = await widget.repository.products();
    final ids = movements.map((m) => m.referenceId).whereType<String>().toSet();
    final references = <String, String>{};
    if (ids.isNotEmpty) {
      final receipts = await (widget.repository.db
              .select(widget.repository.db.stockReceivings)
            ..where((r) => r.id.isIn(ids)))
          .get();
      for (final receipt in receipts) {
        if (receipt.externalReference?.trim().isNotEmpty == true) {
          references[receipt.id] = receipt.externalReference!.trim();
        }
      }
      final sales =
          await (widget.repository.db.select(widget.repository.db.sales)
                ..where((s) => s.id.isIn(ids)))
              .get();
      for (final sale in sales) {
        if (sale.birInvoiceNumber != null) {
          references[sale.id] = 'Invoice #${sale.birInvoiceNumber}';
        }
      }
    }
    return (movements, {for (final p in products) p.id: p}, references);
  }

  String _type(String reason) => switch (reason) {
        'initial_stock' => 'Opening stock',
        'supplier_receiving' || 'batch_received' || 'receiving' => 'Receiving',
        'sale' => 'Sale',
        'refund' || 'item_refund' || 'void' => 'Return / Refund',
        'adjustment' => 'Adjustment',
        'inbound_rma' || 'rma_replacement' || 'rma_restock' => 'RMA',
        _ => 'Other',
      };

  @override
  Widget build(BuildContext context) => Material(
      color: Colors.transparent,
      child: FutureBuilder<
              (
                List<InventoryMovement>,
                Map<String, PosProduct>,
                Map<String, String>
              )>(
          future: rows,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final products = snapshot.data!.$2;
            final matches = snapshot.data!.$1
                .where((row) =>
                    (query.isEmpty ||
                        (products[row.productId]
                                ?.name
                                .toLowerCase()
                                .contains(query) ??
                            false)) &&
                    (filter == 'All' || _type(row.reason) == filter))
                .toList();
            return Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: ListView.builder(
                        padding: const EdgeInsets.all(20),
                        itemCount: matches.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Inventory movements',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall),
                                  const SizedBox(height: 20),
                                  TextField(
                                      decoration: const InputDecoration(
                                          prefixIcon: Icon(Icons.search),
                                          labelText: 'Search product'),
                                      onChanged: (value) => setState(() =>
                                          query = value.trim().toLowerCase())),
                                  const SizedBox(height: 16),
                                  Wrap(spacing: 8, runSpacing: 4, children: [
                                    for (final choice in [
                                      'All',
                                      'Receiving',
                                      'Sale',
                                      'Opening stock',
                                      'Return / Refund',
                                      'Adjustment',
                                      'RMA'
                                    ])
                                      ChoiceChip(
                                          label: Text(choice),
                                          selected: filter == choice,
                                          onSelected: (_) =>
                                              setState(() => filter = choice)),
                                  ]),
                                  const SizedBox(height: 16),
                                  if (matches.isEmpty)
                                    const Padding(
                                        padding: EdgeInsets.all(24),
                                        child:
                                            Text('No inventory movements yet')),
                                ]);
                          }
                          final row = matches[index - 1];
                          return Card(
                              child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  child: InventoryMovementRow(
                                      movement: row,
                                      product: products[row.productId],
                                      reference: row.referenceId == null
                                          ? null
                                          : snapshot
                                              .data!.$3[row.referenceId])));
                        })));
          }));
}
