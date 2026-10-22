import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../shared/utils/safe_message.dart';

class QuotationTemplateScreen extends StatefulWidget {
  final AppDatabase db;
  const QuotationTemplateScreen({super.key, required this.db});

  @override
  State<QuotationTemplateScreen> createState() =>
      _QuotationTemplateScreenState();
}

class _QuotationTemplateScreenState extends State<QuotationTemplateScreen> {
  final footer = TextEditingController(
      text:
          'This document is a quotation only and is not an official receipt or tax invoice.');
  final terms = TextEditingController();
  bool showSku = true;
  bool showBarcode = false;
  bool showUnit = true;
  bool showPreparedBy = true;
  bool showSignature = false;
  bool showAcceptance = false;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final row = await widget.db
          .select(widget.db.quotationDocumentSettings)
          .getSingleOrNull();
      if (row == null || !mounted) return;
      setState(() {
        showSku = row.showSku;
        showBarcode = row.showBarcode;
        showUnit = row.showUnit;
        showPreparedBy = row.showPreparedBy;
        showSignature = row.showSignature;
        showAcceptance = row.showAcceptance;
        footer.text = row.footer;
        terms.text = row.terms;
      });
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    }
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await widget.db.into(widget.db.quotationDocumentSettings).insert(
          QuotationDocumentSettingsCompanion.insert(
            id: const Value(1),
            showSku: Value(showSku),
            showBarcode: Value(showBarcode),
            showUnit: Value(showUnit),
            showPreparedBy: Value(showPreparedBy),
            showSignature: Value(showSignature),
            showAcceptance: Value(showAcceptance),
            footer: Value(footer.text.trim()),
            terms: Value(terms.text.trim()),
          ),
          mode: InsertMode.insertOrReplace);
      if (mounted) Navigator.pop(context);
    } catch (failure) {
      if (mounted) setState(() => error = safeMessage(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    footer.dispose();
    terms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Quotation template')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(padding: const EdgeInsets.all(24), children: [
                Text('Customer document',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                    'The business name, address, and contact details come from Printer & Receipt settings.'),
                const SizedBox(height: 16),
                SwitchListTile(
                    title: const Text('Show SKU'),
                    value: showSku,
                    onChanged: (value) => setState(() => showSku = value)),
                SwitchListTile(
                    title: const Text('Show barcode'),
                    value: showBarcode,
                    onChanged: (value) => setState(() => showBarcode = value)),
                SwitchListTile(
                    title: const Text('Show unit'),
                    value: showUnit,
                    onChanged: (value) => setState(() => showUnit = value)),
                SwitchListTile(
                    title: const Text('Show prepared by'),
                    value: showPreparedBy,
                    onChanged: (value) =>
                        setState(() => showPreparedBy = value)),
                SwitchListTile(
                    title: const Text('Signature area'),
                    value: showSignature,
                    onChanged: (value) =>
                        setState(() => showSignature = value)),
                SwitchListTile(
                    title: const Text('Customer acceptance area'),
                    value: showAcceptance,
                    onChanged: (value) =>
                        setState(() => showAcceptance = value)),
                const SizedBox(height: 16),
                TextField(
                    controller: terms,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Default quotation terms',
                        border: OutlineInputBorder())),
                const SizedBox(height: 16),
                TextField(
                    controller: footer,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Footer message',
                        border: OutlineInputBorder())),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 20),
                Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                        onPressed: busy ? null : save,
                        child: const Text('Save template'))),
              ]))));
}
