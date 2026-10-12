import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/models/product.dart';
import '../../core/models/business_product.dart';
import '../../core/models/business_feature.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../data/daos/stock_receiving_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/expiry_date_field.dart';
import '../pos_checkout/checkout_screen.dart';

String _pesoInput(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

class StockReceivingScreen extends StatefulWidget {
  final StockReceivingRepository repository;
  final DirectoryRepository directory;
  final PosRepository products;
  final ActiveUser user;
  final AuthService? auth;
  final String? initialProductId;
  const StockReceivingScreen(
      {super.key,
      required this.repository,
      required this.directory,
      required this.products,
      required this.user,
      this.auth,
      this.initialProductId});
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
  final lines = <ReceivingLineRequest>[];
  String? error;
  bool busy = false;
  StockReceiving? completed;
  String? draftMessage;
  List<ReceivingLineRequest> completedLines = [];

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
                            onChanged: (_) => update(() {})),
                        Expanded(
                            child: ListView(children: [
                          for (final product in products.where((p) {
                            final term = search.text.toLowerCase();
                            return p.name.toLowerCase().contains(term) ||
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
                sellingPrice.text = _pesoInput(product.priceCents);
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
          sellingPrice.text = _pesoInput(product.priceCents);
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
                      TextField(
                          controller: price,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Current selling price (pesos) *')),
                      TextField(
                          controller: defaultCost,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Current purchase cost (pesos)')),
                      DropdownButtonFormField<String>(
                          initialValue: pricingPolicy,
                          isExpanded: true,
                          decoration: const InputDecoration(
                              labelText: 'Selling price policy'),
                          items: const [
                            DropdownMenuItem(
                                value: 'current',
                                child:
                                    Text('Use current product selling price')),
                            DropdownMenuItem(
                                value: 'layer',
                                child:
                                    Text('Use receiving-layer selling price')),
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
                          final priceCents = tryParsePeso(price.text);
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
                            sellingPrice.text = _pesoInput(priceCents);
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
    productId = widget.initialProductId;
    if (productId != null) view = 'new';
    refresh();
  }

  @override
  void dispose() {
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
      final receivingRows = await widget.repository.history();
      if (mounted) {
        setState(() {
          suppliers = supplierRows.where((s) => s.isActive).toList();
          allSuppliers = supplierRows;
          products = productRows
              .where((p) => p.isActive && !p.business.madeToOrder)
              .toList();
          allProducts = productRows;
          history = receivingRows;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
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
      for (final controller in serialControllers) {
        controller.dispose();
      }
      serialControllers.clear();
      error = null;
    });
  }

  void editLine(int index) {
    final line = lines[index];
    setState(() {
      editingLine = index;
      productId = line.productId;
      quantity.text = Quantity.format(line.quantityMilli);
      cost.text = (line.unitCostCents / 100).toStringAsFixed(2);
      sellingPrice.text = line.unitSellingPriceCents == null
          ? ''
          : _pesoInput(line.unitSellingPriceCents!);
      batch.text = line.batchNumber ?? '';
      expiry = line.expiryDate;
      for (final controller in serialControllers) {
        controller.dispose();
      }
      serialControllers.clear();
      serialControllers.addAll(
          line.serialNumbers.map((s) => TextEditingController(text: s)));
      error = null;
    });
    openItemEditor();
  }

  int get totalCostCents => lines.fold(
      0,
      (sum, line) =>
          sum + (line.quantityMilli * line.unitCostCents ~/ Quantity.scale));

  Future<void> confirmFinalize() async {
    if (supplierId == null || lines.isEmpty) {
      setState(() => error =
          supplierId == null ? 'Select a supplier.' : 'Add at least one item.');
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Finalize this receiving?'),
              content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Supplier: ${suppliers.where((s) => s.id == supplierId).firstOrNull?.name ?? '—'}'),
                    Text('${lines.length} product lines'),
                    Text('Receiving cost: ${formatPeso(totalCostCents)}'),
                    const SizedBox(height: 12),
                    const Text(
                        'Finalizing will add these quantities to inventory.'),
                    for (final line in lines)
                      Text(
                          '${allProducts.where((p) => p.id == line.productId).firstOrNull?.name ?? 'Product'} · ${Quantity.format(line.quantityMilli)} · ${line.serialNumbers.isEmpty ? (line.batchNumber ?? '') : '${line.serialNumbers.length} serials'}'),
                  ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Back')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Finalize Receiving')),
              ],
            ));
    if (confirmed == true) await finalize();
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
        serialControllers.removeLast().dispose();
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

  Future<void> finalize() async {
    if (busy || supplierId == null || lines.isEmpty) {
      setState(() => error = 'Choose a supplier and add at least one item');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final record = await widget.repository.receive(
          widget.user, supplierId!, lines,
          externalReference: externalReference.text,
          notes: notes.text,
          receivedAt: receivedAt);
      if (mounted) {
        setState(() {
          completedLines = List.of(lines);
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
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openItemEditor() async {
    if (editingLine == null) {
      setState(() {
        quantity.clear();
        final selected = products.where((p) => p.id == productId).firstOrNull;
        cost.text = selected == null ? '' : _pesoInput(selected.costCents);
        sellingPrice.text =
            selected == null ? '' : _pesoInput(selected.priceCents);
        batch.clear();
        expiry = null;
        serialPaste.clear();
        for (final controller in serialControllers) {
          controller.dispose();
        }
        serialControllers.clear();
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
                                  ? 'Add item to delivery'
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
                          onPressed: () async {
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
                                  'Quantity (${selected?.business.unit.label ?? 'units'})'),
                        ),
                        const SizedBox(height: 20),
                        Text('PURCHASE',
                            style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 8),
                        TextField(
                            controller: cost,
                            onChanged: (_) => update(() {}),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Unit purchase cost (pesos)')),
                        if (selected?.pricingPolicy == 'layer') ...[
                          const SizedBox(height: 20),
                          Text('SELLING PRICE',
                              style: Theme.of(context).textTheme.labelLarge),
                          const SizedBox(height: 8),
                          TextField(
                              controller: sellingPrice,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText:
                                      'Selling price for this stock (pesos)')),
                        ],
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
                        labelText: 'Supplier reference (optional)'),
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
                      label: const Text('Add item to delivery')),
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
                    label: const Text('Add item to delivery')),
              ]),
            )
          else
            LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              return Column(children: [
                if (wide)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        const Expanded(flex: 3, child: Text('Product')),
                        const SizedBox(width: 105, child: Text('Quantity')),
                        const SizedBox(
                            width: 130, child: Text('Purchase cost')),
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
                  _reviewLine(
                      'Supplier reference', externalReference.text.trim()),
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
              title: Text(supplier),
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

  @override
  Widget build(BuildContext context) {
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
                  if (history.isEmpty)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                                'No deliveries recorded yet. Select a supplier and add products to record incoming stock.'))),
                  for (final record in history)
                    FutureBuilder<List<StockReceivingItem>>(
                        future: widget.repository.items(record.id),
                        builder: (context, snapshot) => Card(
                                child: ListTile(
                              title: Text(record
                                          .externalReference?.isNotEmpty ==
                                      true
                                  ? record.externalReference!
                                  : 'Receiving · ${MaterialLocalizations.of(context).formatMediumDate(record.receivedAt)}'),
                              subtitle: Text(
                                  '${MaterialLocalizations.of(context).formatMediumDate(record.receivedAt)} · ${record.externalReference ?? 'No reference'}'),
                              trailing: Text(
                                  '${snapshot.data?.length ?? 0} lines · ${formatPeso((snapshot.data ?? <StockReceivingItem>[]).fold<int>(0, (sum, item) => sum + item.quantityMilli * item.unitCostCents ~/ Quantity.scale))}'),
                              onTap: () async {
                                final items =
                                    await widget.repository.items(record.id);
                                if (!context.mounted) return;
                                await showDialog<void>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                          title: Text(record.externalReference
                                                      ?.isNotEmpty ==
                                                  true
                                              ? record.externalReference!
                                              : 'Receiving details'),
                                          content: SizedBox(
                                              width: 600,
                                              child: ListView(
                                                  shrinkWrap: true,
                                                  children: [
                                                    Text(
                                                        'Supplier: ${allSuppliers.where((s) => s.id == record.supplierId).firstOrNull?.name ?? 'Inactive supplier'}'),
                                                    Text(
                                                        'Date: ${MaterialLocalizations.of(context).formatMediumDate(record.receivedAt)}'),
                                                    if (record.notes
                                                            ?.isNotEmpty ==
                                                        true)
                                                      Text(
                                                          'Notes: ${record.notes}'),
                                                    for (final item in items)
                                                      ListTile(
                                                          title: Text(allProducts
                                                                  .where((p) =>
                                                                      p.id ==
                                                                      item
                                                                          .productId)
                                                                  .firstOrNull
                                                                  ?.name ??
                                                              'Product'),
                                                          subtitle: Text(
                                                              '${Quantity.format(item.quantityMilli)} · ${formatPeso(item.unitCostCents)} purchase / unit${item.unitSellingPriceCents == null ? '' : ' · ${formatPeso(item.unitSellingPriceCents!)} sell / unit'}${item.batchNumber == null ? '' : ' · ${item.batchNumber}'}')),
                                                    for (final item in items)
                                                      FutureBuilder(
                                                          future: widget
                                                              .repository
                                                              .serialsForItem(
                                                                  item.id),
                                                          builder: (context,
                                                                  snapshot) =>
                                                              snapshot.hasData &&
                                                                      snapshot
                                                                          .data!
                                                                          .isNotEmpty
                                                                  ? Column(
                                                                      children: [
                                                                          for (final serial
                                                                              in snapshot.data!)
                                                                            ListTile(
                                                                              title: Text('Serial: ${serial.serialNumber}'),
                                                                              subtitle: Text(serial.status),
                                                                              trailing: serial.status == 'available' ? IconButton(tooltip: 'Correct unsold serial', icon: const Icon(Icons.edit), onPressed: () => correctSerial(serial)) : null,
                                                                            ),
                                                                        ])
                                                                  : const SizedBox
                                                                      .shrink()),
                                                  ])),
                                          actions: [
                                            TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(context),
                                                child: const Text('Close'))
                                          ],
                                        ));
                              },
                            ))),
                ],
              ]))),
    );
  }
}
