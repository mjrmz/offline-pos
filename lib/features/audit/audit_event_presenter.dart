import 'dart:convert';

import '../../core/models/active_user.dart';
import '../../data/daos/audit_explorer_repository.dart';

class AuditField {
  const AuditField(this.label, this.value);
  final String label, value;
}

class AuditEventItem {
  const AuditEventItem(
      {required this.row,
      required this.module,
      required this.action,
      required this.reference,
      required this.fields,
      this.sourceId,
      this.source});
  final AuditExplorerRow row;
  final String module, action, reference;
  final List<AuditField> fields;
  final String? sourceId, source;
}

class AuditEventPresenter {
  static const _modules = <String, String>{
    'sale': 'POS',
    'product': 'Products',
    'kit': 'Products',
    'stock_receiving': 'Receiving',
    'purchase_order': 'Purchase Orders',
    'purchase_return': 'Purchase Returns',
    'stock_count': 'Stock Count',
    'cycle_count': 'Stock Count',
    'inventory_adjustment': 'Inventory',
    'customer_credit': 'Customer Credit',
    'supplier_payment': 'Supplier Payables',
    'sales_order': 'Sales Orders',
    'made_order': 'Delivery',
    'rma': 'RMA',
    'cash_session': 'Cash Session',
    'shift_handover': 'Shift Handover',
    'promotion': 'Promotions',
    'import': 'Imports',
    'opening_inventory': 'Imports',
    'customer': 'Customers',
    'supplier': 'Suppliers',
    'user': 'Users',
    'role': 'Users',
    'login': 'Users',
    'logout': 'Users',
    'credential': 'Users',
    'password': 'Users',
    'business_feature': 'Settings',
    'bir': 'Settings',
  };

  static String module(String action) {
    final parts = action.split(RegExp(r'[._]'));
    for (var length = parts.length; length > 0; length--) {
      final key = parts.take(length).join('_');
      if (_modules.containsKey(key)) return _modules[key]!;
    }
    return 'Other';
  }

  static String actionLabel(String raw) {
    const known = <String, String>{
      'sale.completed': 'Completed sale',
      'sale.voided': 'Voided sale',
      'sale.refunded': 'Refunded sale',
      'supplier_payment.recorded': 'Recorded supplier payment',
      'customer_credit.payment': 'Recorded customer payment',
      'shift_handover.manager_acknowledged': 'Acknowledged cash handover',
      'stock_receiving.finalized': 'Finalized receiving',
      'product.price_changed': 'Changed product price',
      'login_success': 'Signed in',
      'login_failed': 'Failed sign-in',
      'logout': 'Signed out',
    };
    if (known.containsKey(raw)) return known[raw]!;
    final parts =
        raw.split(RegExp(r'[._]')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return 'Activity recorded';
    final verb = parts.last;
    final subject = parts.take(parts.length - 1).join(' ');
    const verbs = <String, String>{
      'created': 'Created',
      'create': 'Created',
      'updated': 'Updated',
      'edited': 'Updated',
      'finalized': 'Finalized',
      'cancelled': 'Cancelled',
      'completed': 'Completed',
      'started': 'Started',
      'opened': 'Opened',
      'closed': 'Closed',
      'activated': 'Activated',
      'deactivated': 'Deactivated',
      'recorded': 'Recorded',
      'acknowledged': 'Acknowledged',
      'sent': 'Sent',
      'received': 'Received',
      'posted': 'Posted',
      'refunded': 'Refunded',
      'voided': 'Voided',
      'assigned': 'Assigned',
      'removed': 'Removed',
      'added': 'Added',
      'changed': 'Changed',
      'imported': 'Imported',
      'restored': 'Restored',
    };
    if (verbs.containsKey(verb)) return '${verbs[verb]} $subject'.trim();
    return parts
        .join(' ')
        .replaceFirstMapped(RegExp(r'^.'), (m) => m[0]!.toUpperCase());
  }

  static AuditEventItem present(AuditExplorerRow row, ActiveUser viewer) {
    final raw = row.log.details?.trim() ?? '';
    final action = row.log.action;
    final category = module(action);
    final canFinancial = switch (category) {
      'Products' || 'Inventory' => viewer.can(PosPermission.manageCatalog),
      'Supplier Payables' => viewer.can(PosPermission.stockReceiving),
      'Customer Credit' => viewer.can(PosPermission.customerCredit),
      'Cash Session' ||
      'Shift Handover' =>
        viewer.can(PosPermission.manageCashSession),
      _ => true,
    };
    final canDetails = switch (category) {
      'Customers' || 'Suppliers' => viewer.can(PosPermission.viewContacts),
      'RMA' => viewer.can(PosPermission.manageRma),
      'Sales Orders' || 'Delivery' => viewer.can(PosPermission.viewSalesOrders),
      'POS' => viewer.can(PosPermission.viewAllSales),
      _ => true,
    };
    final fields = <AuditField>[];
    String? sourceId;
    String? reference;
    Map<String, dynamic>? data;
    if (raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) data = decoded;
      } catch (_) {}
    }
    if (data != null) {
      for (final entry in data.entries) {
        final key = entry.key;
        if (_sensitive(key) || !canDetails || !canFinancial && _financial(key)) {
          continue;
        }
        if (key.toLowerCase().endsWith('id')) {
          if (key == 'promotionId') sourceId = entry.value?.toString();
          continue;
        }
        if (key == 'reference' &&
            entry.value != null &&
            (canDetails || _humanReference(entry.value.toString()))) {
          reference = entry.value.toString();
        }
        if (entry.value is String ||
            entry.value is num ||
            entry.value is bool) {
          if (_safeField(key)) {
            final value = key == 'file'
                ? entry.value.toString().split(RegExp(r'[/\\]')).last
                : entry.value.toString();
            fields.add(AuditField(_label(key), value));
          }
        }
      }
    } else if (raw.isNotEmpty) {
      final first = raw.split(':').first.trim();
      if (_humanReference(first)) reference = first;
      if (_uuid(first)) sourceId = first;
      sourceId ??= RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}')
          .firstMatch(raw)
          ?.group(0);
      if (action == 'product.price_changed') sourceId = first;
      if (action == 'sale.completed' ||
          action.startsWith('rma.') ||
          action.startsWith('purchase_order.') ||
          action.startsWith('sales_order.') ||
          action.startsWith('stock_receiving.') ||
          action.startsWith('cash_session.')) {
        sourceId ??= _uuid(first) ? first : null;
      }
      if (action == 'product.price_changed' && canFinancial) {
        final diff = RegExp(r'(\d+)\s*[→-]>?\s*(\d+) cents').firstMatch(raw);
        if (diff != null) {
          fields.add(AuditField('Selling price',
              '${_money(int.parse(diff[1]!))} → ${_money(int.parse(diff[2]!))}'));
        }
      }
      if (action.startsWith('product.barcode_alias.') &&
          viewer.can(PosPermission.manageCatalog)) {
        final alias = RegExp(r'^Product [^ ]+ barcode (.+)$').firstMatch(raw);
        if (alias != null) fields.add(AuditField('Barcode alias', alias[1]!));
      }
      if (action.startsWith('role_') && raw.contains(':')) {
        final parts = raw.split(':');
        if (parts.length > 1 && parts[1].trim().isNotEmpty) {
          fields.add(AuditField('Role', parts[1].trim()));
        }
      }
    }
    final source = switch (category) {
      'POS' => 'sale',
      'Products' => 'product',
      'Receiving' => 'receiving',
      'Purchase Orders' => 'purchase_order',
      'Purchase Returns' => 'purchase_return',
      'Stock Count' => 'stock_count',
      'Sales Orders' => 'sales_order',
      'RMA' => 'rma',
      'Cash Session' || 'Shift Handover' => 'cash_session',
      _ => null,
    };
    return AuditEventItem(
        row: row,
        module: category,
        action: actionLabel(action),
        reference: reference ??
            row.resolvedReference ??
            (canFinancial && _humanReference(raw) ? raw : 'Not recorded'),
        fields: fields,
        sourceId: sourceId ?? row.resolvedSourceId,
        source: source);
  }

  static bool _uuid(String value) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(value);
  static bool _humanReference(String value) =>
      RegExp(r'^[A-Za-z]{2,8}-\d{2,}(?:[: ].*)?$').hasMatch(value);
  static bool _sensitive(String key) => RegExp(
          r'password|pin|recovery|token|secret|private|signature|credential|hash|license|payload',
          caseSensitive: false)
      .hasMatch(key);
  static bool _financial(String key) => RegExp(
          r'amount|cost|cogs|margin|price|balance|variance|payment|receivable|payable|credit|total',
          caseSensitive: false)
      .hasMatch(key);
  static bool _safeField(String key) => const {
        'reference',
        'name',
        'status',
        'reason',
        'method',
        'quantity',
        'count',
        'result',
        'file',
        'created',
        'updated',
        'skipped',
        'rows',
        'products',
        'layers',
        'serials'
      }.contains(key);
  static String _label(String key) => key
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ');
  static String _money(int cents) => '₱${(cents / 100).toStringAsFixed(2)}';
}
