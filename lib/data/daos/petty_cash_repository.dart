import 'package:drift/drift.dart';

import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class PettyCashRepository {
  final AppDatabase db;
  PettyCashRepository(this.db);

  Future<List<PettyCashEntry>> history() => (db.select(db.pettyCashEntries)
        ..orderBy([
          (e) => OrderingTerm(expression: e.createdAt, mode: OrderingMode.desc)
        ]))
      .get();

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
