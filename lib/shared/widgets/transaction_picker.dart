import 'package:flutter/material.dart';

import '../../core/models/product.dart';
import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/directory_repository.dart';
import '../utils/money.dart';

class TransactionProductPicker extends StatelessWidget {
  final List<PosProduct> products;
  final ValueChanged<PosProduct> onSelected;
  const TransactionProductPicker(
      {super.key, required this.products, required this.onSelected});

  @override
  Widget build(BuildContext context) => Autocomplete<PosProduct>(
        displayStringForOption: (p) => p.name,
        optionsBuilder: (value) {
          final query = value.text.trim().toLowerCase();
          if (query.isEmpty) return products;
          return products.where((p) => [p.name, p.sku ?? '', p.barcode ?? '']
              .any((part) => part.toLowerCase().contains(query)));
        },
        onSelected: onSelected,
        fieldViewBuilder: (context, controller, focus, submit) => TextField(
          controller: controller,
          focusNode: focus,
          onSubmitted: (_) => submit(),
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search product, SKU, or barcode',
              border: OutlineInputBorder()),
        ),
        optionsViewBuilder: (context, select, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
              elevation: 8,
              child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxHeight: 280, maxWidth: 540),
                  child: ListView(shrinkWrap: true, children: [
                    for (final p in options)
                      ListTile(
                          title: Text(p.name),
                          subtitle: Text(
                              '${formatPeso(p.priceCents)} / ${p.business.unit.label}${p.sku == null ? '' : ' · ${p.sku}'}'),
                          onTap: () => select(p)),
                  ]))),
        ),
      );
}

class TransactionCustomerPicker extends StatelessWidget {
  final List<Customer> customers;
  final ValueChanged<Customer> onSelected;
  const TransactionCustomerPicker(
      {super.key, required this.customers, required this.onSelected});

  @override
  Widget build(BuildContext context) => Autocomplete<Customer>(
        displayStringForOption: (c) => c.name,
        optionsBuilder: (value) {
          final query = value.text.trim().toLowerCase();
          return customers.where((c) =>
              c.name.toLowerCase().contains(query) ||
              (c.phone ?? '').toLowerCase().contains(query));
        },
        onSelected: onSelected,
        fieldViewBuilder: (context, controller, focus, submit) => TextField(
          controller: controller,
          focusNode: focus,
          onSubmitted: (_) => submit(),
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.person_search),
              labelText: 'Search customer',
              border: OutlineInputBorder()),
        ),
      );
}

class TransactionTotal extends StatelessWidget {
  final String label;
  final int cents;
  final bool strong;
  const TransactionTotal(this.label, this.cents,
      {super.key, this.strong = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label,
              style: strong ? Theme.of(context).textTheme.titleMedium : null),
          Text(formatPeso(cents),
              style: strong ? Theme.of(context).textTheme.titleLarge : null),
        ]),
      );
}

Future<Customer?> quickAddTransactionCustomer(BuildContext context,
    DirectoryRepository directory, ActiveUser user) async {
  final name = TextEditingController();
  try {
    final entered = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Add customer'),
              content: TextField(
                  controller: name,
                  autofocus: true,
                  decoration:
                      const InputDecoration(labelText: 'Customer name')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Add customer')),
              ],
            ));
    if (entered != true || name.text.trim().isEmpty) return null;
    return await directory.saveCustomer(user, name: name.text);
  } finally {
    name.dispose();
  }
}
