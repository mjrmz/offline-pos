import 'dart:io';
import 'package:flutter/material.dart';
import '../../backup/backup_service.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../shared/utils/safe_message.dart';

class RecoveryScreen extends StatefulWidget {
  final Directory backupDirectory;
  final String databaseStatus;
  final String licenseStatus;
  final AuthService? auth;
  final Future<void> Function(BackupRecord, String?, String?) onRestore;
  final Future<void> Function()? onCreate;
  final Future<void> Function(File)? onDelete;
  final Future<void> Function()? onRecheck;
  final List<FileSystemEntity> Function(Directory)? listBackupEntries;
  final bool showHealth;
  const RecoveryScreen(
      {super.key,
      required this.backupDirectory,
      required this.databaseStatus,
      this.licenseStatus = 'unavailable',
      required this.onRestore,
      this.auth,
      this.onRecheck,
      this.onCreate,
      this.onDelete,
      this.listBackupEntries,
      this.showHealth = true});
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  List<(File, BackupRecord?, String?)> entries = [];
  bool busy = false;
  String? message;
  final ownerName = TextEditingController();
  final password = TextEditingController();
  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    ownerName.dispose();
    password.dispose();
    super.dispose();
  }

  void refresh() {
    final rows = <(File, BackupRecord?, String?)>[];
    try {
      if (widget.backupDirectory.existsSync()) {
        for (final item
            in widget.listBackupEntries?.call(widget.backupDirectory) ??
                widget.backupDirectory.listSync()) {
          if (item is! File || !item.path.endsWith('.sqlite')) continue;
          try {
            rows.add((item, BackupService.inspect(item), null));
          } catch (e) {
            rows.add((item, null, safeMessage(e)));
          }
        }
      }
    } on FileSystemException {
      if (mounted) {
        setState(() {
          entries = [];
          message = 'Backup directory cannot be read';
        });
      }
      return;
    }
    rows.sort((a, b) => b.$1.path.compareTo(a.$1.path));
    if (mounted) setState(() => entries = rows);
  }

  Future<bool> confirm(String title) async =>
      await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
                  title: Text(title),
                  content: Text(title.startsWith('Delete')
                      ? 'This permanently removes the selected backup.'
                      : 'This replaces current local data. Keep a separate copy before proceeding.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Confirm'))
                  ])) ??
      false;
  Future<void> restore(BackupRecord record) async {
    if (!(await confirm('Restore ${record.file.uri.pathSegments.last}?'))) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.onRestore(
          record,
          widget.auth == null ? ownerName.text : null,
          widget.auth == null ? password.text : null);
      if (mounted) setState(() => message = 'Restore completed');
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> create() async {
    final auth = widget.auth;
    if (auth == null) return;
    auth.requireSession(PosPermission.manageRecovery);
    setState(() => busy = true);
    try {
      await widget.onCreate?.call();
      refresh();
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> delete(File file) async {
    widget.auth?.requireSession(PosPermission.manageRecovery);
    if (!(await confirm('Delete ${file.uri.pathSegments.last}?'))) return;
    setState(() => busy = true);
    try {
      await widget.onDelete?.call(file);
      refresh();
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.all(16), children: [
        if (!widget.showHealth) ...[
          Text('Backup & Recovery',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text('Database protection and restore points.'),
          const SizedBox(height: 16),
        ],
        if (widget.showHealth)
          Text('System health',
              style: Theme.of(context).textTheme.headlineSmall),
        if (widget.showHealth)
          Card(
              child: Column(children: [
            ListTile(
                leading: const Icon(Icons.storage),
                title: const Text('Database'),
                trailing: Text(widget.databaseStatus)),
            ListTile(
                leading: const Icon(Icons.verified_user),
                title: const Text('License'),
                trailing: Text(widget.licenseStatus)),
            ListTile(
                leading: const Icon(Icons.backup),
                title: const Text('Backups'),
                trailing: Text(
                    '${entries.where((e) => e.$2 != null).length} valid, '
                    '${entries.where((e) => e.$2 == null).length} invalid')),
          ])),
        if (message != null) Text(message!),
        if (widget.auth == null) ...[
          TextField(
              controller: ownerName,
              decoration:
                  const InputDecoration(labelText: 'Owner name in backup')),
          TextField(
              controller: password,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Owner password in backup')),
        ],
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (widget.auth != null)
            FilledButton.icon(
                onPressed: busy ? null : create,
                icon: const Icon(Icons.add),
                label: const Text('Create backup')),
          OutlinedButton(
              onPressed: busy ? null : refresh,
              child: const Text('Verify backups')),
          if (widget.onRecheck != null)
            TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await widget.onRecheck!();
                        } catch (e) {
                          if (mounted) setState(() => message = safeMessage(e));
                        }
                      },
                child: const Text('Recheck database')),
        ]),
        const SizedBox(height: 16),
        Text('Backup history', style: Theme.of(context).textTheme.titleLarge),
        if (entries.isEmpty)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                      'No backups found. Create a manual backup to protect this device.'))),
        if (entries.isNotEmpty)
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(columns: const [
                DataColumn(label: Text('Backup')),
                DataColumn(label: Text('Created')),
                DataColumn(label: Text('Type')),
                DataColumn(label: Text('Schema')),
                DataColumn(label: Text('Size')),
                DataColumn(label: Text('Integrity')),
                DataColumn(label: Text('Actions')),
              ], rows: [
                for (final entry in entries)
                  DataRow(cells: [
                    DataCell(Text(entry.$1.uri.pathSegments.last)),
                    DataCell(Text(entry.$2?.createdAt.toString() ?? '—')),
                    DataCell(Text(entry.$2?.kind.name ?? '—')),
                    DataCell(Text(entry.$2?.schemaVersion.toString() ?? '—')),
                    DataCell(
                        Text(entry.$2 == null ? '—' : '${entry.$2!.bytes} B')),
                    DataCell(Text(entry.$2 == null ? 'Invalid' : 'Valid')),
                    DataCell(PopupMenuButton<String>(
                        tooltip: 'Backup actions',
                        enabled: !busy,
                        onSelected: (action) {
                          if (action == 'restore' && entry.$2 != null) {
                            restore(entry.$2!);
                          }
                          if (action == 'delete') delete(entry.$1);
                        },
                        itemBuilder: (_) => [
                              if (entry.$2 != null)
                                const PopupMenuItem(
                                    value: 'restore', child: Text('Restore')),
                              if (widget.onDelete != null)
                                const PopupMenuItem(
                                    value: 'delete', child: Text('Delete')),
                            ])),
                  ])
              ])),
      ]);
}
