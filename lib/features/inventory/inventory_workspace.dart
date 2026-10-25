import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/product.dart';
import '../../core/models/quantity.dart';
import '../../shared/utils/money.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../core/services/auth_service.dart';
import '../../data/database.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../data/daos/inventory_planning_repository.dart';
import '../../data/daos/stock_count_repository.dart';
import '../pos_checkout/checkout_screen.dart';
import 'inventory_overview.dart';
import 'stock_receiving_screen.dart';
import 'purchase_returns_screen.dart';
import '../../data/daos/purchase_return_repository.dart';
import 'purchase_orders_screen.dart';
import 'stock_counts_screen.dart';
import 'cycle_count_schedules_screen.dart';
import 'expiry_monitor_screen.dart';
import '../../data/daos/inventory_health_repository.dart';
import '../../data/daos/inventory_movement_repository.dart';
import '../../data/daos/paged_result.dart';
import 'label_print_dialog.dart';
import 'import_wizard.dart';
import '../../data/daos/import_repository.dart';

class InventoryWorkspace extends StatefulWidget {
  final PosRepository repository;
  final AuthService auth;
  final ActiveUser user;
  final String? initialProductId;
  final String? initialCatalogProductId;
  final String? initialReceiptId;
  final bool createPurchaseOrderOnOpen;
  final String? initialSupplierId;
  final int? suggestedQuantityMilli;
  final String? initialPurchaseProductId;
  final String? initialPurchaseOrderId;
  final String? initialPurchaseViewOrderId;
  final List<({String productId, int quantityMilli})>? initialPurchaseLines;
  final String? initialPurchaseSupplierId;
  final int? initialPurchaseQuantityMilli;
  final String? initialPurchaseQuotationReference;
  final String? returnToQuotationReference;
  final VoidCallback? onReturnToQuotation;
  final ValueChanged<String>? onOpenQuotation;
  final int initialView;
  final String initialFilter;
  const InventoryWorkspace(
      {super.key,
      required this.repository,
      required this.auth,
      required this.user,
      this.initialProductId,
      this.initialCatalogProductId,
      this.initialReceiptId,
      this.createPurchaseOrderOnOpen = false,
      this.initialSupplierId,
      this.suggestedQuantityMilli,
      this.initialPurchaseProductId,
      this.initialPurchaseOrderId,
      this.initialPurchaseViewOrderId,
      this.initialPurchaseLines,
      this.initialPurchaseSupplierId,
      this.initialPurchaseQuantityMilli,
      this.initialPurchaseQuotationReference,
      this.returnToQuotationReference,
      this.onReturnToQuotation,
      this.onOpenQuotation,
      this.initialView = 0,
      this.initialFilter = 'All'});

  @override
  State<InventoryWorkspace> createState() => _InventoryWorkspaceState();
}

class _InventoryWorkspaceState extends State<InventoryWorkspace> {
  // Preserve the existing programmatic Movements index after inserting Stock Counts.
  late int view = widget.initialView == 4 ? 5 : widget.initialView;
  String? receivingProductId;
  String? receivingPurchaseOrderId;
  late String? purchaseProductId = widget.initialPurchaseProductId;
  int? purchaseQuantityMilli;
  String? purchaseSupplierId;
  String? adjustmentProductId;
  String? adjustmentBatch;
  int? adjustmentQuantityMilli;
  late String productFilter = widget.initialFilter;
  bool expiryOpen = false;
  String? returnReceivingId;

  void _startPurchaseReturn(String receiptId) {
    setState(() {
      returnReceivingId = receiptId;
      view = tabs.indexOf('Purchase Returns');
    });
  }

  List<String> get tabs => [
        'Overview',
        if (widget.user.can(PosPermission.manageCatalog)) 'Products',
        if (widget.user.can(PosPermission.stockReceiving)) 'Purchase Orders',
        if (widget.user.can(PosPermission.stockReceiving)) 'Receiving',
        if (widget.user.can(PosPermission.stockReceiving)) 'Purchase Returns',
        if (widget.user.can(PosPermission.stockCount)) 'Stock Counts',
        if (widget.user.can(PosPermission.stockCount)) 'Cycle Count Scheduling',
        'Movements',
        'Tools',
      ];

  void _openReceivingDetail(String receiptId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StockReceivingScreen(
        repository: StockReceivingRepository(widget.repository.db),
        directory: DirectoryRepository(widget.repository.db),
        products: widget.repository,
        user: widget.user,
        auth: widget.auth,
        initialReceiptId: receiptId,
        onReturnToSupplier: (id) {
          Navigator.of(context).pop();
          _startPurchaseReturn(id);
        },
        onViewPurchaseOrder: _openPurchaseOrderDetail,
      ),
    ));
  }

  void _openPurchaseOrderDetail(String orderId) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PurchaseOrdersScreen(
        repository: PurchaseOrderRepository(widget.repository.db),
        directory: DirectoryRepository(widget.repository.db),
        products: widget.repository,
        user: widget.user,
        initialSelectedOrderId: orderId,
        onReceive: (id) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          setState(() {
            receivingPurchaseOrderId = id;
            view = widget.user.can(PosPermission.manageCatalog) ? 3 : 2;
          });
        },
        onOpenReceiving: _openReceivingDetail,
        onOpenQuotation: widget.onOpenQuotation == null
            ? null
            : (reference) {
                Navigator.of(context).popUntil((route) => route.isFirst);
                widget.onOpenQuotation!(reference);
              },
      ),
    ));
  }

  void _openExpiry() {
    setState(() {
      expiryOpen = true;
      view = tabs.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final labels = tabs;
    final selected = view.clamp(0, labels.length - 1);
    final label = labels[selected];
    return Material(
        color: Colors.transparent,
        child: Column(children: [
          if (widget.returnToQuotationReference != null)
            Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          const Icon(Icons.request_quote_outlined),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Text(
                                  'Inventory for ${widget.returnToQuotationReference}')),
                          FilledButton(
                              onPressed: widget.onReturnToQuotation,
                              child: const Text('Return to quotation')),
                        ])))),
          AppWorkspacePadding(
              child: AppWorkspaceTabs(
            labels: labels,
            selectedIndex: selected,
            onSelected: (index) => setState(() {
              final name = labels[index];
              view = index;
              if (name != 'Stock Counts') {
                adjustmentProductId = null;
                adjustmentBatch = null;
                adjustmentQuantityMilli = null;
              }
              if (name == 'Products') {
                productFilter = 'All';
              }
              if (name == 'Purchase Orders') {
                purchaseProductId = null;
              }
              if (name == 'Purchase Returns') {
                returnReceivingId = null;
              }
            }),
          )),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Expanded(
              child: switch (label) {
            'Products' => ProductScreen(
                key: ValueKey((productFilter, widget.initialCatalogProductId)),
                repository: widget.repository,
                auth: widget.auth,
                initialProductId: widget.initialCatalogProductId,
                onCreatePurchaseOrder: labels.contains('Purchase Orders')
                    ? (id) async {
                        final plan = (await InventoryPlanningRepository(
                                widget.repository.db)
                            .load())[id];
                        if (!mounted) return;
                        setState(() {
                          purchaseProductId = id;
                          purchaseQuantityMilli =
                              plan?.suggestedReorderMilli == 0
                                  ? null
                                  : plan?.suggestedReorderMilli;
                          purchaseSupplierId = plan?.preferredSupplierId;
                          view = labels.indexOf('Purchase Orders');
                        });
                      }
                    : null,
                initialFilter: productFilter,
                onReceiveStock: widget.user.can(PosPermission.stockReceiving)
                    ? (id) => setState(() {
                          receivingProductId = id;
                          view = labels.indexOf('Receiving');
                        })
                    : null),
            'Purchase Orders' => PurchaseOrdersScreen(
                key: ValueKey(purchaseProductId),
                initialProductId: purchaseProductId,
                initialExistingOrderId: widget.initialPurchaseOrderId,
                initialSelectedOrderId: widget.initialPurchaseViewOrderId,
                createOnOpen: widget.createPurchaseOrderOnOpen,
                initialLines: widget.initialPurchaseLines,
                initialSupplierId:
                    purchaseSupplierId ?? widget.initialPurchaseSupplierId,
                initialQuantityMilli: purchaseQuantityMilli ??
                    widget.initialPurchaseQuantityMilli,
                initialQuotationReference:
                    widget.initialPurchaseQuotationReference,
                repository: PurchaseOrderRepository(widget.repository.db),
                directory: DirectoryRepository(widget.repository.db),
                products: widget.repository,
                user: widget.user,
                onOpenReceiving: _openReceivingDetail,
                onOpenQuotation: widget.onOpenQuotation,
                onReceive: (id) => setState(() {
                      receivingPurchaseOrderId = id;
                      receivingProductId = null;
                      view = labels.indexOf('Receiving');
                    })),
            'Receiving' => StockReceivingScreen(
                key: ValueKey(receivingPurchaseOrderId ??
                    receivingProductId ??
                    widget.initialProductId),
                purchaseOrderId: receivingPurchaseOrderId,
                initialProductId: receivingProductId ?? widget.initialProductId,
                initialReceiptId: widget.initialReceiptId,
                initialSupplierId: widget.initialSupplierId,
                suggestedQuantityMilli: widget.suggestedQuantityMilli,
                repository: StockReceivingRepository(widget.repository.db),
                directory: DirectoryRepository(widget.repository.db),
                products: widget.repository,
                auth: widget.auth,
                user: widget.user,
                onViewPurchaseOrder: _openPurchaseOrderDetail,
                onReturnToSupplier: _startPurchaseReturn),
            'Purchase Returns' => PurchaseReturnsScreen(
                key: ValueKey(returnReceivingId),
                repository: PurchaseReturnRepository(widget.repository.db),
                user: widget.user,
                initialReceivingId: returnReceivingId),
            'Stock Counts' => StockCountsScreen(
                key: ValueKey('$adjustmentProductId:$adjustmentBatch'),
                repository: StockCountRepository(widget.repository.db),
                user: widget.user,
                initialAdjustmentProductId: adjustmentProductId,
                initialAdjustmentBatch: adjustmentBatch,
                initialAdjustmentQtyMilli: adjustmentQuantityMilli),
            'Cycle Count Scheduling' => CycleCountSchedulesScreen(
                db: widget.repository.db, user: widget.user),
            'Movements' => _Movements(repository: widget.repository),
            'Tools' => expiryOpen
                ? ExpiryMonitorScreen(
                    repository: InventoryHealthRepository(widget.repository.db),
                    user: widget.user,
                    embedded: true,
                    onBack: () => setState(() => expiryOpen = false),
                    onAdjust: widget.user.can(PosPermission.stockAdjust)
                        ? (batch) => setState(() {
                              adjustmentProductId = batch.productId;
                              adjustmentBatch = batch.batchNumber;
                              adjustmentQuantityMilli = batch.quantityMilli;
                              view = labels.indexOf('Stock Counts');
                            })
                        : null,
                  )
                : _InventoryTools(
                    onOpenExpiry: _openExpiry,
                    onOpenImport: widget.user
                                .can(PosPermission.manageCatalog) ||
                            widget.user.can(PosPermission.manageContacts) ||
                            widget.user.can(PosPermission.stockReceiving)
                        ? () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => ImportWizard(
                                    repository:
                                        ImportRepository(widget.repository.db),
                                    user: widget.user,
                                    onViewMovements: () {
                                      Navigator.of(context).pop();
                                      setState(() =>
                                          view = labels.indexOf('Movements'));
                                    },
                                    onViewImported: (kind) {
                                      Navigator.of(context).pop();
                                      if (kind == ImportKind.openingInventory) {
                                        setState(() =>
                                            view = labels.indexOf('Overview'));
                                      } else if (kind == ImportKind.products &&
                                          labels.contains('Products')) {
                                        setState(() =>
                                            view = labels.indexOf('Products'));
                                      }
                                    })))
                        : null,
                    onOpenLabels:
                        widget.user.can(PosPermission.manageCatalog) ||
                                widget.user.can(PosPermission.stockReceiving)
                            ? () => showLabelPrintDialog(
                                context, widget.repository.db, [],
                                products: widget.repository,
                                actorId: widget.user.id)
                            : null),
            _ => InventoryOverview(
                repository: widget.repository,
                showCosts: widget.user.can(PosPermission.reports),
                onExpiry: _openExpiry,
                onPurchaseOrders: labels.contains('Purchase Orders')
                    ? () =>
                        setState(() => view = labels.indexOf('Purchase Orders'))
                    : null,
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
        ]));
  }
}

class _InventoryTools extends StatelessWidget {
  const _InventoryTools(
      {required this.onOpenExpiry, this.onOpenLabels, this.onOpenImport});
  final VoidCallback onOpenExpiry;
  final VoidCallback? onOpenLabels;
  final VoidCallback? onOpenImport;

  @override
  Widget build(BuildContext context) => AppWorkspacePadding(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AppPageHeader(
              title: 'Tools',
              subtitle: 'Inventory utilities and maintenance tools.'),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Expiry Monitor',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text('Review expired and near-expiry batches.'),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                          onPressed: onOpenExpiry,
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open')),
                    ]),
              ),
            ),
          ),
          if (onOpenLabels != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Label Printing',
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 8),
                            const Text(
                                'Create and print product, barcode, batch, expiry, and serial labels.'),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                                onPressed: onOpenLabels,
                                icon: const Icon(Icons.print_outlined),
                                label: const Text('Open')),
                          ]))),
            ),
          if (onOpenImport != null)
            ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Card(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Import Data',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              const Text(
                                  'Import products, customers, and suppliers from CSV files.'),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                  onPressed: onOpenImport,
                                  icon: const Icon(Icons.upload_file),
                                  label: const Text('Open')),
                            ])))),
        ]),
      );
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
  int page = 0;
  Timer? searchDebounce;
  late Future<
      (
        PagedResult<InventoryMovement>,
        Map<String, PosProduct>,
        Map<String, String>
      )> rows = _load();

  @override
  void dispose() {
    searchDebounce?.cancel();
    super.dispose();
  }

  void reload() => setState(() => rows = _load());

  Future<
      (
        PagedResult<InventoryMovement>,
        Map<String, PosProduct>,
        Map<String, String>
      )> _load() async {
    final movementPage = await InventoryMovementRepository(widget.repository.db)
        .page(page: page, search: query, type: filter);
    final movements = movementPage.items;
    final products = await widget.repository
        .productsByIds(movements.map((m) => m.productId));
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
      final adjustments = await (widget.repository.db
              .select(widget.repository.db.inventoryAdjustments)
            ..where((a) => a.id.isIn(ids)))
          .get();
      for (final adjustment in adjustments) {
        references[adjustment.id] = adjustment.reference;
      }
      final returns = await (widget.repository.db
              .select(widget.repository.db.purchaseReturns)
            ..where((r) => r.id.isIn(ids)))
          .get();
      for (final row in returns) {
        references[row.id] = PurchaseReturnRepository.number(row);
      }
      final linkedLineIds = adjustments
          .map((a) => a.stockCountLineId)
          .whereType<String>()
          .toSet();
      if (linkedLineIds.isNotEmpty) {
        final lines = await (widget.repository.db
                .select(widget.repository.db.stockCountLines)
              ..where((l) => l.id.isIn(linkedLineIds)))
            .get();
        final countIds = lines.map((l) => l.stockCountId).toSet();
        final counts =
            await (widget.repository.db.select(widget.repository.db.stockCounts)
                  ..where((c) => c.id.isIn(countIds)))
                .get();
        final referenceById = {for (final c in counts) c.id: c.reference};
        final countByLine = {
          for (final l in lines) l.id: referenceById[l.stockCountId]
        };
        for (final adjustment in adjustments) {
          final linked = countByLine[adjustment.stockCountLineId];
          if (linked != null) {
            references[adjustment.id] = '${adjustment.reference} · $linked';
          }
        }
      }
    }
    return (movementPage, {for (final p in products) p.id: p}, references);
  }

  String _type(String reason) => switch (reason) {
        'initial_stock' => 'Opening stock',
        'opening_inventory_import' => 'Opening Inventory',
        'supplier_receiving' || 'batch_received' || 'receiving' => 'Receiving',
        'sale' => 'Sale',
        'purchase_return' => 'Purchase Return',
        'refund' || 'item_refund' || 'void' => 'Return / Refund',
        'adjustment' => 'Adjustment',
        'stock_adjustment_increase' ||
        'stock_adjustment_decrease' ||
        'stock_count_variance' =>
          'Adjustment',
        'inbound_rma' || 'rma_replacement' || 'rma_restock' => 'RMA',
        _ => 'Other',
      };

  Future<void> _adjustmentDetail(InventoryMovement movement) async {
    final db = widget.repository.db;
    final adjustment = (await db.select(db.inventoryAdjustments).get())
        .where((a) => a.id == movement.referenceId)
        .firstOrNull;
    if (adjustment == null || !mounted) return;
    final actor = (await db.select(db.users).get())
        .where((u) => u.id == adjustment.createdBy)
        .firstOrNull;
    final allocations =
        (await db.select(db.inventoryAdjustmentAllocations).get())
            .where((a) => a.adjustmentId == adjustment.id)
            .toList();
    final layers = {
      for (final layer in await db.select(db.inventoryLayers).get())
        layer.id: layer
    };
    final serials = {
      for (final serial in await db.select(db.serialUnits).get())
        serial.id: serial
    };
    String? countReference;
    if (adjustment.stockCountLineId != null) {
      final line = (await db.select(db.stockCountLines).get())
          .where((l) => l.id == adjustment.stockCountLineId)
          .firstOrNull;
      if (line != null) {
        countReference = (await db.select(db.stockCounts).get())
            .where((c) => c.id == line.stockCountId)
            .firstOrNull
            ?.reference;
      }
    }
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(adjustment.reference),
                content: SizedBox(
                    width: 500,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Reason: ${adjustment.reason}'),
                          Text(
                              'Change: ${Quantity.format(adjustment.deltaMilli)}'),
                          Text('By: ${actor?.name ?? adjustment.createdBy}'),
                          Text('Posted: ${adjustment.createdAt.toLocal()}'),
                          if (countReference != null)
                            Text('Stock count: $countReference'),
                          if (adjustment.notes?.isNotEmpty == true)
                            Text('Notes: ${adjustment.notes}'),
                          const SizedBox(height: 10),
                          for (var index = 0;
                              index < allocations.length;
                              index++)
                            Text('Layer ${index + 1}: '
                                '${Quantity.format(allocations[index].quantityMilli)} · Cost ${formatPeso(allocations[index].unitCostCents)}'
                                '${layers[allocations[index].inventoryLayerId]?.batchNumber == null ? '' : ' · Batch ${layers[allocations[index].inventoryLayerId]?.batchNumber}'}'
                                '${allocations[index].serialUnitId == null ? '' : ' · Serial ${serials[allocations[index].serialUnitId]?.serialNumber}'}'),
                        ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'))
                ]));
  }

  @override
  Widget build(BuildContext context) => AppWorkspacePadding(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AppPageHeader(
            title: 'Inventory movements',
            subtitle: 'Review stock changes and their source records.',
          ),
          AppSearchField(
            hintText: 'Search product, SKU, or reference',
            onChanged: (value) {
              searchDebounce?.cancel();
              searchDebounce = Timer(const Duration(milliseconds: 300), () {
                if (!mounted) return;
                setState(() {
                  query = value.trim();
                  page = 0;
                  rows = _load();
                });
              });
            },
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final choice in const [
              'All',
              'Receiving',
              'Purchase Return',
              'Sale',
              'Opening Inventory',
              'Return / Refund',
              'Adjustment',
              'RMA'
            ])
              ChoiceChip(
                label: Text(choice),
                selected: filter == choice,
                onSelected: (_) => setState(() {
                  filter = choice;
                  page = 0;
                  rows = _load();
                }),
              ),
          ]),
          const SizedBox(height: 16),
          Expanded(
              child: FutureBuilder<
                  (
                    PagedResult<InventoryMovement>,
                    Map<String, PosProduct>,
                    Map<String, String>
                  )>(
            future: rows,
            builder: (context, snapshot) {
              final result = snapshot.data;
              if (snapshot.hasError) {
                return AppPagedListPanel(
                  title: 'Movements',
                  total: 0,
                  count: 0,
                  itemBuilder: (_, __) => const SizedBox.shrink(),
                  error: 'Unable to load inventory movements.',
                  onRetry: reload,
                );
              }
              return AppPagedListPanel(
                key: const Key('movement-list-panel'),
                title: 'Movements',
                total: result?.$1.totalCount ?? 0,
                count: result?.$1.items.length ?? 0,
                page: page,
                loading: result == null,
                emptyTitle: query.isNotEmpty
                    ? 'No movements match this search'
                    : filter != 'All'
                        ? 'No movements match this filter'
                        : 'No inventory movements yet',
                onPrevious: () => setState(() {
                  page--;
                  rows = _load();
                }),
                onNext: () => setState(() {
                  page++;
                  rows = _load();
                }),
                itemBuilder: (context, index) {
                  final row = result!.$1.items[index];
                  return InkWell(
                    onTap: _type(row.reason) == 'Adjustment'
                        ? () => _adjustmentDetail(row)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: InventoryMovementRow(
                        movement: row,
                        product: result.$2[row.productId],
                        reference: result.$3[row.referenceId],
                      ),
                    ),
                  );
                },
              );
            },
          )),
        ]),
      );
}
