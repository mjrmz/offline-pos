import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../core/models/product.dart';
import '../../core/models/business_product.dart';
import '../../core/models/quantity.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../../data/daos/pos_repository.dart';
import '../../data/daos/quotation_repository.dart';
import '../../data/daos/purchase_order_repository.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/expiry_date_field.dart';
import '../../shared/widgets/transaction_picker.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../hardware/printer/receipt_service.dart';
import '../pos_checkout/checkout_screen.dart';
import 'documents/quotation_pdf.dart';
import 'documents/quotation_preview.dart';

class QuotationScreen extends StatefulWidget {
  final QuotationRepository repository;
  final DirectoryRepository directory;
  final PosRepository products;
  final ActiveUser user;
  final AuthService? auth;
  final ReceiptService? receipts;
  final String? initialQuotationReference;
  final void Function(String productId, String? supplierId, int quantityMilli,
      String quotationReference)? onReceiveStock;
  final void Function(String productId, String? supplierId, int quantityMilli,
      String quotationReference)? onCreatePurchaseOrder;
  final void Function(String orderId, String productId, int quantityMilli,
      String quotationReference)? onAddToPurchaseOrder;
  final void Function(String orderId, String quotationReference)?
      onViewPurchaseOrder;
  final void Function(
      List<({String productId, int quantityMilli})> lines,
      String? supplierId,
      String quotationReference)? onCreatePurchaseOrderForLines;
  const QuotationScreen(
      {super.key,
      required this.repository,
      required this.directory,
      required this.products,
      required this.user,
      this.auth,
      this.receipts,
      this.initialQuotationReference,
      this.onReceiveStock,
      this.onCreatePurchaseOrder,
      this.onAddToPurchaseOrder,
      this.onViewPurchaseOrder,
      this.onCreatePurchaseOrderForLines});
  @override
  State<QuotationScreen> createState() => _QuotationScreenState();
}

class _QuotationScreenState extends State<QuotationScreen> {
  Widget? editor;
  List<Quotation> rows = [];
  List<PosProduct> products = [];
  Map<String, int> availabilityMilli = {};
  List<Customer> customers = [];
  Map<String, int> quoteTotals = {};
  Map<String, int> quoteItemCounts = {};
  Map<String, int> quoteAwaitingCounts = {};
  Map<String, int> quoteOrderedCounts = {};
  Map<String, int> quoteNeedsOrderCounts = {};
  Map<String, String> quoteProductNames = {};
  Map<String, String> quoteReceipts = {};
  Map<String, int> quoteUnlinkedCounts = {};
  String? error;
  String query = '';
  String filter = 'all';
  int listPage = 0;
  bool initialQuotationOpened = false;
  String statusOf(Quotation quote) => quote.status == 'open' &&
          quote.validUntil != null &&
          quote.validUntil!.isBefore(DateTime.now())
      ? 'expired'
      : quote.status;
  String modeLabel(String mode) => switch (mode) {
        'exchange' => 'Tank exchange',
        'deposit' => 'New tank / deposit',
        'refill' => 'Refill only',
        'container' => 'Container + refill',
        'made_order' => 'Made to order',
        _ => '',
      };
  int quotedUnitPrice(PosProduct product, String mode) =>
      product.priceCents +
      (mode == 'deposit'
          ? product.business.depositCents
          : mode == 'container'
              ? product.business.containerPriceCents
              : 0);

  Future<String?> configureMode(PosProduct product) async {
    final modes = product.business.tank
        ? const {'exchange': 'Tank exchange', 'deposit': 'New tank / deposit'}
        : product.business.refill
            ? const {'refill': 'Refill only', 'container': 'Container + refill'}
            : product.business.madeToOrder
                ? const {'made_order': 'Made to order'}
                : const {'ordinary': 'Ordinary sale'};
    if (modes.length == 1) return modes.keys.single;
    return showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('Configure ${product.name}'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final entry in modes.entries)
                    ListTile(
                        title: Text(entry.value),
                        subtitle: Text(
                            formatPeso(quotedUnitPrice(product, entry.key))),
                        onTap: () => Navigator.pop(context, entry.key))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'))
                ]));
  }

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final quotes = await widget.repository.history();
      final catalog = await widget.products.products();
      final stock = await widget.products.stockLevels();
      final directory = await widget.directory.customers();
      final itemLists =
          await Future.wait(quotes.map((q) => widget.repository.items(q.id)));
      final receiptRows = await Future.wait(quotes.map((q) async =>
          q.convertedSaleId == null
              ? null
              : await (widget.repository.db.select(widget.repository.db.sales)
                    ..where((s) => s.id.equals(q.convertedSaleId!)))
                  .getSingleOrNull()));
      final purchaseOrders = PurchaseOrderRepository(widget.repository.db);
      final orderProgress = await Future.wait((await purchaseOrders.list())
          .map((order) => purchaseOrders.detail(order.id)));
      final sourceLinks = await widget.repository.db
          .select(widget.repository.db.purchaseOrderLineSourceLinks)
          .get();
      final quotationIds = {
        for (final quote in quotes) quote.reference: quote.id
      };
      int incomingFor(String reference, String productId) {
        final quotationId = quotationIds[reference];
        if (quotationId == null) return 0;
        var incoming = 0;
        for (final progress in orderProgress) {
          if (!{'draft', 'sent', 'partially_received'}
              .contains(progress.status)) {
            continue;
          }
          for (final line
              in progress.lines.where((l) => l.productId == productId)) {
            for (final source in sourceLinks.where((s) =>
                s.purchaseOrderLineId == line.id &&
                s.quotationId == quotationId)) {
              incoming += source.plannedQtyMilli -
                  PurchaseOrderRepository.receivedForSource(
                      source,
                      sourceLinks
                          .where((s) => s.purchaseOrderLineId == line.id),
                      progress.received[line.id] ?? 0);
            }
          }
        }
        return incoming;
      }

      int shortageFor(QuotationItem item) {
        final available = stock[item.productId] == null
            ? 0
            : stock[item.productId]!.$1 - stock[item.productId]!.$2;
        return (item.quantityMilli - available).clamp(0, item.quantityMilli);
      }

      bool needsPhysicalStock(QuotationItem item) =>
          item.productId != null &&
          catalog
                  .where((product) => product.id == item.productId)
                  .firstOrNull
                  ?.business
                  .madeToOrder !=
              true;

      if (mounted) {
        setState(() {
          rows = quotes;
          products = catalog;
          availabilityMilli = {
            for (final entry in stock.entries)
              entry.key: entry.value.$1 - entry.value.$2
          };
          customers = directory.where((c) => c.isActive).toList();
          quoteTotals = {
            for (var index = 0; index < quotes.length; index++)
              quotes[index].id: itemLists[index]
                  .fold<int>(0, (sum, item) => sum + item.lineTotalCents)
          };
          quoteItemCounts = {
            for (var index = 0; index < quotes.length; index++)
              quotes[index].id: itemLists[index].length
          };
          quoteUnlinkedCounts = {
            for (var index = 0; index < quotes.length; index++)
              quotes[index].id: itemLists[index]
                  .where((item) => item.productId == null)
                  .length
          };
          quoteAwaitingCounts = {
            for (var index = 0; index < quotes.length; index++)
              quotes[index].id: itemLists[index]
                  .where((item) =>
                      needsPhysicalStock(item) &&
                      (stock[item.productId] == null
                              ? 0
                              : stock[item.productId]!.$1 -
                                  stock[item.productId]!.$2) <
                          item.quantityMilli)
                  .length
          };
          quoteOrderedCounts = {
            for (var index = 0; index < quotes.length; index++)
              quotes[index].id: itemLists[index]
                  .where((item) =>
                      needsPhysicalStock(item) &&
                      shortageFor(item) > 0 &&
                      incomingFor(quotes[index].reference, item.productId!) >=
                          shortageFor(item))
                  .length
          };
          quoteNeedsOrderCounts = {
            for (var index = 0; index < quotes.length; index++)
              quotes[index].id: itemLists[index]
                  .where((item) =>
                      needsPhysicalStock(item) &&
                      shortageFor(item) > 0 &&
                      incomingFor(quotes[index].reference, item.productId!) <
                          shortageFor(item))
                  .length
          };
          quoteProductNames = {
            for (var index = 0; index < quotes.length; index++)
              quotes[index].id: itemLists[index]
                  .map((item) => item.productNameSnapshot)
                  .join(' ')
          };
          quoteReceipts = {
            for (var index = 0; index < quotes.length; index++)
              if (receiptRows[index]?.receiptNumber != null)
                quotes[index].id: receiptRows[index]!.receiptNumber!
          };
          error = null;
        });
        if (!initialQuotationOpened &&
            widget.initialQuotationReference != null) {
          initialQuotationOpened = true;
          final selected = quotes
              .where((quote) =>
                  quote.reference == widget.initialQuotationReference)
              .firstOrNull;
          if (selected != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) showQuote(selected);
            });
          }
        }
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<PosProduct?> quickCreateProduct(String suggestedName,
      {int? suggestedPriceCents,
      String? suggestedUnit,
      bool fromConversion = false}) async {
    if (!widget.user.can(PosPermission.manageCatalog)) return null;
    final categories = await widget.products.categories();
    if (!mounted) return null;
    final name = TextEditingController(text: suggestedName);
    final sku = TextEditingController();
    final barcode = TextEditingController();
    final price = TextEditingController(
        text: suggestedPriceCents == null
            ? ''
            : (suggestedPriceCents / 100).toStringAsFixed(2));
    final cost = TextEditingController();
    final lowStock = TextEditingController(text: '5');
    String? categoryId;
    var unit = SaleUnit.values
            .where((value) => value.label == suggestedUnit)
            .firstOrNull ??
        SaleUnit.piece;
    bool serial = false;
    bool batch = false;
    bool weight = false;
    bool busy = false;
    String? formError;
    String? nameError;
    String? priceError;
    String? costError;
    String? thresholdError;
    try {
      final id = await showDialog<String>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, update) => AlertDialog(
                    title: const Text('Create Inventory product'),
                    content: SizedBox(
                        width: 560,
                        height: 500,
                        child: ListView(children: [
                          const Text(
                              'Add this item to Inventory for future use. It begins with zero stock.'),
                          const SizedBox(height: 16),
                          const Text('BASIC INFORMATION'),
                          TextField(
                              controller: name,
                              autofocus: true,
                              decoration: const InputDecoration(
                                      labelText: 'Product name *')
                                  .copyWith(errorText: nameError)),
                          TextField(
                              controller: sku,
                              decoration:
                                  const InputDecoration(labelText: 'SKU')),
                          TextField(
                              controller: barcode,
                              decoration:
                                  const InputDecoration(labelText: 'Barcode')),
                          const SizedBox(height: 16),
                          const Text('PRICING & UNIT'),
                          DropdownButtonFormField<String?>(
                              initialValue: categoryId,
                              decoration:
                                  const InputDecoration(labelText: 'Category'),
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null, child: Text('No category')),
                                for (final category in categories)
                                  DropdownMenuItem<String?>(
                                      value: category.id,
                                      child: Text(category.name)),
                              ],
                              onChanged: (value) =>
                                  update(() => categoryId = value)),
                          DropdownButtonFormField<SaleUnit>(
                              initialValue: unit,
                              decoration:
                                  const InputDecoration(labelText: 'Unit'),
                              items: [
                                for (final value in SaleUnit.values)
                                  DropdownMenuItem(
                                      value: value, child: Text(value.label))
                              ],
                              onChanged: (value) => update(() {
                                    if (value != null) unit = value;
                                  })),
                          TextField(
                              controller: price,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                      labelText: 'Selling price *')
                                  .copyWith(errorText: priceError)),
                          ExpansionTile(
                              title: const Text('Advanced product options'),
                              children: [
                                const ListTile(
                                    title: Text('Inventory tracked'),
                                    subtitle: Text(
                                        'Physical stock starts at zero. Record deliveries in Receiving.')),
                                CheckboxListTile(
                                    title: const Text('Serial tracking'),
                                    value: serial,
                                    onChanged: (value) =>
                                        update(() => serial = value ?? false)),
                                CheckboxListTile(
                                    title: const Text('Batch tracking'),
                                    value: batch,
                                    onChanged: (value) =>
                                        update(() => batch = value ?? false)),
                                CheckboxListTile(
                                    title: const Text('Weight pricing'),
                                    value: weight,
                                    onChanged: (value) =>
                                        update(() => weight = value ?? false)),
                                TextField(
                                    controller: cost,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true),
                                    decoration: const InputDecoration(
                                            labelText: 'Expected purchase cost')
                                        .copyWith(errorText: costError)),
                                TextField(
                                    controller: lowStock,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                            labelText: 'Low-stock threshold')
                                        .copyWith(errorText: thresholdError)),
                              ]),
                          if (formError != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(formError!,
                                    style: TextStyle(
                                        color: Theme.of(dialogContext)
                                            .colorScheme
                                            .error))),
                        ])),
                    actions: [
                      TextButton(
                          onPressed:
                              busy ? null : () => Navigator.pop(dialogContext),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  final sellingPrice = tryParsePeso(price.text);
                                  final purchaseCost = cost.text.trim().isEmpty
                                      ? 0
                                      : tryParsePeso(cost.text);
                                  final threshold =
                                      int.tryParse(lowStock.text.trim());
                                  if (name.text.trim().isEmpty ||
                                      sellingPrice == null ||
                                      sellingPrice <= 0 ||
                                      purchaseCost == null ||
                                      purchaseCost < 0 ||
                                      threshold == null ||
                                      threshold < 0) {
                                    update(() {
                                      nameError = name.text.trim().isEmpty
                                          ? 'Enter a product name.'
                                          : null;
                                      priceError = sellingPrice == null ||
                                              sellingPrice <= 0
                                          ? 'Enter a valid selling price.'
                                          : null;
                                      costError = purchaseCost == null ||
                                              purchaseCost < 0
                                          ? 'Enter a valid purchase cost.'
                                          : null;
                                      thresholdError =
                                          threshold == null || threshold < 0
                                              ? 'Enter a valid threshold.'
                                              : null;
                                    });
                                    return;
                                  }
                                  update(() {
                                    busy = true;
                                    formError = null;
                                    nameError = null;
                                    priceError = null;
                                    costError = null;
                                    thresholdError = null;
                                  });
                                  try {
                                    final created = await widget.products
                                        .saveProduct(
                                            name: name.text,
                                            sku: sku.text,
                                            barcode: barcode.text,
                                            categoryId: categoryId,
                                            priceCents: sellingPrice,
                                            costCents: purchaseCost,
                                            lowStockThreshold: threshold,
                                            startingStock: 0,
                                            serialTracking: serial,
                                            business: BusinessProduct(
                                                unit: unit,
                                                weight: weight,
                                                batch: batch),
                                            actorId: widget.user.id);
                                    if (dialogContext.mounted) {
                                      Navigator.pop(dialogContext, created);
                                    }
                                  } catch (failure) {
                                    if (dialogContext.mounted) {
                                      update(() {
                                        busy = false;
                                        formError = safeMessage(failure);
                                      });
                                    }
                                  }
                                },
                          child: Text(fromConversion
                              ? 'Create product'
                              : 'Create & add to quotation')),
                    ],
                  )));
      if (id == null) return null;
      final catalog = await widget.products.products();
      if (!mounted) return null;
      setState(() {
        products = catalog;
        availabilityMilli[id] = 0;
      });
      return catalog.firstWhere((product) => product.id == id);
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      name.dispose();
      sku.dispose();
      barcode.dispose();
      price.dispose();
      cost.dispose();
      lowStock.dispose();
    }
  }

  Future<QuoteLineRequest?> editCustomLine(String suggestedName,
      {QuoteLineRequest? existing}) async {
    final description =
        TextEditingController(text: existing?.description ?? suggestedName);
    final quantity = TextEditingController(
        text: existing == null ? '1' : Quantity.format(existing.quantityMilli));
    final price = TextEditingController(
        text: existing?.unitPriceCents == null
            ? ''
            : (existing!.unitPriceCents! / 100).toStringAsFixed(2));
    final notes = TextEditingController(text: existing?.customNotes ?? '');
    var unit = SaleUnit.values
            .where((value) => value.label == existing?.unit)
            .firstOrNull ??
        SaleUnit.piece;
    String? formError;
    try {
      return await showDialog<QuoteLineRequest>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, update) => AlertDialog(
                    title: const Text('Custom quotation item'),
                    content: SizedBox(
                        width: 420,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text(
                              'Add this item only to this quotation. Link it to Inventory before a stock-controlled sale.'),
                          TextField(
                              controller: description,
                              autofocus: true,
                              decoration: const InputDecoration(
                                  labelText: 'Description *')),
                          TextField(
                              controller: quantity,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Quantity *')),
                          DropdownButtonFormField<SaleUnit>(
                              initialValue: unit,
                              decoration:
                                  const InputDecoration(labelText: 'Unit'),
                              items: [
                                for (final value in SaleUnit.values)
                                  DropdownMenuItem(
                                      value: value, child: Text(value.label))
                              ],
                              onChanged: (value) => update(() {
                                    if (value != null) unit = value;
                                  })),
                          TextField(
                              controller: price,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Unit price *')),
                          TextField(
                              controller: notes,
                              maxLines: 2,
                              decoration: const InputDecoration(
                                  labelText:
                                      'Notes / specification (optional)')),
                          if (formError != null)
                            Text(formError!,
                                style: TextStyle(
                                    color: Theme.of(dialogContext)
                                        .colorScheme
                                        .error)),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () {
                            final milli = Quantity.tryParse(quantity.text,
                                fractional: unit.fractional);
                            final cents = tryParsePeso(price.text);
                            if (description.text.trim().isEmpty ||
                                milli == null ||
                                milli <= 0 ||
                                cents == null ||
                                cents <= 0) {
                              update(() => formError =
                                  'Enter a description, positive quantity, and positive unit price.');
                              return;
                            }
                            Navigator.pop(
                                dialogContext,
                                QuoteLineRequest.custom(
                                    description.text.trim(), milli,
                                    unit: unit.label,
                                    unitPriceCents: cents,
                                    customNotes: notes.text.trim()));
                          },
                          child: Text(existing == null
                              ? 'Add to quotation'
                              : 'Save item')),
                    ],
                  )));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      description.dispose();
      quantity.dispose();
      price.dispose();
      notes.dispose();
    }
  }

  Future<void> create({Quotation? existing}) async {
    final previousItems = existing == null
        ? <QuotationItem>[]
        : await widget.repository.items(existing.id);
    if (!mounted) return;
    final notes = TextEditingController();
    final customerSearch = TextEditingController();
    final customerName = TextEditingController();
    final customerPhone = TextEditingController();
    final productSearch = TextEditingController();
    final lines = <QuoteLineRequest>[];
    final previous = {
      for (final item in previousItems)
        if (item.productId != null) item.productId!: item
    };
    lines.addAll(previousItems.map((item) => item.productId == null
        ? QuoteLineRequest.custom(item.productNameSnapshot, item.quantityMilli,
            unit: item.unitSnapshot,
            unitPriceCents: item.unitPriceCents,
            customNotes: item.customNotes)
        : QuoteLineRequest(item.productId, item.quantityMilli,
            mode: item.saleMode)));
    notes.text = existing?.notes ?? '';
    String? customerId = existing?.customerId;
    DateTime? validUntil = existing?.validUntil;
    String? validation;
    String searchQuery = '';
    String editSignature() =>
        '${lines.map((line) => '${line.productId}|${line.description}|${line.quantityMilli}|${line.unitPriceCents}|${line.mode}|${line.customNotes}').join(';')}|$customerId|$validUntil|${notes.text}';
    final initialSignature = editSignature();
    final wide = MediaQuery.sizeOf(context).width >= 900;
    int linePrice(QuoteLineRequest line) {
      if (line.productId == null) return line.unitPriceCents ?? 0;
      final product = products.firstWhere((p) => p.id == line.productId);
      final prior = previous[line.productId];
      final base = prior?.unitPriceCents ?? product.priceCents;
      final extra = prior != null && prior.saleMode == line.mode
          ? prior.extraCents
          : quotedUnitPrice(product, line.mode) - product.priceCents;
      return base + extra;
    }

    int quoteTotal() => lines.fold<int>(
        0,
        (sum, line) =>
            sum + Quantity.lineCents(linePrice(line), line.quantityMilli));
    String lineAvailability(QuoteLineRequest line) {
      if (line.productId == null) return 'Custom item · Available by order';
      final amount = availabilityMilli[line.productId] ?? 0;
      if (amount < line.quantityMilli) {
        return 'Available by order · Source on order';
      }
      final product = products.firstWhere((p) => p.id == line.productId);
      if (amount <= product.lowStockThreshold * Quantity.scale) {
        return 'Low stock · ${Quantity.format(amount)} currently available';
      }
      return '${Quantity.format(amount)} currently available';
    }

    Future<void> addCatalog(
        PosProduct product, void Function(void Function()) update) async {
      if (lines.any((line) => line.productId == product.id)) {
        update(() =>
            validation = 'Already in quotation — edit quantity on the line.');
        return;
      }
      final mode = await configureMode(product);
      if (mode == null || !mounted) return;
      update(() {
        lines.add(QuoteLineRequest(product.id, Quantity.scale, mode: mode));
        productSearch.clear();
        searchQuery = '';
        validation = null;
      });
    }

    Future<void> createFromSearch(void Function(void Function()) update) async {
      final created = await quickCreateProduct(productSearch.text.trim());
      if (created != null && mounted) await addCatalog(created, update);
    }

    Future<void> customFromSearch(void Function(void Function()) update) async {
      final custom = await editCustomLine(productSearch.text.trim());
      if (custom == null || !mounted) return;
      update(() {
        lines.add(custom);
        productSearch.clear();
        searchQuery = '';
        validation = null;
      });
    }

    Future<void> chooseCustomer(void Function(void Function()) update) async {
      customerSearch.clear();
      final chosen = await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, refreshPicker) => AlertDialog(
                  title: const Text('Select customer'),
                  content: SizedBox(
                      width: 420,
                      height: 360,
                      child: Column(children: [
                        TextField(
                            controller: customerSearch,
                            autofocus: true,
                            onChanged: (_) => refreshPicker(() {}),
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                hintText: 'Search customers...',
                                border: OutlineInputBorder())),
                        const SizedBox(height: 8),
                        Expanded(
                            child: ListView(children: [
                          for (final customer in customers
                              .where((c) =>
                                  c.name.toLowerCase().contains(
                                      customerSearch.text.toLowerCase()) ||
                                  (c.phone ?? '').contains(customerSearch.text))
                              .take(12))
                            ListTile(
                                leading: const Icon(Icons.person_outline),
                                title: Text(customer.name),
                                subtitle: Text(customer.phone ?? 'No phone'),
                                onTap: () =>
                                    Navigator.pop(dialogContext, customer.id)),
                        ])),
                        const Divider(),
                        ListTile(
                            leading: const Icon(Icons.person_add_outlined),
                            title: const Text('Add new customer'),
                            enabled:
                                widget.user.can(PosPermission.manageContacts),
                            onTap: () =>
                                Navigator.pop(dialogContext, '__new__')),
                        ListTile(
                            leading: const Icon(Icons.person_off_outlined),
                            title: const Text('Use walk-in customer'),
                            onTap: () =>
                                Navigator.pop(dialogContext, '__walkin__')),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'))
                  ],
                )),
      );
      if (chosen == null || !mounted) return;
      if (chosen == '__new__') {
        customerName.clear();
        customerPhone.clear();
        final createNew = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                  title: const Text('Add customer'),
                  content: SizedBox(
                      width: 380,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(
                            controller: customerName,
                            autofocus: true,
                            decoration:
                                const InputDecoration(labelText: 'Name *')),
                        TextField(
                            controller: customerPhone,
                            decoration:
                                const InputDecoration(labelText: 'Phone')),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Create & select')),
                  ],
                ));
        if (createNew != true || customerName.text.trim().isEmpty) return;
        try {
          final added = await widget.directory.saveCustomer(widget.user,
              name: customerName.text, phone: customerPhone.text);
          if (mounted) {
            update(() {
              customers.add(added);
              customerId = added.id;
            });
          }
        } catch (failure) {
          if (mounted) update(() => validation = safeMessage(failure));
        }
      } else {
        update(() => customerId = chosen == '__walkin__' ? null : chosen);
      }
    }

    final editorResult = Completer<bool?>();
    void closeEditor([bool? saved]) {
      if (!editorResult.isCompleted) editorResult.complete(saved);
      if (mounted) setState(() => editor = null);
    }

    Future<void> requestClose() async {
      final changed = editSignature() != initialSignature;
      if (changed) {
        final discard = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Discard quotation changes?'),
            content: const Text('Your unsaved changes will be lost.'),
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
        if (discard != true) return;
      }
      closeEditor();
    }

    try {
      setState(() => editor = StatefulBuilder(
          builder: (context, update) => CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape):
                        requestClose
                  },
                  child: Focus(
                      autofocus: true,
                      child: Material(
                          elevation: 24,
                          clipBehavior: Clip.antiAlias,
                          borderRadius: BorderRadius.circular(20),
                          child: Column(children: [
                            ListTile(
                                leading: IconButton(
                                    tooltip: 'Back',
                                    icon: const Icon(Icons.arrow_back),
                                    onPressed: requestClose),
                                title: Text(existing == null
                                    ? 'New quotation'
                                    : 'Edit quotation'),
                                subtitle: Text(existing == null
                                    ? 'Build a customer price offer before checkout.'
                                    : 'Update this customer price offer.'),
                                trailing: IconButton(
                                    tooltip: 'Close',
                                    icon: const Icon(Icons.close),
                                    onPressed: requestClose)),
                            const Divider(height: 1),
                            Expanded(
                                child: Row(children: [
                              Expanded(
                                  child: ListView(
                                      padding: const EdgeInsets.all(24),
                                      children: [
                                    Text('Customer',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium),
                                    const SizedBox(height: 12),
                                    Align(
                                        alignment: Alignment.centerLeft,
                                        child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxWidth: 520),
                                            child: Card(
                                                child: ListTile(
                                                    leading: const Icon(
                                                        Icons.person_outline),
                                                    title: Text(customers.where((c) => c.id == customerId).firstOrNull?.name ??
                                                        'Walk-in customer'),
                                                    subtitle: Text(customers
                                                            .where((c) =>
                                                                c.id ==
                                                                customerId)
                                                            .firstOrNull
                                                            ?.phone ??
                                                        'No customer selected'),
                                                    trailing: TextButton(
                                                        onPressed: () =>
                                                            chooseCustomer(update),
                                                        child: const Text('Change')))))),
                                    const SizedBox(height: 12),
                                    const Text('VALID UNTIL'),
                                    const SizedBox(height: 8),
                                    Align(
                                        alignment: Alignment.centerLeft,
                                        child: SizedBox(
                                            width: 260,
                                            child: ExpiryDateField(
                                                value: validUntil,
                                                onChanged: (date) => update(
                                                    () => validUntil = date)))),
                                    const Divider(height: 36),
                                    Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text('Items',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium),
                                          Text(
                                              '${lines.length} ${lines.length == 1 ? 'item' : 'items'}'),
                                        ]),
                                    const SizedBox(height: 12),
                                    TextField(
                                        controller: productSearch,
                                        onChanged: (value) => update(
                                            () => searchQuery = value.trim()),
                                        decoration: const InputDecoration(
                                            prefixIcon: Icon(Icons.search),
                                            labelText:
                                                'Search product, SKU, or barcode',
                                            border: OutlineInputBorder())),
                                    if (searchQuery.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Builder(builder: (context) {
                                        final matches = products
                                            .where((p) =>
                                                p.isActive &&
                                                [
                                                  p.name,
                                                  p.sku ?? '',
                                                  p.barcode ?? ''
                                                ].any((part) => part
                                                    .toLowerCase()
                                                    .contains(searchQuery
                                                        .toLowerCase())))
                                            .take(8)
                                            .toList();
                                        return Card(
                                            child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                              if (matches.isEmpty)
                                                Padding(
                                                    padding:
                                                        const EdgeInsets.all(
                                                            12),
                                                    child: Text(
                                                        'No products found for "$searchQuery"')),
                                              for (final product in matches)
                                                ListTile(
                                                    title: Text(product.name),
                                                    subtitle: Text(
                                                        '${formatPeso(product.priceCents)} / ${product.business.unit.label} · ${availabilityMilli[product.id] == null || availabilityMilli[product.id]! <= 0 ? 'Available by order' : '${Quantity.format(availabilityMilli[product.id]!)} available'}'),
                                                    trailing:
                                                        const Icon(Icons.add),
                                                    onTap: () => addCatalog(
                                                        product, update)),
                                              const Divider(height: 1),
                                              const Padding(
                                                  padding: EdgeInsets.fromLTRB(
                                                      16, 8, 16, 0),
                                                  child: Align(
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      child: Text(
                                                          "Can't find it?"))),
                                              Wrap(spacing: 8, children: [
                                                TextButton.icon(
                                                    onPressed: widget.user.can(
                                                            PosPermission
                                                                .manageCatalog)
                                                        ? () =>
                                                            createFromSearch(
                                                                update)
                                                        : null,
                                                    icon: const Icon(
                                                        Icons.add_box_outlined),
                                                    label: const Text(
                                                        'Create new product')),
                                                TextButton.icon(
                                                    onPressed: () =>
                                                        customFromSearch(
                                                            update),
                                                    icon: const Icon(Icons
                                                        .note_add_outlined),
                                                    label: const Text(
                                                        'Add custom quotation item')),
                                              ]),
                                            ]));
                                      }),
                                    ],
                                    if (validation != null)
                                      Padding(
                                          padding:
                                              const EdgeInsets.only(top: 8),
                                          child: Text(validation!,
                                              style: TextStyle(
                                                  color: validation!
                                                          .startsWith('Already')
                                                      ? Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                      : Theme.of(context)
                                                          .colorScheme
                                                          .error))),
                                    const SizedBox(height: 16),
                                    if (lines.isEmpty)
                                      const Card(
                                          child: Padding(
                                              padding: EdgeInsets.all(24),
                                              child: Text(
                                                  'Add a product to build the quotation.'))),
                                    for (final line in lines)
                                      if (line.productId == null)
                                        Card(
                                            child: Padding(
                                                padding:
                                                    const EdgeInsets.all(16),
                                                child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Row(children: [
                                                        Expanded(
                                                            child: Text(
                                                                line.description ??
                                                                    '',
                                                                style: Theme.of(
                                                                        context)
                                                                    .textTheme
                                                                    .titleMedium)),
                                                        Text(formatPeso(
                                                            Quantity.lineCents(
                                                                line.unitPriceCents ??
                                                                    0,
                                                                line.quantityMilli))),
                                                      ]),
                                                      const SizedBox(height: 4),
                                                      const Chip(
                                                          label: Text(
                                                              'Custom item')),
                                                      const Text(
                                                          'Available by order'),
                                                      if (line.customNotes
                                                              ?.isNotEmpty ==
                                                          true)
                                                        Text(line.customNotes!),
                                                      Text(
                                                          '${line.unit} × ${formatPeso(line.unitPriceCents ?? 0)}'),
                                                      Wrap(
                                                          spacing: 8,
                                                          crossAxisAlignment:
                                                              WrapCrossAlignment
                                                                  .center,
                                                          children: [
                                                            const Text('Qty'),
                                                            IconButton(
                                                                tooltip:
                                                                    'Decrease quantity',
                                                                onPressed: line.quantityMilli <=
                                                                        Quantity
                                                                            .scale
                                                                    ? null
                                                                    : () => update(() => lines[
                                                                        lines.indexOf(
                                                                            line)] = QuoteLineRequest.custom(
                                                                        line.description,
                                                                        line.quantityMilli - Quantity.scale,
                                                                        unit: line.unit,
                                                                        unitPriceCents: line.unitPriceCents,
                                                                        customNotes: line.customNotes)),
                                                                icon: const Icon(Icons.remove)),
                                                            Text(Quantity
                                                                .format(line
                                                                    .quantityMilli)),
                                                            IconButton(
                                                                tooltip:
                                                                    'Increase quantity',
                                                                onPressed: () => update(() => lines[lines.indexOf(line)] = QuoteLineRequest.custom(
                                                                    line
                                                                        .description,
                                                                    line.quantityMilli +
                                                                        Quantity
                                                                            .scale,
                                                                    unit: line
                                                                        .unit,
                                                                    unitPriceCents: line
                                                                        .unitPriceCents,
                                                                    customNotes:
                                                                        line.customNotes)),
                                                                icon: const Icon(Icons.add)),
                                                            TextButton(
                                                                onPressed:
                                                                    () async {
                                                                  final edited =
                                                                      await editCustomLine(
                                                                          '',
                                                                          existing:
                                                                              line);
                                                                  if (edited !=
                                                                          null &&
                                                                      mounted) {
                                                                    update(() =>
                                                                        lines[lines.indexOf(line)] =
                                                                            edited);
                                                                  }
                                                                },
                                                                child:
                                                                    const Text(
                                                                        'Edit')),
                                                            TextButton(
                                                                onPressed: () =>
                                                                    update(() =>
                                                                        lines.remove(
                                                                            line)),
                                                                child: const Text(
                                                                    'Remove')),
                                                          ]),
                                                    ])))
                                      else
                                        Card(
                                            child: ListTile(
                                                title: Text(previous[
                                                            line.productId]
                                                        ?.productNameSnapshot ??
                                                    products
                                                        .firstWhere((p) =>
                                                            p.id ==
                                                            line.productId)
                                                        .name),
                                                subtitle: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      if (line.mode !=
                                                          'ordinary')
                                                        Text(modeLabel(
                                                            line.mode)),
                                                      Text(
                                                          '${products.firstWhere((p) => p.id == line.productId).business.unit.label} × ${formatPeso(linePrice(line))}'),
                                                      Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                                  vertical: 4),
                                                          child: Text(
                                                              lineAvailability(
                                                                  line),
                                                              style: TextStyle(
                                                                  color: (availabilityMilli[line.productId] ??
                                                                              0) <
                                                                          line
                                                                              .quantityMilli
                                                                      ? Theme.of(
                                                                              context)
                                                                          .colorScheme
                                                                          .tertiary
                                                                      : Theme.of(
                                                                              context)
                                                                          .colorScheme
                                                                          .primary))),
                                                      SizedBox(
                                                          width: 210,
                                                          child: Row(children: [
                                                            IconButton(
                                                                tooltip:
                                                                    'Decrease quantity',
                                                                icon: const Icon(
                                                                    Icons
                                                                        .remove),
                                                                onPressed: line
                                                                            .quantityMilli <=
                                                                        Quantity
                                                                            .scale
                                                                    ? null
                                                                    : () =>
                                                                        update(
                                                                            () {
                                                                          lines[lines.indexOf(line)] = QuoteLineRequest(
                                                                              line.productId,
                                                                              line.quantityMilli - Quantity.scale,
                                                                              mode: line.mode);
                                                                        })),
                                                            Expanded(
                                                                child:
                                                                    TextFormField(
                                                              key: ValueKey(
                                                                  '${line.productId}-${line.quantityMilli}'),
                                                              initialValue: Quantity
                                                                  .format(line
                                                                      .quantityMilli),
                                                              keyboardType:
                                                                  const TextInputType
                                                                      .numberWithOptions(
                                                                      decimal:
                                                                          true),
                                                              decoration: InputDecoration(
                                                                  labelText: products
                                                                      .firstWhere((p) =>
                                                                          p.id ==
                                                                          line
                                                                              .productId)
                                                                      .business
                                                                      .unit
                                                                      .label,
                                                                  isDense:
                                                                      true),
                                                              onFieldSubmitted:
                                                                  (value) {
                                                                final product =
                                                                    products.firstWhere((p) =>
                                                                        p.id ==
                                                                        line.productId);
                                                                final milli = Quantity.tryParse(
                                                                    value,
                                                                    fractional: product
                                                                        .business
                                                                        .fractional);
                                                                if (milli ==
                                                                        null ||
                                                                    milli <=
                                                                        0) {
                                                                  update(() =>
                                                                      validation =
                                                                          'Enter a valid quantity for ${product.name}.');
                                                                  return;
                                                                }
                                                                update(() {
                                                                  lines[lines
                                                                      .indexOf(
                                                                          line)] = QuoteLineRequest(
                                                                      line
                                                                          .productId,
                                                                      milli,
                                                                      mode: line
                                                                          .mode);
                                                                  validation =
                                                                      null;
                                                                });
                                                              },
                                                            )),
                                                            IconButton(
                                                                tooltip:
                                                                    'Increase quantity',
                                                                icon: const Icon(
                                                                    Icons.add),
                                                                onPressed:
                                                                    () =>
                                                                        update(
                                                                            () {
                                                                          lines[lines.indexOf(line)] = QuoteLineRequest(
                                                                              line.productId,
                                                                              line.quantityMilli + Quantity.scale,
                                                                              mode: line.mode);
                                                                        })),
                                                          ])),
                                                    ]),
                                                trailing: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(formatPeso(
                                                          Quantity.lineCents(
                                                              linePrice(line),
                                                              line.quantityMilli))),
                                                      if (line.mode !=
                                                          'ordinary')
                                                        TextButton(
                                                            child: const Text(
                                                                'Configure'),
                                                            onPressed:
                                                                () async {
                                                              final product = products
                                                                  .firstWhere((p) =>
                                                                      p.id ==
                                                                      line.productId);
                                                              final mode =
                                                                  await configureMode(
                                                                      product);
                                                              if (mode ==
                                                                      null ||
                                                                  !context
                                                                      .mounted) {
                                                                return;
                                                              }
                                                              update(() => lines[
                                                                  lines.indexOf(
                                                                      line)] = QuoteLineRequest(
                                                                  line.productId,
                                                                  line.quantityMilli,
                                                                  mode: mode));
                                                            }),
                                                      IconButton(
                                                          tooltip:
                                                              'Remove quotation item',
                                                          icon: const Icon(
                                                              Icons.close),
                                                          onPressed: () =>
                                                              update(() =>
                                                                  lines.remove(
                                                                      line)))
                                                    ]))),
                                    const Divider(height: 36),
                                    Text('CUSTOMER NOTES / TERMS',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge),
                                    const SizedBox(height: 8),
                                    TextField(
                                        controller: notes,
                                        maxLines: 3,
                                        decoration: const InputDecoration(
                                            hintText:
                                                'Terms, delivery details, or a message to the customer',
                                            helperText:
                                                'Shown on the quotation PDF.',
                                            border: OutlineInputBorder())),
                                    const SizedBox(height: 16),
                                    if (!wide) ...[
                                      TransactionTotal(
                                          'Subtotal', quoteTotal()),
                                      TransactionTotal('Total', quoteTotal(),
                                          strong: true),
                                    ],
                                  ])),
                              if (wide)
                                SizedBox(
                                    width: 330,
                                    child: ColoredBox(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerLow,
                                        child: Column(children: [
                                          Expanded(
                                              child: SingleChildScrollView(
                                                  padding:
                                                      const EdgeInsets.all(16),
                                                  child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                            'Quotation summary',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .titleLarge),
                                                        const SizedBox(
                                                            height: 10),
                                                        Text('Customer',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .labelMedium),
                                                        Text(customers
                                                                .where((c) =>
                                                                    c.id ==
                                                                    customerId)
                                                                .firstOrNull
                                                                ?.name ??
                                                            'Walk-in customer'),
                                                        const SizedBox(
                                                            height: 8),
                                                        Text('Valid until',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .labelMedium),
                                                        Text(validUntil == null
                                                            ? 'No expiry'
                                                            : MaterialLocalizations
                                                                    .of(context)
                                                                .formatMediumDate(
                                                                    validUntil!)),
                                                        const SizedBox(
                                                            height: 8),
                                                        Text('Items',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .labelMedium),
                                                        Text('${lines.length}'),
                                                        const Divider(
                                                            height: 20),
                                                        TransactionTotal(
                                                            'Subtotal',
                                                            quoteTotal()),
                                                        const TransactionTotal(
                                                            'Discount', 0),
                                                        TransactionTotal(
                                                            'Total',
                                                            quoteTotal(),
                                                            strong: true),
                                                        const Divider(
                                                            height: 20),
                                                        Text('Availability',
                                                            style: Theme.of(
                                                                    context)
                                                                .textTheme
                                                                .labelMedium),
                                                        Text(
                                                            '${lines.where((line) => (availabilityMilli[line.productId] ?? 0) >= line.quantityMilli).length} ready · ${lines.where((line) => (availabilityMilli[line.productId] ?? 0) < line.quantityMilli).length} available by order'),
                                                        const SizedBox(
                                                            height: 8),
                                                        const Text(
                                                            'ⓘ Stock is not reserved. Availability is checked again at sale.'),
                                                      ]))),
                                          Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      16, 8, 16, 12),
                                              child: Column(children: [
                                                if (lines.isEmpty)
                                                  Text(
                                                      'Add at least one item to save.',
                                                      style: TextStyle(
                                                          color:
                                                              Theme.of(context)
                                                                  .colorScheme
                                                                  .error)),
                                                SizedBox(
                                                    width: double.infinity,
                                                    child: FilledButton(
                                                        onPressed: lines.isEmpty
                                                            ? null
                                                            : () => closeEditor(
                                                                true),
                                                        child: Text(existing ==
                                                                null
                                                            ? 'Save quotation'
                                                            : 'Save changes'))),
                                                SizedBox(
                                                    width: double.infinity,
                                                    child: TextButton(
                                                        onPressed: requestClose,
                                                        child: const Text(
                                                            'Cancel'))),
                                              ])),
                                        ]))),
                            ])),
                            if (!wide)
                              Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Wrap(
                                      alignment: WrapAlignment.end,
                                      spacing: 12,
                                      runSpacing: 8,
                                      children: [
                                        TextButton(
                                            onPressed: requestClose,
                                            child: const Text('Cancel')),
                                        FilledButton(
                                            onPressed: lines.isEmpty
                                                ? null
                                                : () => closeEditor(true),
                                            child: Text(existing == null
                                                ? 'Save quotation'
                                                : 'Save changes'))
                                      ])),
                          ]))))));
      final confirmed = await editorResult.future;
      if (confirmed != true) return;
      if (existing == null) {
        await widget.repository.create(widget.user, lines,
            customerId: customerId, notes: notes.text, validUntil: validUntil);
      } else {
        await widget.repository.update(widget.user, existing.id, lines,
            customerId: customerId, notes: notes.text, validUntil: validUntil);
      }
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      notes.dispose();
      customerSearch.dispose();
      customerName.dispose();
      customerPhone.dispose();
      productSearch.dispose();
    }
  }

  Future<void> convert(Quotation quote) async {
    final approved = await reviewConversion(quote);
    if (!approved || !mounted) return;
    if (widget.auth != null) {
      await Navigator.of(context).push<String>(MaterialPageRoute(
          builder: (_) => CheckoutScreen(
              repository: widget.products,
              user: widget.user,
              auth: widget.auth!,
              receipts: widget.receipts,
              quotationId: quote.id,
              quotationReference: quote.reference)));
      await refresh();
      return;
    }
    final amount = TextEditingController();
    final serialSelections = <String, Set<String>>{};
    final batchSelections = <String, String>{};
    try {
      final items = await widget.repository.items(quote.id);
      final serialOptions = <String, List<SerialUnit>>{};
      final batchOptions = <String, List<ProductLot>>{};
      for (final item in items) {
        final product =
            products.where((p) => p.id == item.productId).firstOrNull;
        if (product == null || !product.isActive) {
          throw StateError(
              '${item.productNameSnapshot} is no longer sellable. Review the quotation before checkout.');
        }
        final available = await widget.products.stockMilli(item.productId!);
        if (!product.business.madeToOrder && available < item.quantityMilli) {
          throw StateError(
              'Stock changed for ${item.productNameSnapshot}. Quoted: ${Quantity.format(item.quantityMilli)} ${item.unitSnapshot}; available: ${Quantity.format(available)}. Review the quotation before checkout.');
        }
        if (product.serialTracking) {
          serialOptions[item.productId!] =
              await widget.products.availableSerials(item.productId!);
          final needed = item.quantityMilli ~/ Quantity.scale;
          final count = serialOptions[item.productId]!.length;
          if (count < needed) {
            throw StateError(
                '$needed units were quoted, but only $count sellable serialized units are currently available for ${item.productNameSnapshot}.');
          }
        }
        if (product.business.batch) {
          batchOptions[item.productId!] =
              await widget.products.batches(item.productId!);
        }
      }
      if (!mounted) return;
      final total = items.fold<int>(0, (sum, i) => sum + i.lineTotalCents);
      amount.text = (total / 100).toStringAsFixed(2);
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text('Convert ${quote.reference}'),
                    content: SizedBox(
                        width: 420,
                        height: 350,
                        child: ListView(children: [
                          Text('Quoted total: ${formatPeso(total)}'),
                          TextField(
                              controller: amount,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'Cash received (pesos)')),
                          for (final item in items) ...[
                            Text(products
                                    .where((p) => p.id == item.productId)
                                    .firstOrNull
                                    ?.name ??
                                'Product'),
                            if (batchOptions[item.productId] != null)
                              DropdownButtonFormField<String>(
                                  decoration:
                                      const InputDecoration(labelText: 'Batch'),
                                  items: [
                                    for (final batch
                                        in batchOptions[item.productId]!)
                                      DropdownMenuItem(
                                          value: batch.id,
                                          child: Text(batch.batchNumber))
                                  ],
                                  onChanged: (value) => update(() {
                                        if (value != null) {
                                          batchSelections[item.productId!] =
                                              value;
                                        }
                                      })),
                            for (final serial
                                in serialOptions[item.productId] ??
                                    <SerialUnit>[])
                              CheckboxListTile(
                                  title: Text(serial.serialNumber),
                                  value: serialSelections[item.productId]
                                          ?.contains(serial.id) ??
                                      false,
                                  onChanged: (value) => update(() {
                                        final selected =
                                            serialSelections.putIfAbsent(
                                                item.productId!,
                                                () => <String>{});
                                        if (value == true) {
                                          selected.add(serial.id);
                                        } else {
                                          selected.remove(serial.id);
                                        }
                                      })),
                          ],
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Complete sale'))
                    ],
                  )));
      if (confirmed != true) return;
      for (final item in items) {
        if (serialOptions.containsKey(item.productId) &&
            (serialSelections[item.productId]?.length ?? 0) !=
                item.quantityMilli ~/ Quantity.scale) {
          throw StateError(
              'Select exactly ${item.quantityMilli ~/ Quantity.scale} serials for ${item.productNameSnapshot}.');
        }
      }
      final cents = tryParsePeso(amount.text);
      if (cents == null || cents < total) {
        throw StateError('Cash received is below quoted total');
      }
      await widget.repository.convertCash(widget.user, quote.id, cents,
          serialIds: serialSelections
              .map((key, value) => MapEntry(key, value.toList())),
          batchIds: batchSelections);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      amount.dispose();
    }
  }

  Future<void> sourceItem(Quotation quote, QuotationItem item) async {
    final available = await widget.products.stockMilli(item.productId!);
    final suppliers = (await widget.directory.suppliers())
        .where((supplier) => supplier.isActive)
        .toList();
    if (!mounted) return;
    String? supplierId;
    final notes = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, update) => AlertDialog(
                    title: const Text('Source from supplier'),
                    content: SizedBox(
                        width: 420,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          ListTile(
                              title: Text(item.productNameSnapshot),
                              subtitle: Text(
                                  'Needed ${Quantity.format(item.quantityMilli)} · Currently available ${Quantity.format(available)} · Need to source ${Quantity.format((item.quantityMilli - available).clamp(0, item.quantityMilli))}')),
                          DropdownButtonFormField<String?>(
                              initialValue: supplierId,
                              decoration: const InputDecoration(
                                  labelText: 'Preferred supplier'),
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null, child: Text('No preference')),
                                for (final supplier in suppliers)
                                  DropdownMenuItem<String?>(
                                      value: supplier.id,
                                      child: Text(supplier.name))
                              ],
                              onChanged: (value) =>
                                  update(() => supplierId = value)),
                          TextField(
                              controller: notes,
                              decoration:
                                  const InputDecoration(labelText: 'Notes')),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Create sourcing requirement')),
                    ],
                  )));
      if (confirmed != true) return;
      await widget.repository.requestSourcing(
          widget.user, quote.id, item.productId!,
          preferredSupplierId: supplierId, notes: notes.text);
      if (mounted) {
        await refresh();
        if (!mounted) return;
        await showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                  title: const Text('✓ Sourcing requirement created'),
                  content: SizedBox(
                      width: 460,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Product: ${item.productNameSnapshot}'),
                            Text(
                                'Quantity: ${Quantity.format((item.quantityMilli - available).clamp(0, item.quantityMilli))}'),
                            Text(
                                'Supplier: ${suppliers.where((s) => s.id == supplierId).firstOrNull?.name ?? 'Not selected'}'),
                            const SizedBox(height: 16),
                            const Text(
                                'Stock remains unchanged until Receiving is finalized.'),
                            const SizedBox(height: 12),
                            const Text(
                                'Next step: Create a Purchase Order for the shortage.'),
                          ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Back to quotation')),
                    if (widget.onCreatePurchaseOrder != null)
                      FilledButton.icon(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            widget.onCreatePurchaseOrder!(
                                item.productId!,
                                supplierId,
                                (item.quantityMilli - available)
                                    .clamp(0, item.quantityMilli),
                                quote.reference);
                          },
                          icon: const Icon(Icons.shopping_bag_outlined),
                          label: const Text('Create Purchase Order')),
                    if (widget.onReceiveStock != null)
                      TextButton.icon(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            widget.onReceiveStock!(
                                item.productId!,
                                supplierId,
                                (item.quantityMilli - available)
                                    .clamp(0, item.quantityMilli),
                                quote.reference);
                          },
                          icon: const Icon(Icons.inventory_2_outlined),
                          label: const Text('Receive directly')),
                  ],
                ));
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      notes.dispose();
    }
  }

  Future<String?> chooseProductForCustomItem(QuotationItem item) async {
    final catalog = (await widget.products.products())
        .where((product) => product.isActive)
        .toList();
    final stock = await widget.products.stockLevels();
    if (!mounted) return null;
    final search = TextEditingController(text: item.productNameSnapshot);
    String? selectedId;
    try {
      return await showDialog<String>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, update) => AlertDialog(
                    title: const Text('Link quotation item to Inventory'),
                    content: SizedBox(
                        width: 500,
                        height: 420,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Quotation item: ${item.productNameSnapshot}'),
                              Text(
                                  'Quoted price: ${formatPeso(item.unitPriceCents)}'),
                              const Text(
                                  'The quoted selling price will remain unchanged.'),
                              const SizedBox(height: 12),
                              TextField(
                                  controller: search,
                                  onChanged: (_) => update(() {}),
                                  decoration: const InputDecoration(
                                      labelText:
                                          'Search product, SKU, or barcode',
                                      border: OutlineInputBorder())),
                              Expanded(
                                  child: ListView(children: [
                                for (final product in catalog
                                    .where((product) => [
                                          product.name,
                                          product.sku ?? '',
                                          product.barcode ?? ''
                                        ].any((part) => part
                                            .toLowerCase()
                                            .contains(search.text
                                                .trim()
                                                .toLowerCase())))
                                    .take(12))
                                  ListTile(
                                      leading: Icon(selectedId == product.id
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_unchecked),
                                      title: Text(product.name),
                                      subtitle: Text(
                                          'SKU ${product.sku ?? '—'} · Current price ${formatPeso(product.priceCents)} · ${Quantity.format(stock[product.id] == null ? 0 : stock[product.id]!.$1 - stock[product.id]!.$2)} available'),
                                      onTap: () => update(
                                          () => selectedId = product.id)),
                              ])),
                            ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: selectedId == null
                              ? null
                              : () => Navigator.pop(dialogContext, selectedId),
                          child: const Text('Link product')),
                    ],
                  )));
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      search.dispose();
    }
  }

  Future<void> resolveCustomItem(
      Quotation quote, QuotationItem item, String action) async {
    try {
      if (action == 'remove') {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                  title: const Text('Remove from conversion?'),
                  content: const Text(
                      'Open the quotation editor and remove this item deliberately. The saved quotation is not changed yet.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Edit quotation')),
                  ],
                ));
        if (confirmed != true || !mounted) return;
        await create(existing: quote);
        return;
      }
      String? productId;
      if (action == 'create') {
        final created = await quickCreateProduct(item.productNameSnapshot,
            suggestedPriceCents: item.unitPriceCents,
            suggestedUnit: item.unitSnapshot,
            fromConversion: true);
        productId = created?.id;
      } else {
        productId = await chooseProductForCustomItem(item);
      }
      if (productId == null || !mounted) return;
      await widget.repository
          .linkCustomItem(widget.user, quote.id, item.id, productId);
      await refresh();
      if (mounted) {
        final linkedItem = (await widget.repository.items(quote.id))
            .firstWhere((candidate) => candidate.id == item.id);
        final available = await widget.products.stockMilli(productId);
        if (!mounted) return;
        final next = await showDialog<String>(
            context: context,
            builder: (dialogContext) => AlertDialog(
                  title: Text(action == 'create'
                      ? '✓ Product created'
                      : '✓ Product linked'),
                  content: SizedBox(
                      width: 460,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.productNameSnapshot),
                            Text(
                                'Quoted price: ${formatPeso(item.unitPriceCents)}'),
                            Text(
                                'Current stock: ${Quantity.format(available)}'),
                            const SizedBox(height: 12),
                            Text(available < item.quantityMilli
                                ? 'Next step: Source the item from a supplier.'
                                : 'Ready for checkout.'),
                          ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext, 'back'),
                        child: const Text('Back to quotation')),
                    if (available < item.quantityMilli)
                      FilledButton(
                          onPressed: () =>
                              Navigator.pop(dialogContext, 'source'),
                          child: const Text('Source from supplier')),
                  ],
                ));
        if (next == 'source') await sourceItem(quote, linkedItem);
        if (mounted && next != null) {
          await refresh();
          final updated = rows.where((row) => row.id == quote.id).firstOrNull;
          if (updated != null && mounted) await showQuote(updated);
        }
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<bool> reviewConversion(Quotation quote) async {
    final items = await widget.repository.items(quote.id);
    final catalog = await widget.products.products();
    final stock = await widget.products.stockLevels();
    var ready = items.isNotEmpty;
    var unresolved = 0;
    final cards = <Widget>[];
    final missingItems = <QuotationItem>[];
    final bulkCandidates =
        <({QuotationItem item, int quantityMilli, String? supplierId})>[];
    final customItems = <QuotationItem>[];
    final requests = await widget.repository.sourcing(quote.id);
    final purchaseOrders = PurchaseOrderRepository(widget.repository.db);
    final orderProgress = await Future.wait((await purchaseOrders.list())
        .map((order) => purchaseOrders.detail(order.id)));
    final sourceLinks = await widget.repository.db
        .select(widget.repository.db.purchaseOrderLineSourceLinks)
        .get();
    for (final item in items) {
      if (item.productId == null) {
        ready = false;
        unresolved++;
        customItems.add(item);
        cards.add(_issueCard(
            item,
            'Needs product link',
            'This custom item is not linked to Inventory.',
            widget.user.can(PosPermission.manageCatalog)
                ? 'Create product'
                : 'Link existing product',
            () {
              Navigator.pop(context, false);
              resolveCustomItem(
                  quote,
                  item,
                  widget.user.can(PosPermission.manageCatalog)
                      ? 'create'
                      : 'link');
            },
            secondary: widget.user.can(PosPermission.manageCatalog)
                ? () {
                    Navigator.pop(context, false);
                    resolveCustomItem(quote, item, 'link');
                  }
                : null,
            remove: () {
              Navigator.pop(context, false);
              resolveCustomItem(quote, item, 'remove');
            }));
        continue;
      }
      final product = catalog.where((p) => p.id == item.productId).firstOrNull;
      if (product == null || !product.isActive) {
        ready = false;
        unresolved++;
        cards.add(_issueCard(
            item,
            'Blocked',
            'The linked Inventory product is no longer sellable.',
            'Edit quotation', () {
          Navigator.pop(context, false);
          create(existing: quote);
        }));
        continue;
      }
      final available = stock[item.productId] == null
          ? 0
          : stock[item.productId]!.$1 - stock[item.productId]!.$2;
      if (!product.business.madeToOrder && available < item.quantityMilli) {
        ready = false;
        unresolved++;
        missingItems.add(item);
        final request =
            requests.where((r) => r.productId == item.productId).firstOrNull;
        final shortage =
            (item.quantityMilli - available).clamp(0, item.quantityMilli);
        final relatedOrders = orderProgress
            .where((progress) =>
                progress.lines.any((line) =>
                    line.productId == item.productId &&
                    sourceLinks.any((s) =>
                        s.purchaseOrderLineId == line.id &&
                        s.quotationId == quote.id)) &&
                {'draft', 'sent', 'partially_received'}
                    .contains(progress.status))
            .toList();
        final incoming = relatedOrders.fold<int>(
            0,
            (total, progress) =>
                total +
                progress.lines
                    .where((line) => line.productId == item.productId)
                    .fold<int>(
                        0,
                        (sum, line) =>
                            sum +
                            sourceLinks
                                .where((s) =>
                                    s.purchaseOrderLineId == line.id &&
                                    s.quotationId == quote.id)
                                .fold<int>(
                                    0,
                                    (subtotal, source) =>
                                        subtotal +
                                        source.plannedQtyMilli -
                                        PurchaseOrderRepository.receivedForSource(
                                            source,
                                            sourceLinks.where((s) =>
                                                s.purchaseOrderLineId == line.id),
                                            progress.received[line.id] ?? 0))));
        final stillToOrder = (shortage - incoming).clamp(0, shortage);
        if (stillToOrder > 0) {
          bulkCandidates.add((
            item: item,
            quantityMilli: stillToOrder,
            supplierId: request?.preferredSupplierId
          ));
        }
        final partiallyReceived = relatedOrders.any((progress) => progress.lines
            .where((line) => line.productId == item.productId)
            .any((line) => (progress.received[line.id] ?? 0) > 0));
        final order = relatedOrders.firstOrNull;
        final eligibleDrafts = orderProgress
            .where((progress) =>
                progress.status == 'draft' &&
                progress.receivings.isEmpty &&
                (request?.preferredSupplierId == null ||
                    progress.order.supplierId == request!.preferredSupplierId))
            .toList();
        final orderLabel = relatedOrders.map((progress) {
          final lines =
              progress.lines.where((line) => line.productId == item.productId);
          final sources = [
            for (final line in lines)
              ...sourceLinks.where((s) =>
                  s.purchaseOrderLineId == line.id && s.quotationId == quote.id)
          ];
          final ordered = sources.fold<int>(
              0, (sum, source) => sum + source.plannedQtyMilli);
          final received = sources.fold<int>(
              0,
              (sum, source) =>
                  sum +
                  PurchaseOrderRepository.receivedForSource(
                      source,
                      sourceLinks.where((s) =>
                          s.purchaseOrderLineId == source.purchaseOrderLineId),
                      progress.received[source.purchaseOrderLineId] ?? 0));
          final expected = progress.order.expectedDeliveryDate;
          final overdue = expected != null &&
              progress.status != 'draft' &&
              expected.isBefore(DateTime.now());
          return '${PurchaseOrderRepository.number(progress.order)} · ${progress.status == 'draft' ? 'Draft order' : progress.status == 'partially_received' ? 'Partially received' : 'Sent'}${overdue ? ' · Overdue' : ''} · ${Quantity.format(ordered)} planned · ${Quantity.format(received)} received · ${Quantity.format((ordered - received).clamp(0, ordered))} incoming${expected == null ? '' : ' · Expected ${MaterialLocalizations.of(context).formatMediumDate(expected)}'}';
        }).join('\n');
        cards.add(_issueCard(
            item,
            partiallyReceived
                ? 'Partially received'
                : incoming >= shortage
                    ? (order?.status == 'draft' ? 'Draft order' : 'Ordered')
                    : 'Needs sourcing',
            'Quoted: ${Quantity.format(item.quantityMilli)} ${item.unitSnapshot}\nAvailable: ${Quantity.format(available)}\nIncoming: ${Quantity.format(incoming)}\nStill needed to order: ${Quantity.format(stillToOrder)}${order == null ? '' : '\n$orderLabel'}',
            widget.onCreatePurchaseOrder == null
                ? 'Request sourcing'
                : stillToOrder == 0 && order != null
                    ? 'View Purchase Order'
                    : 'Create Purchase Order', () {
          Navigator.pop(context, false);
          if (widget.onCreatePurchaseOrder == null) {
            sourceItem(quote, item);
          } else if (stillToOrder == 0 && order != null) {
            if (widget.onViewPurchaseOrder != null) {
              widget.onViewPurchaseOrder!(order.order.id, quote.reference);
            } else {
              widget.onCreatePurchaseOrder?.call('', null, 0, quote.reference);
            }
          } else {
            widget.onCreatePurchaseOrder?.call(
                item.productId!,
                request?.preferredSupplierId ?? order?.order.supplierId,
                stillToOrder,
                quote.reference);
          }
        },
            viewOrder: order != null &&
                    stillToOrder > 0 &&
                    widget.onViewPurchaseOrder != null
                ? () {
                    Navigator.pop(context, false);
                    widget.onViewPurchaseOrder!(
                        order.order.id, quote.reference);
                  }
                : null,
            addToOrder: stillToOrder > 0 &&
                    eligibleDrafts.isNotEmpty &&
                    widget.onAddToPurchaseOrder != null
                ? () async {
                    Navigator.pop(context, false);
                    final suppliers = await widget.directory.suppliers();
                    if (!mounted) return;
                    final selected = await showDialog<PurchaseOrderProgress>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                              title: const Text('Add to existing Draft PO'),
                              content: SizedBox(
                                  width: 480,
                                  height: (eligibleDrafts.length * 72.0)
                                      .clamp(72.0, 420.0),
                                  child: ListView(shrinkWrap: true, children: [
                                    for (final draft in eligibleDrafts)
                                      ListTile(
                                          title: Text(
                                              PurchaseOrderRepository.number(
                                                  draft.order)),
                                          subtitle: Text(
                                              '${suppliers.where((s) => s.id == draft.order.supplierId).firstOrNull?.name ?? 'Supplier'} · Draft · ${draft.lines.length} items${draft.order.expectedDeliveryDate == null ? '' : ' · Expected ${MaterialLocalizations.of(dialogContext).formatMediumDate(draft.order.expectedDeliveryDate!)}'}'),
                                          onTap: () => Navigator.pop(
                                              dialogContext, draft))
                                  ])),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext),
                                    child: const Text('Cancel'))
                              ],
                            ));
                    if (selected != null) {
                      widget.onAddToPurchaseOrder!(selected.order.id,
                          item.productId!, stillToOrder, quote.reference);
                    }
                  }
                : null,
            receiveDirectly: widget.onReceiveStock == null
                ? null
                : () {
                    Navigator.pop(context, false);
                    widget.onReceiveStock!(
                        item.productId!,
                        request?.preferredSupplierId,
                        shortage,
                        quote.reference);
                  }));
        continue;
      }
      if (product.serialTracking) {
        final serials = await widget.products.availableSerials(item.productId!);
        final needed = item.quantityMilli ~/ Quantity.scale;
        if (serials.length < needed) {
          ready = false;
          unresolved++;
          missingItems.add(item);
          cards.add(_issueCard(
              item,
              'Needs sourcing',
              '$needed serialized units required; ${serials.length} available.',
              widget.onCreatePurchaseOrder == null
                  ? 'Request sourcing'
                  : 'Create Purchase Order', () {
            Navigator.pop(context, false);
            if (widget.onCreatePurchaseOrder == null) {
              sourceItem(quote, item);
            } else {
              widget.onCreatePurchaseOrder!.call(
                  item.productId!,
                  null,
                  (item.quantityMilli - serials.length * Quantity.scale)
                      .clamp(0, item.quantityMilli),
                  quote.reference);
            }
          },
              receiveDirectly: widget.onReceiveStock == null
                  ? null
                  : () {
                      Navigator.pop(context, false);
                      widget.onReceiveStock!(
                          item.productId!,
                          null,
                          (item.quantityMilli - serials.length * Quantity.scale)
                              .clamp(0, item.quantityMilli),
                          quote.reference);
                    }));
          continue;
        }
        cards.add(_issueCard(
            item,
            'Ready',
            'Select $needed serial${needed == 1 ? '' : 's'} during checkout.',
            null,
            null));
      } else if (product.business.batch) {
        cards.add(_issueCard(item, 'Ready',
            'Choose an eligible batch during checkout.', null, null));
      } else {
        cards.add(_issueCard(
            item,
            'Ready',
            modeLabel(item.saleMode).isEmpty
                ? 'Ready for checkout'
                : '${modeLabel(item.saleMode)} carried to checkout.',
            null,
            null));
      }
    }
    if (!mounted) return false;
    final selectedForPo =
        bulkCandidates.map((candidate) => candidate.item.id).toSet();
    return await showDialog<bool>(
            context: context,
            builder: (context) => StatefulBuilder(
                builder: (context, update) => AlertDialog(
                        title: Text(ready
                            ? 'Quotation ready to convert'
                            : 'Quotation needs attention'),
                        content: SizedBox(
                            width: 600,
                            child: ListView(shrinkWrap: true, children: [
                              Text(ready
                                  ? '${items.length} of ${items.length} items ready'
                                  : '${items.length - unresolved} of ${items.length} items ready · $unresolved require action'),
                              Wrap(spacing: 6, runSpacing: 4, children: [
                                Chip(
                                    label: Text(
                                        '${items.length - unresolved} Ready')),
                                if (missingItems.isNotEmpty)
                                  Chip(
                                      label: Text(
                                          '${missingItems.length} Needs sourcing')),
                                if (customItems.isNotEmpty)
                                  Chip(
                                      label: Text(
                                          '${customItems.length} Needs product link')),
                                if (unresolved >
                                    missingItems.length + customItems.length)
                                  Chip(
                                      label: Text(
                                          '${unresolved - missingItems.length - customItems.length} Blocked')),
                              ]),
                              const SizedBox(height: 12),
                              if (bulkCandidates.length > 1 &&
                                  widget.onCreatePurchaseOrderForLines != null)
                                Card(
                                    child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('Order selected shortages',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall),
                                      for (final candidate in bulkCandidates)
                                        CheckboxListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          title: Text(candidate
                                              .item.productNameSnapshot),
                                          subtitle: Text(
                                              'Need ${Quantity.format(candidate.quantityMilli)} ${candidate.item.unitSnapshot}'),
                                          value: selectedForPo
                                              .contains(candidate.item.id),
                                          onChanged: (checked) => update(() {
                                            if (checked == true) {
                                              selectedForPo
                                                  .add(candidate.item.id);
                                            } else {
                                              selectedForPo
                                                  .remove(candidate.item.id);
                                            }
                                          }),
                                        ),
                                      if (bulkCandidates
                                              .where((candidate) =>
                                                  selectedForPo.contains(
                                                      candidate.item.id))
                                              .map((candidate) =>
                                                  candidate.supplierId)
                                              .toSet()
                                              .length >
                                          1)
                                        const Text(
                                            'Select items with the same preferred supplier for one PO.'),
                                      FilledButton(
                                        onPressed: selectedForPo.length < 2 ||
                                                bulkCandidates
                                                        .where((candidate) =>
                                                            selectedForPo
                                                                .contains(
                                                                    candidate
                                                                        .item
                                                                        .id))
                                                        .map((candidate) =>
                                                            candidate
                                                                .supplierId)
                                                        .toSet()
                                                        .length !=
                                                    1
                                            ? null
                                            : () {
                                                final selected = bulkCandidates
                                                    .where((candidate) =>
                                                        selectedForPo.contains(
                                                            candidate.item.id))
                                                    .toList();
                                                Navigator.pop(context, false);
                                                widget.onCreatePurchaseOrderForLines!(
                                                    [
                                                      for (final candidate
                                                          in selected)
                                                        (
                                                          productId: candidate
                                                              .item.productId!,
                                                          quantityMilli:
                                                              candidate
                                                                  .quantityMilli
                                                        )
                                                    ],
                                                    selected.first.supplierId,
                                                    quote.reference);
                                              },
                                        child: const Text(
                                            'Create Purchase Order for selected'),
                                      ),
                                    ],
                                  ),
                                )),
                              ...cards,
                            ])),
                        actions: [
                          if (!ready)
                            TextButton(
                                onPressed: () {
                                  Navigator.pop(context, false);
                                  create(existing: quote);
                                },
                                child: const Text('Edit quotation')),
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel conversion')),
                          FilledButton(
                              onPressed: ready
                                  ? () => Navigator.pop(context, true)
                                  : null,
                              child: const Text('Continue to checkout')),
                          if (!ready)
                            Text('Resolve $unresolved items before checkout.'),
                        ]))) ??
        false;
  }

  Widget _issueCard(QuotationItem item, String status, String detail,
          String? action, VoidCallback? onAction,
          {VoidCallback? secondary,
          VoidCallback? remove,
          VoidCallback? viewOrder,
          VoidCallback? addToOrder,
          VoidCallback? receiveDirectly}) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.productNameSnapshot,
                style: Theme.of(context).textTheme.titleMedium),
            Chip(label: Text(status)),
            const SizedBox(height: 8),
            Text(detail),
            if (action != null) ...[
              const SizedBox(height: 12),
              const Text('Recommended next step'),
              const SizedBox(height: 6),
              FilledButton(onPressed: onAction, child: Text(action)),
            ],
            if (secondary != null)
              TextButton(
                  onPressed: secondary,
                  child: const Text('Link existing product')),
            if (addToOrder != null)
              OutlinedButton(
                  onPressed: addToOrder,
                  child: const Text('Add to existing PO')),
            if (viewOrder != null)
              TextButton(
                  onPressed: viewOrder,
                  child: const Text('View Purchase Order')),
            if (receiveDirectly != null)
              TextButton(
                  onPressed: receiveDirectly,
                  child: const Text('Receive directly')),
            if (remove != null)
              PopupMenuButton<String>(
                tooltip: 'More actions',
                onSelected: (_) => remove(),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'remove', child: Text('Remove from sale'))
                ],
                child: const Padding(
                    padding: EdgeInsets.all(8), child: Text('More actions')),
              ),
          ]),
        ),
      );

  Future<void> _cancelFromDetail(
      Quotation quote, BuildContext detailContext) async {
    final confirmed = await showDialog<bool>(
        context: detailContext,
        builder: (context) => AlertDialog(
              title: const Text('Cancel quotation?'),
              content: Text(
                  '${quote.reference} will remain readable, but cannot be converted.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep quotation')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Cancel quotation')),
              ],
            ));
    if (confirmed != true) return;
    try {
      await widget.repository.cancel(widget.user, quote.id);
      if (detailContext.mounted) Navigator.pop(detailContext);
      await refresh();
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> showQuote(Quotation quote) async {
    final items = await widget.repository.items(quote.id);
    String itemAvailability(QuotationItem item) {
      if (item.productId == null) return 'Custom item · Available by order';
      final product = products.where((p) => p.id == item.productId).firstOrNull;
      if (product?.business.madeToOrder == true) return 'Available by order';
      return (availabilityMilli[item.productId] ?? 0) < item.quantityMilli
          ? 'Awaiting stock'
          : 'Ready';
    }

    final poRepository = PurchaseOrderRepository(widget.repository.db);
    final sources = await poRepository.sourceLinksForQuotation(quote.id);
    final allSourceLinks = await widget.repository.db
        .select(widget.repository.db.purchaseOrderLineSourceLinks)
        .get();
    final sourcedOrders = <({
      PurchaseOrderProgress progress,
      PurchaseOrderLineSourceLink source
    })>[];
    final linkedLines = sources.isEmpty
        ? <PurchaseOrderLine>[]
        : await (widget.repository.db
                .select(widget.repository.db.purchaseOrderLines)
              ..where((line) =>
                  line.id.isIn(sources.map((s) => s.purchaseOrderLineId))))
            .get();
    for (final orderId
        in linkedLines.map((line) => line.purchaseOrderId).toSet()) {
      final progress = await poRepository.detail(orderId);
      for (final source in sources) {
        if (progress.lines
            .any((line) => line.id == source.purchaseOrderLineId)) {
          sourcedOrders.add((progress: progress, source: source));
        }
      }
    }
    final sale = quote.convertedSaleId == null
        ? null
        : await (widget.repository.db.select(widget.repository.db.sales)
              ..where((s) => s.id.equals(quote.convertedSaleId!)))
            .getSingleOrNull();
    final needsNextStep = (quoteUnlinkedCounts[quote.id] ?? 0) > 0 ||
        (quoteAwaitingCounts[quote.id] ?? 0) > 0 ||
        (quoteOrderedCounts[quote.id] ?? 0) > 0;
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
            clipBehavior: Clip.antiAlias,
            insetPadding: const EdgeInsets.all(16),
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * .9 < 1200
                        ? MediaQuery.sizeOf(context).width * .9
                        : 1200,
                    maxHeight: MediaQuery.sizeOf(context).height * .88),
                child: Column(children: [
                  ListTile(
                      title: Text(quote.reference),
                      subtitle: Text(
                          '${statusOf(quote)[0].toUpperCase()}${statusOf(quote).substring(1)} · ${quote.validUntil == null ? 'No expiry' : 'Valid until ${MaterialLocalizations.of(context).formatMediumDate(quote.validUntil!)}'}'),
                      trailing: IconButton(
                          tooltip: 'Close quotation detail',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(context))),
                  const Divider(height: 1),
                  Expanded(
                      child: ListView(
                          padding: const EdgeInsets.all(24),
                          children: [
                        Wrap(spacing: 12, runSpacing: 12, children: [
                          _detailFact(context, 'Customer',
                              quote.customerNameSnapshot ?? 'Walk-in customer'),
                          _detailFact(
                              context,
                              'Prepared by',
                              quote.preparedBySnapshot.isEmpty
                                  ? '—'
                                  : quote.preparedBySnapshot),
                          _detailFact(
                              context,
                              'Created',
                              MaterialLocalizations.of(context)
                                  .formatMediumDate(quote.createdAt)),
                          _detailFact(
                              context,
                              'Valid until',
                              quote.validUntil == null
                                  ? 'No expiry'
                                  : MaterialLocalizations.of(context)
                                      .formatMediumDate(quote.validUntil!)),
                          _detailFact(
                              context,
                              'Status',
                              statusOf(quote)[0].toUpperCase() +
                                  statusOf(quote).substring(1)),
                        ]),
                        if (sale?.receiptNumber != null)
                          Text('Receipt #${sale!.receiptNumber}'),
                        if (quote.status == 'open' && needsNextStep)
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('NEXT STEP',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelLarge),
                                        const SizedBox(height: 8),
                                        Text((quoteUnlinkedCounts[quote.id] ??
                                                    0) >
                                                0
                                            ? '${quoteUnlinkedCounts[quote.id]} custom items need product links'
                                            : (quoteNeedsOrderCounts[
                                                                quote.id] ??
                                                            0) >
                                                        0 &&
                                                    (quoteOrderedCounts[
                                                                quote.id] ??
                                                            0) >
                                                        0
                                                ? '${quoteOrderedCounts[quote.id]} ordered · ${quoteNeedsOrderCounts[quote.id]} need sourcing'
                                                : (quoteNeedsOrderCounts[
                                                                quote.id] ??
                                                            0) >
                                                        0
                                                    ? '${quoteNeedsOrderCounts[quote.id]} items need supplier stock'
                                                    : (quoteOrderedCounts[
                                                                    quote.id] ??
                                                                0) >
                                                            0
                                                        ? '${quoteOrderedCounts[quote.id]} items awaiting supplier delivery'
                                                        : 'All items ready'),
                                        const SizedBox(height: 8),
                                        FilledButton(
                                            onPressed: () {
                                              Navigator.pop(context);
                                              convert(quote);
                                            },
                                            child: Text((quoteUnlinkedCounts[
                                                            quote.id] ??
                                                        0) >
                                                    0
                                                ? 'Resolve items'
                                                : (quoteAwaitingCounts[
                                                                quote.id] ??
                                                            0) >
                                                        0
                                                    ? 'Review sourcing'
                                                    : 'Convert to sale')),
                                      ]))),
                        if (quote.status == 'open' && !needsNextStep)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Text('Ready for checkout',
                                  style:
                                      Theme.of(context).textTheme.titleMedium)),
                        const Divider(height: 32),
                        Text('Items',
                            style: Theme.of(context).textTheme.titleMedium),
                        for (final item in items)
                          Card(
                              child: ListTile(
                                  title: Text(item.productNameSnapshot),
                                  subtitle: Text(
                                      '${item.customNotes?.isNotEmpty == true ? '${item.customNotes}\n' : ''}${modeLabel(item.saleMode).isEmpty ? '' : '${modeLabel(item.saleMode)} · '}${Quantity.format(item.quantityMilli)} ${item.unitSnapshot} × ${formatPeso(item.unitPriceCents + item.extraCents)}\n${itemAvailability(item)}'),
                                  trailing:
                                      Text(formatPeso(item.lineTotalCents)))),
                        if (sourcedOrders.isNotEmpty) ...[
                          const Divider(height: 32),
                          Text('Purchase Orders from this quotation',
                              style: Theme.of(context).textTheme.titleMedium),
                          for (final entry in sourcedOrders)
                            ListTile(
                              title: Text(PurchaseOrderRepository.number(
                                  entry.progress.order)),
                              subtitle: Text(() {
                                final received =
                                    PurchaseOrderRepository.receivedForSource(
                                        entry.source,
                                        allSourceLinks.where((s) =>
                                            s.purchaseOrderLineId ==
                                            entry.source.purchaseOrderLineId),
                                        entry.progress.received[entry
                                                .source.purchaseOrderLineId] ??
                                            0);
                                final incoming = {
                                  'draft',
                                  'sent',
                                  'partially_received'
                                }.contains(entry.progress.status)
                                    ? entry.source.plannedQtyMilli - received
                                    : 0;
                                return '${Quantity.format(entry.source.plannedQtyMilli)} planned · ${Quantity.format(received)} received · ${Quantity.format(incoming)} incoming';
                              }()),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: widget.onViewPurchaseOrder == null
                                  ? null
                                  : () {
                                      Navigator.pop(context);
                                      widget.onViewPurchaseOrder!(
                                          entry.progress.order.id,
                                          quote.reference);
                                    },
                            ),
                        ],
                        const Divider(),
                        Card(
                            child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: Column(children: [
                                  TransactionTotal(
                                      'Subtotal',
                                      items.fold(
                                          0,
                                          (sum, item) =>
                                              sum + item.lineTotalCents)),
                                  const TransactionTotal('Discount', 0),
                                  const Divider(),
                                  TransactionTotal(
                                      'Total',
                                      items.fold(
                                          0,
                                          (sum, item) =>
                                              sum + item.lineTotalCents),
                                      strong: true),
                                ]))),
                        if (quote.notes?.isNotEmpty == true) ...[
                          const SizedBox(height: 16),
                          Text('Customer notes / terms: ${quote.notes}')
                        ],
                        const SizedBox(height: 16),
                        const Text(
                            'Stock is not reserved. Availability is checked again at sale.'),
                        const SizedBox(height: 24),
                        Text('Document',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Card(
                            child: Padding(
                                padding: const EdgeInsets.all(16),
                                child:
                                    Wrap(spacing: 8, runSpacing: 8, children: [
                                  OutlinedButton.icon(
                                      onPressed: () =>
                                          documentAction(quote, 'preview'),
                                      icon: const Icon(Icons.preview_outlined),
                                      label: const Text('Preview PDF')),
                                  OutlinedButton.icon(
                                      onPressed: () =>
                                          documentAction(quote, 'print'),
                                      icon: const Icon(Icons.print_outlined),
                                      label: const Text('Print')),
                                  OutlinedButton.icon(
                                      onPressed: () =>
                                          documentAction(quote, 'save'),
                                      icon: const Icon(Icons.download_outlined),
                                      label: const Text('Save PDF')),
                                  OutlinedButton.icon(
                                      onPressed: () =>
                                          documentAction(quote, 'share'),
                                      icon: const Icon(Icons.share_outlined),
                                      label: const Text('Send / Share')),
                                ]))),
                      ])),
                  if (quote.status == 'open')
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
                      child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(context);
                                create(existing: quote);
                              },
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('Edit quotation'),
                            ),
                            TextButton.icon(
                              onPressed: () =>
                                  _cancelFromDetail(quote, context),
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    Theme.of(context).colorScheme.error,
                              ),
                              icon: const Icon(Icons.block_outlined),
                              label: const Text('Cancel quotation'),
                            ),
                            if (quote.validUntil == null ||
                                !quote.validUntil!.isBefore(DateTime.now()))
                              FilledButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  convert(quote);
                                },
                                child: const Text('Convert to sale'),
                              ),
                          ]),
                    ),
                ]))));
  }

  Widget _detailFact(BuildContext context, String label, String value) => Card(
      child: SizedBox(
          width: 160,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.labelMedium),
                    const SizedBox(height: 3),
                    Text(value, style: Theme.of(context).textTheme.titleSmall),
                  ]))));

  Future<void> documentAction(Quotation quote, String action) async {
    try {
      final bytes = await QuotationPdf(widget.repository.db).render(quote.id);
      if (!mounted) return;
      final customer = quote.customerNameSnapshot ?? 'Walk-in';
      final filename = QuotationPdf.safeFilename(quote.reference, customer);
      if (action == 'preview') {
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (context) => QuotationPreview(
                bytes: bytes,
                reference: quote.reference,
                onPrint: () => Printing.layoutPdf(
                    onLayout: (_) async => bytes, name: filename),
                onSave: () => saveQuotationPdf(bytes, filename),
                onShare: () => Platform.isWindows
                    ? saveQuotationPdf(bytes, filename)
                    : Printing.sharePdf(bytes: bytes, filename: filename))));
      } else if (action == 'print') {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
      } else if (action == 'share' && !Platform.isWindows) {
        await Printing.sharePdf(bytes: bytes, filename: filename);
      } else {
        await saveQuotationPdf(bytes, filename);
      }
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> saveQuotationPdf(List<int> bytes, String filename) async {
    final directory = await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final file = File('${directory.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(bytes, flush: true);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = rows.where((row) =>
      (filter == 'all' || filter == statusOf(row) ||
        (filter == 'awaiting stock' && row.status == 'open' &&
          (quoteAwaitingCounts[row.id] ?? 0) > 0) ||
        (filter == 'ready' && row.status == 'open' &&
          (quoteItemCounts[row.id] ?? 0) > 0 &&
          (quoteUnlinkedCounts[row.id] ?? 0) == 0 &&
          (quoteAwaitingCounts[row.id] ?? 0) == 0)) &&
      '${row.reference} ${row.customerNameSnapshot ?? 'Walk-in'} ${quoteProductNames[row.id] ?? ''}'
        .toLowerCase().contains(query)).toList();
    return Stack(children: [
        Scaffold(
            body: LayoutBuilder(builder: (context, viewport) =>
              SingleChildScrollView(
                physics: viewport.maxWidth < 600 ? null : const NeverScrollableScrollPhysics(),
                child: SizedBox(
                  height: viewport.maxWidth < 600 && viewport.maxHeight < 1800
                      ? 1800 : viewport.maxHeight,
                  child: Padding(padding: const EdgeInsets.all(24), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
          AppPageHeader(
            title: 'Quotations',
            subtitle:
                'Create and manage customer price offers before checkout.',
            action: FilledButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New quotation'),
            ),
          ),
          if (error != null)
            Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _metric(
                context,
                'Open',
                rows
                    .where((r) =>
                        r.status == 'open' &&
                        (r.validUntil == null ||
                            !r.validUntil!.isBefore(DateTime.now())))
                    .length),
            _metric(
                context,
                'Expired',
                rows
                    .where((r) =>
                        r.status == 'open' &&
                        r.validUntil != null &&
                        r.validUntil!.isBefore(DateTime.now()))
                    .length),
            _metric(
                context,
                'Awaiting stock',
                rows
                    .where((r) =>
                        r.status == 'open' &&
                        (quoteAwaitingCounts[r.id] ?? 0) > 0)
                    .length),
            _metric(context, 'Converted',
                rows.where((r) => r.status == 'converted').length),
            _metric(
                context,
                'Ready',
                rows
                    .where((r) =>
                        r.status == 'open' &&
                        (quoteItemCounts[r.id] ?? 0) > 0 &&
                        (quoteUnlinkedCounts[r.id] ?? 0) == 0 &&
                        (quoteAwaitingCounts[r.id] ?? 0) == 0)
                    .length),
          ]),
          const SizedBox(height: 20),
          AppSearchField(
              hintText: 'Search quotation, customer, or product',
              onChanged: (value) =>
                  setState(() { query = value.toLowerCase(); listPage = 0; })),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final status in [
              'all',
              'open',
              'awaiting stock',
              'ready',
              'expired',
              'converted',
              'cancelled'
            ])
              AppFilterChip(
                  label: status[0].toUpperCase() + status.substring(1),
                  selected: filter == status,
                  onSelected: () => setState(() { filter = status; listPage = 0; })),
          ]),
          const SizedBox(height: 16),
          Expanded(child: AppPagedListPanel(
            key: const Key('quotation-list-panel'),
            title: 'Quotations', total: visible.length,
            count: visible.skip(listPage * 50).take(50).length,
            page: listPage,
            emptyTitle: 'No quotations found',
            onPrevious: () => setState(() => listPage--),
            onNext: () => setState(() => listPage++),
            itemBuilder: (context, index) {
              final row = visible[listPage * 50 + index];
              return AppEntityRow(
                  title: row.reference,
                  subtitle:
                      '${row.customerNameSnapshot ?? 'Walk-in customer'} · ${row.validUntil == null ? 'No expiry' : 'Valid until ${MaterialLocalizations.of(context).formatMediumDate(row.validUntil!)}'}\n${quoteItemCounts[row.id] ?? 0} items · ${formatPeso(quoteTotals[row.id] ?? 0)} · ${row.status != 'open' ? statusOf(row) : (quoteUnlinkedCounts[row.id] ?? 0) > 0 ? 'Next: Link ${quoteUnlinkedCounts[row.id]} custom item(s) to Inventory' : (quoteNeedsOrderCounts[row.id] ?? 0) > 0 ? 'Next: Order ${quoteNeedsOrderCounts[row.id]} item(s)' : (quoteOrderedCounts[row.id] ?? 0) > 0 ? 'Next: Await PO delivery' : 'Ready for checkout'}',
                  status: AppSemanticStatusBadge(
                      label: statusOf(row)[0].toUpperCase() +
                          statusOf(row).substring(1)),
                  onTap: () => showQuote(row),
                );
            },
          )),
        ])))))) ,
        if (editor != null) ...[
          const ModalBarrier(dismissible: false, color: Colors.black54),
          Center(
              child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 1200,
                maxHeight: MediaQuery.sizeOf(context).height * .88,
              ),
              child: editor!,
            ),
          )),
        ],
      ]);
  }

  Widget _metric(BuildContext context, String label, int value) =>
      AppMetricTile(label: label, value: '$value', width: 175);
}
