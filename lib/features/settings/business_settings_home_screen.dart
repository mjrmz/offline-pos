import 'package:flutter/material.dart';
import '../../shared/theme/theme_mode_controller.dart';

import '../../core/models/active_user.dart';
import '../../data/daos/business_feature_repository.dart';
import 'business_features_screen.dart';

class BusinessSettingsHomeScreen extends StatelessWidget {
  const BusinessSettingsHomeScreen(
      {super.key, required this.repository, required this.user, this.onOpen});
  final BusinessFeatureRepository repository;
  final ActiveUser user;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
          const ThemeSettingTile(),
          const SizedBox(height: 16),
          Text('Business', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Business Features'),
            subtitle: const Text('Choose what can be configured on products'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) =>
                  BusinessFeaturesScreen(repository: repository, user: user),
            )),
          ),
          const SizedBox(height: 16),
          Text('Team & Access', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
              leading: const Icon(Icons.people),
              title: const Text('Users & Roles'),
              onTap: () => onOpen?.call('Users & Roles')),
          const SizedBox(height: 16),
          Text('Receipt & Hardware',
              style: Theme.of(context).textTheme.titleMedium),
          ListTile(
              leading: const Icon(Icons.print),
              title: const Text('Printer & Receipt'),
              onTap: () => onOpen?.call('Printer & Receipt')),
          const SizedBox(height: 16),
          Text('System', style: Theme.of(context).textTheme.titleMedium),
          ListTile(
              leading: const Icon(Icons.backup),
              title: const Text('Backup & Recovery'),
              onTap: () => onOpen?.call('Backup & Recovery')),
        ]),
      );
}

class ThemeSettingTile extends StatelessWidget {
  const ThemeSettingTile({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppThemeController.maybeOf(context);
    return ListTile(
      leading: const Icon(Icons.brightness_6_outlined),
      title: const Text('Theme'),
      subtitle: const Text('System follows your device appearance.'),
      trailing: DropdownButton<ThemeMode>(
        key: const Key('theme-selector'),
        value: controller?.mode ?? ThemeMode.system,
        onChanged: controller == null
            ? null
            : (mode) {
                if (mode != null) controller.setMode(mode);
              },
        items: const [
          DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
          DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
        ],
      ),
    );
  }
}
