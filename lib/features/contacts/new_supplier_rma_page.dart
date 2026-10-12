import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/safe_message.dart';

class NewSupplierRmaPage extends StatefulWidget {
  final RmaRepository repository;
  final ActiveUser user;

  const NewSupplierRmaPage(
      {super.key, required this.repository, required this.user});

  @override
  State<NewSupplierRmaPage> createState() => _NewSupplierRmaPageState();
}

class _NewSupplierRmaPageState extends State<NewSupplierRmaPage> {
  final search = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final reason = TextEditingController();
  final condition = TextEditingController();
  final notes = TextEditingController();
  int step = 0;
  String source = 'inventory';
  RmaChoice? selected;
  RmaCase? customerCase;
  String? serialId;
  String? error;
  bool saving = false;
  Future<List<RmaChoice>>? results;
  late final Future<List<RmaCase>> customerSources = _customerSources();

  Future<List<RmaCase>> _customerSources() async {
    final lifecycle = RmaLifecycleRepository(widget.repository.db);
    final cases = await widget.repository.cases(origin: 'customer');
    final eligible = <RmaCase>[];
    for (final row in cases) {
      final events = await lifecycle.history(row.id);
      if (await lifecycle.nextAction(row.id) == 'Send item to supplier' &&
          !events.any((e) => e.action == 'supplier_claim_opened')) {
        eligible.add(row);
      }
    }
    return eligible;
  }

  void searchSources() => setState(() {
        final query = search.text.trim();
        results = query.length < 2
            ? null
            : widget.repository.choices('inbound', query);
      });

  @override
  void dispose() {
    search.dispose();
    quantity.dispose();
    reason.dispose();
    condition.dispose();
    notes.dispose();
    super.dispose();
  }

  Future<void> create() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final lifecycle = RmaLifecycleRepository(widget.repository.db);
      final RmaCase row;
      if (source == 'customer') {
        row = await lifecycle.createLinkedSupplier(
            widget.user, customerCase!.id,
            note: notes.text);
      } else {
        final amount = Quantity.tryParse(quantity.text, fractional: true);
        if (amount == null || amount <= 0) {
          throw StateError('Enter a valid quantity.');
        }
        row = await lifecycle.requestDirectSupplier(
            widget.user, selected!.itemId, reason.text, condition.text,
            serialUnitId: serialId, quantityMilli: amount, notes: notes.text);
      }
      if (mounted) Navigator.pop(context, row);
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void next() {
    if (step == 1 && source == 'customer' && customerCase == null) {
      setState(() => error = 'Select an eligible customer RMA.');
      return;
    }
    if (step == 1 && source == 'inventory' && selected == null) {
      setState(() => error = 'Select a Receiving item.');
      return;
    }
    if (step == 1 &&
        source == 'inventory' &&
        selected!.serials.isNotEmpty &&
        serialId == null) {
      setState(() => error = 'Select the exact available serial.');
      return;
    }
    if (step == 1 && source == 'inventory' && selected!.serials.isEmpty) {
      final amount = Quantity.tryParse(quantity.text, fractional: true);
      if (amount == null ||
          amount <= 0 ||
          amount > (selected!.soldMilli ?? 0)) {
        setState(() =>
            error = 'Enter a quantity within the available Receiving stock.');
        return;
      }
    }
    if (step == 2 &&
        source == 'inventory' &&
        (reason.text.trim().isEmpty || condition.text.trim().isEmpty)) {
      setState(() => error = 'Enter the claim reason and physical condition.');
      return;
    }
    setState(() {
      error = null;
      step++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('New supplier RMA')),
      body: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Create a supplier claim in four guided steps.'),
                  const SizedBox(height: 12),
                  Text(
                      'Step ${step + 1} of 4 · ${const [
                        'Source',
                        'Select item / unit',
                        'Claim details',
                        'Review'
                      ][step]}',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: (step + 1) / 4),
                ],
              )),
          Expanded(
              child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                if (error != null)
                  Text(error!,
                      style: TextStyle(color: theme.colorScheme.error)),
                if (step == 0) ...[
                  Text('Where is this claim coming from?',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  Card(
                      child: ListTile(
                    title: const Text('Customer RMA'),
                    subtitle: const Text(
                        'Inspected returned item with supplier disposition'),
                    selected: source == 'customer',
                    leading: Icon(source == 'customer'
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
                    onTap: () => setState(() {
                      source = 'customer';
                      selected = null;
                      serialId = null;
                    }),
                  )),
                  Card(
                      child: ListTile(
                    title: const Text('Defective inventory'),
                    subtitle: const Text(
                        'Store-owned stock with exact Receiving provenance; no customer required'),
                    selected: source == 'inventory',
                    leading: Icon(source == 'inventory'
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
                    onTap: () => setState(() {
                      source = 'inventory';
                      customerCase = null;
                    }),
                  )),
                ],
                if (step == 1 && source == 'customer') ...[
                  Text('Select customer RMA',
                      style: theme.textTheme.headlineSmall),
                  FutureBuilder<List<RmaCase>>(
                      future: customerSources,
                      builder: (context, snapshot) {
                        if (snapshot.hasError) {
                          return Text(safeMessage(snapshot.error!));
                        }
                        if (!snapshot.hasData) {
                          return const Text('Loading eligible claims...');
                        }
                        if (snapshot.data!.isEmpty) {
                          return const Text(
                              'No inspected customer claims are ready for supplier recovery.');
                        }
                        return Column(children: [
                          for (final row in snapshot.data!)
                            Card(
                                child: ListTile(
                              selected: customerCase?.id == row.id,
                              title: Text(row.reference),
                              subtitle: Text(row.issueDescription),
                              onTap: () => setState(() => customerCase = row),
                            )),
                        ]);
                      }),
                ],
                if (step == 1 && source == 'inventory') ...[
                  Text('Select exact Receiving stock',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  TextField(
                      controller: search,
                      decoration: const InputDecoration(
                          labelText:
                              'Product, SKU, serial, supplier or Receiving reference',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder()),
                      onChanged: (_) => searchSources()),
                  const SizedBox(height: 12),
                  if (results == null)
                    const Text(
                        'Enter at least two characters or scan a serial.')
                  else
                    FutureBuilder<List<RmaChoice>>(
                        future: results,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Column(children: [
                              Text(safeMessage(snapshot.error!)),
                              TextButton(
                                  onPressed: searchSources,
                                  child: const Text('Retry')),
                            ]);
                          }
                          if (!snapshot.hasData) {
                            return const Text('Searching Receiving stock...');
                          }
                          if (snapshot.data!.isEmpty) {
                            return const Text(
                                'No eligible Receiving stock found.');
                          }
                          return Column(children: [
                            for (final choice in snapshot.data!.take(50))
                              Card(
                                  child: ListTile(
                                selected: selected?.itemId == choice.itemId,
                                title: Text(choice.label),
                                onTap: () => setState(() {
                                  selected = choice;
                                  serialId = null;
                                }),
                              )),
                          ]);
                        }),
                  if (selected != null) ...[
                    const SizedBox(height: 8),
                    Text('Selected source: ${selected!.label}'),
                    if (selected!.soldMilli != null)
                      Text(
                          'Available from this source: ${Quantity.format(selected!.soldMilli!)}'),
                    if (selected!.serials.isNotEmpty) ...[
                      const Text('Choose the exact available serial'),
                      for (final serial in selected!.serials)
                        ListTile(
                          title: Text(serial.serialNumber),
                          selected: serialId == serial.id,
                          leading: Icon(serialId == serial.id
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked),
                          onTap: () => setState(() => serialId = serial.id),
                        ),
                    ] else
                      TextField(
                          controller: quantity,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Quantity to claim',
                              border: OutlineInputBorder())),
                  ],
                ],
                if (step == 2) ...[
                  Text('Claim details', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(source == 'customer'
                      ? customerCase?.reference ?? ''
                      : selected?.label ?? ''),
                  if (source == 'inventory') ...[
                    const SizedBox(height: 12),
                    TextField(
                        controller: reason,
                        maxLines: 3,
                        decoration: const InputDecoration(
                            labelText: 'Claim reason *',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(
                        controller: condition,
                        decoration: const InputDecoration(
                            labelText: 'Physical condition *',
                            border: OutlineInputBorder())),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                      controller: notes,
                      maxLines: 2,
                      decoration: const InputDecoration(
                          labelText: 'Notes (optional)',
                          border: OutlineInputBorder())),
                  if (source == 'customer')
                    const Text(
                        'Customer claim remains open while supplier recovery is in progress.'),
                ],
                if (step == 3) ...[
                  Text('Review and create',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  'Source: ${source == 'customer' ? 'Customer RMA' : 'Defective inventory'}'),
                              Text(
                                  'Item: ${source == 'customer' ? customerCase?.reference ?? '' : selected?.label ?? ''}'),
                              if (serialId != null)
                                Text(
                                    'Serial: ${selected!.serials.where((s) => s.id == serialId).first.serialNumber}'),
                              if (source == 'inventory')
                                Text('Quantity: ${quantity.text}'),
                              if (source == 'inventory')
                                Text('Reason: ${reason.text}'),
                              if (source == 'inventory')
                                Text('Condition: ${condition.text}'),
                              if (notes.text.trim().isNotEmpty)
                                Text('Notes: ${notes.text}'),
                              if (source == 'customer')
                                const Text('Customer claim remains open.'),
                            ],
                          ))),
                ],
              ])),
          SafeArea(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    if (step > 0)
                      OutlinedButton(
                          onPressed:
                              saving ? null : () => setState(() => step--),
                          child: const Text('Back')),
                    const Spacer(),
                    FilledButton(
                        onPressed: saving
                            ? null
                            : step == 3
                                ? create
                                : next,
                        child: Text(saving
                            ? 'Creating...'
                            : step == 3
                                ? 'Create Supplier RMA'
                                : 'Continue')),
                  ]))),
        ]),
      )),
    );
  }
}
