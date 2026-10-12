import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/quantity.dart';
import '../../data/daos/rma_lifecycle_repository.dart';
import '../../data/daos/rma_repository.dart';
import '../../shared/utils/safe_message.dart';

class NewCustomerRmaPage extends StatefulWidget {
  final RmaRepository repository;
  final ActiveUser user;
  final String? initialReceipt;
  const NewCustomerRmaPage(
      {super.key,
      required this.repository,
      required this.user,
      this.initialReceipt});
  @override
  State<NewCustomerRmaPage> createState() => _NewCustomerRmaPageState();
}

class _NewCustomerRmaPageState extends State<NewCustomerRmaPage> {
  final search = TextEditingController();
  final quantity = TextEditingController(text: '1');
  final issue = TextEditingController();
  final notes = TextEditingController();
  int step = 0;
  RmaChoice? selected;
  String? serialId;
  String? error;
  bool saving = false;
  Future<List<RmaChoice>>? results;

  @override
  void initState() {
    super.initState();
    if (widget.initialReceipt != null) {
      search.text = widget.initialReceipt!;
      results = widget.repository.choices('customer', widget.initialReceipt!);
    }
  }

  @override
  void dispose() {
    search.dispose();
    quantity.dispose();
    issue.dispose();
    notes.dispose();
    super.dispose();
  }

  void searchSources() => setState(() {
        final query = search.text.trim();
        results = query.length < 2
            ? null
            : widget.repository.choices('customer', query);
      });

  Future<void> create() async {
    if (selected == null || issue.text.trim().isEmpty) {
      setState(() => error = 'Select an item and enter the reported issue.');
      return;
    }
    final amount = Quantity.tryParse(quantity.text, fractional: true);
    if (amount == null || amount <= 0) {
      setState(() => error = 'Enter a valid claim quantity.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final row = await RmaLifecycleRepository(widget.repository.db).request(
          widget.user, selected!.itemId, issue.text,
          serialUnitId: serialId, quantityMilli: amount, notes: notes.text);
      if (mounted) Navigator.pop(context, row);
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedChoice = selected;
    return Scaffold(
      appBar: AppBar(title: const Text('New Customer RMA')),
      body: Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1050),
        child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Step ${step + 1} of 4',
                        style: theme.textTheme.labelLarge),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: (step + 1) / 4),
                  ])),
          Expanded(
              child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                if (error != null)
                  Text(error!,
                      style: TextStyle(color: theme.colorScheme.error)),
                if (step == 0) ...[
                  Text('Find transaction',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  TextField(
                      controller: search,
                      decoration: const InputDecoration(
                          labelText:
                              'Receipt, customer, phone, product, SKU, barcode or serial',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder()),
                      onChanged: (_) => searchSources()),
                  const SizedBox(height: 16),
                  if (results == null)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                                'Enter at least two characters or scan a barcode.')))
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
                            return const Text('Searching transactions...');
                          }
                          if (snapshot.data!.isEmpty) {
                            return const Text(
                                'No matching transactions found.');
                          }
                          return Column(children: [
                            for (final choice in snapshot.data!.take(50))
                              Card(
                                  child: ListTile(
                                selected:
                                    selectedChoice?.itemId == choice.itemId,
                                title: Text(choice.label),
                                subtitle: Text('Remaining claimable: '
                                    '${Quantity.format((choice.soldMilli ?? 0) - (choice.claimedMilli ?? 0))}'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => setState(() {
                                  selected = choice;
                                  serialId = null;
                                }),
                              )),
                          ]);
                        }),
                  if (selectedChoice != null)
                    Card(
                        child: ListTile(
                            title: const Text('Selected source'),
                            trailing: TextButton(
                                onPressed: () => setState(() {
                                      selected = null;
                                      serialId = null;
                                      step = 0;
                                    }),
                                child: const Text('Change transaction')),
                            subtitle: Text('${selectedChoice.label}\n'
                                'Receipt ${selectedChoice.receipt ?? ''} · '
                                'Customer ${selectedChoice.customerName ?? 'Walk-in'}\n'
                                'Sold ${Quantity.format(selectedChoice.soldMilli ?? 0)} · '
                                'Previously claimed ${Quantity.format(selectedChoice.claimedMilli ?? 0)} · '
                                'Remaining ${Quantity.format((selectedChoice.soldMilli ?? 0) - (selectedChoice.claimedMilli ?? 0))}'))),
                ],
                if (step == 1) ...[
                  Text('Select item / unit',
                      style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  if (selectedChoice != null)
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(selectedChoice.label),
                                  const SizedBox(height: 16),
                                  if (selectedChoice.serials.isEmpty)
                                    TextField(
                                        controller: quantity,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(decimal: true),
                                        decoration: const InputDecoration(
                                            labelText: 'Quantity to claim',
                                            border: OutlineInputBorder()))
                                  else ...[
                                    const Text('Choose the exact sold serial'),
                                    for (final serial in selectedChoice.serials)
                                      ListTile(
                                          selected: serialId == serial.id,
                                          leading: Icon(serialId == serial.id
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked),
                                          title: Text(serial.serialNumber),
                                          onTap: () => setState(
                                              () => serialId = serial.id)),
                                  ],
                                ]))),
                ],
                if (step == 2) ...[
                  Text('Claim details', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  const Text(
                      'Return or warranty handling is decided during approval and resolution.'),
                  const SizedBox(height: 16),
                  TextField(
                      controller: issue,
                      maxLines: 3,
                      decoration: const InputDecoration(
                          labelText: 'Customer-reported issue / reason *',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  TextField(
                      controller: notes,
                      maxLines: 2,
                      decoration: const InputDecoration(
                          labelText: 'Request notes (optional)',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  const Text(
                      'Inspection findings are recorded after physical receipt.'),
                ],
                if (step == 3) ...[
                  Text('Review & create', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Source: ${selectedChoice?.label ?? ''}'),
                                Text(
                                    'Serial: ${selectedChoice?.serials.where((e) => e.id == serialId).firstOrNull?.serialNumber ?? 'Not serialized'}'),
                                Text('Quantity: ${quantity.text}'),
                                Text('Reported issue: ${issue.text}'),
                                if (notes.text.trim().isNotEmpty)
                                  Text('Notes: ${notes.text}'),
                              ]))),
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
                            : () {
                                if (step == 0 && selected == null) {
                                  setState(
                                      () => error = 'Select a source item.');
                                } else if (step == 1 &&
                                    selected!.serials.isNotEmpty &&
                                    serialId == null) {
                                  setState(() =>
                                      error = 'Select the exact sold serial.');
                                } else if (step == 2 &&
                                    issue.text.trim().isEmpty) {
                                  setState(() => error =
                                      'Enter the customer-reported issue.');
                                } else if (step == 3) {
                                  create();
                                } else {
                                  setState(() {
                                    error = null;
                                    step++;
                                  });
                                }
                              },
                        child: Text(step == 3 ? 'Create RMA' : 'Continue')),
                  ]))),
        ]),
      )),
    );
  }
}
