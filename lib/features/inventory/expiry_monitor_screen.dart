import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../shared/utils/money.dart';

class ExpiryMonitorScreen extends StatefulWidget {
  final InventoryHealthRepository repository;
  final ActiveUser user;
  final void Function(ExpiryBatchSummary)? onAdjust;
  const ExpiryMonitorScreen(
      {super.key, required this.repository, required this.user, this.onAdjust});
  @override
  State<ExpiryMonitorScreen> createState() => _ExpiryMonitorScreenState();
}

class _ExpiryMonitorScreenState extends State<ExpiryMonitorScreen> {
  late Future<InventoryHealthSnapshot> snapshot = widget.repository.load();
  String filter = 'Attention';
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Expiry Monitor'), actions: [
          IconButton(
              onPressed: () =>
                  setState(() => snapshot = widget.repository.load()),
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh'),
        ]),
        body: FutureBuilder<InventoryHealthSnapshot>(
            future: snapshot,
            builder: (context, result) {
              if (result.hasError) {
                return Center(child: Text('${result.error}'));
              }
              if (!result.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = result.data!;
              final rows = data.expiry
                  .where((b) => switch (filter) {
                        'Expired' => b.daysRemaining < 0,
                        'Near expiry' => b.daysRemaining >= 0 &&
                            b.daysRemaining <= data.settings.nearExpiryDays,
                        'Attention' =>
                          b.daysRemaining <= data.settings.nearExpiryDays,
                        _ => true,
                      })
                  .toList();
              return Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1280),
                      child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            const Text(
                                'Current remaining batch stock. Expiry status does not change inventory.'),
                            const SizedBox(height: 12),
                            Wrap(spacing: 8, children: [
                              for (final value in [
                                'Attention',
                                'Expired',
                                'Near expiry',
                                'All'
                              ])
                                ChoiceChip(
                                    label: Text(value),
                                    selected: filter == value,
                                    onSelected: (_) =>
                                        setState(() => filter = value))
                            ]),
                            const SizedBox(height: 12),
                            if (rows.isEmpty)
                              const Text('No batches in this view.'),
                            if (rows.isNotEmpty)
                              SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: DataTable(columns: [
                                    const DataColumn(label: Text('Product')),
                                    const DataColumn(
                                        label: Text('Batch / Lot')),
                                    const DataColumn(
                                        label: Text('Available Qty')),
                                    const DataColumn(label: Text('Expiry')),
                                    const DataColumn(
                                        label: Text('Days Remaining')),
                                    if (widget.user.can(PosPermission.reports))
                                      const DataColumn(
                                          label: Text('Cost Value')),
                                    const DataColumn(label: Text('Status')),
                                    if (widget.user
                                        .can(PosPermission.stockAdjust))
                                      const DataColumn(label: Text('Action')),
                                  ], rows: [
                                    for (final batch in rows)
                                      DataRow(cells: [
                                        DataCell(Text(batch.productName)),
                                        DataCell(Text(batch.batchNumber)),
                                        DataCell(Text(Quantity.format(
                                            batch.quantityMilli))),
                                        DataCell(Text(
                                            MaterialLocalizations.of(context)
                                                .formatMediumDate(
                                                    batch.expiryDate))),
                                        DataCell(
                                            Text('${batch.daysRemaining}')),
                                        if (widget.user
                                            .can(PosPermission.reports))
                                          DataCell(Text(
                                              formatPeso(batch.costCents))),
                                        DataCell(Text(batch.status)),
                                        if (widget.user
                                            .can(PosPermission.stockAdjust))
                                          DataCell(batch.daysRemaining < 0 &&
                                                  widget.onAdjust != null
                                              ? TextButton(
                                                  onPressed: () =>
                                                      widget.onAdjust!(batch),
                                                  child: const Text(
                                                      'Adjust expired stock'))
                                              : const SizedBox.shrink()),
                                      ])
                                  ])),
                          ])));
            }),
      );
}
