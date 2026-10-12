import 'dart:async';
import 'package:drift/drift.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import '../../backup/compliance_protection.dart';
import 'package:uuid/uuid.dart';

class CashSessionSummary {
  final CashSession session;
  final int expectedCents;
  final int? varianceCents;
  final bool protectionWarning;
  const CashSessionSummary(this.session, this.expectedCents, this.varianceCents,
      [this.protectionWarning = false]);
}

class CashSessionRepository {
  final AppDatabase db;
  final bool _birReady;
  final bool Function()? birEntitled;
  bool get birReady => birEntitled?.call() ?? _birReady;
  final ComplianceProtection? protection;
  CashSessionRepository(this.db,
      {bool birReady = false, this.birEntitled, this.protection})
      : _birReady = birReady;

  Future<List<ZReading>> zHistory() => (db.select(db.zReadings)
        ..orderBy([
          (z) => OrderingTerm(expression: z.number, mode: OrderingMode.desc)
        ]))
      .get();

  Future<CashSession?> active() =>
      (db.select(db.cashSessions)..where((s) => s.closedAt.isNull()))
          .getSingleOrNull();

  Future<CashSessionSummary?> currentFor(String userId) async {
    final rows = await (db.select(db.cashSessions)
          ..where((s) => s.closedAt.isNull()))
        .get();
    if (rows.length > 1) {
      throw StateError('Multiple open cash sessions require reconciliation');
    }
    if (rows.isEmpty || rows.single.openedByUserId != userId) return null;
    final row = rows.single;
    return CashSessionSummary(row, await expected(row.id), null);
  }

  Stream<CashSessionSummary?> watchCurrentFor(String userId) {
    late final StreamSubscription<dynamic> updates;
    var revision = 0;
    late final StreamController<CashSessionSummary?> controller;
    Future<void> refresh() async {
      final requested = ++revision;
      try {
        final shift = await currentFor(userId);
        if (requested == revision && !controller.isClosed) {
          controller.add(shift);
        }
      } catch (error, stack) {
        if (requested == revision && !controller.isClosed) {
          controller.addError(error, stack);
        }
      }
    }

    controller = StreamController<CashSessionSummary?>(
      onListen: () {
        updates = db
            .tableUpdates(TableUpdateQuery.onAllTables([
              db.cashSessions,
              db.cashMovements,
            ]))
            .listen((_) => refresh());
        refresh();
      },
      onCancel: () async {
        revision++;
        await updates.cancel();
      },
    );
    return controller.stream;
  }

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

  Future<CashSessionSummary> close(
      ActiveUser actor, int actualCashCents) async {
    if (birReady) {
      if (protection == null) {
        throw StateError('Compliance protection is unavailable');
      }
      return protection!.exclusive(() => _close(actor, actualCashCents));
    }
    return _close(actor, actualCashCents);
  }

  Future<CashSessionSummary> _close(
      ActiveUser actor, int actualCashCents) async {
    if (birReady) {
      if (protection == null) {
        throw StateError('Compliance protection is unavailable');
      }
      await protection!.prepare(db);
    }
    String? reservedZId;
    late final CashSessionSummary result;
    try {
      result = await db.transaction(() async {
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
        if (birReady) {
          var state = await (db.select(db.birComplianceState)
                ..where((s) => s.id.equals(1)))
              .getSingleOrNull();
          if (state == null) {
            await db.into(db.birComplianceState).insert(
                BirComplianceStateCompanion.insert(
                    id: const Value(1), activatedAt: DateTime.now()));
            state = await (db.select(db.birComplianceState)
                  ..where((s) => s.id.equals(1)))
                .getSingle();
            await AuthRepository(db).audit(live.id, 'bir.cutover', 'activated');
          }
          final sessionSales = await (db.select(db.sales)
                ..where((s) =>
                    s.cashSessionId.equals(row.id) &
                    s.birInvoiceNumber.isNotNull()))
              .get();
          final numbers = <int>[];
          var salesTotal = 0;
          var reversalTotal = 0;
          for (final sale in sessionSales) {
            numbers.add(sale.birInvoiceNumber!);
            salesTotal += sale.totalCents;
            final reversal = await (db.select(db.saleReversals)
                  ..where((r) => r.saleId.equals(sale.id)))
                .getSingleOrNull();
            reversalTotal += reversal?.amountCents ?? 0;
          }
          final itemRefunds = await (db.select(db.saleItemRefunds)
                ..where((r) => r.cashSessionId.equals(row.id)))
              .get();
          reversalTotal += itemRefunds.fold<int>(
              0, (sum, refund) => sum + refund.amountCents);
          numbers.sort();
          final zNumber = state.highestZNumber + 1;
          reservedZId = const Uuid().v4();
          final generatedAt = DateTime.fromMillisecondsSinceEpoch(
              (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000);
          await protection!.reserveZ(db, {
            'id': reservedZId!,
            'number': zNumber,
            'cashSessionId': row.id,
            'generatedAt': generatedAt.toUtc().toIso8601String(),
            'generatedByUserId': live.id,
            'beginningInvoiceNumber': numbers.isEmpty ? null : numbers.first,
            'endingInvoiceNumber': numbers.isEmpty ? null : numbers.last,
            'periodSalesCents': salesTotal,
            'reversalCents': reversalTotal,
            'grandTotalCents': state.grandTotalCents,
            'expectedCashCents': amount,
            'actualCashCents': actualCashCents,
          });
          await db.into(db.zReadings).insert(ZReadingsCompanion.insert(
              id: Value(reservedZId!),
              number: zNumber,
              cashSessionId: row.id,
              generatedAt: Value(generatedAt),
              generatedByUserId: live.id,
              beginningInvoiceNumber:
                  Value(numbers.isEmpty ? null : numbers.first),
              endingInvoiceNumber: Value(numbers.isEmpty ? null : numbers.last),
              periodSalesCents: salesTotal,
              reversalCents: reversalTotal,
              grandTotalCents: state.grandTotalCents,
              expectedCashCents: amount,
              actualCashCents: actualCashCents));
          await (db.update(db.birComplianceState)..where((s) => s.id.equals(1)))
              .write(
                  BirComplianceStateCompanion(highestZNumber: Value(zNumber)));
          await AuthRepository(db)
              .audit(live.id, 'bir.z_reading', '$zNumber:${row.id}');
        }
        return CashSessionSummary(
            row.copyWith(
                expectedCashCents: Value(amount),
                actualCashCents: Value(actualCashCents),
                closedAt: Value(closed)),
            amount,
            actualCashCents - amount);
      });
    } catch (error) {
      if (reservedZId != null && error is! SimulatedComplianceCrash) {
        await protection!.abortZAfterRollback(db, reservedZId!);
      }
      rethrow;
    }
    if (reservedZId != null) {
      try {
        await protection!.finalizeZ(reservedZId!);
      } catch (_) {
        return CashSessionSummary(
            result.session, result.expectedCents, result.varianceCents, true);
      }
    }
    return result;
  }
}
