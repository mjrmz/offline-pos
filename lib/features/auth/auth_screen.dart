import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../shared/utils/safe_message.dart';

class AuthScreen extends StatefulWidget {
  final AuthService auth;
  final VoidCallback onChanged;
  const AuthScreen({super.key, required this.auth, required this.onChanged});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final name = TextEditingController();
  final credential = TextEditingController();
  final question = TextEditingController();
  final answer = TextEditingController();
  final newPassword = TextEditingController();
  List<ActiveUser> users = [];
  String? selectedId;
  bool setup = false;
  bool recovery = false;
  bool busy = false;
  String? message;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final isSetup = !(await widget.auth.repository.hasOwner());
      final rows = await widget.auth.repository.loginUsers();
      if (mounted) {
        setState(() {
          setup = isSetup;
          users = rows;
          selectedId = rows.any((u) => u.id == selectedId)
              ? selectedId
              : (rows.isEmpty ? null : rows.first.id);
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = 'Unable to load local accounts');
    }
  }

  ActiveUser? get selected =>
      users.where((u) => u.id == selectedId).firstOrNull;
  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (setup) {
        await widget.auth
            .bootstrap(name.text, credential.text, question.text, answer.text);
        credential.clear();
        answer.clear();
        await refresh();
        if (mounted) setState(() => message = 'Owner created. Please log in.');
      } else if (recovery) {
        await widget.auth
            .recover(selectedId ?? '', answer.text, newPassword.text);
        answer.clear();
        newPassword.clear();
        if (mounted) {
          setState(() {
            recovery = false;
            message = 'Password reset. Please log in.';
          });
        }
      } else {
        await widget.auth.login(selectedId ?? '', credential.text);
        credential.clear();
        widget.onChanged();
      }
    } catch (e) {
      if (mounted) setState(() => message = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    credential.dispose();
    question.dispose();
    answer.dispose();
    newPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = selected?.role;
    final ownerUsers = users.where((u) => u.role == UserRole.owner).toList();
    return Scaffold(
        appBar: AppBar(
            title: Text(setup
                ? 'First owner setup'
                : recovery
                    ? 'Offline recovery'
                    : 'Login')),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  if (message != null)
                    Text(message!, style: const TextStyle(color: Colors.red)),
                  if (setup) ...[
                    TextField(
                        controller: name,
                        decoration:
                            const InputDecoration(labelText: 'Owner name')),
                    TextField(
                        controller: credential,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Owner password (8+ characters)')),
                    TextField(
                        controller: question,
                        decoration: const InputDecoration(
                            labelText: 'Offline recovery question')),
                    TextField(
                        controller: answer,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Recovery answer')),
                  ] else if (recovery) ...[
                    DropdownButtonFormField<String>(
                        initialValue: ownerUsers.any((u) => u.id == selectedId)
                            ? selectedId
                            : null,
                        decoration: const InputDecoration(labelText: 'Owner'),
                        items: ownerUsers
                            .map((u) => DropdownMenuItem(
                                value: u.id, child: Text(u.name)))
                            .toList(),
                        onChanged: (id) => setState(() => selectedId = id)),
                    FutureBuilder(
                        future: widget.auth.repository.user(selectedId ?? ''),
                        builder: (context, snapshot) => Text(
                            snapshot.data?.recoveryQuestion ?? 'Select owner')),
                    TextField(
                        controller: answer,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'Recovery answer')),
                    TextField(
                        controller: newPassword,
                        obscureText: true,
                        decoration: const InputDecoration(
                            labelText: 'New password (8+ characters)')),
                    TextButton(
                        onPressed: () => setState(() => recovery = false),
                        child: const Text('Back to login')),
                  ] else ...[
                    DropdownButtonFormField<String>(
                        initialValue: selectedId,
                        decoration: const InputDecoration(labelText: 'User'),
                        items: users
                            .map((u) => DropdownMenuItem(
                                value: u.id,
                                child: Text('${u.name} (${u.role.name})')))
                            .toList(),
                        onChanged: (id) => setState(() => selectedId = id)),
                    TextField(
                        controller: credential,
                        obscureText: true,
                        keyboardType: role == UserRole.cashier
                            ? TextInputType.number
                            : TextInputType.text,
                        decoration: InputDecoration(
                            labelText:
                                role == UserRole.cashier ? 'PIN' : 'Password'),
                        onSubmitted: (_) => submit()),
                    TextButton(
                        onPressed: () => setState(() {
                              recovery = true;
                              selectedId = ownerUsers.isEmpty
                                  ? null
                                  : ownerUsers.first.id;
                              message = null;
                            }),
                        child: const Text('Recover owner password offline')),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                      onPressed: busy ? null : submit,
                      child: Text(busy
                          ? 'Please wait…'
                          : setup
                              ? 'Create owner'
                              : recovery
                                  ? 'Reset password'
                                  : 'Log in')),
                ]))));
  }
}
