# Local roles and permissions

Each user has one role code in `users.role`. `roles.code` is stable; the three
system codes are `owner`, `manager`, and `cashier`. Custom codes are UUIDs.
`role_permissions` stores one row per granted capability. The database v40
migration creates these tables and seeds the built-in roles without changing
existing user, credential, sale, stock, or audit rows.

The central registry is `PermissionRegistry` in
`lib/core/models/active_user.dart`. It contains names, descriptions, groups,
sensitivity, dependencies, and the built-in baselines. Unknown stored keys are
ignored at runtime. Version 40 backup validation rejects unknown keys with an
incompatible-version message. Permission dependencies are added when a child
is selected and dependents are removed when a parent is cleared.

`AuthRepository.requireActive` reloads a custom user's permissions from the
database. Critical repositories use this live identity before writes. A role
edit therefore affects future repository calls and the next sign-in without an
app restart. The Users screen edits roles through `AuthService`, and the role
repository independently requires an active Owner. Role actions and permission
diffs are recorded in `audit_logs`.

Protected Owner identity operations are Owner recovery, backup and restore,
role administration, last active Owner protection, serial mismatch override,
and opening cash funds. These stay outside custom role grants. Manager and
Cashier definitions remain read-only; duplicate a role to customize it.

There is no disabled-role state in this version. A custom role can be deleted
only when no users are assigned to it. Role changes use a new credential so
the sign-in method is explicit. A user with no granted feature sees a no-access
screen after sign-in.
