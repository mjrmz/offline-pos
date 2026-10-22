import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/active_user.dart';
import '../database.dart';

class RoleRecord {
  final String code, name, description;
  final bool isSystem;
  final Set<PosPermission> permissions;
  final int assignedUsers;
  const RoleRecord(this.code, this.name, this.description, this.isSystem,
      this.permissions, this.assignedUsers);
}

class RoleRepository {
  final AppDatabase db;
  RoleRepository(this.db);

  Future<List<RoleRecord>> all() async {
    final rows = await db
        .customSelect('SELECT code, name, description, is_system, '
            "(SELECT COUNT(*) FROM users WHERE users.role = roles.code "
            "AND users.id != 'phase2-local-cashier') AS assigned "
            'FROM roles ORDER BY is_system DESC, name COLLATE NOCASE')
        .get();
    final result = <RoleRecord>[];
    for (final row in rows) {
      final code = row.read<String>('code');
      result.add(RoleRecord(
          code,
          row.read<String>('name'),
          row.read<String>('description'),
          row.read<int>('is_system') == 1,
          await permissions(code),
          row.read<int>('assigned')));
    }
    return result;
  }

  Future<RoleRecord> requireRole(String code) async {
    final roles = await all();
    for (final role in roles) {
      if (role.code == code) return role;
    }
    throw StateError('Role no longer exists');
  }

  Future<Set<PosPermission>> permissions(String code) async {
    final rows = await db.customSelect(
        'SELECT permission_key FROM role_permissions WHERE role_code = ?',
        variables: [Variable.withString(code)]).get();
    return rows
        .map((r) =>
            PermissionRegistry.byKey[r.read<String>('permission_key')]?.key)
        .whereType<PosPermission>()
        .toSet();
  }

  void _validateName(String name) {
    if (name.trim().isEmpty) throw StateError('Role name is required');
    if (name.trim().length > 60) throw StateError('Role name is too long');
  }

  Future<void> _requireOwner(String actorId) async {
    final rows = await db.customSelect(
        'SELECT role, is_active FROM users WHERE id = ?',
        variables: [Variable.withString(actorId)]).get();
    if (rows.length != 1 ||
        rows.first.read<String>('role') != 'owner' ||
        rows.first.read<int>('is_active') != 1) {
      throw StateError('Owner access required');
    }
  }

  Future<void> _uniqueName(String name, {String? except}) async {
    final rows = await db.customSelect(
        'SELECT code FROM roles WHERE lower(trim(name)) = lower(?)',
        variables: [Variable.withString(name.trim())]).get();
    if (rows.any((r) => r.read<String>('code') != except)) {
      throw StateError('A role with this name already exists');
    }
  }

  Future<String> create(String actorId, String name, String description,
      Set<PosPermission> permissions,
      {String? duplicatedFrom}) async {
    _validateName(name);
    _validatePermissions(permissions);
    final code = const Uuid().v4();
    await db.transaction(() async {
      await _requireOwner(actorId);
      await _uniqueName(name);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await db.customStatement(
          'INSERT INTO roles '
          '(code, name, description, is_system, created_at, updated_at) '
          'VALUES (?, ?, ?, 0, ?, ?)',
          [code, name.trim(), description.trim(), now, now]);
      for (final key in PermissionRegistry.normalize(permissions)) {
        await db.customStatement(
            'INSERT INTO role_permissions '
            '(role_code, permission_key) VALUES (?, ?)',
            [code, key.name]);
      }
      await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
          userId: Value(actorId),
          action: duplicatedFrom == null ? 'role_created' : 'role_duplicated',
          details: Value('$code:${name.trim()}:$duplicatedFrom')));
    });
    return code;
  }

  Future<void> update(String actorId, String code, String name,
      String description, Set<PosPermission> permissions) async {
    _validateName(name);
    _validatePermissions(permissions);
    await db.transaction(() async {
      await _requireOwner(actorId);
      final role = await requireRole(code);
      if (role.isSystem) throw StateError('System roles cannot be edited');
      await _uniqueName(name, except: code);
      final next = PermissionRegistry.normalize(permissions);
      await db.customStatement(
          'UPDATE roles SET name = ?, description = ?, '
          'updated_at = ? WHERE code = ?',
          [
            name.trim(),
            description.trim(),
            DateTime.now().millisecondsSinceEpoch ~/ 1000,
            code
          ]);
      await db.customStatement(
          'DELETE FROM role_permissions WHERE role_code = ?', [code]);
      for (final key in next) {
        await db.customStatement(
            'INSERT INTO role_permissions '
            '(role_code, permission_key) VALUES (?, ?)',
            [code, key.name]);
      }
      final added =
          next.difference(role.permissions).map((p) => p.name).join(',');
      final removed =
          role.permissions.difference(next).map((p) => p.name).join(',');
      await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
          userId: Value(actorId),
          action: 'role_updated',
          details: Value(
              '$code:${role.name}->${name.trim()};added=$added;removed=$removed')));
    });
  }

  void _validatePermissions(Set<PosPermission> permissions) {
    if (permissions
        .any((p) => PermissionRegistry.byKey[p.name]?.ownerOnly == true)) {
      throw StateError('Owner-only permissions cannot be assigned');
    }
  }

  Future<void> delete(String actorId, String code) async {
    await db.transaction(() async {
      await _requireOwner(actorId);
      final role = await requireRole(code);
      if (role.isSystem) throw StateError('System roles cannot be deleted');
      if (role.assignedUsers > 0) {
        throw StateError(
            'Reassign ${role.assignedUsers} users before deleting this role');
      }
      await db.customStatement('DELETE FROM roles WHERE code = ?', [code]);
      await db.into(db.auditLogs).insert(AuditLogsCompanion.insert(
          userId: Value(actorId),
          action: 'role_deleted',
          details: Value('$code:${role.name}')));
    });
  }
}
