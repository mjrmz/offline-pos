import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../data/database.dart';
import '../../data/daos/role_repository.dart';
import '../../shared/utils/safe_message.dart';
import '../../shared/widgets/app_workspace.dart';

class UsersScreen extends StatefulWidget {
  final AuthService auth;
  const UsersScreen({super.key, required this.auth});
  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<User> users = [];
  List<RoleRecord> roles = [];
  List<AuditLog> activity = [];
  int activityCount = 0, activityPage = 0, tab = 0;
  String query = '', roleFilter = 'All', statusFilter = 'All';
  final searchController = TextEditingController();
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      widget.auth.requireSession(PosPermission.manageUsers);
      final rows = await widget.auth.repository.managedUsers();
      final roleRows = await widget.auth.roles.all();
      final logs = await widget.auth.repository
          .securityActivity(offset: activityPage * 50);
      final count = await widget.auth.repository.securityActivityCount();
      if (mounted) {
        setState(() {
          users = rows;
          roles = roleRows;
          activity = logs;
          activityCount = count;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  bool locked(User u) =>
      u.lockedUntil != null && widget.auth.now().isBefore(u.lockedUntil!);
  String status(User u) => !u.isActive
      ? 'Disabled'
      : locked(u)
          ? 'Temporarily locked'
          : 'Active';
  String roleName(String role) =>
      roles.where((r) => r.code == role).map((r) => r.name).firstOrNull ??
      '${role[0].toUpperCase()}${role.substring(1)}';
  String roleAuditDetail(AuditLog event) {
    final raw = event.details;
    if (raw == null) return '';
    final parts = raw.split(';');
    final head = parts.first.split(':');
    final title = head.length > 1 ? head[1] : 'Role';
    if (event.action != 'role_updated') return title;
    String names(String prefix) {
      final value = parts.where((p) => p.startsWith(prefix)).firstOrNull;
      if (value == null || value.substring(prefix.length).isEmpty) return '';
      return value
          .substring(prefix.length)
          .split(',')
          .map((key) =>
              PermissionRegistry.byKey[key]?.name ?? 'Unknown permission')
          .join(', ');
    }

    final added = names('added='), removed = names('removed=');
    return '$title${added.isEmpty ? '' : ' · Added: $added'}'
        '${removed.isEmpty ? '' : ' · Removed: $removed'}';
  }

  Color tone(String value) => appStatusColor(
      context,
      switch (value) {
        'Active' => AppStatusTone.success,
        'Temporarily locked' => AppStatusTone.warning,
        'Disabled' => AppStatusTone.neutral,
        _ => AppStatusTone.info,
      });
  Future<bool> confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) =>
              AlertDialog(title: Text(title), content: Text(detail), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: Text(action)),
              ])) ??
      false;
  Future<void> perform(Future<void> Function() action) async {
    try {
      await action();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> credentialDialog({User? user, String? changeTo}) async {
    final creating = user == null;
    var roleCode = changeTo ?? (creating ? 'cashier' : user.role);
    final name = TextEditingController(text: user?.name);
    final secret = TextEditingController(),
        confirmSecret = TextEditingController();
    String? dialogError;
    await showDialog<void>(
        context: context,
        builder: (c) => StatefulBuilder(builder: (c, update) {
              final pin = roleCode == 'cashier';
              final validSecret = pin
                  ? RegExp(r'^\d{4,6}$').hasMatch(secret.text)
                  : secret.text.length >= 8;
              final valid = (creating ? name.text.trim().isNotEmpty : true) &&
                  validSecret &&
                  secret.text == confirmSecret.text;
              final title = creating
                  ? 'Create user'
                  : changeTo != null
                      ? 'Change role for ${user.name}'
                      : 'Reset ${pin ? 'PIN' : 'password'} for ${user.name}';
              return AlertDialog(
                  title: Text(title),
                  content: SizedBox(
                      width: 420,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        if (dialogError != null)
                          Text(dialogError!,
                              style: TextStyle(
                                  color: Theme.of(c).colorScheme.error)),
                        if (creating) ...[
                          TextField(
                              controller: name,
                              onChanged: (_) => update(() {}),
                              decoration: InputDecoration(
                                  labelText: 'Name',
                                  errorText: name.text.isEmpty
                                      ? null
                                      : name.text.trim().isEmpty
                                          ? 'Name is required'
                                          : null)),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                              initialValue: roleCode,
                              decoration:
                                  const InputDecoration(labelText: 'Role'),
                              items: roles
                                  .map((r) => DropdownMenuItem(
                                      value: r.code, child: Text(r.name)))
                                  .toList(),
                              onChanged: (r) => update(() {
                                    roleCode = r!;
                                    secret.clear();
                                    confirmSecret.clear();
                                  })),
                        ] else if (changeTo != null)
                          Text(
                              'New role: ${roleName(roleCode)}. Set a new ${pin ? 'PIN' : 'password'} for this sign-in method. Permissions update immediately.'),
                        const SizedBox(height: 12),
                        TextField(
                            controller: secret,
                            obscureText: true,
                            keyboardType:
                                pin ? TextInputType.number : TextInputType.text,
                            onChanged: (_) => update(() {}),
                            decoration: InputDecoration(
                                labelText: pin ? 'PIN' : 'Password',
                                helperText: pin
                                    ? '4–6 digits'
                                    : 'At least 8 characters',
                                errorText: secret.text.isNotEmpty &&
                                        !validSecret
                                    ? pin
                                        ? 'PIN must contain 4–6 digits'
                                        : 'Password must be at least 8 characters'
                                    : null)),
                        const SizedBox(height: 12),
                        TextField(
                            controller: confirmSecret,
                            obscureText: true,
                            keyboardType:
                                pin ? TextInputType.number : TextInputType.text,
                            onChanged: (_) => update(() {}),
                            decoration: InputDecoration(
                                labelText:
                                    pin ? 'Confirm PIN' : 'Confirm password',
                                errorText: confirmSecret.text.isNotEmpty &&
                                        confirmSecret.text != secret.text
                                    ? '${pin ? 'PINs' : 'Passwords'} do not match'
                                    : null)),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: valid
                            ? () async {
                                try {
                                  if (creating) {
                                    if (UserRole.values.any((r) =>
                                        r.name == roleCode &&
                                        r != UserRole.custom)) {
                                      await widget.auth.createUser(
                                          name.text,
                                          UserRole.values.byName(roleCode),
                                          secret.text);
                                    } else {
                                      await widget.auth.createUserWithRole(
                                          name.text, roleCode, secret.text);
                                    }
                                  } else if (changeTo != null) {
                                    if (UserRole.values.any((r) =>
                                        r.name == roleCode &&
                                        r != UserRole.custom)) {
                                      await widget.auth.changeRole(
                                          user.id,
                                          UserRole.values.byName(roleCode),
                                          secret.text);
                                    } else {
                                      await widget.auth.changeRoleTo(
                                          user.id, roleCode, secret.text);
                                    }
                                  } else {
                                    await widget.auth
                                        .resetCredential(user.id, secret.text);
                                  }
                                  if (c.mounted) Navigator.pop(c);
                                  await refresh();
                                } catch (e) {
                                  update(() => dialogError = safeMessage(e));
                                }
                              }
                            : null,
                        child: Text(creating
                            ? 'Create'
                            : changeTo != null
                                ? 'Change role'
                                : 'Reset credential'))
                  ]);
            }));
    name.dispose();
    secret.dispose();
    confirmSecret.dispose();
  }

  Future<void> edit(User user) async {
    final name = TextEditingController(text: user.name);
    String? dialogError;
    await showDialog<void>(
        context: context,
        builder: (c) => StatefulBuilder(
            builder: (c, update) => AlertDialog(
                    title: Text('Edit ${user.name}'),
                    content: SizedBox(
                        width: 400,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          if (dialogError != null)
                            Text(dialogError!,
                                style: TextStyle(
                                    color: Theme.of(c).colorScheme.error)),
                          TextField(
                              controller: name,
                              onChanged: (_) => update(() {}),
                              decoration:
                                  const InputDecoration(labelText: 'Name')),
                          const SizedBox(height: 12),
                          Text(
                              'Role: ${roleName(user.role)} · Status: ${status(user)}'),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: name.text.trim().isEmpty
                              ? null
                              : () async {
                                  try {
                                    await widget.auth
                                        .editUser(user.id, name.text);
                                    if (c.mounted) Navigator.pop(c);
                                    await refresh();
                                  } catch (e) {
                                    update(() => dialogError = safeMessage(e));
                                  }
                                },
                          child: const Text('Save'))
                    ])));
    name.dispose();
  }

  Widget metric(String label, int count) => SizedBox(
      width: 170,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$count',
                        style: Theme.of(context).textTheme.headlineMedium),
                    Text(label)
                  ]))));
  Widget usersTab() {
    final shown = users
        .where((u) =>
            u.name.toLowerCase().contains(query.toLowerCase()) &&
            (roleFilter == 'All' || u.role == roleFilter) &&
            (statusFilter == 'All' || status(u) == statusFilter))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        metric('Total users', users.length),
        metric('Active', users.where((u) => status(u) == 'Active').length),
        metric('Cashiers', users.where((u) => u.role == 'cashier').length),
        metric('Managers', users.where((u) => u.role == 'manager').length),
        metric('Locked / Disabled',
            users.where((u) => status(u) != 'Active').length)
      ]),
      const SizedBox(height: 16),
      Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
                width: 260,
                child: TextField(
                    controller: searchController,
                    decoration: const InputDecoration(
                        labelText: 'Search users...',
                        prefixIcon: Icon(Icons.search)),
                    onChanged: (v) => setState(() => query = v))),
            SizedBox(
                width: 150,
                child: DropdownButtonFormField<String>(
                    key: ValueKey('role-$roleFilter'),
                    isExpanded: true,
                    initialValue: roleFilter,
                    decoration: const InputDecoration(labelText: 'Role'),
                    items: ['All', ...roles.map((r) => r.code)]
                        .map((v) => DropdownMenuItem(
                            value: v,
                            child: Text(v == 'All' ? v : roleName(v))))
                        .toList(),
                    onChanged: (v) => setState(() => roleFilter = v!))),
            SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                    key: ValueKey('status-$statusFilter'),
                    isExpanded: true,
                    initialValue: statusFilter,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: ['All', 'Active', 'Disabled', 'Temporarily locked']
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (v) => setState(() => statusFilter = v!))),
            TextButton(
                onPressed: () => setState(() {
                      searchController.clear();
                      query = '';
                      roleFilter = 'All';
                      statusFilter = 'All';
                    }),
                child: const Text('Reset filters')),
          ]),
      const SizedBox(height: 12),
      if (shown.isEmpty)
        const AppEmptyState(title: 'No users match these filters.')
      else
        ...shown.map((u) {
          final self = u.id == widget.auth.current?.id;
          final s = status(u);
          return Card(
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    CircleAvatar(
                        child: Text(
                            u.name.isEmpty ? '?' : u.name[0].toUpperCase())),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(u.name,
                              style: Theme.of(context).textTheme.titleMedium),
                          Text(
                              '${roleName(u.role)}${self ? ' · Current user' : ''}')
                        ])),
                    Wrap(spacing: 6, children: [
                      AppStatusBadge(
                          label: roleName(u.role), color: tone('Role')),
                      AppStatusBadge(label: s, color: tone(s))
                    ]),
                    PopupMenuButton<String>(
                        tooltip: 'Actions for ${u.name}',
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await edit(u);
                          }
                          if (!mounted) return;
                          if (v == 'role') {
                            final next = await showDialog<String>(
                                context: context,
                                builder: (c) => SimpleDialog(
                                    title: const Text('Change role'),
                                    children: roles
                                        .where((r) => r.code != u.role)
                                        .map((r) => SimpleDialogOption(
                                            onPressed: () =>
                                                Navigator.pop(c, r.code),
                                            child: Text(r.name)))
                                        .toList()));
                            if (next != null &&
                                mounted &&
                                await confirm(
                                    'Change ${u.name} to ${roleName(next)}?',
                                    '${roleName(u.role)} → ${roleName(next)}. '
                                        'Permissions update immediately and a new credential is required.',
                                    'Continue')) {
                              await credentialDialog(user: u, changeTo: next);
                            }
                          }
                          if (v == 'reset') {
                            if (await confirm(
                                'Reset ${u.name} credential?',
                                'The current credential will stop working.',
                                'Continue')) {
                              await credentialDialog(user: u);
                            }
                          }
                          if (v == 'status') {
                            final enable = !u.isActive;
                            if (await confirm(
                                '${enable ? 'Enable' : 'Disable'} ${u.name}?',
                                enable
                                    ? 'This account can sign in again.'
                                    : 'This account will no longer be able to sign in.',
                                enable ? 'Enable' : 'Disable')) {
                              await perform(
                                  () => widget.auth.setActive(u.id, enable));
                            }
                          }
                          if (v == 'activity') setState(() => tab = 3);
                        },
                        itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'edit', child: Text('Edit user')),
                              if (!self)
                                const PopupMenuItem(
                                    value: 'role', child: Text('Change role')),
                              PopupMenuItem(
                                  value: 'reset',
                                  child: Text(
                                      'Reset ${u.role == 'cashier' ? 'PIN' : 'password'}')),
                              if (!self)
                                PopupMenuItem(
                                    value: 'status',
                                    child: Text(u.isActive
                                        ? 'Disable account'
                                        : 'Enable account')),
                              const PopupMenuItem(
                                  value: 'activity',
                                  child: Text('View activity')),
                            ]),
                  ])));
        }),
    ]);
  }

  Future<void> roleDialog({RoleRecord? role, RoleRecord? template}) async {
    final editing = role != null;
    final name = TextEditingController(
        text: role?.name ?? (template == null ? '' : '${template.name} copy'));
    final description = TextEditingController(text: role?.description ?? '');
    var selected = <PosPermission>{
      ...?role?.permissions,
      if (role == null) ...?template?.permissions
    };
    String? templateCode = template?.code;
    String? dialogError;
    await showDialog<void>(
        context: context,
        builder: (c) => StatefulBuilder(builder: (c, update) {
              final validName = name.text.trim().isNotEmpty &&
                  !roles.any((r) =>
                      r.code != role?.code &&
                      r.name.trim().toLowerCase() ==
                          name.text.trim().toLowerCase());
              final changed = !editing ||
                  name.text.trim() != role.name ||
                  description.text.trim() != role.description ||
                  !selected.containsAll(role.permissions) ||
                  !role.permissions.containsAll(selected);
              final groups =
                  PermissionRegistry.entries.map((e) => e.group).toSet();
              return AlertDialog(
                title: Text(editing ? 'Edit ${role.name}' : 'Create role'),
                content: SizedBox(
                    width: 820,
                    height: 570,
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          if (dialogError != null)
                            Text(dialogError!,
                                style: TextStyle(
                                    color: Theme.of(c).colorScheme.error)),
                          TextField(
                              controller: name,
                              onChanged: (_) => update(() {}),
                              decoration: InputDecoration(
                                  labelText: 'Role name *',
                                  errorText: name.text.isNotEmpty && !validName
                                      ? 'Enter a unique role name'
                                      : null)),
                          const SizedBox(height: 12),
                          TextField(
                              controller: description,
                              onChanged: (_) => update(() {}),
                              decoration: const InputDecoration(
                                  labelText: 'Description')),
                          if (!editing) ...[
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String?>(
                                initialValue: templateCode,
                                decoration: const InputDecoration(
                                    labelText: 'Start from'),
                                items: [
                                  const DropdownMenuItem<String?>(
                                      value: null, child: Text('No template')),
                                  ...roles.where((r) => r.code != 'owner').map(
                                      (r) => DropdownMenuItem<String?>(
                                          value: r.code, child: Text(r.name)))
                                ],
                                onChanged: (code) => update(() {
                                      templateCode = code;
                                      selected = code == null
                                          ? {}
                                          : {
                                              ...roles
                                                  .firstWhere(
                                                      (r) => r.code == code)
                                                  .permissions
                                            };
                                    })),
                          ],
                          if (editing && role.assignedUsers > 0)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Text(
                                    '${role.assignedUsers} assigned users. Permission changes take effect after saving.')),
                          const SizedBox(height: 16),
                          for (final group in groups) ...[
                            Text(group,
                                style: Theme.of(c).textTheme.titleMedium),
                            const Divider(),
                            for (final info in PermissionRegistry.entries
                                .where((e) => e.group == group))
                              CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Row(children: [
                                    Flexible(child: Text(info.name)),
                                    if (info.sensitive)
                                      const Padding(
                                          padding: EdgeInsets.only(left: 8),
                                          child: Text('Sensitive',
                                              style: TextStyle(fontSize: 12)))
                                  ]),
                                  subtitle: Text(info.ownerOnly
                                      ? '${info.description} Owner only.'
                                      : info.description),
                                  value: selected.contains(info.key),
                                  onChanged: info.ownerOnly
                                      ? null
                                      : (value) => update(() {
                                            if (value == true) {
                                              selected =
                                                  PermissionRegistry.normalize(
                                                      {...selected, info.key});
                                            } else {
                                              selected.remove(info.key);
                                              var changed = true;
                                              while (changed) {
                                                final before = selected.length;
                                                for (final dependent
                                                    in PermissionRegistry
                                                        .entries) {
                                                  if (selected.contains(
                                                          dependent.key) &&
                                                      !selected.containsAll(
                                                          dependent.requires)) {
                                                    selected
                                                        .remove(dependent.key);
                                                  }
                                                }
                                                changed =
                                                    before != selected.length;
                                              }
                                            }
                                          })),
                            const SizedBox(height: 10),
                          ],
                          Text('${selected.length} permissions enabled',
                              style: Theme.of(c).textTheme.labelLarge),
                          for (final group in groups)
                            Text(
                                '$group: ${PermissionRegistry.entries.where((e) => e.group == group && selected.contains(e.key)).length} / '
                                '${PermissionRegistry.entries.where((e) => e.group == group && !e.ownerOnly).length}'),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: validName && changed
                          ? () async {
                              try {
                                if (editing) {
                                  final removed =
                                      role.permissions.difference(selected);
                                  if (removed.isNotEmpty &&
                                      role.assignedUsers > 0) {
                                    final ok = await confirm(
                                        'Remove permissions?',
                                        '${role.assignedUsers} users will lose ${removed.map((p) => PermissionRegistry.byKey[p.name]!.name).join(', ')}.',
                                        'Remove permissions');
                                    if (!ok) return;
                                  }
                                  await widget.auth.updateRole(role.code,
                                      name.text, description.text, selected);
                                } else {
                                  await widget.auth.createRole(
                                      name.text, description.text, selected,
                                      duplicatedFrom: template?.code);
                                }
                                if (c.mounted) Navigator.pop(c);
                                await refresh();
                              } catch (e) {
                                update(() => dialogError = safeMessage(e));
                              }
                            }
                          : null,
                      child: Text(editing ? 'Save changes' : 'Create role'))
                ],
              );
            }));
    name.dispose();
    description.dispose();
  }

  Widget rolesTab() {
    final items = {
      for (final info in PermissionRegistry.entries) info.name: info.key
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Roles & Permissions',
              style: Theme.of(context).textTheme.headlineSmall),
          const Text(
              'Control what each type of staff member can access and change.')
        ])),
        FilledButton.icon(
            onPressed: () => roleDialog(),
            icon: const Icon(Icons.add),
            label: const Text('Create role')),
      ]),
      const SizedBox(height: 12),
      for (final role in roles)
        Card(
            child: ListTile(
          title: Text(role.name),
          subtitle: Text('${role.isSystem ? 'System role' : 'Custom role'} · '
              '${role.assignedUsers} users · ${role.permissions.length} permissions'
              '${role.description.isEmpty ? '' : ' · ${role.description}'}'),
          onTap: role.isSystem ? null : () => roleDialog(role: role),
          trailing: Wrap(spacing: 4, children: [
            IconButton(
                tooltip: 'Duplicate ${role.name}',
                icon: const Icon(Icons.copy),
                onPressed: () => roleDialog(template: role)),
            if (!role.isSystem)
              IconButton(
                  tooltip: 'Edit ${role.name}',
                  icon: const Icon(Icons.edit),
                  onPressed: () => roleDialog(role: role)),
            if (!role.isSystem)
              IconButton(
                  tooltip: 'Delete ${role.name}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: role.assignedUsers > 0
                      ? null
                      : () async {
                          if (await confirm(
                              'Delete ${role.name}?',
                              'This unused role will be removed.',
                              'Delete role')) {
                            await perform(
                                () => widget.auth.deleteRole(role.code));
                          }
                        }),
          ]),
        )),
      const SizedBox(height: 20),
      Text('System role comparison',
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                  width:
                      constraints.maxWidth < 700 ? 700 : constraints.maxWidth,
                  child: Column(children: [
                    for (final entry in <MapEntry<String, PosPermission>?>[
                      null,
                      ...items.entries
                    ])
                      Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 16),
                        decoration: BoxDecoration(
                            border: Border(
                                bottom: BorderSide(
                                    color: Theme.of(context).dividerColor))),
                        child: Row(children: [
                          Expanded(
                              flex: 3, child: Text(entry?.key ?? 'Capability')),
                          for (final role in [
                            UserRole.owner,
                            UserRole.manager,
                            UserRole.cashier
                          ])
                            Expanded(
                                child: Text(
                                    entry == null
                                        ? roleName(role.name)
                                        : ActiveUser('', '', role)
                                                .can(entry.value)
                                            ? '✓'
                                            : '—',
                                    semanticsLabel: entry == null
                                        ? null
                                        : '${roleName(role.name)}: ${ActiveUser('', '', role).can(entry.value) ? 'Allowed' : 'Not allowed'}')),
                        ]),
                      ),
                  ]))))
    ]);
  }

  Widget securityTab() {
    final owner = users.where((u) => u.role == 'owner').firstOrNull;
    Widget card(String title, String body) => Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(body)
            ])));
    return Wrap(spacing: 12, runSpacing: 12, children: [
      SizedBox(
          width: 360,
          child: card('Authentication',
              'Cashiers sign in with a 4–6 digit PIN. Managers and Owners use a password of at least 8 characters. Credentials are stored as hashes.')),
      SizedBox(
          width: 360,
          child: card('Account lockout',
              '${AuthService.maxAttempts} failed attempts trigger a temporary lockout for ${AuthService.lockDuration.inMinutes} minutes.')),
      SizedBox(
          width: 360,
          child: card(
              'Owner recovery',
              owner?.recoveryQuestion == null
                  ? 'No recovery question is configured for the listed Owner.'
                  : 'Recovery configured. Security question: ${owner!.recoveryQuestion}')),
      SizedBox(
          width: 360,
          child: card('Sensitive actions',
              'Only Owners can manage users and recovery. Managers or Owners may authorize manual discounts with their password.')),
      SizedBox(
          width: 360,
          child: card('Session',
              'Logging out or locking the register clears the current local session.')),
    ]);
  }

  Widget activityTab() => Column(children: [
        if (activity.isEmpty)
          const AppEmptyState(title: 'No user-management activity yet.')
        else
          ...activity.map((a) {
            final actor = users.where((u) => u.id == a.userId).firstOrNull;
            final targetId = a.details?.split(':').first;
            final target = users.where((u) => u.id == targetId).firstOrNull;
            final label = switch (a.action) {
              'user_created' => 'Created user',
              'user_activated' => 'Enabled account',
              'user_deactivated' => 'Disabled account',
              'user_renamed' => 'Edited user',
              'user_role_changed' => 'Changed role',
              'role_created' => 'Created role',
              'role_duplicated' => 'Duplicated role',
              'role_updated' => 'Updated role',
              'role_deleted' => 'Deleted role',
              'credential_reset' => 'Reset credential',
              'owner_bootstrap' => 'Owner created',
              'password_recovered' => 'Owner recovery used',
              'recovery_failed' => 'Recovery failed',
              'login_success' => 'Signed in',
              'login_failed' => 'Sign-in failed',
              'logout' => 'Signed out',
              'register_locked' => 'Locked register',
              _ => a.action
            };
            return Card(
                child: ListTile(
                    title: Text(
                        '${actor?.name ?? 'Unknown user'} · ${actor == null ? 'Unknown role' : roleName(actor.role)}'),
                    subtitle: Text(
                        '$label${target == null ? '' : ' · ${target.name}'}'
                        '${a.action.startsWith('role_') ? ' · ${roleAuditDetail(a)}' : ''}'),
                    trailing: Text(
                        '${MaterialLocalizations.of(context).formatMediumDate(a.createdAt.toLocal())}, ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(a.createdAt.toLocal()))}')));
          }),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          Text(
              '${activityPage * 50 + 1}–${(activityPage * 50 + activity.length).clamp(0, activityCount)} of $activityCount'),
          TextButton(
              onPressed: activityPage == 0
                  ? null
                  : () {
                      setState(() => activityPage--);
                      refresh();
                    },
              child: const Text('Previous')),
          TextButton(
              onPressed: (activityPage + 1) * 50 >= activityCount
                  ? null
                  : () {
                      setState(() => activityPage++);
                      refresh();
                    },
              child: const Text('Next'))
        ]),
      ]);
  @override
  Widget build(BuildContext context) => Scaffold(
          body: ListView(padding: const EdgeInsets.all(24), children: [
        AppPageHeader(
            title: 'Users & Roles',
            subtitle:
                'Manage staff access, credentials, permissions, and account security.',
            action: FilledButton.icon(
                onPressed: () => credentialDialog(),
                icon: const Icon(Icons.add),
                label: const Text('Add user'))),
        AppWorkspaceTabs(labels: const [
          'Users',
          'Roles & Permissions',
          'Security',
          'Activity'
        ], selectedIndex: tab, onSelected: (v) => setState(() => tab = v)),
        const SizedBox(height: 20),
        if (error != null)
          Text(error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        switch (tab) {
          0 => usersTab(),
          1 => rolesTab(),
          2 => securityTab(),
          _ => activityTab()
        },
      ]));
}
