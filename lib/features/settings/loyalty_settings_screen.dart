import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/loyalty_repository.dart';
import '../../data/database.dart';
import '../../shared/utils/money.dart';
import '../../shared/utils/safe_message.dart';

class LoyaltySettingsScreen extends StatefulWidget {
  final AppDatabase db;
  final ActiveUser user;
  final bool embedded;
  const LoyaltySettingsScreen(
      {super.key, required this.db, required this.user, this.embedded = false});

  @override
  State<LoyaltySettingsScreen> createState() => _LoyaltySettingsScreenState();
}

class _LoyaltySettingsScreenState extends State<LoyaltySettingsScreen> {
  final earn = TextEditingController();
  final redeem = TextEditingController();
  final value = TextEditingController();
  bool enabled = true;
  bool loading = true;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await LoyaltyRepository(widget.db).settings();
      if (!mounted) return;
      setState(() {
        enabled = settings.enabled;
        earn.text = (settings.spendPerPointCents / 100).toStringAsFixed(2);
        redeem.text = '${settings.redeemPoints}';
        value.text = (settings.redeemValueCents / 100).toStringAsFixed(2);
        loading = false;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeMessage(error))));
      }
    }
  }

  Future<void> _save() async {
    final spendCents = tryParsePeso(earn.text);
    final redeemPoints = int.tryParse(redeem.text);
    final discountCents = tryParsePeso(value.text);
    if (spendCents == null ||
        spendCents <= 0 ||
        redeemPoints == null ||
        redeemPoints <= 0 ||
        discountCents == null ||
        discountCents <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Enter positive values for each rewards rule')));
      return;
    }
    setState(() => saving = true);
    try {
      await LoyaltyRepository(widget.db).updateSettings(widget.user.id,
          LoyaltySettings(enabled, spendCents, redeemPoints, discountCents));
      if (mounted) {
        if (widget.embedded) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Loyalty rules saved.'),
              duration: Duration(seconds: 3)));
        } else {
          Navigator.pop(context);
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(safeMessage(error))));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    earn.dispose();
    redeem.dispose();
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _content()
      : Scaffold(
          appBar: AppBar(title: const Text('Loyalty rewards')),
          body: _content());

  Widget _content() => loading
      ? const Center(child: CircularProgressIndicator())
      : ListView(padding: const EdgeInsets.all(20), children: [
          SwitchListTile(
              title: const Text('Enable rewards'),
              value: enabled,
              onChanged: widget.user.can(PosPermission.manageSettings)
                  ? (v) => setState(() => enabled = v)
                  : null),
          TextField(
              controller: earn,
              enabled: widget.user.can(PosPermission.manageSettings),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Pesos spent per point')),
          TextField(
              controller: redeem,
              enabled: widget.user.can(PosPermission.manageSettings),
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Points per redemption unit')),
          TextField(
              controller: value,
              enabled: widget.user.can(PosPermission.manageSettings),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  const InputDecoration(labelText: 'Peso discount per unit')),
          const SizedBox(height: 16),
          if (widget.user.can(PosPermission.manageSettings))
            Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                    onPressed: saving ? null : _save,
                    child: const Text('Save rules'))),
        ]);
}
