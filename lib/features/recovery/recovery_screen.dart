import 'dart:io';
import 'package:flutter/material.dart';
import '../../backup/backup_service.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../shared/utils/safe_message.dart';

class RecoveryScreen extends StatefulWidget {
  final Directory backupDirectory;
  final String databaseStatus;
  final AuthService? auth;
  final Future<void> Function(BackupRecord, String?, String?) onRestore;
  final Future<void> Function()? onCreate;
  final Future<void> Function(File)? onDelete;
  final Future<void> Function()? onRecheck;
  const RecoveryScreen(
      {super.key,
      required this.backupDirectory,
      required this.databaseStatus,
      required this.onRestore,
      this.auth,
      this.onRecheck,
      this.onCreate,
      this.onDelete});
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
    if (widget.backupDirectory.existsSync()) {
      for (final item in widget.backupDirectory.listSync()) {
        if (item is! File || !item.path.endsWith('.sqlite')) continue;
        try {
          rows.add((item, BackupService.inspect(item), null));
        } catch (e) {
          rows.add((item, null, safeMessage(e)));
        }
      }
    }
    rows.sort((a, b) => b.$1.path.compareTo(a.$1.path));
    if (mounted) setState(() => entries = rows);
  }

  Future<bool> confirm(String title) async =>
      await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
                  title: Text(title),
                  content: const Text(
                      'This replaces current local data. Keep a separate copy before proceeding.'),
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
        const Text('Recovery and health', style: TextStyle(fontSize: 22)),
        Text('Database: ${widget.databaseStatus}'),
        const Text(
            'License: pre-license local build; activation is not configured'),
        Text(
            'Backups: ${entries.where((e) => e.$2 != null).length} valid, ${entries.where((e) => e.$2 == null).length} invalid'),
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
        TextButton(
            onPressed: busy ? null : refresh,
            child: const Text('Recheck backups')),
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
        if (widget.auth != null)
          FilledButton(
              onPressed: busy ? null : create,
              child: const Text('Create manual backup')),
        for (final entry in entries)
          ListTile(
            title: Text(entry.$1.uri.pathSegments.last),
            subtitle: Text(entry.$2 == null
                ? 'Invalid: ${entry.$3}'
                : '${entry.$2!.kind.name} · ${entry.$2!.createdAt} · schema ${entry.$2!.schemaVersion} · ${entry.$2!.bytes} bytes · integrity ok'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (entry.$2 != null)
                TextButton(
                    onPressed: busy ? null : () => restore(entry.$2!),
                    child: const Text('Restore')),
              if (widget.onDelete != null)
                TextButton(
                    onPressed: busy ? null : () => delete(entry.$1),
                    child: const Text('Delete')),
            ]),
          ),
      ]);
}
