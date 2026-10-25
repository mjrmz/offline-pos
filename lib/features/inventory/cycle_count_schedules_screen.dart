import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/models/active_user.dart';
import '../../data/database.dart';
import '../../data/daos/cycle_count_schedule_repository.dart';
import '../../data/daos/stock_count_repository.dart';
import '../../shared/widgets/app_workspace.dart';
import 'stock_counts_screen.dart';

class CycleCountSchedulesScreen extends StatefulWidget {
  final AppDatabase db;
  final ActiveUser user;
  const CycleCountSchedulesScreen(
      {super.key, required this.db, required this.user});
  @override
  State<CycleCountSchedulesScreen> createState() =>
      _CycleCountSchedulesScreenState();
}

class _CycleCountSchedulesScreenState extends State<CycleCountSchedulesScreen> {
  late final repo = CycleCountScheduleRepository(widget.db);
  late Future<void> loaded = _load();
  List<CycleCountSchedule> schedules = [];
  List<User> employees = [];
  List<Product> products = [];
  List<Category> categories = [];
  String search = '';
  String statusFilter = 'All';
  String employeeFilter = 'All';
  String scopeFilter = 'All';
  DateTimeRange? dateFilter;
  String? selectedId;
  bool busy = false;

  bool get canManage =>
      widget.user.can(PosPermission.stockCount) &&
      (widget.user.role == UserRole.owner ||
          widget.user.role == UserRole.manager);

  Future<void> _load() async {
    schedules = await repo.all();
    employees = await widget.db.select(widget.db.users).get();
    products = await widget.db.select(widget.db.products).get();
    categories = await widget.db.select(widget.db.categories).get();
  }

  void _reload() => setState(() => loaded = _load());
  String _date(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  String _employee(String id) {
    final user = employees.where((u) => u.id == id).firstOrNull;
    return user == null
        ? 'Missing employee'
        : '${user.name}${user.isActive ? '' : ' (inactive)'}';
  }

  String _status(CycleCountSchedule s) =>
      CycleCountScheduleRepository.overdue(s, DateTime.now())
          ? 'Overdue'
          : switch (s.status) {
              'in_progress' => 'In Progress',
              'completed' => 'Completed',
              'cancelled' => 'Cancelled',
              _ => 'Scheduled',
            };
  String _scope(CycleCountSchedule s) {
    final refs = (jsonDecode(s.scopeRefs) as List).cast<String>();
    final names = s.scopeType == 'products'
        ? refs.map((id) =>
            products.where((p) => p.id == id).firstOrNull?.name ??
            'Unavailable product')
        : refs.map((id) =>
            categories.where((c) => c.id == id).firstOrNull?.name ??
            'Unavailable category');
    return names.join(', ');
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                error is StateError ? error.message.toString() : '$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _form([CycleCountSchedule? existing]) async {
    final title = TextEditingController(text: existing?.title);
    final notes = TextEditingController(text: existing?.notes);
    var scope = existing?.scopeType ?? 'products';
    final refs = existing == null
        ? <String>{}
        : (jsonDecode(existing.scopeRefs) as List).cast<String>().toSet();
    String? assignee = existing?.assigneeId;
    var scheduled = existing?.scheduledDate ?? DateTime.now();
    var due = existing?.dueDate ?? DateTime.now();
    String? error;
    var saving = false;
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: Text(
                      existing == null ? 'Create Schedule' : 'Edit Schedule'),
                  content: SizedBox(
                      width: 620,
                      height: 510,
                      child: SingleChildScrollView(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            TextField(
                                controller: title,
                                decoration: const InputDecoration(
                                    labelText: 'Title or reference')),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                                initialValue: scope,
                                decoration:
                                    const InputDecoration(labelText: 'Scope'),
                                items: const [
                                  DropdownMenuItem(
                                      value: 'products',
                                      child: Text('Selected products')),
                                  DropdownMenuItem(
                                      value: 'categories',
                                      child: Text('Selected categories'))
                                ],
                                onChanged: (value) => update(() {
                                      scope = value!;
                                      refs.clear();
                                    })),
                            const SizedBox(height: 12),
                            Text(
                                'Select ${scope == 'products' ? 'products' : 'categories'}'),
                            SizedBox(
                                height: 175,
                                child: ListView(children: [
                                  for (final entry in scope == 'products'
                                      ? products
                                          .where((p) => p.isActive)
                                          .map((p) => (p.id, p.name))
                                      : categories.map((c) => (c.id, c.name)))
                                    CheckboxListTile(
                                        dense: true,
                                        title: Text(entry.$2),
                                        value: refs.contains(entry.$1),
                                        onChanged: (value) => update(() =>
                                            value == true
                                                ? refs.add(entry.$1)
                                                : refs.remove(entry.$1)))
                                ])),
                            DropdownButtonFormField<String>(
                                initialValue: assignee,
                                decoration: const InputDecoration(
                                    labelText: 'Assigned employee'),
                                items: employees
                                    .where(
                                        (u) => u.isActive || u.id == assignee)
                                    .map((u) => DropdownMenuItem(
                                        value: u.id,
                                        child: Text(_employee(u.id))))
                                    .toList(),
                                onChanged: (value) =>
                                    update(() => assignee = value)),
                            const SizedBox(height: 12),
                            Wrap(spacing: 12, children: [
                              OutlinedButton(
                                  onPressed: () async {
                                    final picked = await showDatePicker(
                                        context: context,
                                        firstDate: DateTime(2000),
                                        lastDate: DateTime(2100),
                                        initialDate: scheduled);
                                    if (picked != null) {
                                      update(() => scheduled = picked);
                                    }
                                  },
                                  child:
                                      Text('Scheduled: ${_date(scheduled)}')),
                              OutlinedButton(
                                  onPressed: () async {
                                    final picked = await showDatePicker(
                                        context: context,
                                        firstDate: DateTime(2000),
                                        lastDate: DateTime(2100),
                                        initialDate: due);
                                    if (picked != null) {
                                      update(() => due = picked);
                                    }
                                  },
                                  child: Text('Due: ${_date(due)}')),
                            ]),
                            TextField(
                                controller: notes,
                                decoration:
                                    const InputDecoration(labelText: 'Notes')),
                            if (error != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(error!,
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error))),
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: busy || saving
                            ? null
                            : () async {
                                if (assignee == null ||
                                    title.text.trim().isEmpty ||
                                    refs.isEmpty ||
                                    CycleCountScheduleRepository.businessDate(
                                            due)
                                        .isBefore(CycleCountScheduleRepository
                                            .businessDate(scheduled))) {
                                  update(() => error =
                                      'Enter a title, scope, employee, and valid dates');
                                  return;
                                }
                                update(() => saving = true);
                                try {
                                  if (existing == null) {
                                    await repo.create(widget.user,
                                        title: title.text,
                                        scopeType: scope,
                                        scopeRefs: refs.toList(),
                                        assigneeId: assignee!,
                                        scheduledDate: scheduled,
                                        dueDate: due,
                                        notes: notes.text);
                                  } else {
                                    await repo.edit(widget.user, existing.id,
                                        title: title.text,
                                        scopeType: scope,
                                        scopeRefs: refs.toList(),
                                        assigneeId: assignee!,
                                        scheduledDate: scheduled,
                                        dueDate: due,
                                        notes: notes.text);
                                  }
                                  if (context.mounted) Navigator.pop(context);
                                  _reload();
                                } catch (e) {
                                  update(() => error = e is StateError
                                      ? e.message.toString()
                                      : '$e');
                                } finally {
                                  if (context.mounted) {
                                    update(() => saving = false);
                                  }
                                }
                              },
                        child: const Text('Save'))
                  ],
                )));
    title.dispose();
    notes.dispose();
  }

  void _openCount(String id) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
            builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Stock Count')),
                  body: StockCountsScreen(
                      repository: StockCountRepository(widget.db),
                      user: widget.user,
                      initialCountId: id),
                )))
        .then((_) => _reload());
  }

  Future<void> _start(CycleCountSchedule s) => _run(() async {
        final count = await repo.start(widget.user, s.id);
        if (mounted) _openCount(count.id);
      });

  Widget _detail(CycleCountSchedule s) {
    final count = s.stockCountId;
    return SafeArea(
        child: SizedBox(
            width: 520,
            child: ListView(padding: const EdgeInsets.all(24), children: [
              Row(children: [
                Expanded(
                    child: Text(s.title,
                        style: Theme.of(context).textTheme.headlineSmall)),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close))
              ]),
              const SizedBox(height: 16),
              Chip(label: Text(_status(s))),
              ListTile(
                  title: const Text('Assigned employee'),
                  subtitle: Text(_employee(s.assigneeId))),
              ListTile(title: const Text('Scope'), subtitle: Text(_scope(s))),
              ListTile(
                  title: const Text('Scheduled'),
                  subtitle: Text(_date(s.scheduledDate))),
              ListTile(
                  title: const Text('Due'), subtitle: Text(_date(s.dueDate))),
              if (s.notes?.isNotEmpty == true)
                ListTile(title: const Text('Notes'), subtitle: Text(s.notes!)),
              if (count != null)
                ListTile(
                    title: const Text('Linked Stock Count'),
                    subtitle: Text(count)),
              const SizedBox(height: 12),
              if (s.status == 'scheduled' || s.status == 'in_progress')
                FilledButton(
                    onPressed:
                        busy || !widget.user.can(PosPermission.stockCount)
                            ? null
                            : () async {
                                Navigator.pop(context);
                                await _start(s);
                              },
                    child:
                        Text(count == null ? 'Start Count' : 'Resume Count')),
              if (count != null && s.status == 'completed')
                OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _openCount(count);
                    },
                    child: const Text('View Stock Count')),
              if (canManage && s.status == 'scheduled' && count == null) ...[
                OutlinedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _form(s);
                    },
                    child: const Text('Edit')),
                TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _run(() => repo.cancel(widget.user, s.id));
                    },
                    child: const Text('Cancel Schedule')),
              ],
              const Divider(),
              Text('Activity', style: Theme.of(context).textTheme.titleMedium),
              FutureBuilder<List<AuditLog>>(
                  future: repo.activity(s.id),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const LinearProgressIndicator();
                    }
                    return Column(children: [
                      for (final entry in snapshot.data!)
                        ListTile(
                          dense: true,
                          title:
                              Text(entry.action.replaceAll('cycle_count.', '')),
                          subtitle: Text(
                              '${_date(entry.createdAt)}  ${entry.details ?? ''}'),
                        ),
                    ]);
                  }),
            ])));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
      future: loaded,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final visible = schedules
            .where((s) =>
                (statusFilter == 'All' || _status(s) == statusFilter) &&
                (employeeFilter == 'All' || s.assigneeId == employeeFilter) &&
                (scopeFilter == 'All' || s.scopeType == scopeFilter) &&
                (dateFilter == null ||
                    (!s.scheduledDate.isBefore(dateFilter!.start) &&
                        !s.scheduledDate.isAfter(dateFilter!.end))) &&
                (search.isEmpty ||
                    s.title.toLowerCase().contains(search.toLowerCase()) ||
                    _employee(s.assigneeId)
                        .toLowerCase()
                        .contains(search.toLowerCase())))
            .toList();
        return Scaffold(
            endDrawer: selectedId == null
                ? null
                : Drawer(
                    width: 520,
                    child: _detail(
                        schedules.firstWhere((s) => s.id == selectedId))),
            body: Builder(
                builder: (drawerContext) => AppWorkspacePadding(
                        child: Column(children: [
                      Row(children: [
                        Text('Cycle Count Scheduling',
                            style: Theme.of(context).textTheme.titleLarge),
                        const Spacer(),
                        if (canManage)
                          FilledButton.icon(
                              onPressed: busy ? null : () => _form(),
                              icon: const Icon(Icons.add),
                              label: const Text('Create Schedule'))
                      ]),
                      const SizedBox(height: 16),
                      Wrap(spacing: 12, runSpacing: 8, children: [
                        for (final label in [
                          'Scheduled',
                          'In Progress',
                          'Overdue',
                          'Completed'
                        ])
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(children: [
                                    Text(
                                        '${schedules.where((s) => label == 'Overdue' ? CycleCountScheduleRepository.overdue(s, DateTime.now()) : s.status == switch (label) {
                                              'In Progress' => 'in_progress',
                                              'Completed' => 'completed',
                                              _ => 'scheduled',
                                            }).length}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall),
                                    Text(label)
                                  ]))),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                            child: TextField(
                                decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search),
                                    labelText: 'Search schedules'),
                                onChanged: (value) =>
                                    setState(() => search = value))),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                            value: statusFilter,
                            items: [
                              'All',
                              'Scheduled',
                              'In Progress',
                              'Overdue',
                              'Completed',
                              'Cancelled'
                            ]
                                .map((v) =>
                                    DropdownMenuItem(value: v, child: Text(v)))
                                .toList(),
                            onChanged: (value) =>
                                setState(() => statusFilter = value!))
                      ]),
                      const SizedBox(height: 8),
                      Wrap(
                          spacing: 16,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            DropdownButton<String>(
                                value: employeeFilter,
                                items: [
                                  const DropdownMenuItem(
                                      value: 'All',
                                      child: Text('All employees')),
                                  ...employees.map((u) => DropdownMenuItem(
                                      value: u.id,
                                      child: Text(_employee(u.id))))
                                ],
                                onChanged: (value) =>
                                    setState(() => employeeFilter = value!)),
                            DropdownButton<String>(
                                value: scopeFilter,
                                items: const [
                                  DropdownMenuItem(
                                      value: 'All', child: Text('All scopes')),
                                  DropdownMenuItem(
                                      value: 'products',
                                      child: Text('Products')),
                                  DropdownMenuItem(
                                      value: 'categories',
                                      child: Text('Categories'))
                                ],
                                onChanged: (value) =>
                                    setState(() => scopeFilter = value!)),
                            OutlinedButton.icon(
                                icon: const Icon(Icons.date_range),
                                label: Text(dateFilter == null
                                    ? 'Scheduled date range'
                                    : '${_date(dateFilter!.start)} – ${_date(dateFilter!.end)}'),
                                onPressed: () async {
                                  final range = await showDateRangePicker(
                                      context: context,
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime(2100),
                                      initialDateRange: dateFilter);
                                  if (range != null) {
                                    setState(() => dateFilter = range);
                                  }
                                }),
                            if (dateFilter != null)
                              TextButton(
                                  onPressed: () =>
                                      setState(() => dateFilter = null),
                                  child: const Text('Clear dates')),
                          ]),
                      const SizedBox(height: 12),
                      Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Row(children: const [
                            Expanded(flex: 2, child: Text('Schedule')),
                            Expanded(flex: 2, child: Text('Scope')),
                            Expanded(flex: 2, child: Text('Employee')),
                            Expanded(child: Text('Scheduled')),
                            Expanded(child: Text('Due')),
                            Expanded(child: Text('Status')),
                            SizedBox(width: 48, child: Text('Open')),
                          ])),
                      Expanded(
                          child: ListView(children: [
                        for (final s in visible)
                          Card(
                              child: InkWell(
                                  onTap: () {
                                    setState(() => selectedId = s.id);
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      if (drawerContext.mounted) {
                                        Scaffold.of(drawerContext)
                                            .openEndDrawer();
                                      }
                                    });
                                  },
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14, vertical: 12),
                                      child: Row(children: [
                                        Expanded(
                                            flex: 2,
                                            child: Text(s.title,
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                        Expanded(
                                            flex: 2,
                                            child: Text(_scope(s),
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                        Expanded(
                                            flex: 2,
                                            child: Text(_employee(s.assigneeId),
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                        Expanded(
                                            child:
                                                Text(_date(s.scheduledDate))),
                                        Expanded(child: Text(_date(s.dueDate))),
                                        Expanded(
                                            child: Text(_status(s),
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                        const SizedBox(
                                            width: 48,
                                            child: Icon(Icons.chevron_right)),
                                      ])))),
                        if (visible.isEmpty)
                          const Center(
                              child: Padding(
                                  padding: EdgeInsets.all(32),
                                  child: Text('No schedules found'))),
                      ])),
                    ]))));
      });
}
