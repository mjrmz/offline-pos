import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/models/product.dart';
import '../../core/models/business_product.dart';
import '../../core/models/business_feature.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/product_barcode_alias_repository.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../data/daos/purchase_return_repository.dart';
import 'purchase_returns_screen.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../data/daos/paged_result.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/expiry_date_field.dart';
import '../../shared/widgets/record_details_drawer.dart';
import '../pos_checkout/checkout_screen.dart';
import 'documents/receiving_pdf.dart';
import '../../hardware/printer/label_printing.dart';
import 'label_print_dialog.dart';

String _pesoInput(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

int? _draftQuantity(String text, {required bool fractional}) =>
    text.trim() == '0' ? 0 : Quantity.tryParse(text, fractional: fractional);

class StockReceivingScreen extends StatefulWidget {
  final StockReceivingRepository repository;
  final DirectoryRepository directory;
  final PosRepository products;
  final ActiveUser user;
  final AuthService? auth;
  final String? initialProductId;
  final String? initialSupplierId;
  final int? suggestedQuantityMilli;
  final String? purchaseOrderId;
  final String? initialReceiptId;
  final ValueChanged<String>? onViewPurchaseOrder;
  final ValueChanged<String>? onReturnToSupplier;
  const StockReceivingScreen(
      {super.key,
      required this.repository,
      required this.directory,
      required this.products,
      required this.user,
      this.auth,
      this.initialProductId,
      this.initialSupplierId,
      this.purchaseOrderId,
      this.initialReceiptId,
      this.onViewPurchaseOrder,
      this.onReturnToSupplier,
      this.suggestedQuantityMilli});
  @override
  State<StockReceivingScreen> createState() => _StockReceivingScreenState();
}

class _StockReceivingScreenState extends State<StockReceivingScreen> {
  String view = 'landing';
  int? editingLine;
  List<Supplier> suppliers = [];
  List<Supplier> allSuppliers = [];
  List<PosProduct> products = [];
  List<PosProduct> allProducts = [];
  List<StockReceiving> history = [];
  PagedResult<StockReceiving>? historyResult;
  List<String> historyReceivers = [];
  int historyPage = 0;
  bool historyLoading = false;
  int historyGeneration = 0;
  Timer? historySearchDebounce;
  Map<String, ReceivingHistorySummary> historySummary = {};
  String historySearch = '';
  String? historySupplierId;
  String? historyActorName;
  String historyType = 'All';
  DateTimeRange? historyDates;

  bool matchesHistory(StockReceiving record) {
    final summary = historySummary[record.id];
    final text = '${StockReceivingRepository.number(record)} '
            '${summary?.supplierName ?? ''} ${summary?.poReference ?? ''} '
            '${record.externalReference ?? ''} ${summary?.productSearchText ?? ''}'
        .toLowerCase();
    if (!text.contains(historySearch) ||
        (historySupplierId != null && record.supplierId != historySupplierId) ||
        (historyActorName != null && summary?.actorName != historyActorName) ||
        (historyType == 'PO-based' && record.purchaseOrderId == null) ||
        (historyType == 'Direct' && record.purchaseOrderId != null)) {
      return false;
    }
    if (historyDates != null) {
      final date = DateUtils.dateOnly(record.receivedAt);
      if (date.isBefore(historyDates!.start) ||
          date.isAfter(historyDates!.end)) {
        return false;
      }
    }
    return true;
  }

  String? supplierId;
  String? productId;
  DateTime? expiry;
  DateTime receivedAt = DateTime.now();
  final externalReference = TextEditingController();
  final notes = TextEditingController();
  final quantity = TextEditingController();
  final cost = TextEditingController();
  final sellingPrice = TextEditingController();
  final batch = TextEditingController();
  final serialPaste = TextEditingController();
  final serialControllers = <TextEditingController>[];
  final retiredSerialControllers = <TextEditingController>[];

  void retireSerialFields() {
    retiredSerialControllers.addAll(serialControllers);
    serialControllers.clear();
  }

  final lines = <ReceivingLineRequest>[];
  String? error;
  bool busy = false;
  StockReceiving? completed;
  String? draftMessage;
  List<ReceivingLineRequest> completedLines = [];
  PurchaseOrderProgress? purchaseOrder;
  final poQuantities = <String, TextEditingController>{};
  final poCosts = <String, TextEditingController>{};
  bool addingUnplanned = false;
  bool escapeScheduled = false;

  void retirePoControllers() {
    final old = [...poQuantities.values, ...poCosts.values];
    poQuantities.clear();
    poCosts.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in old) {
        controller.dispose();
      }
    });
  }

  bool handleEscape(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        view != 'new' ||
        ModalRoute.of(context)?.isCurrent != true) {
      return false;
    }
    if (!escapeScheduled) {
      escapeScheduled = true;
      Future.microtask(() async {
        if (mounted) await leaveNewReceiving();
        escapeScheduled = false;
      });
    }
    return true;
  }

  Future<void> loadPurchaseOrder() async {
    if (widget.purchaseOrderId == null) {
      return;
    }
    try {
      final progress = await PurchaseOrderRepository(widget.repository.db)
          .detail(widget.purchaseOrderId!);
      if (mounted) {
        setState(() {
          purchaseOrder = progress;
          supplierId = progress.order.supplierId;
          retirePoControllers();
          lines.clear();
          for (final line in progress.lines) {
            final remaining = progress.remaining(line);
            if (remaining <= 0) continue;
            poQuantities[line.id] =
                TextEditingController(text: Quantity.format(remaining));
            poCosts[line.id] = TextEditingController(
                text: _pesoInput(line.expectedUnitCostCents));
            lines.add(ReceivingLineRequest(
                line.productId, remaining, line.expectedUnitCostCents,
                unitSellingPriceCents: products
                    .where((product) =>
                        product.id == line.productId &&
                        product.pricingPolicy == 'layer')
                    .firstOrNull
                    ?.priceCents,
                purchaseOrderLineId: line.id));
          }
          view = lines.isEmpty ? 'noRemaining' : 'new';
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  void updatePoLine(PurchaseOrderLine poLine) {
    final index =
        lines.indexWhere((line) => line.purchaseOrderLineId == poLine.id);
    if (index < 0) return;
    final product = products.where((p) => p.id == poLine.productId).firstOrNull;
    final qty = product == null
        ? null
        : _draftQuantity(poQuantities[poLine.id]!.text,
            fractional: product.business.fractional);
    final cents = tryParsePeso(poCosts[poLine.id]!.text);
    if (qty == null || cents == null) return;
    final previous = lines[index];
    setState(() => lines[index] = ReceivingLineRequest(
        previous.productId, qty, cents,
        purchaseOrderLineId: previous.purchaseOrderLineId,
        unitSellingPriceCents: previous.unitSellingPriceCents,
        batchNumber: previous.batchNumber,
        expiryDate: previous.expiryDate,
        serialNumbers: previous.serialNumbers));
  }

  Future<void> leaveNewReceiving() async {
    final hasDraft = supplierId != null ||
        externalReference.text.trim().isNotEmpty ||
        notes.text.trim().isNotEmpty ||
        lines.isNotEmpty;
    if (hasDraft) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Discard receiving draft?'),
          content: const Text('The delivery details and items will be lost.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Keep editing')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Discard')),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() {
      purchaseOrder = null;
      retirePoControllers();
      supplierId = null;
      productId = null;
      externalReference.clear();
      notes.clear();
      lines.clear();
      receivedAt = DateTime.now();
      view = 'landing';
    });
  }

  Future<void> chooseSupplier() async {
    final search = TextEditingController();
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
                title: const Text('Select supplier'),
                content: SizedBox(
                    width: 520,
                    height: 400,
                    child: Column(children: [
                      TextField(
                          controller: search,
                          autofocus: true,
                          decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              labelText: 'Search suppliers'),
                          onChanged: (_) => update(() {})),
                      Expanded(
                          child: ListView(children: [
                        for (final supplier in suppliers.where((s) => s.name
                            .toLowerCase()
                            .contains(search.text.toLowerCase())))
                          ListTile(
                              title: Text(supplier.name),
                              subtitle: supplier.contact == null
                                  ? null
                                  : Text(supplier.contact!),
                              onTap: () => Navigator.pop(context, supplier.id)),
                      ])),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  if (widget.user.can(PosPermission.manageContacts))
                    TextButton(
                        onPressed: () => Navigator.pop(context, '__add__'),
                        child: const Text('Quick add supplier')),
                ],
              )),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    search.dispose();
    if (!mounted) return;
    if (chosen == '__add__') {
      await quickAddSupplier();
    } else if (chosen != null && mounted) {
      setState(() => supplierId = chosen);
    }
  }

  Future<void> quickAddSupplier() async {
    final name = TextEditingController();
    final contact = TextEditingController();
    String? dialogError;
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                title: const Text('Quick add supplier'),
                content: SizedBox(
                    width: 440,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (dialogError != null)
                        Text(dialogError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      TextField(
                          controller: name,
                          autofocus: true,
                          decoration: const InputDecoration(
                              labelText: 'Supplier name *')),
                      TextField(
                          controller: contact,
                          decoration: const InputDecoration(
                              labelText: 'Contact (optional)')),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        try {
                          final supplier = await widget.directory.saveSupplier(
                              widget.user,
                              name: name.text,
                              contact: contact.text);
                          if (!mounted) return;
                          await refresh();
                          setState(() => supplierId = supplier.id);
                          if (context.mounted) Navigator.pop(context);
                        } catch (failure) {
                          update(() => dialogError = safeMessage(failure));
                        }
                      },
                      child: const Text('Create & select')),
                ],
              ),
            ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    contact.dispose();
  }

  Future<void> chooseProduct() async {
    final search = TextEditingController();
    String? aliasProductId;
    var searchRevision = 0;
    final chosen = await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Select product'),
                  content: SizedBox(
                      width: 600,
                      height: 440,
                      child: Column(children: [
                        TextField(
                            controller: search,
                            autofocus: true,
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                labelText: 'Search name, SKU, or barcode'),
                            onChanged: (value) async {
                              final revision = ++searchRevision;
                              update(() => aliasProductId = null);
                              final id = await ProductBarcodeAliasRepository(
                                  widget.products.db).productIdFor(value);
                              if (context.mounted && revision == searchRevision) {
                                update(() => aliasProductId = id);
                              }
                            }),
                        Expanded(
                            child: ListView(children: [
                          for (final product in products.where((p) {
                            final term = search.text.toLowerCase();
                            return p.id == aliasProductId ||
                                p.name.toLowerCase().contains(term) ||
                                (p.sku ?? '').toLowerCase().contains(term) ||
                                (p.barcode ?? '').toLowerCase().contains(term);
                          }))
                            ListTile(
                                title: Text(product.name),
                                subtitle: Text(
                                    '${product.sku ?? ''} · ${product.business.unit.label}${product.serialTracking ? ' · Serialized' : ''}${product.business.batch ? ' · Batch' : ''}'),
                                trailing: FutureBuilder<int>(
                                    future:
                                        widget.products.stockMilli(product.id),
                                    builder: (context, value) => Text(
                                        value.data == null
                                            ? '…'
                                            : Quantity.format(value.data!))),
                                onTap: () =>
                                    Navigator.pop(context, product.id)),
                        ])),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    if (widget.user.can(PosPermission.manageCatalog))
                      TextButton(
                          onPressed: () => Navigator.pop(context, '__add__'),
                          child: const Text('Quick add product')),
                  ],
                )));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    search.dispose();
    if (!mounted) return;
    if (chosen == '__add__') {
      if (widget.auth == null) {
        await quickAddProduct();
      } else {
        String? createdId;
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ProductScreen(
            repository: widget.products,
            auth: widget.auth!,
            createOnOpen: true,
            onCreated: (id) {
              createdId = id;
            },
          ),
        ));
        if (createdId != null && mounted) {
          await refresh();
          setState(() {
            productId = createdId;
            final product =
                products.where((p) => p.id == createdId).firstOrNull;
            if (product != null) {
              cost.text = _pesoInput(product.costCents);
              if (product.pricingPolicy == 'layer') {
                sellingPrice.text = product.priceCents > 0
                    ? _pesoInput(product.priceCents)
                    : '';
              }
            }
          });
        }
      }
    } else if (chosen != null && mounted) {
      setState(() {
        productId = chosen;
        final product = products.where((p) => p.id == chosen).firstOrNull;
        if (product != null) {
          cost.text = _pesoInput(product.costCents);
          sellingPrice.text =
              product.pricingPolicy == 'layer' && product.priceCents == 0
                  ? ''
                  : _pesoInput(product.priceCents);
        }
        expiry = null;
        batch.clear();
        quantity.clear();
      });
      syncSerialFields();
    }
  }

  Future<void> quickAddProduct() async {
    final name = TextEditingController();
    final sku = TextEditingController();
    final barcode = TextEditingController();
    final price = TextEditingController();
    final defaultCost = TextEditingController(text: '0');
    final categories = await widget.products.categories();
    final availability =
        await BusinessFeatureRepository(widget.products.db).availability();
    if (!mounted) return;
    String? categoryId;
    String pricingPolicy = 'current';
    SaleUnit unit = SaleUnit.piece;
    bool serial = false,
        batchTracking = false,
        weight = false,
        refill = false,
        tank = false,
        made = false;
    String? dialogError;
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                title: const Text('Quick add product'),
                content: SizedBox(
                    width: 680,
                    child: ListView(shrinkWrap: true, children: [
                      if (dialogError != null)
                        Text(dialogError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      Text('Basic information',
                          style: Theme.of(context).textTheme.titleMedium),
                      TextField(
                          controller: name,
                          autofocus: true,
                          decoration:
                              const InputDecoration(labelText: 'Name *')),
                      TextField(
                          controller: sku,
                          decoration: const InputDecoration(labelText: 'SKU')),
                      TextField(
                          controller: barcode,
                          decoration:
                              const InputDecoration(labelText: 'Barcode')),
                      DropdownButtonFormField<String?>(
                          initialValue: categoryId,
                          decoration:
                              const InputDecoration(labelText: 'Category'),
                          items: [
                            const DropdownMenuItem<String?>(
                                value: null, child: Text('None')),
                            ...categories.map((c) => DropdownMenuItem<String?>(
                                value: c.id, child: Text(c.name)))
                          ],
                          onChanged: (value) =>
                              update(() => categoryId = value)),
                      Text('Pricing',
                          style: Theme.of(context).textTheme.titleMedium),
                      if (pricingPolicy == 'current')
                        TextField(
                            controller: price,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Selling price *')),
                      TextField(
                          controller: defaultCost,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Reference purchase cost')),
                      DropdownButtonFormField<String>(
                          initialValue: pricingPolicy,
                          isExpanded: true,
                          decoration: const InputDecoration(
                              labelText: 'How should this product be priced?'),
                          items: [
                            const DropdownMenuItem(
                                value: 'current',
                                child: Text('Use one product price')),
                            DropdownMenuItem(
                                value: 'layer',
                                enabled: !(weight || refill || tank),
                                child: const Text(
                                    'Price each stock layer separately')),
                          ],
                          onChanged: (value) =>
                              update(() => pricingPolicy = value ?? 'current')),
                      Text('Unit / selling basis',
                          style: Theme.of(context).textTheme.titleMedium),
                      DropdownButtonFormField<SaleUnit>(
                          initialValue: unit,
                          decoration:
                              const InputDecoration(labelText: 'Sale unit'),
                          items: SaleUnit.values
                              .where((u) => weight
                                  ? (u == SaleUnit.kilogram ||
                                      u == SaleUnit.gram)
                                  : (serial || refill || tank)
                                      ? !u.fractional
                                      : true)
                              .map((u) => DropdownMenuItem(
                                  value: u, child: Text(u.label)))
                              .toList(),
                          onChanged: (value) =>
                              update(() => unit = value ?? unit)),
                      Text('Tracking',
                          style: Theme.of(context).textTheme.titleMedium),
                      SwitchListTile(
                          title: const Text('Individual serial numbers'),
                          subtitle: const Text(
                              'Whole units; receive serials with stock'),
                          value: serial,
                          onChanged: (value) => update(() {
                                serial = value;
                                if (value && unit.fractional) {
                                  unit = SaleUnit.piece;
                                }
                              })),
                      if (availability[BusinessFeature.expiryBatchTracking] ==
                          true)
                        SwitchListTile(
                            title: const Text('Batch / expiry'),
                            value: batchTracking,
                            onChanged: (value) => update(() {
                                  batchTracking = value;
                                  if (value) made = false;
                                })),
                      if (availability[BusinessFeature.weightBasedPricing] ==
                          true)
                        SwitchListTile(
                            title: const Text('Sold by weight'),
                            value: weight,
                            onChanged: (value) => update(() {
                                  weight = value;
                                  if (value) {
                                    unit = SaleUnit.kilogram;
                                    pricingPolicy = 'current';
                                    serial = false;
                                    refill = false;
                                    tank = false;
                                  }
                                })),
                      ExpansionTile(
                          title: const Text('More options'),
                          children: [
                            if (availability[
                                    BusinessFeature.containerRefillPricing] ==
                                true)
                              SwitchListTile(
                                  title: const Text('Water refill / container'),
                                  value: refill,
                                  onChanged: (value) => update(() {
                                        refill = value;
                                        if (value) {
                                          unit = SaleUnit.bottle;
                                          pricingPolicy = 'current';
                                          weight = false;
                                          tank = false;
                                          made = false;
                                        }
                                      })),
                            if (availability[
                                    BusinessFeature.tankDepositExchange] ==
                                true)
                              SwitchListTile(
                                  title:
                                      const Text('LPG tank exchange / deposit'),
                                  value: tank,
                                  onChanged: (value) => update(() {
                                        tank = value;
                                        if (value) {
                                          unit = SaleUnit.piece;
                                          pricingPolicy = 'current';
                                          weight = false;
                                          refill = false;
                                          made = false;
                                        }
                                      })),
                            if (availability[
                                    BusinessFeature.madeToOrderTracking] ==
                                true)
                              SwitchListTile(
                                  title: const Text('Made to order'),
                                  value: made,
                                  onChanged: (value) => update(() {
                                        made = value;
                                        if (value) {
                                          batchTracking = false;
                                          refill = false;
                                          tank = false;
                                        }
                                      })),
                          ]),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () async {
                        try {
                          if (name.text.trim().isEmpty) {
                            throw ArgumentError('Name is required.');
                          }
                          final priceCents = pricingPolicy == 'layer'
                              ? 0
                              : tryParsePeso(price.text);
                          final costCents = tryParsePeso(defaultCost.text);
                          if (priceCents == null || priceCents < 0) {
                            throw ArgumentError('Selling price is invalid.');
                          }
                          if (costCents == null || costCents < 0) {
                            throw ArgumentError('Default cost is invalid.');
                          }
                          if (made) {
                            throw StateError(
                                'Made-to-order products have no finished stock to receive. Create this product from Products.');
                          }
                          final id = await widget.products.saveProduct(
                              name: name.text,
                              sku: sku.text,
                              barcode: barcode.text,
                              categoryId: categoryId,
                              priceCents: priceCents,
                              costCents: costCents,
                              pricingPolicy: pricingPolicy,
                              startingStockMilli: 0,
                              serialTracking: serial,
                              actorId: widget.user.id,
                              business: BusinessProduct(
                                  unit: unit,
                                  weight: weight,
                                  batch: batchTracking,
                                  refill: refill,
                                  tank: tank,
                                  madeToOrder: made));
                          if (!mounted) return;
                          await refresh();
                          setState(() {
                            productId = id;
                            cost.text = _pesoInput(costCents);
                            sellingPrice.text = pricingPolicy == 'layer'
                                ? ''
                                : _pesoInput(priceCents);
                          });
                          if (context.mounted) Navigator.pop(context);
                        } catch (failure) {
                          update(() => dialogError = safeMessage(failure));
                        }
                      },
                      child: const Text('Create & select')),
                ],
              ),
            ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    sku.dispose();
    barcode.dispose();
    price.dispose();
    defaultCost.dispose();
  }

  Future<void> correctSerial(SerialUnit serial) async {
    final number = TextEditingController(text: serial.serialNumber);
    try {
      final confirmed = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Correct unsold serial'),
                content: TextField(
                    controller: number,
                    decoration:
                        const InputDecoration(labelText: 'Serial number')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, number.text),
                      child: const Text('Save correction')),
                ],
              ));
      if (confirmed == null) return;
      await widget.repository
          .correctUnsoldSerial(widget.user, serial.id, confirmed);
      if (mounted) setState(() {});
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      number.dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(handleEscape);
    productId = widget.initialProductId;
    supplierId = widget.initialSupplierId;
    if (productId != null) view = 'new';
    if (widget.purchaseOrderId == null) {
      refresh().then((_) async {
        if (!mounted || widget.initialReceiptId == null) return;
        final receipt = await (widget.repository.db
                .select(widget.repository.db.stockReceivings)
              ..where((r) => r.id.equals(widget.initialReceiptId!)))
            .getSingleOrNull();
        if (receipt != null) {
          setState(() => view = 'history');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) openReceivingDetail(receipt);
          });
        }
      });
    } else {
      refresh().then((_) => loadPurchaseOrder());
    }
  }

  @override
  void dispose() {
    historySearchDebounce?.cancel();
    HardwareKeyboard.instance.removeHandler(handleEscape);
    for (final controller in [...poQuantities.values, ...poCosts.values]) {
      controller.dispose();
    }
    externalReference.dispose();
    notes.dispose();
    quantity.dispose();
    cost.dispose();
    sellingPrice.dispose();
    batch.dispose();
    serialPaste.dispose();
    for (final controller in serialControllers) {
      controller.dispose();
    }
    for (final controller in retiredSerialControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final supplierRows = await widget.directory.suppliers();
      final productRows = await widget.products.products();
      final initial = productRows.where((p) => p.id == productId).firstOrNull;
      if (initial != null && cost.text.isEmpty) {
        cost.text = _pesoInput(initial.costCents);
        sellingPrice.text = _pesoInput(initial.priceCents);
      }
      final recent = await widget.repository.historyPage();
      final summaries = await widget.repository
          .historySummaries(receivingIds: recent.items.map((r) => r.id));
      final receivers = await widget.repository.receiverNames();
      if (mounted) {
        setState(() {
          suppliers = supplierRows.where((s) => s.isActive).toList();
          allSuppliers = supplierRows;
          products = productRows
              .where((p) => p.isActive && !p.business.madeToOrder)
              .toList();
          allProducts = productRows;
          history = recent.items.take(5).toList();
          historySummary = summaries;
          historyReceivers = receivers;
        });
      }
      await loadHistory();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> loadHistory() async {
    final generation = ++historyGeneration;
    if (mounted) setState(() => historyLoading = true);
    try {
      final result = await widget.repository.historyPage(
        page: historyPage,
        search: historySearch,
        supplierId: historySupplierId,
        actorName: historyActorName,
        type: historyType,
        from: historyDates?.start,
        through: historyDates?.end,
      );
      final summaries = await widget.repository
          .historySummaries(receivingIds: result.items.map((r) => r.id));
      if (mounted && generation == historyGeneration) {
        setState(() {
          historyResult = result;
          historySummary.addAll(summaries);
          historyLoading = false;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted && generation == historyGeneration) {
        setState(() {
          historyLoading = false;
          error = safeMessage(failure);
        });
      }
    }
  }

  void changeHistoryFilter(VoidCallback update) {
    setState(() {
      update();
      historyPage = 0;
    });
    loadHistory();
  }

  Future<void> addLine() async {
    final product = products.where((p) => p.id == productId).firstOrNull;
    final milli = product == null
        ? null
        : Quantity.tryParse(quantity.text,
            fractional: product.business.fractional);
    final cents = tryParsePeso(cost.text);
    final layerPrice = product?.pricingPolicy == 'layer'
        ? tryParsePeso(sellingPrice.text)
        : null;
    if (product == null) {
      setState(() => error = 'Select a product.');
      return;
    }
    if (milli == null || milli <= 0) {
      setState(() => error = 'Quantity must be greater than zero.');
      return;
    }
    final poLineId = editingLine != null
        ? lines[editingLine!].purchaseOrderLineId
        : addingUnplanned
            ? null
            : purchaseOrder?.lines
                .where((line) => line.productId == product.id)
                .firstOrNull
                ?.id;
    if (poLineId != null) {
      final poLine =
          purchaseOrder!.lines.firstWhere((line) => line.id == poLineId);
      if (milli > purchaseOrder!.remaining(poLine)) {
        setState(() => error =
            'Receive quantity cannot exceed the remaining Purchase Order quantity.');
        return;
      }
    }
    if (cents == null || cents < 0) {
      setState(() => error = 'Enter a valid unit cost.');
      return;
    }
    if (product.pricingPolicy == 'layer' &&
        (layerPrice == null || layerPrice < 0)) {
      setState(() => error = 'Enter a valid selling price for this stock.');
      return;
    }
    if (product.business.batch && batch.text.trim().isEmpty) {
      setState(() => error = 'Batch number is required.');
      return;
    }
    if (expiry != null &&
        expiry!.isBefore(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day))) {
      setState(() => error = 'Cannot receive an expired batch.');
      return;
    }
    final serials = product.serialTracking
        ? serialControllers.map((c) => c.text.trim()).toList()
        : <String>[];
    if (product.serialTracking) {
      final missing =
          milli ~/ Quantity.scale - serials.where((s) => s.isNotEmpty).length;
      if (missing > 0) {
        setState(() => error =
            'Enter $missing more serial number${missing == 1 ? '' : 's'}.');
        return;
      }
      if (serials.length != milli ~/ Quantity.scale ||
          serials.toSet().length != serials.length) {
        setState(() => error = 'Enter one unique serial per unit.');
        return;
      }
      for (final serial in serials) {
        if (lines.asMap().entries.any((entry) =>
                entry.key != editingLine &&
                entry.value.serialNumbers.contains(serial)) ||
            await widget.repository.serialNumberExists(serial)) {
          if (mounted) setState(() => error = 'Serial $serial already exists.');
          return;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      final request = ReceivingLineRequest(product.id, milli, cents,
          purchaseOrderLineId: poLineId,
          unitSellingPriceCents: layerPrice,
          batchNumber: product.business.batch ? batch.text : null,
          expiryDate: product.business.batch ? expiry : null,
          serialNumbers: serials);
      if (editingLine == null) {
        lines.add(request);
        draftMessage =
            'Added to this delivery. Inventory will update when the receiving is finalized.';
      } else {
        lines[editingLine!] = request;
        if (poLineId != null) {
          poQuantities[poLineId]?.text = Quantity.format(milli);
          poCosts[poLineId]?.text = _pesoInput(cents);
        }
        draftMessage =
            'Delivery item updated. Inventory has not been updated yet.';
      }
      editingLine = null;
      quantity.clear();
      cost.clear();
      sellingPrice.clear();
      batch.clear();
      expiry = null;
      serialPaste.clear();
      retireSerialFields();
      error = null;
    });
  }

  void editLine(int index) {
    final line = lines[index];
    setState(() {
      addingUnplanned = line.purchaseOrderLineId == null;
      editingLine = index;
      productId = line.productId;
      quantity.text = Quantity.format(line.quantityMilli);
      cost.text = (line.unitCostCents / 100).toStringAsFixed(2);
      sellingPrice.text = line.unitSellingPriceCents == null
          ? ''
          : _pesoInput(line.unitSellingPriceCents!);
      batch.text = line.batchNumber ?? '';
      expiry = line.expiryDate;
      retireSerialFields();
      serialControllers.addAll(
          line.serialNumbers.map((s) => TextEditingController(text: s)));
      error = null;
    });
    syncSerialFields();
    openItemEditor();
  }

  int get totalCostCents => lines.fold(
      0,
      (sum, line) =>
          sum + (line.quantityMilli * line.unitCostCents ~/ Quantity.scale));

  List<ReceivingLineRequest>? validatedDelivery() {
    for (final poLine in purchaseOrder?.lines ?? <PurchaseOrderLine>[]) {
      if (!poQuantities.containsKey(poLine.id)) continue;
      final product =
          products.where((p) => p.id == poLine.productId).firstOrNull;
      final qty = product == null
          ? null
          : _draftQuantity(poQuantities[poLine.id]!.text,
              fractional: product.business.fractional);
      final cents = tryParsePeso(poCosts[poLine.id]!.text);
      if (qty == null || qty < 0) {
        setState(() => error = 'Enter a valid receive quantity.');
        return null;
      }
      if (qty > purchaseOrder!.remaining(poLine)) {
        setState(() => error =
            'Receive quantity cannot exceed the remaining Purchase Order quantity.');
        return null;
      }
      if (qty > 0 && (cents == null || cents < 0)) {
        setState(() => error = 'Enter a valid actual unit cost.');
        return null;
      }
      if (qty > 0 && product!.serialTracking) {
        final draft =
            lines.firstWhere((line) => line.purchaseOrderLineId == poLine.id);
        if (draft.serialNumbers.length != qty ~/ Quantity.scale) {
          setState(() => error =
              'Enter one serial number per received unit for ${product.name}.');
          return null;
        }
      }
      if (qty > 0) {
        final draft =
            lines.firstWhere((line) => line.purchaseOrderLineId == poLine.id);
        if (product!.business.batch &&
            (draft.batchNumber?.trim().isEmpty ?? true)) {
          setState(() => error = 'Enter batch details for ${product.name}.');
          return null;
        }
        if (product.pricingPolicy == 'layer' &&
            draft.unitSellingPriceCents == null) {
          setState(() => error = 'Enter a selling price for ${product.name}.');
          return null;
        }
      }
    }
    final result = <ReceivingLineRequest>[];
    for (final line in lines) {
      if (line.purchaseOrderLineId == null) {
        result.add(line);
        continue;
      }
      final id = line.purchaseOrderLineId!;
      final poLine =
          purchaseOrder!.lines.firstWhere((poLine) => poLine.id == id);
      final product =
          products.firstWhere((product) => product.id == poLine.productId);
      final qty = _draftQuantity(poQuantities[id]!.text,
          fractional: product.business.fractional)!;
      if (qty == 0) continue;
      result.add(ReceivingLineRequest(
          line.productId, qty, tryParsePeso(poCosts[id]!.text)!,
          purchaseOrderLineId: id,
          unitSellingPriceCents: line.unitSellingPriceCents,
          batchNumber: line.batchNumber,
          expiryDate: line.expiryDate,
          serialNumbers: line.serialNumbers));
    }
    if (result.isEmpty) {
      setState(() => error = 'Enter a receive quantity for at least one item.');
      return null;
    }
    setState(() => error = null);
    return result;
  }

  Future<void> confirmFinalize() async {
    final delivery = validatedDelivery();
    if (delivery == null) return;
    if (supplierId == null) {
      setState(() => error =
          supplierId == null ? 'Select a supplier.' : 'Add at least one item.');
      return;
    }
    final duplicates = await widget.repository
        .duplicateReference(supplierId!, externalReference.text);
    if (!mounted) return;
    if (duplicates.isNotEmpty &&
        !widget.user.can(PosPermission.approveDuplicateReceiving)) {
      setState(() => error =
          'This supplier reference was used before. Ask a manager or owner to finalize.');
      return;
    }
    final prior = purchaseOrder?.receivedTotal ?? 0;
    final arriving = delivery.fold<int>(
        0,
        (sum, line) =>
            sum + (line.purchaseOrderLineId == null ? 0 : line.quantityMilli));
    final remainingAfter = (purchaseOrder?.remainingTotal ?? 0) - arriving;
    final expectedCostByLine = {
      for (final line in purchaseOrder?.lines ?? <PurchaseOrderLine>[])
        line.id: line.expectedUnitCostCents
    };
    final expectedReceivedValue = delivery.fold<int>(
        0,
        (sum, line) =>
            sum +
            (line.purchaseOrderLineId == null
                ? 0
                : Quantity.lineCents(
                    expectedCostByLine[line.purchaseOrderLineId] ?? 0,
                    line.quantityMilli)));
    final actualLinkedValue = delivery.fold<int>(
        0,
        (sum, line) =>
            sum +
            (line.purchaseOrderLineId == null
                ? 0
                : Quantity.lineCents(line.unitCostCents, line.quantityMilli)));
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Finalize this receiving?'),
              content: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        'Supplier: ${suppliers.where((s) => s.id == supplierId).firstOrNull?.name ?? '—'}'),
                    Text(
                        'Supplier invoice / reference: ${externalReference.text.trim().isEmpty ? 'Not set' : externalReference.text.trim()}'),
                    Text(
                        'Received: ${MaterialLocalizations.of(context).formatMediumDate(receivedAt)}'),
                    if (purchaseOrder != null) ...[
                      Text(
                          'PO: ${PurchaseOrderRepository.number(purchaseOrder!.order)}'),
                      Text(
                          '${Quantity.format(purchaseOrder!.ordered)} ordered · ${Quantity.format(prior)} previously received'),
                      Text(
                          '${Quantity.format(arriving)} this delivery · ${Quantity.format(remainingAfter)} remaining afterward'),
                    ],
                    if (duplicates.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                          'This supplier already has a receiving using this reference:'),
                      for (final receipt in duplicates)
                        Text(
                            '${StockReceivingRepository.number(receipt)} · ${MaterialLocalizations.of(context).formatMediumDate(receipt.receivedAt)}'),
                      const Text('Confirm to use the reference again.'),
                    ],
                    Text('${delivery.length} product lines'),
                    Text(
                        'Receiving cost: ${formatPeso(delivery.fold<int>(0, (sum, line) => sum + line.quantityMilli * line.unitCostCents ~/ Quantity.scale))}'),
                    if (purchaseOrder != null)
                      Text(
                          'Expected cost of PO lines received: ${formatPeso(expectedReceivedValue)} · Actual: ${formatPeso(actualLinkedValue)} · Variance: ${formatPeso(actualLinkedValue - expectedReceivedValue)}'),
                    const SizedBox(height: 12),
                    const Text(
                        'Finalizing this receiving will add these quantities to inventory.'),
                    if (purchaseOrder != null)
                      Text(remainingAfter == 0
                          ? 'This delivery will fully receive the Purchase Order.'
                          : 'The Purchase Order will remain partially received with ${Quantity.format(remainingAfter)} units remaining.'),
                    for (final line in delivery)
                      Text(
                          '${allProducts.where((p) => p.id == line.productId).firstOrNull?.name ?? 'Product'} · ${Quantity.format(line.quantityMilli)} · ${line.serialNumbers.isEmpty ? (line.batchNumber ?? '') : '${line.serialNumbers.length} serials'}'),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Back')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Finalize Receiving')),
              ],
            ));
    if (confirmed == true) {
      await finalize(delivery, allowDuplicateReference: duplicates.isNotEmpty);
    }
  }

  void syncSerialFields() {
    final product = products.where((p) => p.id == productId).firstOrNull;
    final milli = product == null
        ? null
        : Quantity.tryParse(quantity.text, fractional: false);
    final target = product?.serialTracking == true && milli != null
        ? milli ~/ Quantity.scale
        : 0;
    setState(() {
      while (serialControllers.length < target) {
        serialControllers.add(TextEditingController());
      }
      while (serialControllers.length > target) {
        retiredSerialControllers.add(serialControllers.removeLast());
      }
    });
  }

  void distributeSerialPaste() {
    final parts = serialPaste.text
        .split(RegExp(r'[\r\n,]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    setState(() {
      for (var i = 0; i < parts.length && i < serialControllers.length; i++) {
        serialControllers[i].text = parts[i];
      }
      error = parts.length == serialControllers.length
          ? null
          : 'Pasted ${parts.length} serials; ${serialControllers.length} required';
    });
  }

  Future<void> finalize(List<ReceivingLineRequest> delivery,
      {bool allowDuplicateReference = false}) async {
    if (busy || supplierId == null || delivery.isEmpty) {
      setState(() => error = 'Choose a supplier and add at least one item');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final record = await widget.repository.receive(
          widget.user, supplierId!, delivery,
          externalReference: externalReference.text,
          allowDuplicateReference: allowDuplicateReference,
          notes: notes.text,
          receivedAt: receivedAt,
          purchaseOrderId: purchaseOrder?.order.id);
      if (mounted) {
        setState(() {
          completedLines = List.of(delivery);
          lines.clear();
          draftMessage = null;
          externalReference.clear();
          notes.clear();
          receivedAt = DateTime.now();
          completed = record;
          view = 'landing';
        });
      }
      await refresh();
      if (purchaseOrder != null) await loadPurchaseOrder();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openItemEditor() async {
    if (editingLine == null) {
      setState(() {
        if (purchaseOrder == null) quantity.clear();
        final selected = products.where((p) => p.id == productId).firstOrNull;
        if (purchaseOrder == null) {
          cost.text = selected == null ? '' : _pesoInput(selected.costCents);
        }
        sellingPrice.text =
            selected == null ? '' : _pesoInput(selected.priceCents);
        batch.clear();
        expiry = null;
        serialPaste.clear();
        retireSerialFields();
        error = null;
      });
    }
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close item editor',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (drawerContext, _, __) => StatefulBuilder(
        builder: (drawerContext, update) {
          final selected = products.where((p) => p.id == productId).firstOrNull;
          return Align(
            alignment: Alignment.centerRight,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: SizedBox(
                width: MediaQuery.sizeOf(context).width < 600
                    ? MediaQuery.sizeOf(context).width
                    : 520,
                height: double.infinity,
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(children: [
                      Expanded(
                          child: Text(
                              editingLine == null
                                  ? purchaseOrder == null
                                      ? 'Add item'
                                      : 'Add unplanned item'
                                  : 'Edit delivery item',
                              style:
                                  Theme.of(context).textTheme.headlineSmall)),
                      IconButton(
                        tooltip: 'Close item editor',
                        onPressed: () => Navigator.pop(drawerContext),
                        icon: const Icon(Icons.close),
                      ),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                      child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                        if (error != null)
                          Text(error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        Text('PRODUCT',
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: editingLine != null &&
                                  lines[editingLine!].purchaseOrderLineId !=
                                      null
                              ? null
                              : () async {
                                  await chooseProduct();
                                  update(() {});
                                },
                          icon: const Icon(Icons.search),
                          label:
                              Text(selected?.name ?? 'Search/select product'),
                        ),
                        const SizedBox(height: 20),
                        Text('QUANTITY',
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 8),
                        TextField(
                          controller: quantity,
                          onChanged: (_) {
                            syncSerialFields();
                            update(() {});
                          },
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText:
                                  'Quantity (${selected?.business.unit.label ?? 'units'})',
                              hintText: widget.suggestedQuantityMilli == null
                                  ? null
                                  : 'Suggested ${Quantity.format(widget.suggestedQuantityMilli!)} — enter actual received quantity'),
                        ),
                        const SizedBox(height: 20),
                        Text('STOCK PRICING',
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 8),
                        LayoutBuilder(builder: (context, box) {
                          final width = box.maxWidth >= 420
                              ? (box.maxWidth - 12) / 2
                              : box.maxWidth;
                          return Wrap(spacing: 12, runSpacing: 8, children: [
                            SizedBox(
                                width: width,
                                child: TextField(
                                    controller: cost,
                                    onChanged: (_) => update(() {}),
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: InputDecoration(
                                        prefixText: '₱ ',
                                        labelText:
                                            'Cost / ${selected?.business.unit.label ?? 'unit'} *'))),
                            if (selected != null)
                              SizedBox(
                                  width: width,
                                  child: selected.pricingPolicy == 'layer'
                                      ? TextField(
                                          controller: sellingPrice,
                                          keyboardType: const TextInputType
                                              .numberWithOptions(decimal: true),
                                          decoration: InputDecoration(
                                              prefixText: '₱ ',
                                              labelText:
                                                  'Selling price / ${selected.business.unit.label} *'))
                                      : InputDecorator(
                                          decoration: InputDecoration(
                                              labelText:
                                                  'Product selling price / ${selected.business.unit.label}'),
                                          child: Text(formatPeso(
                                              selected.priceCents)))),
                          ]);
                        }),
                        if (selected?.business.batch == true ||
                            selected?.serialTracking == true) ...[
                          const SizedBox(height: 20),
                          Text('TRACKING',
                              style: Theme.of(context).textTheme.labelLarge),
                        ],
                        if (selected?.business.batch == true) ...[
                          TextField(
                              controller: batch,
                              decoration: const InputDecoration(
                                  labelText: 'Batch number')),
                          ExpiryDateField(
                              value: expiry,
                              onChanged: (date) {
                                setState(() => expiry = date);
                                update(() {});
                              }),
                        ],
                        if (selected?.serialTracking == true) ...[
                          const SizedBox(height: 16),
                          Text(
                              '${serialControllers.where((c) => c.text.trim().isNotEmpty).length} / ${serialControllers.length} serials entered'),
                          TextField(
                              controller: serialPaste,
                              maxLines: 2,
                              decoration: const InputDecoration(
                                  labelText:
                                      'Paste serials (one per line or comma separated)')),
                          TextButton(
                              onPressed: () {
                                distributeSerialPaste();
                                update(() {});
                              },
                              child: const Text('Fill serial fields')),
                          for (var i = 0; i < serialControllers.length; i++)
                            TextField(
                                controller: serialControllers[i],
                                decoration: InputDecoration(
                                    labelText: 'Serial ${i + 1}')),
                        ],
                        const SizedBox(height: 24),
                        Text('LINE SUMMARY',
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 8),
                        Text(
                            'Quantity: ${quantity.text.isEmpty ? '—' : quantity.text} ${selected?.business.unit.label ?? 'units'}'),
                        Text(
                            'Line receiving value: ${formatPeso((Quantity.tryParse(quantity.text, fractional: selected?.business.fractional ?? false) ?? 0) * (tryParsePeso(cost.text) ?? 0) ~/ Quantity.scale)}'),
                      ])),
                  const Divider(height: 1),
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                                'This adds the item to the receiving draft. Stock changes only after finalization.'),
                            const SizedBox(height: 8),
                            Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(drawerContext),
                                      child: const Text('Cancel')),
                                  const SizedBox(width: 8),
                                  FilledButton(
                                      onPressed: () async {
                                        await addLine();
                                        if (error == null &&
                                            drawerContext.mounted) {
                                          Navigator.pop(drawerContext);
                                        } else {
                                          update(() {});
                                        }
                                      },
                                      child: Text(editingLine == null
                                          ? 'Add to delivery'
                                          : 'Save delivery item')),
                                ])
                          ])),
                ]),
              ),
            ),
          );
        },
      ),
      transitionBuilder: (context, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
    if (mounted) setState(() => editingLine = null);
  }

  Widget _step(BuildContext context, int number, String title) =>
      Row(children: [
        CircleAvatar(radius: 14, child: Text('$number')),
        const SizedBox(width: 12),
        Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
      ]);

  Widget _reviewLine(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          SizedBox(width: 160, child: Text(label)),
          Expanded(
              child: Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );

  String _trackingSummary(ReceivingLineRequest line) {
    if (line.serialNumbers.isNotEmpty) {
      return '${line.serialNumbers.length} serials entered';
    }
    if (line.batchNumber != null) {
      final expiryText = line.expiryDate == null
          ? ''
          : ' · Exp ${line.expiryDate!.month}/${line.expiryDate!.year}';
      return '${line.batchNumber}$expiryText';
    }
    return '—';
  }

  Widget _draftItem(BuildContext context, int index, bool wide) {
    final line = lines[index];
    final product = products.where((p) => p.id == line.productId).firstOrNull;
    final amount =
        formatPeso(line.quantityMilli * line.unitCostCents ~/ Quantity.scale);
    final actions = Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
          tooltip: 'Edit item',
          icon: const Icon(Icons.edit_outlined),
          onPressed: busy ? null : () => editLine(index)),
      IconButton(
          tooltip: 'Remove item',
          icon: const Icon(Icons.close),
          onPressed: busy ? null : () => setState(() => lines.removeAt(index))),
    ]);
    if (!wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(product?.name ?? 'Product',
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            Text(amount)
          ]),
          Text(
              '${Quantity.format(line.quantityMilli)} ${product?.business.unit.label ?? ''} · ${formatPeso(line.unitCostCents)} purchase / unit'),
          Text(
              'Selling: ${product?.pricingPolicy == 'layer' ? (line.unitSellingPriceCents == null ? 'Required' : formatPeso(line.unitSellingPriceCents!)) : (product == null ? '—' : '${formatPeso(product.priceCents)} (Product price)')}'),
          if (_trackingSummary(line) != '—') Text(_trackingSummary(line)),
          Align(alignment: Alignment.centerRight, child: actions),
          const Divider(height: 1),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
            flex: 3,
            child: Text(product?.name ?? 'Product',
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        SizedBox(
            width: 105,
            child: Text(
                '${Quantity.format(line.quantityMilli)} ${product?.business.unit.label ?? ''}')),
        SizedBox(width: 130, child: Text(formatPeso(line.unitCostCents))),
        SizedBox(
            width: 130,
            child: Text(product?.pricingPolicy == 'layer'
                ? (line.unitSellingPriceCents == null
                    ? 'Required'
                    : formatPeso(line.unitSellingPriceCents!))
                : (product == null
                    ? '—'
                    : '${formatPeso(product.priceCents)} (Product)'))),
        Expanded(
            flex: 2,
            child: Text(_trackingSummary(line),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        SizedBox(width: 120, child: Text(amount)),
        actions,
      ]),
    );
  }

  Widget _buildReceivingDocument(BuildContext context) {
    final supplier = suppliers.where((s) => s.id == supplierId).firstOrNull;
    final localizations = MaterialLocalizations.of(context);
    final sameUnit = lines.isNotEmpty &&
        lines
                .map((line) => products
                    .where((p) => p.id == line.productId)
                    .firstOrNull
                    ?.business
                    .unit
                    .label)
                .toSet()
                .length ==
            1;
    final totalUnit = sameUnit
        ? products
                .where((p) => p.id == lines.first.productId)
                .firstOrNull
                ?.business
                .unit
                .label ??
            ''
        : 'mixed';
    final missing = supplierId == null
        ? 'Select a supplier to continue.'
        : lines.isEmpty
            ? 'Add at least one item to continue.'
            : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      IconButton(
          tooltip: 'Back to receiving',
          icon: const Icon(Icons.arrow_back),
          onPressed: leaveNewReceiving),
      Card(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('New Receiving',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 6),
          const Text(
              'Record a supplier delivery. Stock is updated only after finalization.'),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 28),
          _step(context, 1, 'Delivery details'),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth >= 680;
            final fieldWidth =
                wide ? (constraints.maxWidth - 16) / 2 : constraints.maxWidth;
            return Wrap(spacing: 16, runSpacing: 16, children: [
              SizedBox(
                  width: fieldWidth,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Supplier *'),
                        const SizedBox(height: 8),
                        SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: chooseSupplier,
                              icon: const Icon(Icons.search),
                              label: Text(
                                  supplier?.name ?? 'Search/select supplier'),
                            )),
                        if (supplierId == null)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                                'A supplier is required to finalize this receiving.'),
                          ),
                      ])),
              SizedBox(
                  width: fieldWidth,
                  child: TextField(
                    controller: externalReference,
                    decoration: const InputDecoration(
                        labelText: 'Supplier invoice / reference (optional)',
                        helperText:
                            'Invoice, delivery receipt, or supplier document number.'),
                    onChanged: (_) => setState(() {}),
                  )),
            ]);
          }),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () async {
              final selected = await showDatePicker(
                  context: context,
                  initialDate: receivedAt,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now());
              if (selected != null && mounted) {
                setState(() => receivedAt = selected);
              }
            },
            icon: const Icon(Icons.calendar_today_outlined),
            label: Text(
                'Received date: ${localizations.formatMediumDate(receivedAt)}'),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: TextField(
                  controller: notes,
                  decoration:
                      const InputDecoration(labelText: 'Notes (optional)'))),
          const SizedBox(height: 28),
          const Divider(height: 1),
          const SizedBox(height: 24),
          _step(context, 2, 'Items in this delivery'),
          const SizedBox(height: 12),
          Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                    '${lines.length} product ${lines.length == 1 ? 'line' : 'lines'} in this receiving draft'),
                if (lines.isNotEmpty)
                  FilledButton.icon(
                      onPressed: busy ? null : openItemEditor,
                      icon: const Icon(Icons.add),
                      label: const Text('Add item')),
              ]),
          if (draftMessage != null && lines.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(draftMessage!),
          ],
          const SizedBox(height: 12),
          if (lines.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                const Text('No products added yet.'),
                const SizedBox(height: 4),
                const Text(
                    'Add the products included in this supplier delivery.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed: busy ? null : openItemEditor,
                    icon: const Icon(Icons.add),
                    label: const Text('Add item')),
              ]),
            )
          else
            LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              return Column(children: [
                if (wide)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        const Expanded(flex: 3, child: Text('Product')),
                        const SizedBox(width: 105, child: Text('Quantity')),
                        const SizedBox(
                            width: 130, child: Text('Purchase cost')),
                        const SizedBox(width: 130, child: Text('Selling')),
                        const Expanded(flex: 2, child: Text('Tracking')),
                        const SizedBox(width: 120, child: Text('Line value')),
                        const SizedBox(width: 96, child: Text('Actions')),
                      ])),
                for (var i = 0; i < lines.length; i++) ...[
                  const Divider(height: 1),
                  _draftItem(context, i, wide),
                ],
              ]);
            }),
          const SizedBox(height: 28),
          const Divider(height: 1),
          const SizedBox(height: 24),
          _step(context, 3, 'Review & Finalize'),
          const SizedBox(height: 16),
          ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(children: [
                _reviewLine('Supplier', supplier?.name ?? 'Not selected'),
                _reviewLine('Received date',
                    localizations.formatMediumDate(receivedAt)),
                if (externalReference.text.trim().isNotEmpty)
                  _reviewLine('Supplier invoice / reference',
                      externalReference.text.trim()),
                _reviewLine('Product lines', '${lines.length}'),
                _reviewLine('Total quantity',
                    '${Quantity.format(lines.fold<int>(0, (sum, line) => sum + line.quantityMilli))} $totalUnit'),
                _reviewLine('Receiving value', formatPeso(totalCostCents)),
              ])),
          const SizedBox(height: 16),
          const Text(
              'Inventory has not been updated yet. Stock will be added only after you finalize this receiving.'),
          if (missing != null) ...[
            const SizedBox(height: 6),
            Text(missing),
          ],
          const SizedBox(height: 16),
          Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: busy || missing != null ? null : confirmFinalize,
                child: Text(busy ? 'Finalizing…' : 'Finalize Receiving'),
              )),
        ]),
      )),
    ]);
  }

  Widget _recentReceivingRow(StockReceiving record) =>
      FutureBuilder<List<StockReceivingItem>>(
          future: widget.repository.items(record.id),
          builder: (context, snapshot) {
            final supplier = allSuppliers
                    .where((s) => s.id == record.supplierId)
                    .firstOrNull
                    ?.name ??
                'Supplier';
            final items = snapshot.data ?? <StockReceivingItem>[];
            final value = items.fold<int>(
                0,
                (sum, item) =>
                    sum +
                    item.quantityMilli * item.unitCostCents ~/ Quantity.scale);
            final date = MaterialLocalizations.of(context)
                .formatMediumDate(record.receivedAt);
            final reference = record.externalReference?.trim();
            return Card(
                child: ListTile(
              title: Text(
                  '${StockReceivingRepository.number(record)} · $supplier'),
              subtitle: Text(
                  '$date · ${items.length} product ${items.length == 1 ? 'line' : 'lines'}'
                  '${reference?.isNotEmpty == true ? ' · $reference' : ''}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(formatPeso(value)),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right),
              ]),
              onTap: () => setState(() => view = 'history'),
            ));
          });

  Widget _poReceivingDocument(BuildContext context) {
    final progress = purchaseOrder!;
    final supplier = suppliers.where((s) => s.id == supplierId).firstOrNull;
    final open = progress.lines.where((line) => progress.remaining(line) > 0);
    return Column(children: [
      Expanded(
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1180),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('New Receiving',
                                style:
                                    Theme.of(context).textTheme.headlineSmall),
                            Text(
                                'Against ${PurchaseOrderRepository.number(progress.order)}'),
                            Text('Supplier: ${supplier?.name ?? 'Supplier'}'),
                            const SizedBox(height: 12),
                            Wrap(spacing: 12, runSpacing: 8, children: [
                              OutlinedButton.icon(
                                  onPressed: () async {
                                    final picked = await showDatePicker(
                                        context: context,
                                        initialDate: receivedAt,
                                        firstDate: DateTime(2000),
                                        lastDate: DateTime.now());
                                    if (picked != null && mounted) {
                                      setState(() => receivedAt = picked);
                                    }
                                  },
                                  icon: const Icon(Icons.event),
                                  label: Text(
                                      'Received: ${MaterialLocalizations.of(context).formatMediumDate(receivedAt)}')),
                              SizedBox(
                                  width: 260,
                                  child: TextField(
                                      controller: externalReference,
                                      decoration: const InputDecoration(
                                          labelText:
                                              'Supplier invoice / reference'))),
                              SizedBox(
                                  width: 300,
                                  child: TextField(
                                      controller: notes,
                                      decoration: const InputDecoration(
                                          labelText: 'Notes'))),
                            ]),
                            const SizedBox(height: 16),
                            Text('Items received',
                                style: Theme.of(context).textTheme.titleMedium),
                            Text(
                                '${open.length} PO ${open.length == 1 ? 'line' : 'lines'} loaded'),
                            if (error != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                            const SizedBox(height: 8),
                            for (final poLine in open) ...[
                              const Divider(height: 1),
                              Builder(builder: (context) {
                                final product = products
                                    .where((p) => p.id == poLine.productId)
                                    .firstOrNull;
                                final draft = lines
                                    .where((line) =>
                                        line.purchaseOrderLineId == poLine.id)
                                    .firstOrNull;
                                final unit = product?.business.unit.label ?? '';
                                return Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    child: Wrap(
                                        spacing: 12,
                                        runSpacing: 8,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          SizedBox(
                                              width: 220,
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                        product?.name ??
                                                            'Product',
                                                        style: const TextStyle(
                                                            fontWeight:
                                                                FontWeight
                                                                    .w600)),
                                                    Text(
                                                        'Expected cost ${formatPeso(poLine.expectedUnitCostCents)}'),
                                                  ])),
                                          SizedBox(
                                              width: 88,
                                              child: Text(
                                                  'Ordered\n${Quantity.format(poLine.orderedQtyMilli)} $unit')),
                                          SizedBox(
                                              width: 96,
                                              child: Text(
                                                  'Prev. recv.\n${Quantity.format(progress.received[poLine.id] ?? 0)} $unit')),
                                          SizedBox(
                                              width: 98,
                                              child: Text(
                                                  'Remaining\n${Quantity.format(progress.remaining(poLine))} $unit')),
                                          SizedBox(
                                              width: 115,
                                              child: TextField(
                                                  key: ValueKey(
                                                      'po-qty-${poLine.id}'),
                                                  controller:
                                                      poQuantities[poLine.id],
                                                  keyboardType:
                                                      const TextInputType
                                                          .numberWithOptions(
                                                          decimal: true),
                                                  decoration:
                                                      const InputDecoration(
                                                          labelText:
                                                              'Receive qty'),
                                                  onChanged: (_) =>
                                                      updatePoLine(poLine))),
                                          SizedBox(
                                              width: 130,
                                              child: TextField(
                                                  key: ValueKey(
                                                      'po-cost-${poLine.id}'),
                                                  controller:
                                                      poCosts[poLine.id],
                                                  keyboardType:
                                                      const TextInputType
                                                          .numberWithOptions(
                                                          decimal: true),
                                                  decoration:
                                                      const InputDecoration(
                                                          labelText:
                                                              'Actual cost'),
                                                  onChanged: (_) =>
                                                      updatePoLine(poLine))),
                                          if (product?.serialTracking == true ||
                                              product?.business.batch == true ||
                                              product?.pricingPolicy == 'layer')
                                            TextButton(
                                                onPressed: draft == null
                                                    ? null
                                                    : () => editLine(
                                                        lines.indexOf(draft)),
                                                child: const Text('Details')),
                                        ]));
                              }),
                            ],
                            const SizedBox(height: 12),
                            TextButton.icon(
                                onPressed: busy
                                    ? null
                                    : () {
                                        setState(() {
                                          addingUnplanned = true;
                                          productId = null;
                                          cost.clear();
                                        });
                                        openItemEditor();
                                      },
                                icon: const Icon(Icons.add),
                                label: const Text('Add unplanned item')),
                            for (var i = 0; i < lines.length; i++)
                              if (lines[i].purchaseOrderLineId == null)
                                ListTile(
                                    dense: true,
                                    title: Text(products
                                            .where((p) =>
                                                p.id == lines[i].productId)
                                            .firstOrNull
                                            ?.name ??
                                        'Product'),
                                    subtitle: Text(
                                        'Unplanned item · ${Quantity.format(lines[i].quantityMilli)} · ${formatPeso(lines[i].unitCostCents)} actual cost'),
                                    trailing: IconButton(
                                        tooltip: 'Remove unplanned item',
                                        icon: const Icon(Icons.close),
                                        onPressed: () =>
                                            setState(() => lines.removeAt(i))),
                                    onTap: () => editLine(i)),
                          ]))))),
      const Divider(height: 1),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(children: [
            Expanded(
                child: Text(
                    '${lines.where((line) => line.quantityMilli > 0).length} lines receiving · ${formatPeso(totalCostCents)} actual total')),
            TextButton(
                onPressed: busy ? null : leaveNewReceiving,
                child: const Text('Cancel')),
            const SizedBox(width: 12),
            FilledButton(
                onPressed: busy ? null : confirmFinalize,
                child: Text(busy ? 'Finalizing…' : 'Finalize Receiving')),
          ])),
    ]);
  }

  Future<void> openReceivingDetail(StockReceiving record) async {
    final items = await widget.repository.items(record.id);
    final actor =
        (await widget.repository.db.select(widget.repository.db.users).get())
            .where((u) => u.id == record.userId)
            .firstOrNull;
    final linkedOrder = record.purchaseOrderId == null
        ? null
        : await PurchaseOrderRepository(widget.repository.db)
            .detail(record.purchaseOrderId!);
    final actualTotal = items.fold<int>(
        0,
        (sum, item) =>
            sum + Quantity.lineCents(item.unitCostCents, item.quantityMilli));
    final expectedLinked = linkedOrder == null
        ? 0
        : items.fold<int>(0, (sum, item) {
            final line = linkedOrder.lines
                .where((l) => l.id == item.purchaseOrderLineId)
                .firstOrNull;
            return sum +
                (line == null
                    ? 0
                    : Quantity.lineCents(
                        line.expectedUnitCostCents, item.quantityMilli));
          });
    final actualLinked = linkedOrder == null
        ? 0
        : items.fold<int>(
            0,
            (sum, item) =>
                sum +
                (item.purchaseOrderLineId == null
                    ? 0
                    : Quantity.lineCents(
                        item.unitCostCents, item.quantityMilli)));
    if (!mounted) return;
    final supplier = allSuppliers
            .where((s) => s.id == record.supplierId)
            .firstOrNull
            ?.name ??
        'Inactive supplier';
    final receivedQuantity =
        items.fold<int>(0, (total, item) => total + item.quantityMilli);
    final receivedUnits = {
      for (final item in items)
        allProducts
            .where((p) => p.id == item.productId)
            .firstOrNull
            ?.business
            .unit
            .label
    };
    final comparableQuantity =
        !receivedUnits.contains(null) && receivedUnits.length <= 1;
    await showRecordDetailsDrawer<void>(
      context: context,
      builder: (drawerContext) => RecordDetailsDrawer(
        width: 680,
        title: Text(StockReceivingRepository.number(record)),
        subtitle: Text(
            '$supplier · ${MaterialLocalizations.of(drawerContext).formatMediumDate(record.receivedAt)}'),
        badges: [
          DrawerStatusBadge(
              linkedOrder == null ? 'Direct receiving' : 'PO linked')
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DrawerSection(
                title: 'Receiving summary',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DrawerMetricGrid(metrics: [
                      DrawerMetric(
                          label: 'Actual received cost',
                          value: formatPeso(actualTotal)),
                      DrawerMetric(
                          label: 'Received quantity',
                          value: comparableQuantity
                              ? Quantity.format(receivedQuantity)
                              : 'Mixed units',
                          detail: comparableQuantity
                              ? receivedUnits.firstOrNull
                              : 'See item quantities'),
                    ]),
                    const SizedBox(height: 12),
                    DrawerLabelValue(
                        label: 'Received by',
                        value: actor?.name ?? 'Unknown user'),
                    DrawerLabelValue(
                        label: 'Supplier invoice / reference',
                        value: record.externalReference?.isNotEmpty == true
                            ? record.externalReference!
                            : 'Not set'),
                    DrawerLabelValue(
                        label: 'Purchase Order',
                        value: linkedOrder == null
                            ? 'Direct receiving'
                            : PurchaseOrderRepository.number(
                                linkedOrder.order)),
                    DrawerLabelValue(
                        label: 'Finalized',
                        value: record.finalizedAt == null
                            ? 'Legacy record · time unavailable'
                            : '${MaterialLocalizations.of(drawerContext).formatMediumDate(record.finalizedAt!)} · ${MaterialLocalizations.of(drawerContext).formatTimeOfDay(TimeOfDay.fromDateTime(record.finalizedAt!))}'),
                    if (record.notes?.isNotEmpty == true)
                      DrawerLabelValue(label: 'Notes', value: record.notes!),
                  ],
                )),
            if (linkedOrder != null && expectedLinked > 0 && actualLinked > 0)
              DrawerSection(
                  title: 'Linked PO cost comparison',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DrawerProgressSummary(
                          value: expectedLinked /
                              (expectedLinked > actualLinked
                                  ? expectedLinked
                                  : actualLinked),
                          label: 'Expected cost',
                          showPercent: false,
                          detail: formatPeso(expectedLinked)),
                      const SizedBox(height: 12),
                      DrawerProgressSummary(
                          value: actualLinked /
                              (expectedLinked > actualLinked
                                  ? expectedLinked
                                  : actualLinked),
                          label: 'Actual cost',
                          showPercent: false,
                          detail: formatPeso(actualLinked)),
                      const SizedBox(height: 8),
                      DrawerLabelValue(
                          label: 'Variance',
                          value: formatPeso(actualLinked - expectedLinked)),
                    ],
                  )),
            DrawerSection(
                title: 'Received items',
                child: Column(children: [
                  for (final item in items)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                allProducts
                                        .where((p) => p.id == item.productId)
                                        .firstOrNull
                                        ?.name ??
                                    'Product',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(drawerContext)
                                    .textTheme
                                    .titleSmall),
                            const SizedBox(height: 6),
                            DrawerLabelValue(
                                label: 'Quantity',
                                value:
                                    '${Quantity.format(item.quantityMilli)} ${allProducts.where((p) => p.id == item.productId).firstOrNull?.business.unit.label ?? 'units'}'),
                            DrawerLabelValue(
                                label: 'Actual unit cost',
                                value: formatPeso(item.unitCostCents)),
                            DrawerLabelValue(
                                label: 'Line subtotal',
                                value: formatPeso(Quantity.lineCents(
                                    item.unitCostCents, item.quantityMilli))),
                            if (linkedOrder != null)
                              Builder(builder: (context) {
                                final line = linkedOrder.lines
                                    .where(
                                        (l) => l.id == item.purchaseOrderLineId)
                                    .firstOrNull;
                                return line == null
                                    ? const SizedBox.shrink()
                                    : DrawerLabelValue(
                                        label: 'Expected unit cost',
                                        value: formatPeso(
                                            line.expectedUnitCostCents));
                              }),
                            if (item.batchNumber?.isNotEmpty == true)
                              DrawerLabelValue(
                                  label: 'Batch', value: item.batchNumber!),
                            FutureBuilder(
                              future: widget.repository.serialsForItem(item.id),
                              builder: (context, snapshot) {
                                final serials =
                                    snapshot.data ?? const <SerialUnit>[];
                                if (serials.isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return ExpansionTile(
                                  tilePadding: EdgeInsets.zero,
                                  title: Text(
                                      'Serial numbers (${serials.length})'),
                                  children: [
                                    SizedBox(
                                      height: serials.length > 4
                                          ? 240
                                          : serials.length * 64.0,
                                      child: ListView.builder(
                                        itemCount: serials.length,
                                        itemBuilder: (context, index) {
                                          final serial = serials[index];
                                          return ListTile(
                                            dense: true,
                                            title: Text(serial.serialNumber,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis),
                                            subtitle: DrawerStatusBadge(
                                                serial.status),
                                            trailing: serial.status ==
                                                    'available'
                                                ? IconButton(
                                                    tooltip:
                                                        'Correct unsold serial',
                                                    icon:
                                                        const Icon(Icons.edit),
                                                    onPressed: () =>
                                                        correctSerial(serial))
                                                : null,
                                          );
                                        },
                                      ),
                                    )
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                ])),
            DrawerSection(title: 'Purchase returns', child: FutureBuilder(
              future: PurchaseReturnRepository(widget.repository.db).forReceiving(record.id),
              builder: (context, snapshot) {
                final returns = snapshot.data ?? <PurchaseReturn>[];
                if (returns.isEmpty) return const Text('No purchase returns for this receiving.');
                return Column(children: [for (final row in returns)
                  FutureBuilder(future: PurchaseReturnRepository(widget.repository.db).lines(row.id),
                    builder: (context, lineSnapshot) {
                    final lines = lineSnapshot.data ?? <PurchaseReturnLine>[];
                    return ListTile(contentPadding: EdgeInsets.zero,
                    title: Text(PurchaseReturnRepository.number(row)),
                    subtitle: Text('${Quantity.format(lines.fold<int>(0, (n, l) => n + l.quantityMilli))} units · ${formatPeso(lines.fold<int>(0, (n, l) => n + l.returnValueCents))} · ${row.status} · ${PurchaseReturnResolution.values.byName(row.resolution).label}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(drawerContext);
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(
                        appBar: AppBar(title: const Text('Purchase Returns')),
                        body: PurchaseReturnsScreen(
                          repository: PurchaseReturnRepository(widget.repository.db),
                          user: widget.user, initialReturnId: row.id))));
                    });
                  })]);
              })),
          ],
        ),
        primaryAction: FilledButton(
            onPressed: () => exportReceipt(record, print: true),
            child: const Text('Print GRN')),
        secondaryActions: [
          if (widget.user.can(PosPermission.stockReceiving))
            OutlinedButton(
                onPressed: () async {
                  final rows = await widget.repository.items(record.id);
                  final labels = <LabelItem>[];
                  for (final row in rows) {
                    final product = allProducts.where((p) => p.id == row.productId).firstOrNull;
                    if (product == null) continue;
                    if (product.serialTracking) {
                      final serials = await widget.repository.serialsForItem(row.id);
                      for (final serial in serials) {
                        labels.add(LabelItem(product, 1, serialNumber: serial.serialNumber,
                          batchNumber: row.batchNumber, expiryDate: row.expiryDate,
                          receivingPriceCents: row.unitSellingPriceCents));
                      }
                    } else {
                      labels.add(LabelItem(product,
                        suggestedReceivingLabels(row.quantityMilli, weight: product.business.weight),
                        batchNumber: row.batchNumber, expiryDate: row.expiryDate,
                        receivingPriceCents: row.unitSellingPriceCents));
                    }
                  }
                  if (!mounted || !drawerContext.mounted) return;
                  Navigator.pop(drawerContext);
                  showLabelPrintDialog(context, widget.repository.db, labels,
                    products: widget.products, actorId: widget.user.id);
                },
                child: const Text('Print labels')),
          if (widget.onReturnToSupplier != null &&
              widget.user.can(PosPermission.stockReceiving))
            OutlinedButton(
                onPressed: () {
                  Navigator.pop(drawerContext);
                  widget.onReturnToSupplier!(record.id);
                },
                child: const Text('Return to supplier')),
          OutlinedButton(
              onPressed: () => exportReceipt(record, print: false),
              child: const Text('Save GRN PDF')),
          if (linkedOrder != null && widget.onViewPurchaseOrder != null)
            OutlinedButton(
                onPressed: () {
                  Navigator.pop(drawerContext);
                  widget.onViewPurchaseOrder!(linkedOrder.order.id);
                },
                child: const Text('View Purchase Order')),
        ],
        tertiaryAction: TextButton(
            onPressed: () => Navigator.pop(drawerContext),
            child: const Text('Close')),
      ),
    );
  }

  Future<void> exportReceipt(StockReceiving receipt,
      {required bool print}) async {
    try {
      final bytes = await ReceivingPdf(widget.repository.db).render(receipt.id);
      final filename = ReceivingPdf.filename(receipt);
      if (print) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
      } else {
        final directory = await getDownloadsDirectory() ??
            await getApplicationDocumentsDirectory();
        final file =
            File('${directory.path}${Platform.pathSeparator}$filename');
        await file.writeAsBytes(bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
        }
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Widget historyWorkspace(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(),
            child: AppWorkspacePadding(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppPageHeader(
                      title: 'Receiving history',
                      subtitle:
                          'Review supplier deliveries and finalized stock receipts.',
                      action: FilledButton.icon(
                        onPressed: () => setState(() => view = 'new'),
                        icon: const Icon(Icons.add),
                        label: const Text('New receiving'),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => view = 'landing'),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back to receiving'),
                    ),
                    AppSearchField(
                      hintText:
                          'Search RCV, PO, supplier, reference, product, SKU',
                      onChanged: (value) {
                        historySearchDebounce?.cancel();
                        historySearchDebounce = Timer(
                          const Duration(milliseconds: 300),
                          () {
                            if (!mounted) return;
                            changeHistoryFilter(
                                () => historySearch = value.trim());
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, runSpacing: 6, children: [
                      DropdownButton<String?>(
                        value: historySupplierId,
                        hint: const Text('All suppliers'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('All suppliers')),
                          for (final supplier in allSuppliers)
                            DropdownMenuItem<String?>(
                                value: supplier.id, child: Text(supplier.name)),
                        ],
                        onChanged: (value) => changeHistoryFilter(
                            () => historySupplierId = value),
                      ),
                      DropdownButton<String>(
                        value: historyType,
                        items: ['All', 'PO-based', 'Direct']
                            .map((value) => DropdownMenuItem(
                                value: value, child: Text(value)))
                            .toList(),
                        onChanged: (value) => changeHistoryFilter(
                            () => historyType = value ?? 'All'),
                      ),
                      DropdownButton<String?>(
                        value: historyActorName,
                        hint: const Text('All receivers'),
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('All receivers')),
                          for (final name in historyReceivers)
                            DropdownMenuItem<String?>(
                                value: name, child: Text(name)),
                        ],
                        onChanged: (value) =>
                            changeHistoryFilter(() => historyActorName = value),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          final dates = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                            initialDateRange: historyDates,
                          );
                          if (dates != null) {
                            changeHistoryFilter(() => historyDates = dates);
                          }
                        },
                        child: Text(historyDates == null
                            ? 'Dates'
                            : '${MaterialLocalizations.of(context).formatShortDate(historyDates!.start)}–${MaterialLocalizations.of(context).formatShortDate(historyDates!.end)}'),
                      ),
                      if (historyDates != null)
                        TextButton(
                          onPressed: () =>
                              changeHistoryFilter(() => historyDates = null),
                          child: const Text('Clear dates'),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    Expanded(
                        child: AppPagedListPanel(
                      key: const Key('receiving-history-panel'),
                      title: 'Receivings',
                      total: historyResult?.totalCount ?? 0,
                      count: historyResult?.items.length ?? 0,
                      page: historyPage,
                      loading: historyLoading || historyResult == null,
                      error: error,
                      onRetry: loadHistory,
                      emptyTitle: historySearch.isNotEmpty
                          ? 'No receivings match this search'
                          : historySupplierId != null ||
                                  historyActorName != null ||
                                  historyType != 'All' ||
                                  historyDates != null
                              ? 'No receivings match these filters'
                              : 'No receivings yet',
                      onPrevious: () {
                        setState(() => historyPage--);
                        loadHistory();
                      },
                      onNext: () {
                        setState(() => historyPage++);
                        loadHistory();
                      },
                      itemBuilder: (context, index) {
                        final record = historyResult!.items[index];
                        final summary = historySummary[record.id];
                        return AppEntityRow(
                          title: StockReceivingRepository.number(record),
                          subtitle: '${summary?.supplierName ?? 'Supplier'} · '
                              '${MaterialLocalizations.of(context).formatMediumDate(record.receivedAt)} · '
                              '${record.externalReference ?? 'No supplier reference'} · '
                              '${summary?.poReference ?? 'Direct receiving'} · '
                              '${summary?.actorName ?? 'Unknown / legacy'}\n'
                              '${summary?.lineCount ?? 0} lines',
                          amount: formatPeso(summary?.actualCostCents ?? 0),
                          onTap: () => openReceivingDetail(record),
                        );
                      },
                    )),
                  ]),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (view == 'history') return historyWorkspace(context);
    if (purchaseOrder != null && view == 'new') {
      return Scaffold(body: _poReceivingDocument(context));
    }
    if (view == 'noRemaining') {
      return const Scaffold(
          body: Center(
              child: Text(
                  'This Purchase Order has no remaining quantity to receive.')));
    }
    return Scaffold(
      appBar: view == 'landing' ? AppBar(title: const Text('Receiving')) : null,
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: ListView(padding: const EdgeInsets.all(20), children: [
                if (view == 'landing') ...[
                  const Text(
                      'Record supplier deliveries and review receiving history.'),
                  const SizedBox(height: 24),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    FilledButton.icon(
                        onPressed: () => setState(() {
                              view = 'new';
                              completed = null;
                            }),
                        icon: const Icon(Icons.add),
                        label: const Text('New receiving')),
                    OutlinedButton.icon(
                        onPressed: () => setState(() => view = 'history'),
                        icon: const Icon(Icons.history),
                        label: const Text('View history')),
                  ]),
                  if (completed != null)
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Receiving finalized',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge),
                                  for (final line in completedLines)
                                    Text(
                                        '${Quantity.format(line.quantityMilli)} ${allProducts.where((p) => p.id == line.productId).firstOrNull?.business.unit.label ?? ''} ${allProducts.where((p) => p.id == line.productId).firstOrNull?.name ?? 'Product'} added'),
                                  const SizedBox(height: 8),
                                  Wrap(spacing: 8, children: [
                                    OutlinedButton(
                                        onPressed: () =>
                                            setState(() => view = 'history'),
                                        child: const Text('View receiving')),
                                    TextButton(
                                        onPressed: () => setState(() {
                                              completed = null;
                                              view = 'new';
                                            }),
                                        child: const Text('New receiving')),
                                  ]),
                                ]))),
                  const SizedBox(height: 24),
                  Text('Recent receiving',
                      style: Theme.of(context).textTheme.titleLarge),
                  if (history.isEmpty)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                                'No deliveries recorded yet. Start a new receiving to record incoming stock.'))),
                  for (final record in history.take(5))
                    _recentReceivingRow(record),
                ],
                if (view == 'new') _buildReceivingDocument(context),
                if (view == 'history') ...[
                  Row(children: [
                    IconButton(
                        tooltip: 'Back to receiving',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => setState(() => view = 'landing')),
                    Expanded(
                        child: Text('Receiving history',
                            style: Theme.of(context).textTheme.headlineMedium)),
                    FilledButton.icon(
                        onPressed: () => setState(() => view = 'new'),
                        icon: const Icon(Icons.add),
                        label: const Text('New receiving')),
                  ]),
                  TextField(
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText:
                            'Search RCV, PO, supplier, reference, product, SKU'),
                    onChanged: (value) => setState(
                        () => historySearch = value.trim().toLowerCase()),
                  ),
                  Wrap(spacing: 12, runSpacing: 6, children: [
                    DropdownButton<String?>(
                      value: historySupplierId,
                      hint: const Text('All suppliers'),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('All suppliers')),
                        for (final supplier in allSuppliers)
                          DropdownMenuItem<String?>(
                              value: supplier.id, child: Text(supplier.name)),
                      ],
                      onChanged: (value) =>
                          setState(() => historySupplierId = value),
                    ),
                    DropdownButton<String>(
                      value: historyType,
                      items: ['All', 'PO-based', 'Direct']
                          .map((value) => DropdownMenuItem(
                              value: value, child: Text(value)))
                          .toList(),
                      onChanged: (value) =>
                          setState(() => historyType = value ?? 'All'),
                    ),
                    DropdownButton<String?>(
                      value: historyActorName,
                      hint: const Text('All receivers'),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('All receivers')),
                        for (final name in historySummary.values
                            .map((s) => s.actorName)
                            .whereType<String>()
                            .toSet())
                          DropdownMenuItem<String?>(
                              value: name, child: Text(name)),
                      ],
                      onChanged: (value) =>
                          setState(() => historyActorName = value),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        final dates = await showDateRangePicker(
                            context: context,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                            initialDateRange: historyDates);
                        if (dates != null) setState(() => historyDates = dates);
                      },
                      child: Text(historyDates == null
                          ? 'Dates'
                          : '${MaterialLocalizations.of(context).formatShortDate(historyDates!.start)}–${MaterialLocalizations.of(context).formatShortDate(historyDates!.end)}'),
                    ),
                    if (historyDates != null)
                      TextButton(
                          onPressed: () => setState(() => historyDates = null),
                          child: const Text('Clear dates')),
                  ]),
                  if (history.isEmpty)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                                'No deliveries recorded yet. Select a supplier and add products to record incoming stock.'))),
                  for (final record in history)
                    if (matchesHistory(record))
                      Card(
                          child: ListTile(
                        title: Text(StockReceivingRepository.number(record)),
                        subtitle: Text(
                            '${historySummary[record.id]?.supplierName ?? 'Supplier'} · '
                            '${MaterialLocalizations.of(context).formatMediumDate(record.receivedAt)} · '
                            '${record.externalReference ?? 'No supplier reference'} · '
                            '${historySummary[record.id]?.poReference ?? 'Direct receiving'} · '
                            '${historySummary[record.id]?.actorName ?? 'Unknown / legacy'}'),
                        trailing: Text(
                            '${historySummary[record.id]?.lineCount ?? 0} lines · '
                            '${formatPeso(historySummary[record.id]?.actualCostCents ?? 0)}'),
                        onTap: () => openReceivingDetail(record),
                      )),
                ],
              ]))),
    );
  }
}
