import 'package:flutter/material.dart';
import '../../shared/theme/theme_mode_controller.dart';
import '../../shared/widgets/app_workspace.dart';
import '../../core/models/active_user.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../data/daos/inventory_health_repository.dart';
import 'business_features_screen.dart';
import 'quotation_template_screen.dart';
import 'pos_layout_settings_screen.dart';
import 'loyalty_settings_screen.dart';
import 'inventory_health_settings_screen.dart';
import 'appearance_settings.dart';

class BusinessSettingsHomeScreen extends StatefulWidget {
  const BusinessSettingsHomeScreen(
      {super.key, required this.repository, required this.user, this.onOpen});
  final BusinessFeatureRepository repository;
  final ActiveUser user;
  final ValueChanged<String>? onOpen;

  @override
  State<BusinessSettingsHomeScreen> createState() => _SettingsState();
}

class _SettingsState extends State<BusinessSettingsHomeScreen> {
  int selected = 0;
  static const categories = <(String, IconData)>[
    ('General', Icons.tune_outlined),
    ('POS', Icons.point_of_sale_outlined),
    ('Inventory', Icons.inventory_2_outlined),
    ('Business', Icons.storefront_outlined),
    ('Team & Access', Icons.people_outline),
    ('Receipt & Hardware', Icons.print_outlined),
    ('System', Icons.settings_backup_restore_outlined),
  ];

  void open(Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));

  Widget row(
          IconData icon, String title, String description, VoidCallback action,
          {String? value}) =>
      _SettingRow(
          icon: icon,
          title: title,
          description: description,
          value: value,
          onTap: action);

  List<Widget> rows() => switch (selected) {
        0 => [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Appearance & Branding',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const ThemeSettingTile(),
            const SidebarColorTile(),
            const SidebarLogoTile(),
            const ResetAppearanceTile(),
          ],
        1 => [
            row(
                Icons.view_quilt_outlined,
                'Checkout layout',
                'Choose the default checkout experience.',
                () => open(const PosLayoutSettingsScreen())),
            row(
                Icons.stars_outlined,
                'Loyalty rewards',
                'Customer earning and redemption rules.',
                () => open(LoyaltySettingsScreen(
                    db: widget.repository.db, user: widget.user))),
          ],
        2 => [
            if (widget.user.can(PosPermission.manageCatalog))
              row(
                  Icons.monitor_heart_outlined,
                  'Inventory health',
                  'Configure slow-moving, dead-stock, and expiry thresholds.',
                  () => open(InventoryHealthSettingsScreen(
                      repository:
                          InventoryHealthRepository(widget.repository.db)))),
          ],
        3 => [
            row(
                Icons.tune,
                'Business Features',
                'Choose product-level capabilities and supported workflows.',
                () => open(BusinessFeaturesScreen(
                    repository: widget.repository, user: widget.user)))
          ],
        4 => [
            row(
                Icons.people_outline,
                'Users & Roles',
                'Manage staff accounts, roles, and permissions.',
                () => widget.onOpen?.call('Users & Roles'),
                value: 'Open Users & Roles')
          ],
        5 => [
            row(
                Icons.print_outlined,
                'Printer & Receipt',
                'Configure printing and receipt options.',
                () => widget.onOpen?.call('Printer & Receipt'),
                value: 'Open Printer & Receipt'),
            row(
                Icons.request_quote_outlined,
                'Quotation template',
                'Choose fields and terms for customer PDFs.',
                () => open(QuotationTemplateScreen(db: widget.repository.db))),
          ],
        _ => [
            row(
                Icons.backup_outlined,
                'Backup & Recovery',
                'Manage backups and restore your data.',
                () => widget.onOpen?.call('Backup & Recovery'),
                value: 'Open Backup & Recovery')
          ],
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const AppPageHeader(
              title: 'Settings',
              subtitle:
                  'Manage your application, business, and device preferences.',
            ),
            Expanded(child: LayoutBuilder(builder: (context, constraints) {
              final railWidth = constraints.maxWidth < 900 ? 200.0 : 240.0;
              return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                        width: railWidth,
                        child: ListView.separated(
                            itemCount: categories.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 4),
                            itemBuilder: (context, index) {
                              final active = selected == index;
                              return Material(
                                color: active
                                    ? scheme.primaryContainer
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => setState(() => selected = index),
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 12),
                                      child: Row(children: [
                                        Icon(categories[index].$2,
                                            size: 20,
                                            color: active
                                                ? scheme.primary
                                                : scheme.onSurfaceVariant),
                                        const SizedBox(width: 12),
                                        Expanded(
                                            child: Text(categories[index].$1,
                                                style: theme
                                                    .textTheme.bodyMedium
                                                    ?.copyWith(
                                                        color: active
                                                            ? scheme.primary
                                                            : scheme.onSurface,
                                                        fontWeight: active
                                                            ? FontWeight.w600
                                                            : null))),
                                      ])),
                                ),
                              );
                            })),
                    const SizedBox(width: 24),
                    Expanded(
                        child: SingleChildScrollView(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                          Text(categories[selected].$1,
                              style: theme.textTheme.titleLarge),
                          const SizedBox(height: 12),
                          ...rows(),
                        ]))),
                  ]);
            })),
          ])),
    ))));
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow(
      {required this.icon,
      required this.title,
      required this.description,
      required this.onTap,
      this.value});
  final IconData icon;
  final String title;
  final String description;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: scheme.outlineVariant)),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 78),
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(children: [
                  Icon(icon, size: 22, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 16),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                        Text(title,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(description,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      ])),
                  if (value != null) ...[
                    const SizedBox(width: 12),
                    Text(value!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right,
                      size: 20, color: scheme.onSurfaceVariant),
                ])),
          ),
        ),
      ),
    );
  }
}

class ThemeSettingTile extends StatelessWidget {
  const ThemeSettingTile({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppThemeController.maybeOf(context);
    final mode = controller?.mode ?? ThemeMode.system;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = switch (mode) {
      ThemeMode.light => 'Use the light workspace appearance.',
      ThemeMode.dark => 'Use the dark workspace appearance.',
      ThemeMode.system =>
        'Use the default navy sidebar with a light workspace.',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: scheme.outlineVariant)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 50),
              child: Row(children: [
                Icon(Icons.brightness_6_outlined,
                    size: 22, color: scheme.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Theme',
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(description,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant)),
                    ])),
                const SizedBox(width: 12),
                DropdownButton<ThemeMode>(
                    key: const Key('theme-selector'),
                    value: mode,
                    onChanged: controller == null
                        ? null
                        : (value) {
                            if (value != null) controller.setMode(value);
                          },
                    items: const [
                      DropdownMenuItem(
                          value: ThemeMode.system, child: Text('System')),
                      DropdownMenuItem(
                          value: ThemeMode.light, child: Text('Light')),
                      DropdownMenuItem(
                          value: ThemeMode.dark, child: Text('Dark')),
                    ]),
              ])),
        ),
      ),
    );
  }
}
