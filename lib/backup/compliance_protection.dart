import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';

import '../data/database.dart';

enum ComplianceStep {
  beforeReservation,
  afterReservation,
  beforeFinalize,
  duringFinalize,
  duringReconcile,
}

/// Used only by deterministic tests to model process termination. The
/// transaction rolls back, but the durable reservation is intentionally left.
class SimulatedComplianceCrash implements Exception {}

/// A write-ahead ledger outside the SQLite file replaced by Phase 5 restore.
/// Both journals must acknowledge a reservation before SQLite may commit.
/// An unresolved reservation blocks new BIR issuance if the original DB is
/// unavailable, because its outcome cannot then be proved.
class ComplianceProtection {
  final File file; // The former Phase 7 mirror; read once for migration only.
  final Future<void> Function(ComplianceStep)? failureHook;
  ComplianceProtection(this.file, {this.failureHook});

  File get _first => File('${file.path}.journal-a');
  File get _second => File('${file.path}.journal-b');
  File get _marker => File('${file.path}.journal-active');
  File get _head => File('${file.path}.journal-head');
  _Ledger? _ledger;
  Future<void>? _preparing;
  Future<void> _operationTail = Future.value();

  Future<T> exclusive<T>(Future<T> Function() action) async {
    final prior = _operationTail;
    final done = Completer<void>();
    _operationTail = done.future;
    await prior;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<void> _fail(ComplianceStep step) async {
    if (failureHook != null) await failureHook!(step);
  }

  Future<String> _digest(Map<String, dynamic> body) async {
    final result = await Sha256().hash(utf8.encode(jsonEncode(body)));
    return result.bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<List<Map<String, dynamic>>> _readJournal(File source) async {
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty || bytes.last != 10) {
      throw StateError('Compliance journal has an incomplete tail');
    }
    final lines = utf8.decode(bytes).trimRight().split('\n');
    final rows = <Map<String, dynamic>>[];
    var previous = '';
    for (final line in lines) {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('Malformed compliance journal record');
      }
      final record = Map<String, dynamic>.from(decoded);
      final hash = record.remove('hash');
      if (record['seq'] != rows.length + 1 ||
          record['previous'] != previous ||
          hash != await _digest(record)) {
        throw StateError('Compliance journal checksum or sequence mismatch');
      }
      previous = hash as String;
      record['hash'] = hash;
      rows.add(record);
    }
    return rows;
  }

  Future<void> _replace(File target, List<Map<String, dynamic>> records) async {
    final temp = File('${target.path}.pending');
    final old = File('${target.path}.previous');
    await temp.writeAsString('${records.map(jsonEncode).join('\n')}\n',
        flush: true);
    if (await old.exists()) await old.delete();
    if (await target.exists()) await target.rename(old.path);
    try {
      await temp.rename(target.path);
    } catch (_) {
      if (await old.exists()) await old.rename(target.path);
      rethrow;
    }
  }

  Future<void> _writeHead(Map<String, dynamic> record) async {
    final temp = File('${_head.path}.pending');
    final prior = File('${_head.path}.previous');
    await temp.writeAsString(
        jsonEncode({
          'seq': record['seq'],
          'hash': record['hash'],
        }),
        flush: true);
    if (await prior.exists()) await prior.delete();
    if (await _head.exists()) await _head.rename(prior.path);
    try {
      await temp.rename(_head.path);
    } catch (_) {
      if (await prior.exists()) await prior.rename(_head.path);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> _readHead() async {
    final choices = <Map<String, dynamic>>[];
    for (final candidate in [_head, File('${_head.path}.previous')]) {
      if (!await candidate.exists()) continue;
      try {
        final value = jsonDecode(await candidate.readAsString());
        if (value is Map<String, dynamic> &&
            value['seq'] is int &&
            value['hash'] is String) {
          choices.add(value);
        }
      } catch (_) {/* The other generation may be valid. */}
    }
    if (choices.isEmpty) return null;
    choices.sort((a, b) => (b['seq'] as int).compareTo(a['seq'] as int));
    return choices.first;
  }

  Future<List<Map<String, dynamic>>?> _loadRecords() async {
    final aExists = await _first.exists();
    final bExists = await _second.exists();
    if (!aExists && !bExists) {
      if (await _marker.exists()) {
        throw StateError('Both protected compliance journals are missing');
      }
      return null;
    }
    List<Map<String, dynamic>>? a;
    List<Map<String, dynamic>>? b;
    try {
      if (aExists) a = await _readJournal(_first);
    } catch (_) {/* The other copy may be valid. */}
    try {
      if (bExists) b = await _readJournal(_second);
    } catch (_) {/* The other copy may be valid. */}
    if (a == null && b == null) {
      throw StateError('Both protected compliance journals are unreadable');
    }
    if (a != null && b != null) {
      final common = a.length < b.length ? a.length : b.length;
      for (var i = 0; i < common; i++) {
        if (a[i]['hash'] != b[i]['hash']) {
          throw StateError('Protected compliance journals disagree');
        }
      }
    }
    final selected = a == null || (b != null && b.length > a.length) ? b! : a;
    final state = _Ledger.replay(selected);
    final head = await _readHead();
    if (head == null) {
      if (await _marker.exists()) {
        throw StateError('Protected compliance journal head is missing');
      }
    } else {
      final sequence = head['seq'] as int;
      if (sequence < 1 ||
          sequence > selected.length ||
          selected[sequence - 1]['hash'] != head['hash']) {
        throw StateError(
            'Protected compliance journal was truncated or changed');
      }
    }
    if (a == null || a.length != selected.length) {
      await _replace(_first, selected);
    }
    if (b == null || b.length != selected.length) {
      await _replace(_second, selected);
    }
    if (head == null || head['seq'] != selected.length) {
      await _writeHead(selected.last);
    }
    if (!await _marker.exists()) {
      await _marker.writeAsString('bir-journal-v1', flush: true);
    } else if (await _marker.readAsString() != 'bir-journal-v1') {
      throw StateError('Invalid compliance journal marker');
    }
    _ledger = state;
    return selected;
  }

  Future<Map<String, dynamic>> _snapshot(AppDatabase db) async {
    final state = await (db.select(db.birComplianceState)
          ..where((s) => s.id.equals(1)))
        .getSingleOrNull();
    final snapshots = <Map<String, dynamic>>[
      for (final z in await db.select(db.zReadings).get()) zData(z)
    ];
    if (!await file.exists()) {
      if (state != null) {
        throw StateError('BIR database has no protected compliance journal');
      }
      return {
        'invoice': 0,
        'total': 0,
        'z': 0,
        'activatedAt': null,
        'zReadings': <Map<String, dynamic>>[],
      };
    }
    // Migration from the earlier post-commit mirror requires a healthy live
    // database. It cannot repair an already-lost commit from that design.
    final old = jsonDecode(await file.readAsString());
    if (old is! Map<String, dynamic>) {
      throw StateError('Legacy compliance mirror is malformed');
    }
    final oldZ = <int, Map<String, dynamic>>{};
    for (final raw in old['zReadings'] as List? ?? []) {
      final row = Map<String, dynamic>.from(raw as Map);
      oldZ[row['number'] as int] = row;
    }
    for (final row in snapshots) {
      final prior = oldZ[row['number'] as int];
      if (prior != null && jsonEncode(prior) != jsonEncode(row)) {
        throw StateError('Legacy mirror Z-reading conflicts with database');
      }
      oldZ[row['number'] as int] = row;
    }
    final invoice = old['highestInvoiceNumber'] as int;
    final total = old['grandTotalCents'] as int;
    final zNumber = old['highestZNumber'] as int;
    if (state == null ||
        state.highestInvoiceNumber < invoice ||
        state.grandTotalCents < total ||
        state.highestZNumber < zNumber) {
      throw StateError(
          'Legacy compliance mirror is ahead of the live database; supervised migration is required');
    }
    return {
      'invoice': state.highestInvoiceNumber,
      'total': state.grandTotalCents,
      'z': state.highestZNumber,
      'activatedAt':
          old['activatedAt'] ?? state.activatedAt.toUtc().toIso8601String(),
      'zReadings': oldZ.values.toList()
        ..sort((a, b) => (a['number'] as int).compareTo(b['number'] as int)),
    };
  }

  Future<void> _initialize(AppDatabase db) async {
    if (_ledger != null) return;
    if (await _loadRecords() != null) return;
    final snapshot = await _snapshot(db);
    final record = <String, dynamic>{
      'seq': 1,
      'previous': '',
      'kind': 'genesis',
      'data': snapshot,
    };
    record['hash'] = await _digest(record);
    await file.parent.create(recursive: true);
    await _replace(_first, [record]);
    await _replace(_second, [record]);
    await _writeHead(record);
    await _marker.writeAsString('bir-journal-v1', flush: true);
    _ledger = _Ledger.replay([record]);
  }

  Future<void> prepare(AppDatabase db) async {
    final existing = _preparing;
    if (existing != null) return existing;
    final operation = _prepareInternal(db);
    _preparing = operation;
    try {
      await operation;
    } finally {
      if (identical(_preparing, operation)) _preparing = null;
    }
  }

  Future<void> _prepareInternal(AppDatabase db) async {
    await _initialize(db);
    if (_ledger!.pending != null) {
      throw StateError('Unresolved compliance reservation; recovery required');
    }
  }

  Future<void> _append(String kind, Map<String, dynamic> data) async {
    final current = _ledger!;
    final record = <String, dynamic>{
      'seq': current.records.length + 1,
      'previous': current.records.last['hash'],
      'kind': kind,
      'data': data,
    };
    record['hash'] = await _digest(record);
    final encoded = '${jsonEncode(record)}\n';
    try {
      await _first.writeAsString(encoded, mode: FileMode.append, flush: true);
      if (kind.startsWith('commit_')) {
        await _fail(ComplianceStep.duringFinalize);
      }
      await _second.writeAsString(encoded, mode: FileMode.append, flush: true);
      await _writeHead(record);
      _ledger = _Ledger.replay([...current.records, record]);
    } catch (_) {
      _ledger = null;
      rethrow;
    }
  }

  Future<void> reserveSale(AppDatabase db, String saleId, int number,
      int amountCents, DateTime activatedAt) async {
    await prepare(db);
    await _fail(ComplianceStep.beforeReservation);
    if (number != _ledger!.invoice + 1 || amountCents <= 0) {
      throw StateError(
          'BIR invoice reservation disagrees with protected state');
    }
    await _append('reserve_sale', {
      'id': saleId,
      'number': number,
      'amount': amountCents,
      'activatedAt': activatedAt.toUtc().toIso8601String(),
    });
    await _fail(ComplianceStep.afterReservation);
  }

  Future<void> finalizeSale(String saleId) async {
    await _fail(ComplianceStep.beforeFinalize);
    await _append('commit_sale', {'id': saleId});
  }

  Future<void> abortSaleAfterRollback(AppDatabase db, String saleId) async {
    await _loadRecords();
    if ((_ledger?.pending?['data'] as Map?)?['id'] != saleId) return;
    final sale = await (db.select(db.sales)..where((s) => s.id.equals(saleId)))
        .getSingleOrNull();
    if (sale != null) throw StateError('Cannot abandon a committed sale');
    await _append('abort_sale', {'id': saleId});
  }

  Future<void> reserveZ(AppDatabase db, Map<String, dynamic> z) async {
    await prepare(db);
    await _fail(ComplianceStep.beforeReservation);
    if (z['number'] != _ledger!.z + 1 ||
        z['grandTotalCents'] != _ledger!.total) {
      throw StateError('Z-reading reservation disagrees with protected state');
    }
    await _append('reserve_z', z);
    await _fail(ComplianceStep.afterReservation);
  }

  Future<void> finalizeZ(String id) async {
    await _fail(ComplianceStep.beforeFinalize);
    await _append('commit_z', {'id': id});
  }

  Future<void> abortZAfterRollback(AppDatabase db, String id) async {
    await _loadRecords();
    if ((_ledger?.pending?['data'] as Map?)?['id'] != id) return;
    final z = await (db.select(db.zReadings)..where((r) => r.id.equals(id)))
        .getSingleOrNull();
    if (z != null) throw StateError('Cannot abandon a committed Z-reading');
    await _append('abort_z', {'id': id});
  }

  Future<void> reconcile(AppDatabase db, {String? actorId}) async {
    await _fail(ComplianceStep.duringReconcile);
    final loaded = await _loadRecords();
    if (loaded == null) {
      final state = await db.select(db.birComplianceState).getSingleOrNull();
      if (state == null && !await file.exists()) return;
      await _initialize(db);
    }
    final pending = _ledger!.pending;
    if (pending != null) {
      final data = pending['data'] as Map<String, dynamic>;
      if (pending['kind'] == 'reserve_sale') {
        final sale = await (db.select(db.sales)
              ..where((s) => s.id.equals(data['id'] as String)))
            .getSingleOrNull();
        if (sale == null) {
          throw StateError(
              'Unresolved invoice reservation ${data['number']}; keep original DB or seek supervised recovery');
        }
        if (sale.birInvoiceNumber != data['number'] ||
            sale.totalCents != data['amount']) {
          throw StateError('Committed sale differs from protected reservation');
        }
        await _append('commit_sale', {'id': sale.id});
      } else {
        final z = await (db.select(db.zReadings)
              ..where((r) => r.id.equals(data['id'] as String)))
            .getSingleOrNull();
        if (z == null) {
          throw StateError(
              'Unresolved Z-reading reservation; keep original DB or seek supervised recovery');
        }
        if (jsonEncode(zData(z)) != jsonEncode(data)) {
          throw StateError(
              'Committed Z-reading differs from protected reservation');
        }
        await _append('commit_z', {'id': z.id});
      }
    }
    final ledger = _ledger!;
    await db.transaction(() async {
      var state = await (db.select(db.birComplianceState)
            ..where((s) => s.id.equals(1)))
          .getSingleOrNull();
      if (state == null &&
          (ledger.invoice > 0 || ledger.z > 0 || ledger.total > 0)) {
        await db.into(db.birComplianceState).insert(
            BirComplianceStateCompanion.insert(
                id: const Value(1),
                activatedAt: DateTime.parse(ledger.activatedAt!)));
        state = await (db.select(db.birComplianceState)
              ..where((s) => s.id.equals(1)))
            .getSingle();
      }
      if (state != null) {
        if (state.highestInvoiceNumber > ledger.invoice ||
            state.grandTotalCents > ledger.total ||
            state.highestZNumber > ledger.z) {
          throw StateError(
              'Database compliance state exceeds protected journal');
        }
        if (state.highestInvoiceNumber < ledger.invoice ||
            state.grandTotalCents < ledger.total ||
            state.highestZNumber < ledger.z) {
          await (db.update(db.birComplianceState)..where((s) => s.id.equals(1)))
              .write(BirComplianceStateCompanion(
                  highestInvoiceNumber: Value(ledger.invoice),
                  grandTotalCents: Value(ledger.total),
                  highestZNumber: Value(ledger.z)));
          await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
              userId: Value(actorId),
              action: 'bir.restore_reconcile',
              details: Value(
                  'invoice=${ledger.invoice};grandTotal=${ledger.total};z=${ledger.z}')));
        }
      }
      for (final data in ledger.zReadings.values) {
        final number = data['number'] as int;
        final existing = await (db.select(db.zReadings)
              ..where((r) => r.number.equals(number)))
            .getSingleOrNull();
        if (existing != null) {
          if (jsonEncode(zData(existing)) != jsonEncode(data)) {
            throw StateError(
                'Restored Z-reading conflicts with protected journal');
          }
          continue;
        }
        await db.into(db.zReadings).insert(ZReadingsCompanion.insert(
            id: Value(data['id'] as String),
            number: number,
            cashSessionId: data['cashSessionId'] as String,
            generatedAt: Value(DateTime.parse(data['generatedAt'] as String)),
            generatedByUserId: data['generatedByUserId'] as String,
            beginningInvoiceNumber:
                Value(data['beginningInvoiceNumber'] as int?),
            endingInvoiceNumber: Value(data['endingInvoiceNumber'] as int?),
            periodSalesCents: data['periodSalesCents'] as int,
            reversalCents: data['reversalCents'] as int,
            grandTotalCents: data['grandTotalCents'] as int,
            expectedCashCents: data['expectedCashCents'] as int,
            actualCashCents: data['actualCashCents'] as int));
        final session = await (db.select(db.cashSessions)
              ..where((s) => s.id.equals(data['cashSessionId'] as String)))
            .getSingleOrNull();
        if (session != null && session.closedAt == null) {
          await (db.update(db.cashSessions)
                ..where((s) => s.id.equals(session.id)))
              .write(CashSessionsCompanion(
                  closedAt:
                      Value(DateTime.parse(data['generatedAt'] as String)),
                  expectedCashCents: Value(data['expectedCashCents'] as int),
                  actualCashCents: Value(data['actualCashCents'] as int)));
        }
      }
    });
  }

  static Map<String, dynamic> zData(ZReading z) => {
        'id': z.id,
        'number': z.number,
        'cashSessionId': z.cashSessionId,
        'generatedAt': z.generatedAt.toUtc().toIso8601String(),
        'generatedByUserId': z.generatedByUserId,
        'beginningInvoiceNumber': z.beginningInvoiceNumber,
        'endingInvoiceNumber': z.endingInvoiceNumber,
        'periodSalesCents': z.periodSalesCents,
        'reversalCents': z.reversalCents,
        'grandTotalCents': z.grandTotalCents,
        'expectedCashCents': z.expectedCashCents,
        'actualCashCents': z.actualCashCents,
      };
}

class _Ledger {
  final List<Map<String, dynamic>> records;
  int invoice = 0;
  int total = 0;
  int z = 0;
  String? activatedAt;
  Map<String, dynamic>? pending;
  final Map<int, Map<String, dynamic>> zReadings = {};
  _Ledger(this.records);

  static _Ledger replay(List<Map<String, dynamic>> records) {
    if (records.isEmpty || records.first['kind'] != 'genesis') {
      throw StateError('Compliance journal has no genesis');
    }
    final ledger = _Ledger(records);
    for (final record in records) {
      final kind = record['kind'];
      final data = record['data'] as Map<String, dynamic>;
      switch (kind) {
        case 'genesis':
          if (record != records.first) throw StateError('Repeated genesis');
          ledger.invoice = data['invoice'] as int;
          ledger.total = data['total'] as int;
          ledger.z = data['z'] as int;
          ledger.activatedAt = data['activatedAt'] as String?;
          for (final raw in data['zReadings'] as List) {
            final snapshot = Map<String, dynamic>.from(raw as Map);
            ledger.zReadings[snapshot['number'] as int] = snapshot;
          }
          break;
        case 'reserve_sale':
          if (ledger.pending != null ||
              data['number'] != ledger.invoice + 1 ||
              (data['amount'] as int) <= 0) {
            throw StateError('Invalid invoice reservation order');
          }
          ledger.pending = record;
          break;
        case 'commit_sale':
        case 'abort_sale':
          final held = ledger.pending;
          if (held?['kind'] != 'reserve_sale' ||
              (held!['data'] as Map)['id'] != data['id']) {
            throw StateError('Unmatched invoice resolution');
          }
          if (kind == 'commit_sale') {
            final reservation = held['data'] as Map<String, dynamic>;
            ledger.invoice = reservation['number'] as int;
            ledger.total += reservation['amount'] as int;
            ledger.activatedAt ??= reservation['activatedAt'] as String;
          }
          ledger.pending = null;
          break;
        case 'reserve_z':
          if (ledger.pending != null ||
              data['number'] != ledger.z + 1 ||
              data['grandTotalCents'] != ledger.total) {
            throw StateError('Invalid Z-reading reservation order');
          }
          ledger.pending = record;
          break;
        case 'commit_z':
        case 'abort_z':
          final held = ledger.pending;
          if (held?['kind'] != 'reserve_z' ||
              (held!['data'] as Map)['id'] != data['id']) {
            throw StateError('Unmatched Z-reading resolution');
          }
          if (kind == 'commit_z') {
            final snapshot = held['data'] as Map<String, dynamic>;
            ledger.z = snapshot['number'] as int;
            ledger.zReadings[ledger.z] = snapshot;
            ledger.activatedAt ??= snapshot['generatedAt'] as String;
          }
          ledger.pending = null;
          break;
        default:
          throw StateError('Unknown compliance journal event');
      }
    }
    if (ledger.invoice < 0 ||
        ledger.total < 0 ||
        ledger.z < 0 ||
        ledger.zReadings.length > ledger.z) {
      throw StateError('Invalid compliance journal totals');
    }
    return ledger;
  }
}
