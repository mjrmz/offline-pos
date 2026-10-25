import 'package:flutter/material.dart';

import '../../data/daos/inventory_health_repository.dart';

class InventoryHealthSettingsScreen extends StatefulWidget {
  final InventoryHealthRepository repository;
  final bool embedded;
  final ValueChanged<bool>? onDirtyChanged;
  const InventoryHealthSettingsScreen(
      {super.key,
      required this.repository,
      this.embedded = false,
      this.onDirtyChanged});
  @override
  State<InventoryHealthSettingsScreen> createState() =>
      _InventoryHealthSettingsScreenState();
}

class _InventoryHealthSettingsScreenState
    extends State<InventoryHealthSettingsScreen> {
  final slow = TextEditingController();
  final dead = TextEditingController();
  final expiry = TextEditingController();
  String? error;
  bool saving = false;
  bool loaded = false;
  List<String> savedValues = const [];
  bool get changed =>
      loaded &&
      (savedValues[0] != slow.text ||
          savedValues[1] != dead.text ||
          savedValues[2] != expiry.text);

  @override
  void initState() {
    super.initState();
    for (final controller in [slow, dead, expiry]) {
      controller.addListener(_edited);
    }
    widget.repository.settings().then((value) {
      if (!mounted) return;
      slow.text = '${value.slowMovingDays}';
      dead.text = '${value.deadStockDays}';
      expiry.text = '${value.nearExpiryDays}';
      setState(() {
        savedValues = [slow.text, dead.text, expiry.text];
        loaded = true;
      });
    });
  }

  void _edited() {
    if (mounted && loaded) {
      setState(() {});
      widget.onDirtyChanged?.call(changed);
    }
  }

  @override
  void dispose() {
    slow.dispose();
    dead.dispose();
    expiry.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final s = int.tryParse(slow.text.trim());
    final d = int.tryParse(dead.text.trim());
    final e = int.tryParse(expiry.text.trim());
    if (s == null ||
        d == null ||
        e == null ||
        s < 1 ||
        d < s ||
        e < 1 ||
        s > 3650 ||
        d > 3650 ||
        e > 3650) {
      setState(() =>
          error = 'Use 1–3650 days. Dead stock must be at least slow moving.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.repository.saveSettings(InventoryHealthSettings(s, d, e));
      if (mounted) {
        setState(() => savedValues = [slow.text, dead.text, expiry.text]);
        widget.onDirtyChanged?.call(false);
        if (widget.embedded) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Inventory settings saved.'),
              duration: Duration(seconds: 3)));
        } else {
          Navigator.pop(context);
        }
      }
    } catch (cause) {
      if (mounted) setState(() => error = '$cause');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _content()
      : Scaffold(
          appBar: AppBar(title: const Text('Inventory health settings')),
          body: _content(),
        );

  Widget _content() => Center(
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Text('Stock health',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Configure stock aging and expiry rules.'),
            const SizedBox(height: 20),
            TextField(
                controller: slow,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Slow moving after (days)',
                    helperText: 'Stock that has not sold within this period.',
                    suffixText: 'days')),
            const SizedBox(height: 16),
            TextField(
                controller: dead,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Dead stock after (days)',
                    helperText: 'Stock inactive for a longer period.',
                    suffixText: 'days')),
            const SizedBox(height: 16),
            TextField(
                controller: expiry,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Near expiry within (days)',
                    helperText: 'Batch stock approaching expiry.',
                    suffixText: 'days')),
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
                    onPressed: saving || !changed ? null : save,
                    child: const Text('Save changes'))),
          ])));
}
