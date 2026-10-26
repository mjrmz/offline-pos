enum UserRole { cashier, manager, owner, custom }

enum PosPermission {
  sell,
  holdSale,
  resumeSale,
  viewOwnSales,
  viewAllSales,
  reverseSale,
  reports,
  manageUsers,
  manageCatalog,
  manageRecovery,
  manageCashSession,
  closeAnyCashSession,
  acknowledgeShiftHandover,
  manageContacts,
  viewContacts,
  customerCredit,
  manageLoyalty,
  stockReceiving,
  finalizePurchaseReturn,
  approveDuplicateReceiving,
  cancelPurchaseOrders,
  stockCount,
  finalizeStockCount,
  stockAdjust,
  manageRma,
  manageQuotations,
  viewSalesOrders,
  manageSalesOrders,
  manageStockReservations,
  manageLayaway,
  viewPromotions,
  managePromotions,
  approveDiscount,
  authorizeBelowCost,
  manageSettings,
  manageExpenses,
  manageExpenseFunds,
  manageRoles,
  managePrinter,
  refreshLicense
}

class PermissionInfo {
  final PosPermission key;
  final String name, description, group;
  final bool sensitive;
  final bool ownerOnly;
  final Set<PosPermission> requires;
  const PermissionInfo(this.key, this.name, this.description, this.group,
      {this.sensitive = false,
      this.ownerOnly = false,
      this.requires = const {}});
}

class PermissionRegistry {
  static const entries = <PermissionInfo>[
    PermissionInfo(PosPermission.sell, 'Use POS',
        'Create sales and take payment.', 'POS & Sales'),
    PermissionInfo(PosPermission.holdSale, 'Hold sales',
        'Save an unfinished sale for later.', 'POS & Sales',
        requires: {PosPermission.sell}),
    PermissionInfo(PosPermission.resumeSale, 'Resume held sales',
        'Open or discard a held sale.', 'POS & Sales',
        requires: {PosPermission.sell}),
    PermissionInfo(PosPermission.viewOwnSales, 'View own sales',
        'See sales made by this account.', 'POS & Sales'),
    PermissionInfo(PosPermission.viewAllSales, 'View all sales',
        'See sales made by all staff.', 'POS & Sales',
        requires: {PosPermission.viewOwnSales}),
    PermissionInfo(
        PosPermission.reverseSale,
        'Reverse sales and process returns',
        'Void, refund, or exchange a sale.',
        'POS & Sales',
        sensitive: true,
        requires: {PosPermission.viewAllSales}),
    PermissionInfo(PosPermission.approveDiscount, 'Approve manual discounts',
        'Authorize a discount with a password.', 'POS & Sales',
        sensitive: true, requires: {PosPermission.sell}),
    PermissionInfo(
        PosPermission.authorizeBelowCost,
        'Authorize below-cost sales',
        'Approve a sale with a negative estimated inventory margin.',
        'POS & Sales',
        sensitive: true,
        requires: {PosPermission.sell}),
    PermissionInfo(PosPermission.manageCatalog, 'Manage catalog',
        'Edit products, prices, and catalog records.', 'Inventory'),
    PermissionInfo(
        PosPermission.stockReceiving,
        'Receive stock and purchase orders',
        'Receive inventory and manage purchase orders.',
        'Inventory'),
    PermissionInfo(
        PosPermission.finalizePurchaseReturn,
        'Finalize purchase returns',
        'Remove received stock being returned to a supplier.',
        'Inventory',
        sensitive: true,
        requires: {PosPermission.stockReceiving}),
    PermissionInfo(
        PosPermission.approveDuplicateReceiving,
        'Approve duplicate receiving reference',
        'Accept a supplier delivery reference already used.',
        'Inventory',
        sensitive: true,
        requires: {PosPermission.stockReceiving}),
    PermissionInfo(
        PosPermission.cancelPurchaseOrders,
        'Cancel or close purchase orders',
        'Cancel an open order or close a fully received order.',
        'Inventory',
        sensitive: true,
        requires: {PosPermission.stockReceiving}),
    PermissionInfo(PosPermission.stockCount, 'Perform stock counts',
        'Record and review physical stock counts.', 'Inventory'),
    PermissionInfo(PosPermission.finalizeStockCount, 'Finalize stock counts',
        'Post reviewed physical count variances.', 'Inventory',
        sensitive: true, requires: {PosPermission.stockCount}),
    PermissionInfo(PosPermission.stockAdjust, 'Post inventory adjustments',
        'Post stock variances and adjustments.', 'Inventory',
        sensitive: true, requires: {PosPermission.stockCount}),
    PermissionInfo(PosPermission.viewContacts, 'View contacts',
        'See customers and suppliers.', 'Customers'),
    PermissionInfo(PosPermission.manageContacts, 'Manage contacts',
        'Edit customers and suppliers.', 'Customers',
        requires: {PosPermission.viewContacts}),
    PermissionInfo(PosPermission.customerCredit, 'Manage customer credit',
        'Record customer credit activity.', 'Customers',
        sensitive: true, requires: {PosPermission.viewContacts}),
    PermissionInfo(
        PosPermission.manageLoyalty,
        'Adjust loyalty points and groups',
        'Manually change loyalty points and customer groups.',
        'Customers',
        sensitive: true,
        requires: {PosPermission.viewContacts}),
    PermissionInfo(PosPermission.manageQuotations, 'Manage quotations',
        'Create and update quotations.', 'Quotations & Layaway'),
    PermissionInfo(PosPermission.viewSalesOrders, 'View sales orders',
        'See customer sales orders.', 'POS & Sales'),
    PermissionInfo(PosPermission.manageSalesOrders, 'Manage sales orders',
        'Create and update customer sales orders.', 'POS & Sales',
        requires: {PosPermission.viewSalesOrders}),
    PermissionInfo(
        PosPermission.manageStockReservations,
        'Manage stock reservations',
        'Reserve and release stock for confirmed sales orders.',
        'POS & Sales',
        requires: {PosPermission.viewSalesOrders}),
    PermissionInfo(PosPermission.manageLayaway, 'Manage layaway',
        'Create and update layaway orders.', 'Quotations & Layaway'),
    PermissionInfo(PosPermission.viewPromotions, 'View promotions',
        'Browse promotion rules and history.', 'POS & Sales'),
    PermissionInfo(PosPermission.managePromotions, 'Manage promotions',
        'Create, edit, and activate promotion rules.', 'POS & Sales',
        requires: {PosPermission.viewPromotions}),
    PermissionInfo(PosPermission.manageRma, 'Manage RMA',
        'Manage warranty and RMA cases.', 'RMA / Warranty'),
    PermissionInfo(PosPermission.reports, 'View reports',
        'See sales and operational reports.', 'Expenses & Reports'),
    PermissionInfo(PosPermission.manageExpenses, 'Manage expenses',
        'Record and review business expenses.', 'Expenses & Reports'),
    PermissionInfo(
        PosPermission.manageExpenseFunds,
        'Manage expense funds',
        'Manage categories, petty cash, reimbursements, and reversals.',
        'Expenses & Reports',
        sensitive: true,
        requires: {PosPermission.manageExpenses}),
    PermissionInfo(PosPermission.manageCashSession, 'Manage cash session',
        'Open, close, and manage cash sessions.', 'Cash Session'),
    PermissionInfo(
        PosPermission.closeAnyCashSession,
        'Close another staff session',
        'Close a cash session opened by another user.',
        'Cash Session',
        sensitive: true,
        requires: {PosPermission.manageCashSession}),
    PermissionInfo(
        PosPermission.acknowledgeShiftHandover,
        'Acknowledge shift handover',
        'Approve a counted drawer transfer.',
        'Cash Session',
        sensitive: true,
        requires: {PosPermission.manageCashSession}),
    PermissionInfo(PosPermission.manageUsers, 'Manage users',
        'Create and edit staff accounts.', 'Administration',
        sensitive: true),
    PermissionInfo(PosPermission.manageRoles, 'Manage roles',
        'Create and edit custom roles.', 'Administration',
        sensitive: true,
        ownerOnly: true,
        requires: {PosPermission.manageUsers}),
    PermissionInfo(PosPermission.manageSettings, 'Manage settings',
        'Change business settings.', 'Administration',
        sensitive: true),
    PermissionInfo(PosPermission.managePrinter, 'Manage printer and receipts',
        'Change receipt printer settings.', 'Administration'),
    PermissionInfo(PosPermission.manageRecovery, 'Manage backup and recovery',
        'Create and restore local backups.', 'Backup & Recovery',
        sensitive: true, ownerOnly: true),
    PermissionInfo(PosPermission.refreshLicense, 'Refresh license',
        'Activate a new license key for this device.', 'License / Device',
        sensitive: true, ownerOnly: true),
  ];
  static final byKey = {for (final e in entries) e.key.name: e};
  static Set<PosPermission> normalize(Iterable<PosPermission> values) {
    final result = values.toSet();
    var changed = true;
    while (changed) {
      final before = result.length;
      for (final e in entries) {
        if (result.contains(e.key)) result.addAll(e.requires);
      }
      changed = result.length != before;
    }
    return result;
  }

  static Set<PosPermission> baseline(UserRole role) => switch (role) {
        UserRole.owner => PosPermission.values.toSet(),
        UserRole.manager => {
            PosPermission.sell,
            PosPermission.holdSale,
            PosPermission.resumeSale,
            PosPermission.viewOwnSales,
            PosPermission.viewAllSales,
            PosPermission.reverseSale,
            PosPermission.reports,
            PosPermission.manageCatalog,
            PosPermission.manageCashSession,
            PosPermission.manageContacts,
            PosPermission.viewContacts,
            PosPermission.closeAnyCashSession,
            PosPermission.acknowledgeShiftHandover,
            PosPermission.customerCredit,
            PosPermission.stockReceiving,
            PosPermission.finalizePurchaseReturn,
            PosPermission.approveDuplicateReceiving,
            PosPermission.stockCount,
            PosPermission.manageRma,
            PosPermission.manageQuotations,
            PosPermission.manageSalesOrders,
            PosPermission.manageStockReservations,
            PosPermission.manageLayaway,
            PosPermission.viewPromotions,
            PosPermission.managePromotions,
            PosPermission.approveDiscount,
            PosPermission.authorizeBelowCost,
            PosPermission.manageExpenses,
            PosPermission.manageExpenseFunds,
          },
        UserRole.cashier => {
            PosPermission.sell,
            PosPermission.holdSale,
            PosPermission.resumeSale,
            PosPermission.viewOwnSales,
            PosPermission.manageCashSession,
            PosPermission.customerCredit,
            PosPermission.viewContacts,
            PosPermission.manageQuotations,
            PosPermission.manageSalesOrders,
            PosPermission.manageStockReservations,
            PosPermission.manageLayaway,
            PosPermission.manageExpenses,
          },
        UserRole.custom => {},
      };
}

class ActiveUser {
  final String id;
  final String name;
  final UserRole role;
  final bool isActive;
  final String? roleCode;
  final Set<PosPermission>? grantedPermissions;
  const ActiveUser(this.id, this.name, this.role,
      [this.isActive = true, this.roleCode, this.grantedPermissions]);

  bool can(PosPermission permission) =>
      isActive &&
      (role == UserRole.owner ||
          (grantedPermissions ?? PermissionRegistry.baseline(role))
              .contains(permission));
  void require(PosPermission permission) {
    if (!can(permission)) throw StateError('Not authorized for this action');
  }
}
