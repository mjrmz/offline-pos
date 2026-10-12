enum UserRole { cashier, manager, owner }

enum PosPermission {
  sell,
  viewOwnSales,
  viewAllSales,
  reverseSale,
  reports,
  manageUsers,
  manageCatalog,
  manageRecovery,
  manageCashSession,
  manageContacts,
  customerCredit,
  stockReceiving,
  manageRma,
  manageQuotations,
  manageLayaway
}

class ActiveUser {
  final String id;
  final String name;
  final UserRole role;
  final bool isActive;
  const ActiveUser(this.id, this.name, this.role, [this.isActive = true]);

  bool can(PosPermission permission) => switch (permission) {
        PosPermission.sell ||
        PosPermission.manageQuotations ||
        PosPermission.manageLayaway ||
        PosPermission.viewOwnSales ||
        PosPermission.manageCashSession =>
          true,
        PosPermission.viewAllSales ||
        PosPermission.reverseSale ||
        PosPermission.reports ||
        PosPermission.manageCatalog =>
          role != UserRole.cashier,
        PosPermission.manageContacts => role != UserRole.cashier,
        PosPermission.customerCredit => true,
        PosPermission.stockReceiving ||
        PosPermission.manageRma =>
          role != UserRole.cashier,
        PosPermission.manageUsers ||
        PosPermission.manageRecovery =>
          role == UserRole.owner,
      };
  void require(PosPermission permission) {
    if (!can(permission)) throw StateError('Not authorized for this action');
  }
}
