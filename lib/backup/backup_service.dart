import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:bcrypt/bcrypt.dart';
import '../data/database.dart';
import '../core/models/app_config.dart';

enum BackupKind { manual, daily, weekly }

class BackupRecord {
  final File file;
  final BackupKind kind;
  final DateTime createdAt;
  final int schemaVersion;
  final String appVersion;
  final int bytes;
  final String integrity;
  const BackupRecord(this.file, this.kind, this.createdAt, this.schemaVersion,
      this.appVersion, this.bytes, this.integrity);
  Map<String, Object> toJson() => {
        'file': p.basename(file.path),
        'kind': kind.name,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'bytes': bytes,
        'integrity': integrity,
      };
}

class BackupService {
  static const dailyRetention = 7;
  static const weeklyRetention = 4;
  static const manualRetention = 5;
  final AppDatabase db;
  final Directory directory;
  final DateTime Function() now;
  BackupService(this.db, this.directory, {DateTime Function()? clock})
      : now = clock ?? DateTime.now;

  static BackupRecord inspect(File file) {
    final metadata = File('${file.path}.json');
    if (!file.existsSync() || !metadata.existsSync()) {
      throw StateError('Backup or metadata is missing');
    }
    final json =
        jsonDecode(metadata.readAsStringSync()) as Map<String, dynamic>;
    if (json['file'] != p.basename(file.path) || json['integrity'] != 'ok') {
      throw StateError('Backup metadata is invalid');
    }
    final size = file.lengthSync();
    if (size != json['bytes']) {
      throw StateError('Backup size differs from metadata');
    }
    final check = verify(file);
    if (check != json['schemaVersion']) {
      throw StateError('Backup schema differs from metadata');
    }
    return BackupRecord(
        file,
        BackupKind.values.byName(json['kind'] as String),
        DateTime.parse(json['createdAt'] as String),
        check,
        json['appVersion'] as String,
        size,
        'ok');
  }

  static int verify(File file, {int maxSchemaVersion = 7}) {
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw StateError('Backup is missing or empty');
    }
    sqlite.Database? connection;
    try {
      connection =
          sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
      final result = connection.select('PRAGMA integrity_check');
      if (result.length != 1 || result.first.values.first != 'ok') {
        throw StateError('SQLite integrity check failed');
      }
      if (connection.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw StateError('Backup contains broken foreign keys');
      }
      final version =
          connection.select('PRAGMA user_version').first.values.first as int;
      if (version < 1 || version > maxSchemaVersion) {
        throw StateError('Incompatible backup schema');
      }
      final requiredTables = <String>{
        'products',
        'inventory_movements',
        'sales',
        'sale_items',
        'payments',
        'users',
        'cash_sessions',
        'audit_logs',
        if (version >= 2) ...['categories', 'inventory'],
        if (version >= 3) 'sale_reversals',
        if (version >= 6) 'settings',
        if (version >= 7) 'cash_movements',
      };
      for (final name in requiredTables) {
        final rows = connection.select(
            'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
            ['table', name]);
        if (rows.isEmpty) {
          throw StateError('Backup lacks required table: $name');
        }
      }
      final columns = <String, List<String>>{
        'products': [
          'id',
          'sku',
          'barcode',
          'name',
          'price_cents',
          'cost_cents',
          'is_active',
          'created_at',
          if (version >= 2) 'category_id',
          if (version >= 3) 'low_stock_threshold',
        ],
        'inventory_movements': [
          'id',
          'product_id',
          'quantity_delta',
          'reason',
          'reference_id',
          'created_at',
        ],
        'sales': ['id', 'cashier_id', 'total_cents', 'status', 'created_at'],
        'sale_items': [
          'id',
          'sale_id',
          'product_id',
          'quantity',
          'unit_price_cents',
          if (version >= 2) 'line_total_cents',
          if (version >= 5) 'product_name',
        ],
        'payments': ['id', 'sale_id', 'method', 'amount_cents'],
        'users': [
          'id',
          'name',
          'pin_hash',
          'password_hash',
          'role',
          'is_active',
          if (version >= 3) ...[
            'failed_attempts',
            'locked_until',
            'recovery_question',
            'recovery_answer_hash',
          ],
        ],
        'cash_sessions': [
          'id',
          'opened_by_user_id',
          'starting_cash_cents',
          'expected_cash_cents',
          'actual_cash_cents',
          'opened_at',
          'closed_at',
        ],
        'audit_logs': ['id', 'user_id', 'action', 'details', 'created_at'],
        if (version >= 2) 'categories': ['id', 'name', 'parent_category_id'],
        if (version >= 2) 'inventory': ['product_id', 'quantity'],
        if (version >= 3)
          'sale_reversals': [
            'id',
            'sale_id',
            'actor_id',
            'kind',
            'amount_cents',
            'created_at',
            if (version >= 4) 'stock_restored',
          ],
        if (version >= 6)
          'settings': [
            'id',
            'store_name',
            'printer_enabled',
            'printer_transport',
            'printer_host',
            'printer_port',
            'printer_device_id',
            'printer_device_name',
            'printer_width_mm',
            'drawer_enabled',
          ],
        if (version >= 7)
          'cash_movements': [
            'id',
            'session_id',
            'sale_id',
            'amount_cents',
            'kind',
            'created_at',
          ],
      };
      for (final entry in columns.entries) {
        final actual = connection
            .select('PRAGMA table_info(${entry.key})')
            .map((row) => row['name'] as String)
            .toSet();
        if (!actual.containsAll(entry.value)) {
          throw StateError('Backup has incompatible table: ${entry.key}');
        }
      }
      return version;
    } on sqlite.SqliteException catch (_) {
      throw StateError('SQLite could not read the backup');
    } finally {
      connection?.dispose();
    }
  }

  static String? ownerIdForCredentials(
      File file, String name, String password) {
    verify(file);
    final connection =
        sqlite.sqlite3.open(file.path, mode: sqlite.OpenMode.readOnly);
    try {
      final rows = connection.select(
          'SELECT id, password_hash FROM users WHERE role = ? AND is_active = 1 AND name = ?',
          ['owner', name.trim()]);
      for (final row in rows) {
        final hash = row['password_hash'];
        if (hash is String && BCrypt.checkpw(password, hash)) {
          return row['id'] as String;
        }
      }
      return null;
    } finally {
      connection.dispose();
    }
  }

  Future<BackupRecord> create(BackupKind kind,
      {bool rotateAfter = true}) async {
    final stamp = now().toUtc();
    final token = stamp.microsecondsSinceEpoch;
    final file = File(p.join(directory.path, '${kind.name}-$token.sqlite'));
    final temp = File('${file.path}.pending');
    final metadata = File('${file.path}.json');
    try {
      await directory.create(recursive: true);
      if (temp.existsSync()) await temp.delete();
      await db.customStatement('VACUUM INTO ?', [temp.absolute.path]);
      final version = verify(temp, maxSchemaVersion: db.schemaVersion);
      final bytes = await temp.length();
      await temp.rename(file.path);
      final record = BackupRecord(
          file, kind, stamp, version, AppConfig.appVersion, bytes, 'ok');
      await metadata.writeAsString(jsonEncode(record.toJson()), flush: true);
      if (rotateAfter) await rotate();
      return record;
    } catch (error) {
      if (temp.existsSync()) await temp.delete();
      if (file.existsSync()) await file.delete();
      if (metadata.existsSync()) await metadata.delete();
      throw StateError('Backup failed: $error');
    }
  }

  Future<List<BackupRecord>> listValid() async {
    if (!directory.existsSync()) return [];
    final result = <BackupRecord>[];
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.sqlite')) continue;
      try {
        result.add(inspect(entity));
      } catch (_) {/* invalid files are not restorable */}
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<void> rotate() async {
    final records = await listValid();
    for (final kind in BackupKind.values) {
      final limit = switch (kind) {
        BackupKind.daily => dailyRetention,
        BackupKind.weekly => weeklyRetention,
        BackupKind.manual => manualRetention,
      };
      for (final old in records.where((r) => r.kind == kind).skip(limit)) {
        await old.file.delete();
        await File('${old.file.path}.json').delete();
      }
    }
  }

  Future<void> createDue() async {
    final records = await listValid();
    final current = now().toUtc();
    if (!records.any((r) =>
        r.kind == BackupKind.daily &&
        current.difference(r.createdAt) < const Duration(days: 1))) {
      await create(BackupKind.daily);
    }
    if (!records.any((r) =>
        r.kind == BackupKind.weekly &&
        current.difference(r.createdAt) < const Duration(days: 7))) {
      await create(BackupKind.weekly);
    }
  }
}
