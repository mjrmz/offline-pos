import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'paged_result.dart';

class PettyCashRepository {
  final AppDatabase db;
  PettyCashRepository(this.db);

  Future<List<PettyCashEntry>> history({int? limit}) =>
      (db.select(db.pettyCashEntries)
            ..orderBy([
              (e) =>
                  OrderingTerm(expression: e.createdAt, mode: OrderingMode.desc)
            ])
            ..limit(limit ?? 9223372036854775807))
          .get();

  Future<PagedResult<PettyCashEntry>> page({
    int page = 0,
    String search = '',
    String? userId,
    DateTime? from,
    DateTime? until,
  }) async {
    final conditions = <String>[];
    final variables = <Variable<Object>>[];
    if (userId != null) {
      conditions.add('user_id = ?');
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
      conditions.add('''(instr(lower(category), ?) > 0 OR
        instr(lower(COALESCE(note, '')), ?) > 0)''');
      variables.addAll([Variable.withString(term), Variable.withString(term)]);
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final count = await db
        .customSelect('SELECT COUNT(*) AS total FROM petty_cash_entries $where',
            variables: variables)
        .getSingle();
    final ids = await db.customSelect(
        '''SELECT id FROM petty_cash_entries $where
      ORDER BY created_at DESC, id DESC LIMIT 50 OFFSET ?''',
        variables: [...variables, Variable.withInt(page * 50)]).get();
    final ordered = ids.map((row) => row.read<String>('id')).toList();
    final rows = ordered.isEmpty
        ? <PettyCashEntry>[]
        : await (db.select(db.pettyCashEntries)
              ..where((row) => row.id.isIn(ordered)))
            .get();
    final byId = {for (final row in rows) row.id: row};
    return PagedResult(
        items: [for (final id in ordered) byId[id]!],
        totalCount: count.read<int>('total'),
        page: page);
  }

  Future<PettyCashEntry> record(ActiveUser actor,
          {required int amountCents, required String category, String? note}) =>
      db.transaction(() async {
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageCashSession);
        if (amountCents <= 0) throw ArgumentError('Amount must be positive');
        final cleanCategory = category.trim();
        if (cleanCategory.isEmpty) throw ArgumentError('Category is required');
        final session = await (db.select(db.cashSessions)
              ..where((s) => s.closedAt.isNull()))
            .getSingleOrNull();
        if (session == null) throw StateError('Open a cash session first');
        final entry = await db.into(db.pettyCashEntries).insertReturning(
              PettyCashEntriesCompanion.insert(
                cashSessionId: session.id,
                userId: live.id,
                amountCents: amountCents,
                category: cleanCategory,
                note: Value(note?.trim().isEmpty == true ? null : note?.trim()),
              ),
            );
        await db.into(db.cashMovements).insert(CashMovementsCompanion.insert(
              sessionId: session.id,
              amountCents: -amountCents,
              kind: 'petty_cash',
            ));
        await AuthRepository(db).audit(live.id, 'petty_cash.record', entry.id);
        return entry;
      });
}
