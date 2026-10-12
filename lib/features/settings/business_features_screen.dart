import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/business_feature.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../shared/utils/safe_message.dart';

class BusinessFeaturesScreen extends StatefulWidget {
  const BusinessFeaturesScreen(
      {super.key, required this.repository, required this.user});
  final BusinessFeatureRepository repository;
  final ActiveUser user;
  @override
  State<BusinessFeaturesScreen> createState() => _BusinessFeaturesScreenState();
}

class _BusinessFeaturesScreenState extends State<BusinessFeaturesScreen> {
  Map<BusinessFeature, bool>? values;
  String? error;
  BusinessFeature? saving;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.repository.availability();
      if (mounted) setState(() => values = result);
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> change(BusinessFeature feature, bool enabled) async {
    setState(() {
      saving = feature;
      error = null;
    });
    try {
      await widget.repository.setEnabled(feature, enabled, widget.user);
      if (mounted) setState(() => values = {...values!, feature: enabled});
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => saving = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings → Business Features')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text(
              'Choose any combination. You can change these later. Existing product settings are kept when a feature is disabled.'),
          if (error != null)
            Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (values == null) const Center(child: CircularProgressIndicator()),
          if (values != null)
            for (final feature in BusinessFeature.values)
              SwitchListTile(
                title: Text(feature.displayName),
                subtitle: Text(feature.description),
                value: values![feature] ?? false,
                onChanged:
                    saving != null ? null : (value) => change(feature, value),
              ),
        ]),
      );
}
