import 'package:flutter/material.dart';

import '../../data/daos/inventory_health_repository.dart';

class InventoryHealthSettingsScreen extends StatefulWidget {
  final InventoryHealthRepository repository;
  const InventoryHealthSettingsScreen({super.key, required this.repository});
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

  @override
  void initState() {
    super.initState();
    widget.repository.settings().then((value) {
      if (!mounted) return;
      slow.text = '${value.slowMovingDays}';
      dead.text = '${value.deadStockDays}';
      expiry.text = '${value.nearExpiryDays}';
    });
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
      if (mounted) Navigator.pop(context);
    } catch (cause) {
      if (mounted) setState(() => error = '$cause');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Inventory health settings')),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  TextField(
                      controller: slow,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Slow moving after (days)')),
                  TextField(
                      controller: dead,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Dead stock after (days)')),
                  TextField(
                      controller: expiry,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Near expiry within (days)')),
                  if (error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))),
                  const SizedBox(height: 20),
                  FilledButton(
                      onPressed: saving ? null : save,
                      child: const Text('Save')),
                ]))),
      );
}
