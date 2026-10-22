import 'package:flutter/material.dart';
import '../../core/models/active_user.dart';
import '../../core/services/auth_service.dart';
import '../../shared/utils/safe_message.dart';
import '../../core/models/business_feature.dart';
import '../../data/daos/business_feature_repository.dart';
import '../../data/daos/printer_settings_repository.dart';
import '../../core/services/business_logo_store.dart';
import 'dart:io';
import 'dart:async';

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
  final Set<BusinessFeature> selectedFeatures = {};
  String? message;
  String businessName = 'POS';
  File? logo;
  bool visible = false;
  DateTime? lockedUntil;
  Timer? lockTicker;
  final credentialFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    refresh();
    lockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && lockedUntil != null) {
        setState(() {
          if (lockRemaining == Duration.zero) lockedUntil = null;
        });
      }
    });
    PrinterSettingsStore(widget.auth.repository.db).load().then((settings) {
      if (mounted) {
        setState(() => businessName = settings.storeName.trim().isEmpty
            ? 'POS'
            : settings.storeName.trim());
      }
    });
    BusinessLogoStore().load().then((file) {
      if (mounted) setState(() => logo = file);
    });
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
        await refreshLock();
        if (mounted && !isSetup && selectedId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) credentialFocus.requestFocus();
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => message = 'Unable to load local accounts');
    }
  }

  ActiveUser? get selected =>
      users.where((u) => u.id == selectedId).firstOrNull;

  Future<void> refreshLock() async {
    final id = selectedId;
    final row = await widget.auth.repository.user(id ?? '');
    if (mounted && selectedId == id) {
      setState(() => lockedUntil = row?.lockedUntil);
    }
  }

  Duration get lockRemaining {
    final until = lockedUntil;
    if (until == null) return Duration.zero;
    final remaining = until.difference(widget.auth.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Future<void> submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (setup) {
        final ownerId = await widget.auth
            .bootstrap(name.text, credential.text, question.text, answer.text);
        final featureStore =
            BusinessFeatureRepository(widget.auth.repository.db);
        final owner = ActiveUser(ownerId, name.text.trim(), UserRole.owner);
        await featureStore.setInitialSelections(selectedFeatures, owner);
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
      if (mounted) {
        final detail = safeMessage(e);
        setState(() => message =
            detail == 'Invalid credentials' && !setup && !recovery
                ? (selected?.role == UserRole.cashier
                    ? 'Incorrect PIN.'
                    : 'Incorrect password.')
                : detail);
      }
      await refreshLock();
      if (setup) await refresh();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    lockTicker?.cancel();
    credentialFocus.dispose();
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
    final colors = Theme.of(context).colorScheme;
    final locked = !setup && !recovery && lockRemaining > Duration.zero;
    final seconds = lockRemaining.inSeconds +
        (lockRemaining.inMilliseconds % 1000 == 0 ? 0 : 1);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final inputTheme = InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colors.primary, width: 2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    );
    Widget brandMark(double size) => Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: dark ? const Color(0xFF34334A) : const Color(0xFFF1EFF8),
              borderRadius: BorderRadius.circular(16)),
          child: logo == null
              ? Icon(Icons.storefront_outlined,
                  size: size * .55, color: colors.primary)
              : Image.file(logo!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Icon(Icons.storefront_outlined,
                      size: size * .55, color: colors.primary)),
        );
    final card = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Card(
        elevation: dark ? 0 : 12,
        shadowColor: Colors.black.withValues(alpha: .12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(
                color: colors.outlineVariant.withValues(alpha: .55))),
        child: Padding(
            padding: const EdgeInsets.all(32),
            child: Theme(
                data: Theme.of(context)
                    .copyWith(inputDecorationTheme: inputTheme),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        brandMark(64),
                        const SizedBox(width: 16),
                        Expanded(
                            child: Text(businessName,
                                style: Theme.of(context).textTheme.titleLarge,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis))
                      ]),
                      const SizedBox(height: 28),
                      Text(
                          setup
                              ? 'Set up your workspace'
                              : recovery
                                  ? 'Offline recovery'
                                  : 'Welcome back',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(
                          setup
                              ? 'Create the first owner account.'
                              : recovery
                                  ? 'Reset the owner password on this device.'
                                  : 'Sign in to continue to your POS workspace.',
                          style: TextStyle(color: colors.onSurfaceVariant)),
                      const SizedBox(height: 24),
                      if (message != null &&
                          !(locked &&
                              message == 'Account temporarily locked')) ...[
                        Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: colors.errorContainer,
                                borderRadius: BorderRadius.circular(10)),
                            child: Text(message!,
                                style:
                                    TextStyle(color: colors.onErrorContainer))),
                        const SizedBox(height: 14),
                      ],
                      if (locked) ...[
                        Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: colors.errorContainer,
                                borderRadius: BorderRadius.circular(10)),
                            child: Text(
                                'Account temporarily locked. Try again in ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}.',
                                style:
                                    TextStyle(color: colors.onErrorContainer))),
                        const SizedBox(height: 14),
                      ],
                      if (setup) ...[
                        TextField(
                            controller: name,
                            decoration:
                                const InputDecoration(labelText: 'Owner name')),
                        const SizedBox(height: 12),
                        TextField(
                            controller: credential,
                            obscureText: true,
                            decoration: const InputDecoration(
                                labelText: 'Owner password (8+ characters)')),
                        const SizedBox(height: 12),
                        TextField(
                            controller: question,
                            decoration: const InputDecoration(
                                labelText: 'Offline recovery question')),
                        const SizedBox(height: 12),
                        TextField(
                            controller: answer,
                            obscureText: true,
                            decoration: const InputDecoration(
                                labelText: 'Recovery answer')),
                        const SizedBox(height: 12),
                        const Text('What do you sell?'),
                        const Text(
                            'Select any combination. You can change these later.'),
                        for (final feature in BusinessFeature.values)
                          CheckboxListTile(
                              title: Text(feature.displayName),
                              value: selectedFeatures.contains(feature),
                              onChanged: busy
                                  ? null
                                  : (value) => setState(() {
                                        if (value == true) {
                                          selectedFeatures.add(feature);
                                        } else {
                                          selectedFeatures.remove(feature);
                                        }
                                      })),
                      ] else if (recovery) ...[
                        DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue:
                                ownerUsers.any((u) => u.id == selectedId)
                                    ? selectedId
                                    : null,
                            decoration:
                                const InputDecoration(labelText: 'Owner'),
                            items: ownerUsers
                                .map((u) => DropdownMenuItem(
                                    value: u.id, child: Text(u.name)))
                                .toList(),
                            onChanged: (id) => setState(() => selectedId = id)),
                        const SizedBox(height: 12),
                        FutureBuilder(
                            future:
                                widget.auth.repository.user(selectedId ?? ''),
                            builder: (context, snapshot) => Text(
                                snapshot.data?.recoveryQuestion ??
                                    'Select owner')),
                        const SizedBox(height: 12),
                        TextField(
                            controller: answer,
                            obscureText: true,
                            decoration: const InputDecoration(
                                labelText: 'Recovery answer')),
                        const SizedBox(height: 12),
                        TextField(
                            controller: newPassword,
                            obscureText: true,
                            decoration: const InputDecoration(
                                labelText: 'New password (8+ characters)')),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                                onPressed: () =>
                                    setState(() => recovery = false),
                                child: const Text('Back to login'))),
                      ] else ...[
                        DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: selectedId,
                            decoration: const InputDecoration(
                                labelText: 'User',
                                prefixIcon: Icon(Icons.person_outline)),
                            items: users
                                .map((u) => DropdownMenuItem(
                                    value: u.id,
                                    child: Text(
                                        '${u.name} (${u.role.name[0].toUpperCase()}${u.role.name.substring(1)})')))
                                .toList(),
                            onChanged: (id) {
                              setState(() {
                                selectedId = id;
                                message = null;
                                credential.clear();
                                visible = false;
                              });
                              refreshLock();
                              credentialFocus.requestFocus();
                            }),
                        const SizedBox(height: 16),
                        TextField(
                            controller: credential,
                            focusNode: credentialFocus,
                            autofocus: selectedId != null,
                            obscureText: !visible,
                            keyboardType: role == UserRole.cashier
                                ? TextInputType.number
                                : TextInputType.text,
                            decoration: InputDecoration(
                                labelText: role == UserRole.cashier
                                    ? 'PIN'
                                    : 'Password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                    tooltip: visible
                                        ? 'Hide credential'
                                        : 'Show credential',
                                    icon: Icon(visible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined),
                                    onPressed: () =>
                                        setState(() => visible = !visible))),
                            onSubmitted: (_) => submit()),
                        if (role == UserRole.owner)
                          Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                  child: const Text(
                                      'Recover owner password offline'),
                                  onPressed: () => setState(() {
                                        recovery = true;
                                        selectedId = ownerUsers.first.id;
                                        message = null;
                                      }))),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 12),
                      SizedBox(
                          height: 50,
                          child: FilledButton(
                              onPressed: busy || locked ? null : submit,
                              child: Text(busy
                                  ? 'Please wait…'
                                  : setup
                                      ? 'Create owner'
                                      : recovery
                                          ? 'Reset password'
                                          : 'Log in'))),
                      const SizedBox(height: 18),
                      Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Icon(Icons.wifi_off_outlined,
                                size: 16, color: colors.onSurfaceVariant),
                            const SizedBox(width: 6),
                            Text('Offline-ready · Secure local login',
                                style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 12))
                          ]),
                    ]))),
      ),
    );
    return Scaffold(
      body: LayoutBuilder(builder: (context, constraints) {
        final split =
            constraints.maxWidth >= 900 && constraints.maxHeight >= 620;
        return Row(children: [
          if (split)
            Expanded(
                flex: 42,
                child: Container(
                  decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF171B2B), Color(0xFF30234B)])),
                  child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.point_of_sale,
                                color: Color(0xFFB7A4F9), size: 34),
                            const SizedBox(height: 20),
                            Text('OFFLINE POS SYSTEM',
                                style: TextStyle(
                                    color: Colors.deepPurple.shade100,
                                    letterSpacing: 2,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 18),
                            const Text(
                                'Built for your business.\nAlways ready.',
                                style: TextStyle(
                                    fontSize: 36,
                                    height: 1.2,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 18),
                            const Text('Fast, reliable, and fully offline.',
                                style: TextStyle(
                                    fontSize: 17, color: Color(0xFFD2D0DE))),
                            const SizedBox(height: 26),
                            for (final item in const [
                              (
                                Icons.wifi_off_outlined,
                                'Works offline',
                                'Your business keeps running without internet.'
                              ),
                              (
                                Icons.verified_user_outlined,
                                'Secure & local',
                                'Business data stays on this device.'
                              ),
                              (
                                Icons.inventory_2_outlined,
                                'Built for real operations',
                                'Sales, inventory, customers, and service workflows.'
                              )
                            ])
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(item.$1,
                                            color: const Color(0xFFB7A4F9)),
                                        const SizedBox(width: 16),
                                        Expanded(
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                              Text(item.$2,
                                                  style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w600)),
                                              const SizedBox(height: 3),
                                              Text(item.$3,
                                                  style: const TextStyle(
                                                      color: Color(0xFFBDBBCC)))
                                            ]))
                                      ])),
                          ])),
                )),
          Expanded(
              flex: 58,
              child: ColoredBox(
                  color:
                      dark ? const Color(0xFF121520) : const Color(0xFFF5F5F9),
                  child: Center(
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24), child: card)))),
        ]);
      }),
    );
  }
}
