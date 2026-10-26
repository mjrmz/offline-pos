import 'package:drift/drift.dart';
import 'package:bcrypt/bcrypt.dart';
import '../../core/models/active_user.dart';
import '../database.dart';
import 'auth_repository.dart';
import 'cash_session_repository.dart';

const handoverDenominations = <int>[
  100000,
  50000,
  20000,
  10000,
  5000,
  2000,
  1000,
  500,
  100,
];

class CashShiftHandover {
  final int id;
  final String sessionId, outgoingId, incomingId, status, notes;
  final int expected, actual, variance, createdAt;
  final String? managerId;
  final int? acknowledgedAt, completedAt;
  const CashShiftHandover(
      this.id,
      this.sessionId,
      this.outgoingId,
      this.incomingId,
      this.status,
      this.notes,
      this.expected,
      this.actual,
      this.variance,
      this.createdAt,
      this.managerId,
      this.acknowledgedAt,
      this.completedAt);
  String get reference => 'HOV-${id.toString().padLeft(6, '0')}';
}

class CashShiftHandoverRepository {
  final AppDatabase db;
  CashShiftHandoverRepository(this.db);
  CashSessionRepository get sessions => CashSessionRepository(db);
  AuthRepository get auth => AuthRepository(db);

  CashShiftHandover _read(QueryRow r) => CashShiftHandover(
      r.read<int>('id'),
      r.read<String>('cash_session_id'),
      r.read<String>('outgoing_user_id'),
      r.readNullable<String>('incoming_user_id') ?? '',
      r.read<String>('status'),
      r.read<String>('notes'),
      r.read<int>('expected_cash_cents'),
      r.readNullable<int>('actual_cash_cents') ?? 0,
      r.readNullable<int>('variance_cents') ?? 0,
      r.read<int>('created_at'),
      r.readNullable<String>('manager_user_id'),
      r.readNullable<int>('manager_acknowledged_at'),
      r.readNullable<int>('completed_at'));

  Future<CashShiftHandover> _get(int id) async => _read((await db.customSelect(
      'SELECT * FROM cash_shift_handovers WHERE id = ?',
      variables: [Variable.withInt(id)]).getSingle()));

  Future<CashShiftHandover> detail(ActiveUser actor, int id) async {
    final row = await _get(id);
    final live = await auth.requireActive(actor.id);
    if (live.id != row.outgoingId &&
        live.id != row.incomingId &&
        !live.can(PosPermission.acknowledgeShiftHandover)) {
      throw StateError('Not authorized for this handover');
    }
    return row;
  }

  Future<bool> hasActive(String sessionId) async =>
      (await _active(sessionId)) != null;

  Future<CashShiftHandover?> active(ActiveUser actor, String sessionId) async {
    final row = await _active(sessionId);
    if (row == null) return null;
    final live = await auth.requireActive(actor.id);
    if (live.id != row.outgoingId &&
        live.id != row.incomingId &&
        !live.can(PosPermission.acknowledgeShiftHandover)) {
      return null;
    }
    return row;
  }

  Future<CashShiftHandover?> _active(String sessionId) async {
    final row = await db.customSelect(
        "SELECT * FROM cash_shift_handovers WHERE cash_session_id = ? AND status IN ('draft','awaiting_acknowledgment')",
        variables: [Variable.withString(sessionId)]).getSingleOrNull();
    return row == null ? null : _read(row);
  }

  Future<List<CashShiftHandover>> history(ActiveUser actor,
      {int limit = 50,
      int offset = 0,
      String? status,
      bool varianceOnly = false}) async {
    final live = await auth.requireActive(actor.id);
    live.require(PosPermission.acknowledgeShiftHandover);
    final where = <String>[];
    final args = <Variable>[];
    if (status != null) {
      where.add('status = ?');
      args.add(Variable.withString(status));
    }
    if (varianceOnly) where.add('variance_cents != 0');
    args.add(Variable.withInt(limit.clamp(1, 50)));
    args.add(Variable.withInt(offset < 0 ? 0 : offset));
    final rows = await db
        .customSelect(
            'SELECT * FROM cash_shift_handovers ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY id DESC LIMIT ? OFFSET ?',
            variables: args)
        .get();
    return rows.map(_read).toList();
  }

  Future<Map<int, int>> denominations(int id, ActiveUser actor) async {
    await detail(actor, id);
    final rows = await db.customSelect(
        'SELECT denomination_cents, quantity FROM cash_shift_handover_denominations WHERE handover_id = ?',
        variables: [Variable.withInt(id)]).get();
    return {
      for (final r in rows)
        r.read<int>('denomination_cents'): r.read<int>('quantity')
    };
  }

  Future<CashShiftHandover> start(ActiveUser actor, String sessionId) =>
      db.transaction(() async {
        final live = await auth.requireActive(actor.id);
        live.require(PosPermission.manageCashSession);
        final session = await sessions.active();
        if (session == null || session.id != sessionId) {
          throw StateError('Cash session is closed');
        }
        if (await _active(sessionId) != null) {
          throw StateError('An active handover already exists');
        }
        final last = await db.customSelect(
            "SELECT incoming_user_id FROM cash_shift_handovers WHERE cash_session_id = ? AND status = 'completed' ORDER BY id DESC LIMIT 1",
            variables: [Variable.withString(sessionId)]).getSingleOrNull();
        final owner =
            last?.read<String>('incoming_user_id') ?? session.openedByUserId;
        if (live.id != owner && !live.can(PosPermission.closeAnyCashSession)) {
          throw StateError(
              'Only the current cashier or a manager can hand over this drawer');
        }
        await db.customStatement(
            'INSERT INTO cash_shift_handovers (cash_session_id, outgoing_user_id, expected_cash_cents, created_at) VALUES (?, ?, ?, ?)',
            [
              sessionId,
              owner,
              await sessions.expected(sessionId),
              DateTime.now().millisecondsSinceEpoch
            ]);
        final id = (await db
                .customSelect('SELECT last_insert_rowid() AS id')
                .getSingle())
            .read<int>('id');
        final row = await _get(id);
        await auth.audit(live.id, 'shift_handover.started',
            '${row.reference}:$sessionId:outgoing=$owner');
        return row;
      });

  Future<CashShiftHandover> submit(ActiveUser actor, int id, String incomingId,
          Map<int, int> count, String notes) =>
      db.transaction(() async {
        final row = await _get(id);
        final live = await auth.requireActive(actor.id);
        if (live.id != row.outgoingId &&
            !live.can(PosPermission.closeAnyCashSession)) {
          throw StateError('Only the outgoing cashier or a manager can submit');
        }
        if (row.status != 'draft') throw StateError('Count is locked');
        if ((await sessions.active())?.id != row.sessionId) {
          throw StateError('Cash session is closed');
        }
        final incoming = await auth.requireActive(incomingId);
        incoming.require(PosPermission.manageCashSession);
        incoming.require(PosPermission.sell);
        if (incoming.id == row.outgoingId) {
          throw StateError(
              'Incoming cashier must differ from outgoing cashier');
        }
        if (count.keys.any((key) => !handoverDenominations.contains(key)) ||
            count.values.any((value) => value < 0 || value > 1000000)) {
          throw StateError('Invalid denomination count');
        }
        final expected = await sessions.expected(row.sessionId);
        if (expected != row.expected) {
          throw StateError(
              'Drawer activity changed since counting began. Expected cash changed from ${row.expected} to $expected cents. Recount required.');
        }
        final actual = count.entries
            .fold<int>(0, (sum, entry) => sum + entry.key * entry.value);
        final variance = actual - expected;
        if (variance != 0 && notes.trim().isEmpty) {
          throw StateError('A reason is required for a cash variance');
        }
        await db.customStatement(
            'DELETE FROM cash_shift_handover_denominations WHERE handover_id = ?',
            [id]);
        for (final entry in count.entries) {
          await db.customStatement(
              'INSERT INTO cash_shift_handover_denominations (handover_id, denomination_cents, quantity, subtotal_cents) VALUES (?, ?, ?, ?)',
              [id, entry.key, entry.value, entry.key * entry.value]);
        }
        await db.customStatement(
            "UPDATE cash_shift_handovers SET incoming_user_id = ?, actual_cash_cents = ?, variance_cents = ?, notes = ?, status = 'awaiting_acknowledgment', submitted_at = ? WHERE id = ? AND status = 'draft'",
            [
              incomingId,
              actual,
              variance,
              notes.trim(),
              DateTime.now().millisecondsSinceEpoch,
              id
            ]);
        await auth.audit(live.id, 'shift_handover.count_submitted',
            '${row.reference}:${row.sessionId}:outgoing=${row.outgoingId}:incoming=$incomingId:variance=$variance');
        return _get(id);
      });

  Future<CashShiftHandover> recount(ActiveUser actor, int id) =>
      db.transaction(() async {
        final row = await _get(id);
        final live = await auth.requireActive(actor.id);
        if (live.id != row.outgoingId &&
            !live.can(PosPermission.closeAnyCashSession)) {
          throw StateError('Not authorized to recount');
        }
        if (row.status != 'awaiting_acknowledgment') {
          throw StateError('Handover is not awaiting acknowledgment');
        }
        if ((await sessions.active())?.id != row.sessionId) {
          throw StateError('Cash session is closed');
        }
        await db.customStatement(
            "UPDATE cash_shift_handovers SET status = 'draft', actual_cash_cents = NULL, variance_cents = NULL, expected_cash_cents = ?, submitted_at = NULL WHERE id = ?",
            [await sessions.expected(row.sessionId), id]);
        await db.customStatement(
            'DELETE FROM cash_shift_handover_denominations WHERE handover_id = ?',
            [id]);
        return _get(id);
      });

  Future<CashShiftHandover> complete(ActiveUser actor, int id, String managerId,
      {String? credential}) async {
    final manager = await auth.requireActive(managerId);
    manager.require(PosPermission.acknowledgeShiftHandover);
    if (actor.id != managerId || credential != null) {
      final account = await auth.user(managerId);
      if (account == null ||
          account.lockedUntil != null &&
              DateTime.now().isBefore(account.lockedUntil!) ||
          credential == null ||
          account.passwordHash == null ||
          !BCrypt.checkpw(credential, account.passwordHash!)) {
        if (account != null &&
            account.isActive &&
            account.lockedUntil == null) {
          final attempts = account.failedAttempts + 1;
          await auth.failed(
              managerId,
              attempts,
              attempts >= 5
                  ? DateTime.now().add(const Duration(minutes: 2))
                  : null);
        }
        await auth.audit(actor.id, 'shift_handover.authorization_failed');
        throw StateError('Manager authorization failed');
      }
      await auth.discountCredentialSucceeded(managerId);
    }
    return db.transaction(() async {
      final live = await auth.requireActive(actor.id);
      final approver = await auth.requireActive(managerId);
      approver.require(PosPermission.acknowledgeShiftHandover);
      final row = await _get(id);
      if (row.status != 'awaiting_acknowledgment') {
        throw StateError('Handover is not awaiting acknowledgment');
      }
      if (live.id != row.outgoingId &&
          live.id != row.incomingId &&
          !live.can(PosPermission.acknowledgeShiftHandover)) {
        throw StateError('Not authorized for this handover');
      }
      if ((await sessions.active())?.id != row.sessionId) {
        throw StateError('Cash session is closed');
      }
      final expected = await sessions.expected(row.sessionId);
      if (expected != row.expected) {
        throw StateError(
            'Drawer activity changed since counting began. Expected cash changed from ${row.expected} to $expected cents. Recount required.');
      }
      final incoming = await auth.requireActive(row.incomingId);
      incoming.require(PosPermission.manageCashSession);
      incoming.require(PosPermission.sell);
      if (incoming.id == row.outgoingId) {
        throw StateError('Invalid receiving cashier');
      }
      final sum = (await db.customSelect(
              'SELECT COALESCE(SUM(subtotal_cents), 0) AS total FROM cash_shift_handover_denominations WHERE handover_id = ?',
              variables: [Variable.withInt(id)]).getSingle())
          .read<int>('total');
      if (sum != row.actual || row.variance != row.actual - expected) {
        throw StateError('Denomination total does not match');
      }
      if (row.variance != 0 && row.notes.trim().isEmpty) {
        throw StateError('Variance reason is required');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.customStatement(
          "UPDATE cash_shift_handovers SET status = 'completed', manager_user_id = ?, manager_acknowledged_at = ?, completed_at = ? WHERE id = ? AND status = 'awaiting_acknowledgment'",
          [approver.id, now, now, id]);
      await auth.audit(approver.id, 'shift_handover.manager_acknowledged',
          '${row.reference}:${row.sessionId}:outgoing=${row.outgoingId}:incoming=${row.incomingId}:variance=${row.variance}');
      await auth.audit(live.id, 'shift_handover.completed', row.reference);
      return _get(id);
    });
  }

  Future<void> cancel(ActiveUser actor, int id) => db.transaction(() async {
        final row = await _get(id);
        final live = await auth.requireActive(actor.id);
        if (live.id != row.outgoingId &&
            !live.can(PosPermission.closeAnyCashSession)) {
          throw StateError('Not authorized to cancel');
        }
        if (row.status != 'draft' && row.status != 'awaiting_acknowledgment') {
          throw StateError('Handover cannot be cancelled');
        }
        await db.customStatement(
            "UPDATE cash_shift_handovers SET status = 'cancelled', cancelled_at = ? WHERE id = ?",
            [DateTime.now().millisecondsSinceEpoch, id]);
        await auth.audit(live.id, 'shift_handover.cancelled',
            '${row.reference}:${row.sessionId}:outgoing=${row.outgoingId}:incoming=${row.incomingId}:variance=${row.variance}');
      });
}
