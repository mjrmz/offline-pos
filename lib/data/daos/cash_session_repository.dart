import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';

class CashSessionSummary {
  final CashSession session;
  final int expectedCents;
  final int? varianceCents;
  const CashSessionSummary(
      this.session, this.expectedCents, this.varianceCents);
}

class CashSessionRepository {
  final AppDatabase db;
  CashSessionRepository(this.db);

  Future<CashSession?> active() =>
      (db.select(db.cashSessions)..where((s) => s.closedAt.isNull()))
          .getSingleOrNull();

  Future<int> expected(String sessionId) async {
    final session = await (db.select(db.cashSessions)
          ..where((s) => s.id.equals(sessionId)))
        .getSingle();
    final movements = await (db.select(db.cashMovements)
          ..where((m) => m.sessionId.equals(sessionId)))
        .get();
    return session.startingCashCents +
        movements.fold<int>(0, (sum, row) => sum + row.amountCents);
  }

  Future<List<CashSessionSummary>> history() async {
    final rows = await (db.select(db.cashSessions)
          ..orderBy([
            (s) => OrderingTerm(expression: s.openedAt, mode: OrderingMode.desc)
          ]))
        .get();
    return Future.wait(rows.map((row) async {
      final amount = row.expectedCashCents ?? await expected(row.id);
      return CashSessionSummary(row, amount,
          row.actualCashCents == null ? null : row.actualCashCents! - amount);
    }));
  }

  Future<CashSession> open(ActiveUser actor, int startingCashCents) =>
      db.transaction(() async {
        if (startingCashCents < 0) {
          throw ArgumentError('Starting cash must be nonnegative');
        }
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageCashSession);
        if (await active() != null) {
          throw StateError('A cash session is already open');
        }
        final row = await db.into(db.cashSessions).insertReturning(
            CashSessionsCompanion.insert(
                openedByUserId: live.id, startingCashCents: startingCashCents));
        await AuthRepository(db).audit(live.id, 'cash_session.open', row.id);
        return row;
      });

  Future<CashSessionSummary> close(ActiveUser actor, int actualCashCents) =>
      db.transaction(() async {
        if (actualCashCents < 0) {
          throw ArgumentError('Actual cash must be nonnegative');
        }
        final live = await AuthRepository(db).requireActive(actor.id);
        live.require(PosPermission.manageCashSession);
        final row = await active();
        if (row == null) throw StateError('No active cash session');
        if (row.openedByUserId != live.id && live.role == UserRole.cashier) {
          throw StateError(
              'Only the opener or a manager can close this session');
        }
        final amount = await expected(row.id);
        final closed = DateTime.now();
        final count = await (db.update(db.cashSessions)
              ..where((s) => s.id.equals(row.id) & s.closedAt.isNull()))
            .write(CashSessionsCompanion(
                expectedCashCents: Value(amount),
                actualCashCents: Value(actualCashCents),
                closedAt: Value(closed)));
        if (count != 1) throw StateError('Session already closed');
        await AuthRepository(db).audit(live.id, 'cash_session.close',
            '${row.id}:expected=$amount:actual=$actualCashCents');
        return CashSessionSummary(
            row.copyWith(
                expectedCashCents: Value(amount),
                actualCashCents: Value(actualCashCents),
                closedAt: Value(closed)),
            amount,
            actualCashCents - amount);
      });
}
