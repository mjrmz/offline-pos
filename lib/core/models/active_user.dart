enum UserRole { cashier, manager, owner }

enum PosPermission {
  sell,
  viewOwnSales,
  viewAllSales,
  reverseSale,
  reports,
  manageUsers,
  manageCatalog
}

class ActiveUser {
  final String id;
  final String name;
  final UserRole role;
  final bool isActive;
  const ActiveUser(this.id, this.name, this.role, [this.isActive = true]);

  bool can(PosPermission permission) => switch (permission) {
        PosPermission.sell || PosPermission.viewOwnSales => true,
        PosPermission.viewAllSales ||
        PosPermission.reverseSale ||
        PosPermission.reports ||
        PosPermission.manageCatalog =>
          role != UserRole.cashier,
        PosPermission.manageUsers => role == UserRole.owner,
      };
  void require(PosPermission permission) {
    if (!can(permission)) throw StateError('Not authorized for this action');
  }
}
