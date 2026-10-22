import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'cash_session_repository.dart';

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

  Future<List<BusinessCashMovement>> history() =>
      (db.select(db.businessCashMovements)
            ..orderBy([
              (m) =>
                  OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc)
            ]))
          .get();

  Future<int> balance(String fund) async {
    if (fund == 'drawer') {
      final session = await CashSessionRepository(db).active();
      return session == null
          ? 0
          : await CashSessionRepository(db).expected(session.id);
    }
    final rows = await history();
    var total = 0;
    for (final row in rows) {
      if (row.source == fund) total -= row.amountCents;
      if (row.destination == fund) total += row.amountCents;
    }
    return total;
  }

  Future<int> reimbursementDue() async {
    final rows = await history();
    return rows.fold<int>(
        0,
        (sum, row) =>
            sum +
            (row.source == 'personal' && row.type == 'expense'
                ? row.amountCents
                : 0) -
            (row.destination == 'personal' ? row.amountCents : 0));
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
