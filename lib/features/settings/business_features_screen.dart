import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../core/models/business_feature.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../shared/utils/safe_message.dart';

class BusinessFeaturesScreen extends StatefulWidget {
  const BusinessFeaturesScreen(
      {super.key,
      required this.repository,
      required this.user,
      this.embedded = false});
  final BusinessFeatureRepository repository;
  final ActiveUser user;
  final bool embedded;
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
  Widget build(BuildContext context) => widget.embedded
      ? _content()
      : Scaffold(
          appBar: AppBar(title: const Text('Business Features')),
          body: _content(),
        );

  Widget _content() => ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'Choose any combination. You can change these later. Existing product settings are kept when a feature is disabled.'),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (values == null) const Center(child: CircularProgressIndicator()),
        if (values != null) ...[
          _group('Product quantities', [
            BusinessFeature.weightBasedPricing,
            BusinessFeature.unitOfMeasureVariety
          ]),
          _group('Traceability', [BusinessFeature.expiryBatchTracking]),
          _group('Special workflows', [
            BusinessFeature.containerRefillPricing,
            BusinessFeature.tankDepositExchange,
            BusinessFeature.madeToOrderTracking
          ]),
        ],
      ]);

  Widget _group(String title, List<BusinessFeature> features) => Card(
        margin: const EdgeInsets.only(top: 16),
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium)),
              for (final feature in features)
                SwitchListTile(
                  title: Text(feature.displayName),
                  subtitle: Text(feature.description),
                  value: values![feature] ?? false,
                  onChanged:
                      saving != null ? null : (value) => change(feature, value),
                ),
            ])),
      );
}
