import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../shared/utils/safe_message.dart';

class UsersScreen extends StatefulWidget {
  final AuthService auth;
  const UsersScreen({super.key, required this.auth});
  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  List<ActiveUser> users = [];
  String? error;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final rows = await widget.auth.repository.allUsers();
      if (mounted) {
        setState(() {
          users = rows;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    }
  }

  Future<void> create() async {
    final name = TextEditingController();
    final secret = TextEditingController();
    var role = UserRole.cashier;
    String? dialogError;
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: const Text('Create user'),
                    content: SizedBox(
                        width: 400,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          if (dialogError != null)
                            Text(dialogError!,
                                style: const TextStyle(color: Colors.red)),
                          TextField(
                              controller: name,
                              decoration:
                                  const InputDecoration(labelText: 'Name')),
                          DropdownButtonFormField<UserRole>(
                              initialValue: role,
                              items: UserRole.values
                                  .map((r) => DropdownMenuItem(
                                      value: r, child: Text(r.name)))
                                  .toList(),
                              onChanged: (r) {
                                if (r != null) update(() => role = r);
                              }),
                          TextField(
                              controller: secret,
                              obscureText: true,
                              keyboardType: role == UserRole.cashier
                                  ? TextInputType.number
                                  : TextInputType.text,
                              decoration: InputDecoration(
                                  labelText: role == UserRole.cashier
                                      ? '4–6 digit PIN'
                                      : 'Password (8+ characters)')),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            try {
                              await widget.auth
                                  .createUser(name.text, role, secret.text);
                              if (context.mounted) Navigator.pop(context);
                              await refresh();
                            } catch (e) {
                              update(() => dialogError = safeMessage(e));
                            }
                          },
                          child: const Text('Create'))
                    ])));
    name.dispose();
    secret.dispose();
  }

  Future<void> reset(ActiveUser user) async {
    final secret = TextEditingController();
    String? dialogError;
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                    title: Text('Reset ${user.name} credential'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (dialogError != null)
                        Text(dialogError!,
                            style: const TextStyle(color: Colors.red)),
                      TextField(
                          controller: secret,
                          obscureText: true,
                          decoration: InputDecoration(
                              labelText: user.role == UserRole.cashier
                                  ? 'New 4–6 digit PIN'
                                  : 'New password (8+ characters)'))
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () async {
                            try {
                              await widget.auth
                                  .resetCredential(user.id, secret.text);
                              if (context.mounted) Navigator.pop(context);
                              await refresh();
                            } catch (e) {
                              update(() => dialogError = safeMessage(e));
                            }
                          },
                          child: const Text('Save'))
                    ])));
    secret.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Users'), actions: [
          IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))
        ]),
        body: ListView(children: [
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          FilledButton(onPressed: create, child: const Text('Add user')),
          ...users.map((u) => ListTile(
                title: Text(u.name),
                subtitle: Text(
                    '${u.role.name} · ${u.isActive ? 'Active' : 'Inactive'}'),
                trailing: Wrap(children: [
                  IconButton(
                      onPressed: () => reset(u),
                      icon: const Icon(Icons.password)),
                  IconButton(
                    onPressed: () async {
                      try {
                        await widget.auth.setActive(u.id, !u.isActive);
                        await refresh();
                      } catch (e) {
                        if (mounted) setState(() => error = safeMessage(e));
                      }
                    },
                    icon:
                        Icon(u.isActive ? Icons.person_off : Icons.person_add),
                  ),
                ]),
              )),
        ]),
      );
}
