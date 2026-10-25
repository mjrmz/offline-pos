import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:bcrypt/bcrypt.dart';
import '../data/database.dart';
import '../core/models/app_config.dart';
import '../core/models/active_user.dart';

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

  static int verify(File file, {int maxSchemaVersion = 51}) {
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
        if (version >= 40) ...['roles', 'role_permissions'],
        if (version >= 41) ...[
          'promotions',
          'promotion_product_targets',
          'promotion_category_targets'
        ],
        if (version >= 42) 'sale_promotion_applications',
        if (version >= 51) 'cycle_count_schedules',
        if (version >= 37) 'inventory_health_settings',
        if (version >= 22) 'rma_lifecycle_events',
        if (version >= 23) 'serial_warranty_snapshots',
        if (version >= 2) ...['categories', 'inventory'],
        if (version >= 3) 'sale_reversals',
        if (version >= 6) 'settings',
        if (version >= 7) 'cash_movements',
        if (version >= 8) ...['bir_compliance_state', 'z_readings'],
        if (version >= 9) ...[
          'business_feature_settings',
          'product_business_configurations'
        ],
        if (version >= 10) ...[
          'product_lots',
          'made_orders',
          'tank_empty_movements'
        ],
        if (version >= 11) ...[
          'customers',
          'suppliers',
          'petty_cash_entries',
          'price_history'
        ],
        if (version >= 13) 'customer_credit_entries',
        if (version >= 14) ...['stock_receivings', 'stock_receiving_items'],
        if (version >= 31) ...['purchase_orders', 'purchase_order_lines'],
        if (version >= 39) 'purchase_order_line_source_links',
        if (version >= 32) ...[
          'stock_counts',
          'stock_count_lines',
          'inventory_adjustments',
          'inventory_adjustment_allocations'
        ],
        if (version >= 33) ...[
          'sale_returns',
          'sale_return_lines',
          'sale_return_allocations'
        ],
        if (version >= 34) ...[
          'loyalty_settings',
          'loyalty_ledger',
          'sale_loyalty',
          'customer_groups'
        ],
        if (version >= 35) ...['held_sales', 'sale_manual_discounts'],
        if (version >= 19) ...['sale_item_refunds', 'inbound_rma_replacements'],
        if (version >= 20) ...[
          'inventory_layers',
          'sale_item_inventory_allocations'
        ],
        if (version >= 26) 'quotation_document_settings',
        if (version >= 28) 'quotation_sourcing_requirements',
        if (version >= 30) ...[
          'cash_expense_categories',
          'business_cash_movements'
        ],
        if (version >= 50) 'sales_order_physical_events',
      };
      for (final name in requiredTables) {
        final rows = connection.select(
            'SELECT name FROM sqlite_master WHERE type = ? AND name = ?',
            ['table', name]);
        if (rows.isEmpty) {
          throw StateError('Backup lacks required table: $name');
        }
      }
      if (version >= 40) {
        final hasUsers =
            connection.select('SELECT 1 FROM users LIMIT 1').isNotEmpty;
        final owner = connection.select(
            "SELECT 1 FROM users WHERE role = 'owner' AND is_active = 1 LIMIT 1");
        if (hasUsers && owner.isEmpty) {
          throw StateError('Backup has no active Owner');
        }
        final orphan =
            connection.select('SELECT 1 FROM users u LEFT JOIN roles r '
                'ON r.code = u.role WHERE r.code IS NULL LIMIT 1');
        if (orphan.isNotEmpty) {
          throw StateError('Backup has an unknown user role');
        }
        final unknown = connection.select(
            'SELECT permission_key FROM '
            'role_permissions WHERE permission_key NOT IN (${PermissionRegistry.byKey.keys.map((_) => '?').join(',')}) '
            'LIMIT 1',
            PermissionRegistry.byKey.keys.toList());
        if (unknown.isNotEmpty) {
          throw StateError('Backup uses a newer permission version');
        }
      }
      final columns = <String, List<String>>{
        if (version >= 37)
          'inventory_health_settings': [
            'id',
            'slow_moving_days',
            'dead_stock_days',
            'near_expiry_days'
          ],
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
          if (version >= 17) 'serial_tracking',
          if (version >= 20) 'pricing_policy',
          if (version >= 36) ...[
            'reorder_level_qty_milli',
            'target_stock_qty_milli',
            'preferred_supplier_id'
          ],
        ],
        'inventory_movements': [
          'id',
          'product_id',
          'quantity_delta',
          if (version >= 10) 'quantity_delta_milli',
          'reason',
          'reference_id',
          'created_at',
        ],
        'sales': [
          'id',
          'cashier_id',
          'total_cents',
          'status',
          'created_at',
          if (version >= 8) 'bir_invoice_number',
          if (version >= 12) 'cash_session_id',
          if (version >= 13) 'customer_id',
          if (version >= 24) 'receipt_number',
          if (version >= 35) ...[
            'walk_in_name',
            'walk_in_contact',
            'held_reference'
          ],
          if (version >= 42) 'discount_source',
        ],
        'sale_items': [
          'id',
          'sale_id',
          'product_id',
          'quantity',
          if (version >= 10) ...[
            'quantity_milli',
            'sale_unit',
            'sale_mode',
            'batch_id',
            'batch_number',
            'extra_cents'
          ],
          'unit_price_cents',
          if (version >= 2) 'line_total_cents',
          if (version >= 5) 'product_name',
          if (version >= 35) 'manual_discount_cents',
          if (version >= 42) 'promotion_discount_cents',
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
        if (version >= 2)
          'inventory': [
            'product_id',
            'quantity',
            if (version >= 10) 'quantity_milli'
          ],
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
            if (version >= 16) ...[
              'store_address',
              'store_contact',
              'receipt_header',
              'receipt_footer'
            ],
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
            if (version >= 17) 'reference_id',
            'amount_cents',
            'kind',
            'created_at',
          ],
        if (version >= 8)
          'bir_compliance_state': [
            'id',
            'activated_at',
            'highest_invoice_number',
            'grand_total_cents',
            'highest_z_number'
          ],
        if (version >= 8)
          'z_readings': [
            'id',
            'number',
            'cash_session_id',
            'generated_at',
            'generated_by_user_id',
            'beginning_invoice_number',
            'ending_invoice_number',
            'period_sales_cents',
            'reversal_cents',
            'grand_total_cents',
            'expected_cash_cents',
            'actual_cash_cents'
          ],
        if (version >= 9)
          'business_feature_settings': ['feature_id', 'enabled'],
        if (version >= 9)
          'product_business_configurations': [
            'product_id',
            'feature_id',
            'configuration_json'
          ],
        if (version >= 10)
          'product_lots': [
            'id',
            'product_id',
            'batch_number',
            'expiry_date',
            'quantity_milli',
            'received_at'
          ],
        if (version >= 10)
          'made_orders': [
            'id',
            'sale_item_id',
            'status',
            'created_at',
            'updated_at'
          ],
        if (version >= 10)
          'tank_empty_movements': [
            'id',
            'product_id',
            'quantity_delta',
            'reason',
            'reference_id',
            'created_at'
          ],
        if (version >= 17)
          'customer_refund_obligations': [
            'id',
            'customer_id',
            'sale_id',
            'user_id',
            'amount_cents',
            'layaway_id',
            if (version >= 19) 'rma_case_id',
            'settled_cents',
            'created_at'
          ],
        if (version >= 19)
          'sale_item_refunds': [
            'id',
            'rma_case_id',
            'sale_id',
            'sale_item_id',
            'cash_session_id',
            'quantity_milli',
            'amount_cents',
            'cash_allocation_cents',
            'credit_allocation_cents',
            'receivable_reduction_cents',
            'obligation_cents',
            'immediate_cash_cents',
            'obligation_id',
            'cash_movement_id',
            'created_at'
          ],
        if (version >= 19)
          'inbound_rma_replacements': [
            'id',
            'rma_case_id',
            'receiving_id',
            'receiving_item_id',
            'serial_unit_id',
            'quantity_milli',
            'created_at'
          ],
        if (version >= 17)
          'customer_refund_settlements': [
            'id',
            'obligation_id',
            'user_id',
            'amount_cents',
            'method',
            'note',
            'created_at'
          ],
        if (version >= 17)
          'serial_units': [
            'id',
            'product_id',
            'serial_number',
            'status',
            'receiving_item_id',
            if (version >= 20) 'inventory_layer_id',
            'sale_item_id',
            'created_at'
          ],
        if (version >= 20)
          'stock_receiving_items': [
            'id',
            'receiving_id',
            'product_id',
            'quantity_milli',
            'unit_cost_cents',
            'unit_selling_price_cents'
          ],
        if (version >= 20)
          'inventory_layers': [
            'id',
            'product_id',
            'receiving_item_id',
            'source',
            'quantity_received_milli',
            'quantity_remaining_milli',
            'unit_cost_cents',
            'unit_selling_price_cents',
            'received_at'
          ],
        if (version >= 20)
          'sale_item_inventory_allocations': [
            'id',
            'sale_item_id',
            'inventory_layer_id',
            'serial_unit_id',
            'quantity_milli',
            'unit_cost_snapshot_cents',
            'unit_selling_price_snapshot_cents',
            'created_at'
          ],
        if (version >= 17)
          'serial_sale_links': [
            'id',
            'serial_unit_id',
            'sale_item_id',
            'created_at'
          ],
        if (version >= 17)
          'rma_cases': [
            'id',
            'reference',
            'origin',
            'sale_id',
            'sale_item_id',
            'receiving_id',
            'receiving_item_id',
            'customer_id',
            'supplier_id',
            'serial_unit_id',
            'issue_description',
            'intake_condition',
            'quantity_milli',
            'notes',
            'status',
            'customer_resolution',
            'unit_disposition',
            'created_at'
          ],
        if (version >= 17)
          'rma_events': [
            'id',
            'case_id',
            'actor_id',
            'status',
            'note',
            'created_at'
          ],
        if (version >= 17)
          'quotations': [
            'id',
            'reference',
            'customer_id',
            if (version >= 27) ...[
              'customer_name_snapshot',
              'customer_phone_snapshot'
            ],
            'created_by',
            if (version >= 27) 'prepared_by_snapshot',
            'valid_until',
            'status',
            'notes',
            'converted_sale_id',
            'created_at'
          ],
        if (version >= 17)
          'quotation_items': [
            'id',
            'quotation_id',
            'product_id',
            if (version >= 25) ...[
              'product_name_snapshot',
              'sku_snapshot',
              'barcode_snapshot',
              'sale_mode',
              'extra_cents'
            ],
            if (version >= 29) 'custom_notes',
            'quantity_milli',
            'unit_snapshot',
            'unit_price_cents',
            'line_total_cents'
          ],
        if (version >= 28)
          'quotation_sourcing_requirements': [
            'id',
            'quotation_id',
            'product_id',
            'quantity_required_milli',
            'quantity_available_at_request_milli',
            'quantity_to_source_milli',
            'preferred_supplier_id',
            'notes',
            'status',
            'created_by',
            'created_at',
            'resolved_at'
          ],
        if (version >= 26)
          'quotation_document_settings': [
            'id',
            'show_sku',
            'show_barcode',
            'show_unit',
            'show_prepared_by',
            'show_signature',
            'show_acceptance',
            'footer',
            'terms'
          ],
        if (version >= 17)
          'layaways': [
            'id',
            'reference',
            'customer_id',
            'created_by',
            'total_cents',
            'status',
            'sale_id',
            'created_at',
            'completed_at'
          ],
        if (version >= 17)
          'layaway_items': [
            'id',
            'layaway_id',
            'product_id',
            'quantity_milli',
            'unit_snapshot',
            'unit_price_cents',
            'line_total_cents'
          ],
        if (version >= 17)
          'layaway_serials': [
            'id',
            'layaway_id',
            'serial_unit_id',
            'product_id'
          ],
        if (version >= 17)
          'layaway_payments': [
            'id',
            'layaway_id',
            'user_id',
            'amount_cents',
            'method',
            'created_at'
          ],
        if (version >= 30) 'cash_expense_categories': ['id', 'name', 'active'],
        if (version >= 30)
          'business_cash_movements': [
            'id',
            'type',
            'amount_cents',
            'source',
            'destination',
            'cash_session_id',
            'drawer_movement_id',
            'category_id',
            'category_name',
            'payee',
            'reference',
            'note',
            'personally_paid_by',
            'recorded_by_user_id',
            'reversal_of_id',
            'created_at'
          ],
        if (version >= 31)
          'purchase_orders': [
            'id',
            'sequence',
            'supplier_id',
            'status',
            'order_date',
            'expected_delivery_date',
            'supplier_reference',
            'notes',
            'created_by',
            'created_at',
            'updated_at',
            'sent_at',
            'cancelled_at',
            'cancelled_by',
            'cancel_reason',
            'closed_at',
            if (version >= 39) ...['sent_by', 'closed_by']
          ],
        if (version >= 39)
          'purchase_order_line_source_links': [
            'id',
            'purchase_order_line_id',
            'quotation_id',
            'quotation_line_id',
            'planned_qty_milli',
            'created_at',
            'created_by_user_id'
          ],
        if (version >= 31)
          'purchase_order_lines': [
            'id',
            'purchase_order_id',
            'product_id',
            'ordered_qty_milli',
            'expected_unit_cost_cents',
            'cancelled_qty_milli',
            'notes'
          ],
        if (version >= 31 && version < 38)
          'stock_receivings': ['purchase_order_id'],
        if (version >= 38 && version < 39)
          'stock_receivings': ['purchase_order_id', 'sequence'],
        if (version >= 39)
          'stock_receivings': ['purchase_order_id', 'sequence', 'finalized_at'],
        if (version >= 31) 'stock_receiving_items': ['purchase_order_line_id'],
        if (version >= 32)
          'stock_counts': [
            'id',
            'reference',
            'status',
            'scope',
            'created_by',
            'created_at',
            'finalized_by',
            'finalized_at'
          ],
        if (version >= 51)
          'cycle_count_schedules': [
            'id',
            'title',
            'scope_type',
            'scope_refs',
            'assignee_id',
            'scheduled_date',
            'due_date',
            'status',
            'created_at',
            'created_by',
            'updated_at',
            'stock_count_id'
          ],
        if (version >= 32)
          'stock_count_lines': [
            'id',
            'stock_count_id',
            'product_id',
            'unit_label',
            'expected_milli',
            'movement_count',
            'counted_milli'
          ],
        if (version >= 32)
          'inventory_adjustments': [
            'id',
            'reference',
            'product_id',
            'delta_milli',
            'reason',
            'created_by',
            'created_at',
            'stock_count_line_id'
          ],
        if (version >= 32)
          'inventory_adjustment_allocations': [
            'id',
            'adjustment_id',
            'inventory_layer_id',
            'serial_unit_id',
            'quantity_milli',
            'unit_cost_cents'
          ],
        if (version >= 35)
          'held_sales': [
            'id',
            'reference',
            'label',
            'snapshot_json',
            'held_by',
            'held_at'
          ],
        if (version >= 35)
          'sale_manual_discounts': [
            'id',
            'sale_id',
            'scope',
            'line_key',
            'kind',
            'value',
            'effect_cents',
            'reason',
            'notes',
            'requested_by',
            'authorized_by',
            'authorized_at'
          ],
        if (version >= 42)
          'sale_promotion_applications': [
            'id',
            'sale_id',
            'promotion_id',
            'promotion_reference',
            'promotion_name',
            'promotion_type',
            'stacking_mode',
            'priority',
            'eligible_subtotal_cents',
            'discount_cents',
            'created_at'
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
