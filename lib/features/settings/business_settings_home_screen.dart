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
import '../auth/users_screen.dart';
import '../../core/services/auth_service.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../hardware/printer/receipt_printer.dart';
import '../../hardware/printer/device_transports.dart';
import 'printer_settings_screen.dart';
import 'business_identity_settings.dart';
import '../recovery/recovery_screen.dart';

class BusinessSettingsHomeScreen extends StatefulWidget {
  const BusinessSettingsHomeScreen(
      {super.key,
      required this.repository,
      required this.user,
      required this.auth,
      required this.printerStore,
      required this.printer,
      required this.devices,
      this.recoveryScreen,
      this.initialSection = 0});
  final BusinessFeatureRepository repository;
  final ActiveUser user;
  final AuthService auth;
  final PrinterSettingsStore printerStore;
  final ReceiptPrinter printer;
  final DevicePrinterClient devices;
  final Widget? recoveryScreen;
  final int initialSection;

  @override
  State<BusinessSettingsHomeScreen> createState() => _SettingsState();
}

class _SettingsState extends State<BusinessSettingsHomeScreen> {
  int selected = 0;
  int inventoryTab = 0;
  int businessTab = 0;
  int systemTab = 0;
  bool dirty = false;

  Future<bool> _discardChanges() async {
    if (!dirty) return true;
    return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('Discard unsaved changes?'),
                  content: const Text(
                      'Your edits in this section have not been saved.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Keep editing')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Discard changes')),
                  ],
                )) ??
        false;
  }

  Future<void> _selectCategory(int category) async {
    if (selected == category || !await _discardChanges() || !mounted) return;
    setState(() {
      dirty = false;
      selected = category;
    });
  }

  Future<void> _selectInventoryTab(int value) async {
    if (inventoryTab == value || !await _discardChanges() || !mounted) return;
    setState(() {
      dirty = false;
      inventoryTab = value;
    });
  }

  List<int> get available => [
        if (widget.user.can(PosPermission.manageSettings)) ...[0, 1, 2, 3],
        if (widget.user.can(PosPermission.manageUsers)) 4,
        if (widget.user.can(PosPermission.managePrinter)) 5,
        if (widget.user.can(PosPermission.manageRecovery)) 6,
      ];
  @override
  void initState() {
    super.initState();
    selected = available.contains(widget.initialSection)
        ? widget.initialSection
        : available.first;
  }

  static const categories = <(String, IconData)>[
    ('General', Icons.tune_outlined),
    ('POS', Icons.point_of_sale_outlined),
    ('Inventory', Icons.inventory_2_outlined),
    ('Business', Icons.storefront_outlined),
    ('Team & Access', Icons.people_outline),
    ('Receipt & Hardware', Icons.print_outlined),
    ('System', Icons.settings_backup_restore_outlined),
  ];

  Widget _section(String title, String description, Widget body,
      {List<String>? tabs, int activeTab = 0, ValueChanged<int>? onTab}) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: theme.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(description,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      if (tabs != null) ...[
        const SizedBox(height: 16),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < tabs.length; i++)
                Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                        label: Text(tabs[i]),
                        selected: activeTab == i,
                        onSelected: (_) => onTab?.call(i))),
            ])),
      ],
      const SizedBox(height: 16),
      Expanded(child: body),
    ]);
  }

  Widget _content() => switch (selected) {
        0 => _section(
            'General',
            'Business identity and application appearance.',
            ListView(children: [
              BusinessIdentitySettings(
                  store: widget.printerStore,
                  onDirtyChanged: (value) => dirty = value),
              const SizedBox(height: 24),
              Text('Application appearance',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              const ThemeSettingTile(),
              const SidebarColorTile(),
              const SidebarLogoTile(),
              const ResetAppearanceTile(),
            ])),
        1 => _section('POS', 'Checkout experience and scanner behavior.',
            const PosLayoutSettingsScreen(embedded: true)),
        2 => _section(
            'Inventory',
            'Stock health and product capabilities.',
            inventoryTab == 0
                ? InventoryHealthSettingsScreen(
                    repository: InventoryHealthRepository(widget.repository.db),
                    embedded: true,
                    onDirtyChanged: (value) => dirty = value)
                : BusinessFeaturesScreen(
                    repository: widget.repository,
                    user: widget.user,
                    embedded: true),
            tabs: const ['Stock health', 'Product capabilities'],
            activeTab: inventoryTab,
            onTab: _selectInventoryTab),
        3 => _section(
            'Business',
            'Loyalty and quotation preferences.',
            businessTab == 0
                ? LoyaltySettingsScreen(
                    db: widget.repository.db, user: widget.user, embedded: true)
                : QuotationTemplateScreen(
                    db: widget.repository.db, embedded: true),
            tabs: const ['Loyalty', 'Quotation defaults'],
            activeTab: businessTab,
            onTab: (v) => setState(() => businessTab = v)),
        4 => _section(
            'Team & Access',
            'Staff accounts, roles, security, and activity.',
            widget.user.can(PosPermission.manageUsers)
                ? UsersScreen(auth: widget.auth, embedded: true)
                : const Center(
                    child:
                        Text('You do not have permission to manage users.'))),
        5 => _section(
            'Receipt & Hardware',
            'Receipt identity, printer, and cash drawer.',
            widget.user.can(PosPermission.managePrinter)
                ? PrinterSettingsScreen(
                    store: widget.printerStore,
                    printer: widget.printer,
                    devices: widget.devices,
                    embedded: true,
                    onDirtyChanged: (value) => dirty = value)
                : const Center(
                    child: Text(
                        'You do not have permission to manage printer settings.'))),
        _ => _section(
            'System',
            'Device health and data protection.',
            systemTab == 0
                ? widget.recoveryScreen is RecoveryScreen
                    ? ListView(children: [
                        Card(
                            child: ListTile(
                                leading: const Icon(Icons.storage_outlined),
                                title: const Text('Database'),
                                trailing: Text(
                                    (widget.recoveryScreen as RecoveryScreen)
                                        .databaseStatus))),
                        Card(
                            child: ListTile(
                                leading:
                                    const Icon(Icons.verified_user_outlined),
                                title: const Text('License'),
                                trailing: Text(
                                    (widget.recoveryScreen as RecoveryScreen)
                                        .licenseStatus))),
                        Card(
                            child: ListTile(
                                leading: const Icon(Icons.layers_outlined),
                                title: const Text('Database schema'),
                                trailing: Text(
                                    '${widget.repository.db.schemaVersion}'))),
                      ])
                    : const Center(
                        child: Text(
                            'System health is unavailable on this device.'))
                : widget.user.can(PosPermission.manageRecovery) &&
                        widget.recoveryScreen != null
                    ? widget.recoveryScreen is RecoveryScreen
                        ? RecoveryScreen(
                            backupDirectory:
                                (widget.recoveryScreen as RecoveryScreen)
                                    .backupDirectory,
                            databaseStatus:
                                (widget.recoveryScreen as RecoveryScreen)
                                    .databaseStatus,
                            licenseStatus:
                                (widget.recoveryScreen as RecoveryScreen)
                                    .licenseStatus,
                            auth:
                                (widget.recoveryScreen as RecoveryScreen).auth,
                            onRestore: (widget.recoveryScreen as RecoveryScreen)
                                .onRestore,
                            onCreate: (widget.recoveryScreen as RecoveryScreen)
                                .onCreate,
                            onDelete: (widget.recoveryScreen as RecoveryScreen)
                                .onDelete,
                            onRecheck: (widget.recoveryScreen as RecoveryScreen)
                                .onRecheck,
                            listBackupEntries:
                                (widget.recoveryScreen as RecoveryScreen)
                                    .listBackupEntries,
                            showHealth: false)
                        : widget.recoveryScreen!
                    : const Center(
                        child: Text(
                            'Backup and recovery is unavailable for this account.')),
            tabs: const ['System Health', 'Backup & Recovery'],
            activeTab: systemTab,
            onTab: (v) => setState(() => systemTab = v)),
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
                            key: const Key('settings-navigation'),
                            itemCount: available.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 4),
                            itemBuilder: (context, index) {
                              final category = available[index];
                              final active = selected == category;
                              return Material(
                                color: active
                                    ? scheme.primaryContainer
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => _selectCategory(category),
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 12),
                                      child: Row(children: [
                                        Icon(categories[category].$2,
                                            size: 20,
                                            color: active
                                                ? scheme.primary
                                                : scheme.onSurfaceVariant),
                                        const SizedBox(width: 12),
                                        Expanded(
                                            child: Text(categories[category].$1,
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
                    Expanded(child: _content()),
                  ]);
            })),
          ])),
    ))));
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
