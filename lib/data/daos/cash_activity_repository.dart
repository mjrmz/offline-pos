import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'cash_session_repository.dart';
import 'paged_result.dart';

class CashRecord {
  final BusinessCashMovement? movement;
  final PettyCashEntry? legacy;
  const CashRecord.movement(this.movement) : legacy = null;
  const CashRecord.legacy(this.legacy) : movement = null;
}

class CashExpenseOverview {
  final int month, today, petty, drawer;
  final Map<String, int> categoryTotals;
  final BusinessCashMovement? lastPettyCashAdded;
  final Map<String, BusinessCashMovement?> fundOpenings;
  final Map<String, bool> fundActivity;
  const CashExpenseOverview(
      this.month,
      this.today,
      this.petty,
      this.drawer,
      this.categoryTotals,
      this.lastPettyCashAdded,
      this.fundOpenings,
      this.fundActivity);
}

class CashActivityRepository {
  final AppDatabase db;
  CashActivityRepository(this.db);

  static const defaultCategories = [
    'Transportation',
    'Office supplies',
    'Meals',
    'Utilities',
    'Repairs & maintenance',
    'Delivery / courier',
    'Cleaning supplies',
    'Miscellaneous'
  ];

  Future<List<CashExpenseCategory>> categories(
      {bool activeOnly = false}) async {
    await _seedCategories();
    return (db.select(db.cashExpenseCategories)
          ..where(
              (c) => activeOnly ? c.active.equals(true) : const Constant(true))
          ..orderBy([(c) => OrderingTerm(expression: c.name)]))
        .get();
  }

  Future<void> _seedCategories() async {
    if ((await db.select(db.cashExpenseCategories).get()).isNotEmpty) return;
    final legacy = await db.select(db.pettyCashEntries).get();
    final names = legacy.isEmpty
        ? defaultCategories
        : legacy
            .map((e) => e.category.trim())
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList();
    await db.transaction(() async {
      if ((await db.select(db.cashExpenseCategories).get()).isNotEmpty) return;
      for (final name in names) {
        await db
            .into(db.cashExpenseCategories)
            .insert(CashExpenseCategoriesCompanion.insert(name: name));
      }
    });
  }

  Future<void> saveCategory(ActiveUser actor,
          {String? id, required String name, bool active = true}) =>
      db.transaction(() async {
        final user = await AuthRepository(db).requireActive(actor.id);
        user.require(PosPermission.manageExpenseFunds);
        final clean = name.trim();
        if (clean.isEmpty) throw ArgumentError('Category name is required');
        final all = await db.select(db.cashExpenseCategories).get();
        if (all.any(
            (e) => e.id != id && e.name.toLowerCase() == clean.toLowerCase())) {
          throw StateError('Category already exists');
        }
        if (id == null) {
          await db
              .into(db.cashExpenseCategories)
              .insert(CashExpenseCategoriesCompanion.insert(name: clean));
        } else {
          final count = await (db.update(db.cashExpenseCategories)
                ..where((c) => c.id.equals(id)))
              .write(CashExpenseCategoriesCompanion(
                  name: Value(clean), active: Value(active)));
          if (count != 1) throw StateError('Category not found');
        }
        await AuthRepository(db)
            .audit(user.id, 'cash_category.save', id ?? clean);
      });

  Future<List<BusinessCashMovement>> history({int? limit}) => (db
          .select(db.businessCashMovements)
        ..orderBy([
          (m) => OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc),
          (m) => OrderingTerm(expression: m.id, mode: OrderingMode.desc)
        ])
        ..limit(limit ?? 9223372036854775807))
      .get();

  Future<PagedResult<BusinessCashMovement>> page({
    int page = 0,
    bool expensesOnly = false,
    String search = '',
    String fund = 'all',
    String type = 'all',
    String? categoryId,
    String? userId,
    DateTime? from,
    DateTime? until,
  }) async {
    final conditions = <String>[];
    final variables = <Variable<Object>>[];
    if (expensesOnly) {
      conditions.add("type = 'expense'");
    } else if (type != 'all') {
      conditions.add('type = ?');
      variables.add(Variable.withString(type));
    }
    if (fund != 'all') {
      conditions.add('(source = ? OR destination = ?)');
      variables.addAll([Variable.withString(fund), Variable.withString(fund)]);
    }
    if (categoryId != null) {
      conditions.add('category_id = ?');
      variables.add(Variable.withString(categoryId));
    }
    if (userId != null) {
      conditions.add('recorded_by_user_id = ?');
      variables.add(Variable.withString(userId));
    }
    if (from != null) {
      conditions.add('created_at >= ?');
      variables.add(Variable.withInt(from.millisecondsSinceEpoch ~/ 1000));
    }
    if (until != null) {
      conditions.add('created_at < ?');
      variables.add(Variable.withInt(until.millisecondsSinceEpoch ~/ 1000));
    }
    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      conditions.add('''(instr(lower(COALESCE(category_name, '')), ?) > 0 OR
        instr(lower(COALESCE(payee, '')), ?) > 0 OR
        instr(lower(COALESCE(note, '')), ?) > 0 OR
        instr(lower(COALESCE(reference, '')), ?) > 0)''');
      for (var i = 0; i < 4; i++) {
        variables.add(Variable.withString(term));
      }
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final count = await db
        .customSelect(
            'SELECT COUNT(*) AS total FROM business_cash_movements $where',
            variables: variables)
        .getSingle();
    final ids = await db.customSelect('''SELECT id FROM business_cash_movements
      $where ORDER BY created_at DESC, id DESC LIMIT 50 OFFSET ?''',
        variables: [...variables, Variable.withInt(page * 50)]).get();
    final ordered = ids.map((row) => row.read<String>('id')).toList();
    final rows = ordered.isEmpty
        ? <BusinessCashMovement>[]
        : await (db.select(db.businessCashMovements)
              ..where((row) => row.id.isIn(ordered)))
            .get();
    final byId = {for (final row in rows) row.id: row};
    return PagedResult(
        items: [for (final id in ordered) byId[id]!],
        totalCount: count.read<int>('total'),
        page: page);
  }

  Future<PagedResult<CashRecord>> recordsPage({
    int page = 0,
    bool expensesOnly = false,
    String search = '',
    String fund = 'all',
    String type = 'all',
    String? categoryId,
    String? categoryName,
    String? userId,
    DateTime? from,
    DateTime? until,
  }) async {
    final movement = <String>[];
    final movementVars = <Variable<Object>>[];
    final legacy = <String>[];
    final legacyVars = <Variable<Object>>[];
    if (expensesOnly) {
      movement.add("type = 'expense'");
    } else if (type != 'all') {
      movement.add('type = ?');
      movementVars.add(Variable.withString(type));
    }
    if (fund != 'all') {
      movement.add('(source = ? OR destination = ?)');
      movementVars
          .addAll([Variable.withString(fund), Variable.withString(fund)]);
      if (fund != 'drawer') legacy.add('0');
    }
    if (type != 'all' && type != 'expense' && !expensesOnly) legacy.add('0');
    if (categoryId != null) {
      movement.add('category_id = ?');
      movementVars.add(Variable.withString(categoryId));
      if (categoryName == null) {
        legacy.add('0');
      } else {
        legacy.add('category = ?');
        legacyVars.add(Variable.withString(categoryName));
      }
    }
    if (userId != null) {
      movement.add('recorded_by_user_id = ?');
      movementVars.add(Variable.withString(userId));
      legacy.add('user_id = ?');
      legacyVars.add(Variable.withString(userId));
    }
    if (from != null) {
      movement.add('created_at >= ?');
      movementVars.add(Variable.withInt(from.millisecondsSinceEpoch ~/ 1000));
      legacy.add('created_at >= ?');
      legacyVars.add(Variable.withInt(from.millisecondsSinceEpoch ~/ 1000));
    }
    if (until != null) {
      movement.add('created_at < ?');
      movementVars.add(Variable.withInt(until.millisecondsSinceEpoch ~/ 1000));
      legacy.add('created_at < ?');
      legacyVars.add(Variable.withInt(until.millisecondsSinceEpoch ~/ 1000));
    }
    final term = search.trim().toLowerCase();
    if (term.isNotEmpty) {
      movement.add('''(instr(lower(COALESCE(category_name, '')), ?) > 0 OR
        instr(lower(COALESCE(payee, '')), ?) > 0 OR
        instr(lower(COALESCE(note, '')), ?) > 0 OR
        instr(lower(COALESCE(reference, '')), ?) > 0)''');
      for (var i = 0; i < 4; i++) {
        movementVars.add(Variable.withString(term));
      }
      legacy.add('''(instr(lower(category), ?) > 0 OR
        instr(lower(COALESCE(note, '')), ?) > 0)''');
      legacyVars.addAll([Variable.withString(term), Variable.withString(term)]);
    }
    final movementWhere =
        movement.isEmpty ? '' : 'WHERE ${movement.join(' AND ')}';
    final legacyWhere = legacy.isEmpty ? '' : 'WHERE ${legacy.join(' AND ')}';
    final source =
        '''SELECT 0 AS kind, id, created_at FROM business_cash_movements $movementWhere
      UNION ALL SELECT 1 AS kind, id, created_at FROM petty_cash_entries $legacyWhere''';
    final variables = [...movementVars, ...legacyVars];
    final count = await db
        .customSelect('SELECT COUNT(*) AS total FROM ($source)',
            variables: variables)
        .getSingle();
    final idRows = await db.customSelect('''SELECT kind, id FROM ($source)
      ORDER BY created_at DESC, kind ASC, id DESC LIMIT 50 OFFSET ?''',
        variables: [...variables, Variable.withInt(page * 50)]).get();
    final movementIds = <String>[];
    final legacyIds = <String>[];
    for (final row in idRows) {
      (row.read<int>('kind') == 0 ? movementIds : legacyIds)
          .add(row.read<String>('id'));
    }
    final movementRows = movementIds.isEmpty
        ? <BusinessCashMovement>[]
        : await (db.select(db.businessCashMovements)
              ..where((row) => row.id.isIn(movementIds)))
            .get();
    final legacyRows = legacyIds.isEmpty
        ? <PettyCashEntry>[]
        : await (db.select(db.pettyCashEntries)
              ..where((row) => row.id.isIn(legacyIds)))
            .get();
    final movementsById = {for (final row in movementRows) row.id: row};
    final legacyById = {for (final row in legacyRows) row.id: row};
    return PagedResult(items: [
      for (final row in idRows)
        row.read<int>('kind') == 0
            ? CashRecord.movement(movementsById[row.read<String>('id')]!)
            : CashRecord.legacy(legacyById[row.read<String>('id')]!)
    ], totalCount: count.read<int>('total'), page: page);
  }

  Future<CashExpenseOverview> expenseOverview(DateTime now) async {
    final monthStart =
        DateTime(now.year, now.month).millisecondsSinceEpoch ~/ 1000;
    final monthEnd =
        DateTime(now.year, now.month + 1).millisecondsSinceEpoch ~/ 1000;
    final todayStart =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 1000;
    final todayEnd =
        DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch ~/
            1000;
    final aggregate = await db.customSelect('''SELECT
      COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? THEN amount_cents ELSE 0 END), 0) AS month_total,
      COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? THEN amount_cents ELSE 0 END), 0) AS today_total,
      COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND source = 'petty' THEN amount_cents ELSE 0 END), 0) AS petty_total,
      COALESCE(SUM(CASE WHEN created_at >= ? AND created_at < ? AND source = 'drawer' THEN amount_cents ELSE 0 END), 0) AS drawer_total
      FROM business_cash_movements WHERE type = 'expense' ''', variables: [
      Variable.withInt(monthStart),
      Variable.withInt(monthEnd),
      Variable.withInt(todayStart),
      Variable.withInt(todayEnd),
      Variable.withInt(monthStart),
      Variable.withInt(monthEnd),
      Variable.withInt(monthStart),
      Variable.withInt(monthEnd),
    ]).getSingle();
    final categories = await db
        .customSelect('''SELECT COALESCE(category_name, 'Uncategorized') AS name,
      SUM(amount_cents) AS total FROM business_cash_movements
      WHERE type = 'expense' AND created_at >= ? AND created_at < ?
      GROUP BY COALESCE(category_name, 'Uncategorized') ORDER BY total DESC''',
            variables: [
          Variable.withInt(monthStart),
          Variable.withInt(monthEnd)
        ]).get();
    final latest = await (db.select(db.businessCashMovements)
          ..where((row) =>
              row.destination.equals('petty') &
              row.type.equals('replenishment'))
          ..orderBy([
            (row) => OrderingTerm(
                expression: row.createdAt, mode: OrderingMode.desc),
            (row) => OrderingTerm(expression: row.id, mode: OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
    final openings = <String, BusinessCashMovement?>{};
    final activity = <String, bool>{};
    for (final fund in ['petty', 'company']) {
      openings[fund] = await (db.select(db.businessCashMovements)
            ..where((row) =>
                row.type.equals('opening') & row.destination.equals(fund))
            ..orderBy([
              (row) => OrderingTerm(
                  expression: row.createdAt, mode: OrderingMode.desc)
            ])
            ..limit(1))
          .getSingleOrNull();
      final count = await db
          .customSelect('''SELECT EXISTS(SELECT 1 FROM business_cash_movements
        WHERE source = ? OR destination = ?) AS has_activity''', variables: [
        Variable.withString(fund),
        Variable.withString(fund)
      ]).getSingle();
      activity[fund] = count.read<int>('has_activity') != 0;
    }
    return CashExpenseOverview(
        aggregate.read<int>('month_total'),
        aggregate.read<int>('today_total'),
        aggregate.read<int>('petty_total'),
        aggregate.read<int>('drawer_total'),
        {
          for (final row in categories)
            row.read<String>('name'): row.read<int>('total')
        },
        latest,
        openings,
        activity);
  }

  Future<bool> hasReversal(String id) async {
    final result = await db.customSelect(
        '''SELECT EXISTS(SELECT 1 FROM business_cash_movements
      WHERE reversal_of_id = ?) AS found''',
        variables: [Variable.withString(id)]).getSingle();
    return result.read<int>('found') != 0;
  }

  Future<int> fundBalanceBefore(BusinessCashMovement row, String fund) async {
    final result = await db.customSelect('''SELECT COALESCE(SUM(
      CASE WHEN destination = ? THEN amount_cents ELSE 0 END -
      CASE WHEN source = ? THEN amount_cents ELSE 0 END), 0) AS total
      FROM business_cash_movements
      WHERE created_at < ? OR (created_at = ? AND id < ?)''', variables: [
      Variable.withString(fund),
      Variable.withString(fund),
      Variable.withInt(row.createdAt.millisecondsSinceEpoch ~/ 1000),
      Variable.withInt(row.createdAt.millisecondsSinceEpoch ~/ 1000),
      Variable.withString(row.id),
    ]).getSingle();
    return result.read<int>('total');
  }

  Future<int> balance(String fund) async {
    if (fund == 'drawer') {
      final session = await CashSessionRepository(db).active();
      return session == null
          ? 0
          : await CashSessionRepository(db).expected(session.id);
    }
    final result = await db.customSelect('''SELECT COALESCE(SUM(
      CASE WHEN destination = ? THEN amount_cents ELSE 0 END -
      CASE WHEN source = ? THEN amount_cents ELSE 0 END), 0) AS total
      FROM business_cash_movements''', variables: [
      Variable.withString(fund),
      Variable.withString(fund)
    ]).getSingle();
    return result.read<int>('total');
  }

  Future<int> reimbursementDue() async {
    final result = await db.customSelect('''SELECT COALESCE(SUM(
      CASE WHEN source = 'personal' AND type = 'expense' THEN amount_cents ELSE 0 END -
      CASE WHEN destination = 'personal' THEN amount_cents ELSE 0 END), 0) AS total
      FROM business_cash_movements''').getSingle();
    return result.read<int>('total');
  }

  Future<BusinessCashMovement> expense(
    ActiveUser actor, {
    required int amountCents,
    required String source,
    required String categoryId,
    String? payee,
    String? reference,
    String? note,
    String? personallyPaidBy,
  }) =>
      db.transaction(() async {
        final user = await AuthRepository(db).requireActive(actor.id);
        user.require(PosPermission.manageExpenses);
        if (amountCents <= 0) throw ArgumentError('Amount must be positive');
        if (!['drawer', 'petty', 'company', 'personal'].contains(source)) {
          throw ArgumentError('Invalid source');
        }
        if (source != 'drawer') user.require(PosPermission.manageExpenseFunds);
        final category = await (db.select(db.cashExpenseCategories)
              ..where((c) => c.id.equals(categoryId)))
            .getSingleOrNull();
        if (category == null || !category.active) {
          throw StateError('Select an active category');
        }
        final session = source == 'drawer'
            ? await CashSessionRepository(db).active()
            : null;
        if (source == 'drawer' && session == null) {
          throw StateError('Open a cash session first');
        }
        if (source == 'drawer' && await balance(source) < amountCents) {
          throw StateError('Insufficient drawer cash');
        }
        if ((source == 'petty' || source == 'company') &&
            await balance(source) < amountCents) {
          throw StateError('Insufficient fund balance');
        }
        if (source == 'personal' &&
            (personallyPaidBy?.trim().isEmpty ?? true)) {
          throw ArgumentError('Enter who paid personally');
        }
        CashMovement? drawerMovement;
        if (session != null) {
          drawerMovement = await db.into(db.cashMovements).insertReturning(
              CashMovementsCompanion.insert(
                  sessionId: session.id,
                  amountCents: -amountCents,
                  kind: 'business_expense'));
        }
        final row = await db.into(db.businessCashMovements).insertReturning(
            BusinessCashMovementsCompanion.insert(
                type: 'expense',
                amountCents: amountCents,
                source: Value(source),
                cashSessionId: Value(session?.id),
                drawerMovementId: Value(drawerMovement?.id),
                categoryId: Value(category.id),
                categoryName: Value(category.name),
                payee: Value(_clean(payee)),
                reference: Value(_clean(reference)),
                note: Value(_clean(note)),
                personallyPaidBy: Value(_clean(personallyPaidBy)),
                recordedByUserId: user.id));
        await AuthRepository(db)
            .audit(user.id, 'cash_activity.expense', row.id);
        return row;
      });

  Future<BusinessCashMovement> replenish(ActiveUser actor,
          {required int amountCents,
          required String destination,
          String source = 'company',
          String? reference,
          String? note}) =>
      db.transaction(() async {
        final user = await AuthRepository(db).requireActive(actor.id);
        user.require(PosPermission.manageExpenseFunds);
        if (amountCents <= 0) throw ArgumentError('Amount must be positive');
        if (destination != 'petty' || source != 'company') {
          throw ArgumentError('Unsupported fund transfer');
        }
        if (await balance(source) < amountCents) {
          throw StateError('Insufficient company cash');
        }
        final row = await db.into(db.businessCashMovements).insertReturning(
            BusinessCashMovementsCompanion.insert(
                type: 'replenishment',
                amountCents: amountCents,
                source: Value(source),
                destination: Value(destination),
                reference: Value(_clean(reference)),
                note: Value(_clean(note)),
                recordedByUserId: user.id));
        await AuthRepository(db)
            .audit(user.id, 'cash_activity.replenish', row.id);
        return row;
      });

  Future<BusinessCashMovement> addOpeningCash(ActiveUser actor,
          {required String fund,
          required int amountCents,
          required String note}) =>
      db.transaction(() async {
        final user = await AuthRepository(db).requireActive(actor.id);
        if (user.role != UserRole.owner) {
          throw StateError('Owner access required');
        }
        if (!['petty', 'company'].contains(fund) ||
            amountCents <= 0 ||
            note.trim().isEmpty) {
          throw ArgumentError('Fund, positive amount and reason are required');
        }
        final existingOpening = await (db.select(db.businessCashMovements)
              ..where(
                  (m) => m.source.equals(fund) | m.destination.equals(fund)))
            .getSingleOrNull();
        if (existingOpening != null) {
          throw StateError('Fund already has cash activity');
        }
        final row = await db.into(db.businessCashMovements).insertReturning(
            BusinessCashMovementsCompanion.insert(
                type: 'opening',
                amountCents: amountCents,
                destination: Value(fund),
                note: Value(note.trim()),
                recordedByUserId: user.id));
        await AuthRepository(db)
            .audit(user.id, 'cash_activity.opening', row.id);
        return row;
      });

  Future<BusinessCashMovement> reverse(
          ActiveUser actor, String originalId, String reason) =>
      db.transaction(() async {
        final user = await AuthRepository(db).requireActive(actor.id);
        user.require(PosPermission.manageExpenseFunds);
        if (reason.trim().isEmpty) {
          throw ArgumentError('Reversal reason is required');
        }
        final original = await (db.select(db.businessCashMovements)
              ..where((m) => m.id.equals(originalId)))
            .getSingleOrNull();
        if (original == null || original.type == 'reversal') {
          throw StateError('Movement cannot be reversed');
        }
        if (await (db.select(db.businessCashMovements)
                  ..where((m) => m.reversalOfId.equals(originalId)))
                .getSingleOrNull() !=
            null) {
          throw StateError('Movement already reversed');
        }
        final session = original.cashSessionId == null
            ? null
            : await (db.select(db.cashSessions)
                  ..where((s) => s.id.equals(original.cashSessionId!)))
                .getSingleOrNull();
        if (session?.closedAt != null) {
          throw StateError('Closed shift movements cannot be reversed');
        }
        if (original.destination != null &&
            original.destination != 'personal' &&
            await balance(original.destination!) < original.amountCents) {
          throw StateError('Insufficient fund balance to reverse this inflow');
        }
        CashMovement? drawerMovement;
        if (original.drawerMovementId != null) {
          drawerMovement = await db.into(db.cashMovements).insertReturning(
              CashMovementsCompanion.insert(
                  sessionId: original.cashSessionId!,
                  amountCents: original.amountCents,
                  kind: 'business_expense_reversal',
                  referenceId: Value(original.drawerMovementId)));
        }
        final row = await db.into(db.businessCashMovements).insertReturning(
            BusinessCashMovementsCompanion.insert(
                type: 'reversal',
                amountCents: original.amountCents,
                source: Value(original.destination),
                destination: Value(original.source),
                cashSessionId: Value(original.cashSessionId),
                drawerMovementId: Value(drawerMovement?.id),
                recordedByUserId: user.id,
                reversalOfId: Value(original.id),
                note: Value(reason.trim())));
        await AuthRepository(db)
            .audit(user.id, 'cash_activity.reverse', row.id);
        return row;
      });

  String? _clean(String? value) =>
      value?.trim().isEmpty == true ? null : value?.trim();
}
