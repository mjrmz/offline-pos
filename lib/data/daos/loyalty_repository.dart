import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import 'auth_repository.dart';
import '../../core/models/active_user.dart';

class LoyaltySettings {
  final bool enabled;
  final int spendPerPointCents;
  final int redeemPoints;
  final int redeemValueCents;
  const LoyaltySettings(this.enabled, this.spendPerPointCents,
      this.redeemPoints, this.redeemValueCents);
}

class LoyaltyEntry {
  final String kind;
  final int points;
  final String? sourceId;
  final String? reason;
  final String? note;
  final DateTime createdAt;
  const LoyaltyEntry(this.kind, this.points, this.sourceId, this.reason,
      this.note, this.createdAt);
}

class LoyaltyLedgerSummary {
  final int count;
  final int earned;
  final int redeemed;
  final int adjustments;
  const LoyaltyLedgerSummary(
      this.count, this.earned, this.redeemed, this.adjustments);
}

class LoyaltyLedgerRow {
  final LoyaltyEntry entry;
  final int balance;
  const LoyaltyLedgerRow(this.entry, this.balance);
}

class LoyaltyRepository {
  final AppDatabase db;
  const LoyaltyRepository(this.db);

  Future<LoyaltySettings> settings() async {
    final row = await db
        .customSelect('SELECT * FROM loyalty_settings WHERE id=1')
        .getSingle();
    return LoyaltySettings(
        row.read<int>('enabled') != 0,
        row.read<int>('spend_per_point_cents'),
        row.read<int>('redeem_points'),
        row.read<int>('redeem_value_cents'));
  }

  Future<int> balance(String customerId) async {
    final row = await db.customSelect(
        'SELECT COALESCE(SUM(points_delta),0) AS balance FROM loyalty_ledger WHERE customer_id=?',
        variables: [Variable.withString(customerId)]).getSingle();
    return row.read<int>('balance');
  }

  Future<String> group(String customerId) async {
    final row = await db.customSelect(
        'SELECT group_name FROM customer_groups WHERE customer_id=?',
        variables: [Variable.withString(customerId)]).getSingleOrNull();
    return row?.read<String>('group_name') ?? 'Retail';
  }

  Future<void> setGroup(String customerId, String actorId, String group) =>
      db.transaction(() async {
        if (!const ['Retail', 'VIP', 'Dealer', 'Wholesale', 'Employee']
            .contains(group)) {
          throw ArgumentError('Invalid group');
        }
        (await AuthRepository(db).requireActive(actorId))
            .require(PosPermission.manageLoyalty);
        await db.customStatement(
            '''INSERT INTO customer_groups(customer_id,group_name)
      VALUES (?,?) ON CONFLICT(customer_id) DO UPDATE SET group_name=excluded.group_name''',
            [customerId, group]);
        await AuthRepository(db)
            .audit(actorId, 'customer.group', '$customerId:$group');
      });

  Future<List<LoyaltyEntry>> entries(String customerId) async {
    final rows = await db.customSelect(
        '''SELECT l.*, COALESCE(s.receipt_number,r.reference,l.source_id) AS source_reference
        FROM loyalty_ledger l LEFT JOIN sales s ON s.id=l.source_id
        LEFT JOIN sale_returns r ON r.id=l.source_id
        WHERE l.customer_id=? ORDER BY l.created_at DESC, l.rowid DESC''',
        variables: [Variable.withString(customerId)]).get();
    return rows
        .map((row) => LoyaltyEntry(
            row.read<String>('kind'),
            row.read<int>('points_delta'),
            row.readNullable<String>('source_reference'),
            row.readNullable<String>('reason'),
            row.readNullable<String>('note'),
            DateTime.fromMillisecondsSinceEpoch(
                row.read<int>('created_at') * 1000)))
        .toList();
  }

  Future<LoyaltyLedgerSummary> ledgerSummary(String customerId) async {
    final row = await db.customSelect('''
      SELECT COUNT(*) AS total,
        COALESCE(SUM(CASE WHEN kind='earn' THEN points_delta ELSE 0 END),0) AS earned,
        COALESCE(SUM(CASE WHEN kind='redeem' THEN -points_delta ELSE 0 END),0) AS redeemed,
        COALESCE(SUM(CASE WHEN kind='manual' THEN points_delta ELSE 0 END),0) AS adjustments
      FROM loyalty_ledger WHERE customer_id=?
    ''', variables: [Variable.withString(customerId)]).getSingle();
    return LoyaltyLedgerSummary(row.read<int>('total'), row.read<int>('earned'),
        row.read<int>('redeemed'), row.read<int>('adjustments'));
  }

  Future<List<LoyaltyLedgerRow>> ledgerPage(String customerId, int page) async {
    final rows = await db.customSelect('''
      WITH ledger AS (
        SELECT l.*, l.rowid AS sequence,
          SUM(l.points_delta) OVER (
            PARTITION BY l.customer_id ORDER BY l.created_at, l.rowid
            ROWS UNBOUNDED PRECEDING) AS running_balance
        FROM loyalty_ledger l WHERE l.customer_id=?
      )
      SELECT ledger.*, COALESCE(s.receipt_number,r.reference,ledger.source_id)
        AS source_reference
      FROM ledger LEFT JOIN sales s ON s.id=ledger.source_id
      LEFT JOIN sale_returns r ON r.id=ledger.source_id
      ORDER BY ledger.created_at DESC, ledger.sequence DESC
      LIMIT 50 OFFSET ?
    ''', variables: [
      Variable.withString(customerId),
      Variable.withInt(page * 50)
    ]).get();
    return [
      for (final row in rows)
        LoyaltyLedgerRow(
          LoyaltyEntry(
            row.read<String>('kind'),
            row.read<int>('points_delta'),
            row.readNullable<String>('source_reference'),
            row.readNullable<String>('reason'),
            row.readNullable<String>('note'),
            DateTime.fromMillisecondsSinceEpoch(
                row.read<int>('created_at') * 1000),
          ),
          row.read<int>('running_balance'),
        ),
    ];
  }

  Future<void> append(String customerId, String kind, int points,
      {String? sourceId,
      String? actorId,
      String? reason,
      String? note,
      int? eligibleCents,
      String? snapshot}) async {
    if (points == 0) return;
    await db.customStatement('''INSERT INTO loyalty_ledger
      (id,customer_id,kind,points_delta,source_id,actor_id,reason,note,eligible_cents,rule_snapshot)
      VALUES (?,?,?,?,?,?,?,?,?,?)''', [
      const Uuid().v4(),
      customerId,
      kind,
      points,
      sourceId,
      actorId,
      reason,
      note,
      eligibleCents,
      snapshot
    ]);
  }

  Future<void> adjust(
          String customerId, String actorId, int delta, String reason,
          {String? note}) =>
      db.transaction(() async {
        if (delta == 0 || reason.trim().isEmpty) {
          throw ArgumentError('Points and reason are required');
        }
        (await AuthRepository(db).requireActive(actorId))
            .require(PosPermission.manageLoyalty);
        if (delta < 0 && await balance(customerId) + delta < 0) {
          throw StateError('Insufficient points');
        }
        await append(customerId, 'manual', delta,
            actorId: actorId, reason: reason.trim(), note: note);
        await AuthRepository(db).audit(
            actorId, 'loyalty.adjust', '$customerId:$delta:${reason.trim()}');
      });

  Future<void> updateSettings(String actorId, LoyaltySettings value) =>
      db.transaction(() async {
        if (value.spendPerPointCents <= 0 ||
            value.redeemPoints <= 0 ||
            value.redeemValueCents <= 0) {
          throw ArgumentError('Loyalty values must be positive');
        }
        (await AuthRepository(db).requireActive(actorId))
            .require(PosPermission.manageSettings);
        await db.customStatement(
            '''UPDATE loyalty_settings SET enabled=?,
      spend_per_point_cents=?,redeem_points=?,redeem_value_cents=? WHERE id=1''',
            [
              value.enabled ? 1 : 0,
              value.spendPerPointCents,
              value.redeemPoints,
              value.redeemValueCents
            ]);
        await AuthRepository(db).audit(actorId, 'loyalty.settings',
            '${value.enabled}:${value.spendPerPointCents}:${value.redeemPoints}:${value.redeemValueCents}');
      });
}
