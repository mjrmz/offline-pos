// lib/data/database.dart
//
// Local SQLite database via drift. This is the source of truth for a single
// device — never the UI, never the cloud. See docs/DATABASE_SCHEMA.md.

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

part 'database.g.dart';

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

class Products extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get sku => text().nullable()();
  TextColumn get barcode => text().nullable()();
  TextColumn get categoryId => text().nullable().references(Categories, #id)();
  TextColumn get name => text()();
  IntColumn get priceCents => integer()(); // store money as integer cents
  IntColumn get costCents => integer().nullable()();
  TextColumn get pricingPolicy =>
      text().withDefault(const Constant('current'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get serialTracking =>
      boolean().withDefault(const Constant(false))();
  IntColumn get lowStockThreshold => integer().withDefault(const Constant(5))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class Categories extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get name => text()();
  TextColumn get parentCategoryId =>
      text().nullable().references(Categories, #id)();
  @override
  Set<Column> get primaryKey => {id};
}

class Inventory extends Table {
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantity => integer().withDefault(const Constant(0))();
  IntColumn get quantityMilli => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {productId};
}

class InventoryMovements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantityDelta => integer()(); // +50 stock in, -2 sale, etc.
  IntColumn get quantityDeltaMilli =>
      integer().withDefault(const Constant(0))();
  TextColumn get reason =>
      text()(); // 'sale' | 'purchase' | 'adjustment' | 'damaged'
  TextColumn get referenceId => text().nullable()(); // e.g. Sale.id
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class Sales extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get receiptNumber => text().nullable().unique()();
  TextColumn get cashierId => text().references(Users, #id)();
  TextColumn get cashSessionId =>
      text().nullable().references(CashSessions, #id)();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  IntColumn get totalCents => integer()();
  IntColumn get birInvoiceNumber => integer().nullable().unique()();
  TextColumn get status => text().withDefault(
      const Constant('completed'))(); // completed | voided | refunded
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class SaleItems extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get productName => text().withDefault(const Constant(''))();
  IntColumn get quantity => integer()();
  IntColumn get quantityMilli => integer().withDefault(const Constant(0))();
  TextColumn get saleUnit => text().withDefault(const Constant('pcs'))();
  TextColumn get saleMode => text().withDefault(const Constant('ordinary'))();
  TextColumn get batchId => text().nullable()();
  TextColumn get batchNumber => text().nullable()();
  IntColumn get extraCents => integer().withDefault(const Constant(0))();
  IntColumn get unitPriceCents => integer()();
  IntColumn get lineTotalCents => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Payments extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get method => text()(); // cash | gcash | card | other
  IntColumn get amountCents => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

class Users extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get name => text()();
  TextColumn get pinHash => text().nullable()(); // cashier
  TextColumn get passwordHash => text().nullable()(); // admin/manager
  TextColumn get role => text()(); // cashier | manager | owner
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get failedAttempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lockedUntil => dateTime().nullable()();
  TextColumn get recoveryQuestion => text().nullable()();
  TextColumn get recoveryAnswerHash => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SaleReversals extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleId => text().references(Sales, #id).unique()();
  TextColumn get actorId => text().references(Users, #id)();
  TextColumn get kind => text()(); // void | refund
  IntColumn get amountCents => integer()();
  BoolColumn get stockRestored => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

// Financial reversal of exactly one claimed SaleItem quantity. The original
// sale and invoice stay immutable.
class SaleItemRefunds extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get rmaCaseId => text().unique()();
  TextColumn get saleId => text().references(Sales, #id)();
  TextColumn get saleItemId => text().references(SaleItems, #id)();
  TextColumn get cashSessionId =>
      text().nullable().references(CashSessions, #id)();
  IntColumn get quantityMilli => integer()();
  IntColumn get amountCents => integer()();
  IntColumn get cashAllocationCents => integer()();
  IntColumn get creditAllocationCents => integer()();
  IntColumn get receivableReductionCents => integer()();
  IntColumn get obligationCents => integer()();
  IntColumn get immediateCashCents => integer()();
  TextColumn get obligationId => text().nullable()();
  TextColumn get cashMovementId => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class CashSessions extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get openedByUserId => text().references(Users, #id)();
  IntColumn get startingCashCents => integer()();
  IntColumn get expectedCashCents => integer().nullable()();
  IntColumn get actualCashCents => integer().nullable()();
  DateTimeColumn get openedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get closedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class CashMovements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get sessionId => text().references(CashSessions, #id)();
  TextColumn get saleId => text().nullable().unique().references(Sales, #id)();
  TextColumn get referenceId => text().nullable()();
  IntColumn get amountCents => integer()();
  TextColumn get kind =>
      text()(); // cash_sale; later kinds require actual cash evidence
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class AuditLogs extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get userId => text().nullable()();
  TextColumn get action => text()(); // 'login' | 'void' | 'refund' | ...
  TextColumn get details => text().nullable()(); // JSON-encoded context
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();

  @override
  Set<Column> get primaryKey => {id};
}

class Settings extends Table {
  IntColumn get id => integer()();
  TextColumn get storeName => text().withDefault(const Constant(''))();
  TextColumn get storeAddress => text().withDefault(const Constant(''))();
  TextColumn get storeContact => text().withDefault(const Constant(''))();
  TextColumn get receiptHeader => text().withDefault(const Constant(''))();
  TextColumn get receiptFooter => text().withDefault(const Constant(''))();
  BoolColumn get printerEnabled =>
      boolean().withDefault(const Constant(false))();
  TextColumn get printerTransport =>
      text().withDefault(const Constant('lan'))();
  TextColumn get printerHost => text().withDefault(const Constant(''))();
  IntColumn get printerPort => integer().withDefault(const Constant(9100))();
  TextColumn get printerDeviceId => text().withDefault(const Constant(''))();
  TextColumn get printerDeviceName => text().withDefault(const Constant(''))();
  IntColumn get printerWidthMm => integer().withDefault(const Constant(80))();
  BoolColumn get drawerEnabled =>
      boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {id};
}

class BusinessFeatureSettings extends Table {
  TextColumn get featureId => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(false))();
  @override
  Set<Column> get primaryKey => {featureId};
}

class ProductBusinessConfigurations extends Table {
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get featureId => text()();
  TextColumn get configurationJson => text()();
  @override
  Set<Column> get primaryKey => {productId, featureId};
}

class ProductLots extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get batchNumber => text()();
  DateTimeColumn get expiryDate => dateTime().nullable()();
  IntColumn get quantityMilli => integer().withDefault(const Constant(0))();
  DateTimeColumn get receivedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class MadeOrders extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleItemId => text().references(SaleItems, #id)();
  TextColumn get status => text().withDefault(const Constant('ordered'))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class TankEmptyMovements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantityDelta => integer()();
  TextColumn get reason => text()();
  TextColumn get referenceId => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class Customers extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class CustomerCreditEntries extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get saleId => text().nullable().references(Sales, #id)();
  TextColumn get userId => text().references(Users, #id)();
  IntColumn get amountCents => integer()();
  TextColumn get kind => text()();
  TextColumn get paymentMethod => text().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

// A paid pooled receivable can become money owed to the customer when its
// originating sale is reversed. Keep that liability separate from utang.
class CustomerRefundObligations extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get saleId => text().nullable().references(Sales, #id).unique()();
  TextColumn get layawayId =>
      text().nullable().unique().references(Layaways, #id)();
  TextColumn get rmaCaseId => text().nullable()();
  TextColumn get userId => text().references(Users, #id)();
  IntColumn get amountCents => integer()();
  IntColumn get settledCents => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class CustomerRefundSettlements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get obligationId =>
      text().references(CustomerRefundObligations, #id)();
  TextColumn get userId => text().references(Users, #id)();
  IntColumn get amountCents => integer()();
  TextColumn get method => text()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class Suppliers extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get name => text()();
  TextColumn get contact => text().nullable()();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class StockReceivings extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get supplierId => text().references(Suppliers, #id)();
  TextColumn get userId => text().references(Users, #id)();
  TextColumn get externalReference => text().nullable()();
  TextColumn get notes => text().nullable()();
  DateTimeColumn get receivedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class StockReceivingItems extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get receivingId => text().references(StockReceivings, #id)();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantityMilli => integer()();
  IntColumn get unitCostCents => integer()();
  IntColumn get unitSellingPriceCents => integer().nullable()();
  TextColumn get batchNumber => text().nullable()();
  DateTimeColumn get expiryDate => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class InventoryLayers extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get receivingItemId =>
      text().nullable().unique().references(StockReceivingItems, #id)();
  TextColumn get source => text().withDefault(const Constant('receiving'))();
  IntColumn get quantityReceivedMilli => integer()();
  IntColumn get quantityRemainingMilli => integer()();
  IntColumn get unitCostCents => integer()();
  IntColumn get unitSellingPriceCents => integer().nullable()();
  TextColumn get batchNumber => text().nullable()();
  DateTimeColumn get expiryDate => dateTime().nullable()();
  DateTimeColumn get receivedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class SaleItemInventoryAllocations extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get saleItemId => text().references(SaleItems, #id)();
  TextColumn get inventoryLayerId => text().references(InventoryLayers, #id)();
  TextColumn get serialUnitId =>
      text().nullable().references(SerialUnits, #id)();
  IntColumn get quantityMilli => integer()();
  IntColumn get unitCostSnapshotCents => integer()();
  IntColumn get unitSellingPriceSnapshotCents => integer()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class SerialUnits extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get serialNumber => text().unique()();
  TextColumn get status => text().withDefault(const Constant('available'))();
  TextColumn get receivingItemId =>
      text().nullable().references(StockReceivingItems, #id)();
  TextColumn get inventoryLayerId =>
      text().nullable().references(InventoryLayers, #id)();
  TextColumn get saleItemId => text().nullable().references(SaleItems, #id)();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class SerialSaleLinks extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get serialUnitId => text().references(SerialUnits, #id)();
  TextColumn get saleItemId => text().references(SaleItems, #id)();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class RmaCases extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get reference => text().unique()();
  TextColumn get origin => text()(); // customer | inbound
  TextColumn get saleId => text().nullable().references(Sales, #id)();
  TextColumn get saleItemId => text().nullable().references(SaleItems, #id)();
  TextColumn get receivingId =>
      text().nullable().references(StockReceivings, #id)();
  TextColumn get receivingItemId =>
      text().nullable().references(StockReceivingItems, #id)();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get supplierId => text().nullable().references(Suppliers, #id)();
  TextColumn get serialUnitId =>
      text().nullable().references(SerialUnits, #id)();
  TextColumn get issueDescription => text()();
  TextColumn get intakeCondition => text()();
  IntColumn get quantityMilli => integer().withDefault(const Constant(1000))();
  TextColumn get notes => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get customerResolution => text().nullable()();
  TextColumn get unitDisposition => text().nullable()();
  TextColumn get replacementSerialUnitId => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class RmaEvents extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get caseId => text().references(RmaCases, #id)();
  TextColumn get actorId => text().references(Users, #id)();
  TextColumn get status => text()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

// Version 2 claims record physical and authorization facts separately. Old
// rma_events remain untouched and are never treated as receipt/inspection proof.
class RmaLifecycleEvents extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get caseId => text().references(RmaCases, #id)();
  TextColumn get actorId => text().references(Users, #id)();
  TextColumn get action => text()();
  IntColumn get quantityMilli => integer().nullable()();
  TextColumn get expectedSerial => text().nullable()();
  TextColumn get returnedSerial => text().nullable()();
  TextColumn get condition => text().nullable()();
  BoolColumn get faultReproduced => boolean().nullable()();
  TextColumn get finding => text().nullable()();
  TextColumn get outcome => text().nullable()();
  TextColumn get disposition => text().nullable()();
  IntColumn get amountCents => integer().nullable()();
  TextColumn get method => text().nullable()();
  TextColumn get serialUnitId =>
      text().nullable().references(SerialUnits, #id)();
  TextColumn get relatedCaseId => text().nullable()();
  TextColumn get recipient => text().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

// Append-only warranty facts for a serialized unit. Historical sale rows are
// never rewritten; a missing original snapshot remains legacy/unknown.
class SerialWarrantySnapshots extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get serialUnitId => text().references(SerialUnits, #id)();
  TextColumn get sourceRmaCaseId =>
      text().nullable().references(RmaCases, #id)();
  TextColumn get sourceEventId =>
      text().nullable().references(RmaLifecycleEvents, #id)();
  TextColumn get treatment => text()();
  TextColumn get source => text()();
  DateTimeColumn get startAt => dateTime().nullable()();
  DateTimeColumn get endAt => dateTime().nullable()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class InboundRmaReplacements extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get rmaCaseId => text().unique()();
  TextColumn get receivingId => text().references(StockReceivings, #id)();
  TextColumn get receivingItemId =>
      text().references(StockReceivingItems, #id)();
  TextColumn get serialUnitId =>
      text().nullable().references(SerialUnits, #id)();
  IntColumn get quantityMilli => integer()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class Quotations extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get reference => text().unique()();
  TextColumn get customerId => text().nullable().references(Customers, #id)();
  TextColumn get createdBy => text().references(Users, #id)();
  DateTimeColumn get validUntil => dateTime().nullable()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  TextColumn get notes => text().nullable()();
  TextColumn get convertedSaleId =>
      text().nullable().unique().references(Sales, #id)();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class QuotationItems extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get quotationId => text().references(Quotations, #id)();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantityMilli => integer()();
  TextColumn get unitSnapshot => text()();
  IntColumn get unitPriceCents => integer()();
  IntColumn get lineTotalCents => integer()();
  @override
  Set<Column> get primaryKey => {id};
}

class Layaways extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get reference => text().unique()();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get createdBy => text().references(Users, #id)();
  IntColumn get totalCents => integer()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get saleId => text().nullable().unique().references(Sales, #id)();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  DateTimeColumn get completedAt => dateTime().nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

class LayawayItems extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get layawayId => text().references(Layaways, #id)();
  TextColumn get productId => text().references(Products, #id)();
  IntColumn get quantityMilli => integer()();
  TextColumn get unitSnapshot => text()();
  IntColumn get unitPriceCents => integer()();
  IntColumn get lineTotalCents => integer()();
  @override
  Set<Column> get primaryKey => {id};
}

class LayawaySerials extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get layawayId => text().references(Layaways, #id)();
  TextColumn get serialUnitId => text().references(SerialUnits, #id)();
  TextColumn get productId => text().references(Products, #id)();
  @override
  Set<Column> get primaryKey => {id};
}

class LayawayPayments extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get layawayId => text().references(Layaways, #id)();
  TextColumn get userId => text().references(Users, #id)();
  IntColumn get amountCents => integer()();
  TextColumn get method => text()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class PettyCashEntries extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get cashSessionId => text().references(CashSessions, #id)();
  TextColumn get userId => text().references(Users, #id)();
  IntColumn get amountCents => integer()();
  TextColumn get category => text()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class PriceHistory extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get userId => text().nullable().references(Users, #id)();
  IntColumn get oldPriceCents => integer()();
  IntColumn get newPriceCents => integer()();
  IntColumn get oldCostCents => integer().nullable()();
  IntColumn get newCostCents => integer().nullable()();
  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now())();
  @override
  Set<Column> get primaryKey => {id};
}

class BirComplianceState extends Table {
  IntColumn get id => integer()();
  DateTimeColumn get activatedAt => dateTime()();
  IntColumn get highestInvoiceNumber =>
      integer().withDefault(const Constant(0))();
  IntColumn get grandTotalCents => integer().withDefault(const Constant(0))();
  IntColumn get highestZNumber => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {id};
}

class ZReadings extends Table {
  TextColumn get id => text().clientDefault(() => _uuid())();
  IntColumn get number => integer().unique()();
  TextColumn get cashSessionId => text().unique()();
  DateTimeColumn get generatedAt =>
      dateTime().clientDefault(() => DateTime.now())();
  TextColumn get generatedByUserId => text()();
  IntColumn get beginningInvoiceNumber => integer().nullable()();
  IntColumn get endingInvoiceNumber => integer().nullable()();
  IntColumn get periodSalesCents => integer()();
  IntColumn get reversalCents => integer()();
  IntColumn get grandTotalCents => integer()();
  IntColumn get expectedCashCents => integer()();
  IntColumn get actualCashCents => integer()();
  @override
  Set<Column> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

@DriftDatabase(tables: [
  Products,
  Categories,
  Inventory,
  InventoryMovements,
  Sales,
  SaleReversals,
  SaleItemRefunds,
  SaleItems,
  Payments,
  Users,
  CashSessions,
  CashMovements,
  AuditLogs,
  Settings,
  BusinessFeatureSettings,
  ProductBusinessConfigurations,
  ProductLots,
  MadeOrders,
  TankEmptyMovements,
  Customers,
  CustomerCreditEntries,
  CustomerRefundObligations,
  CustomerRefundSettlements,
  Suppliers,
  StockReceivings,
  StockReceivingItems,
  InventoryLayers,
  SaleItemInventoryAllocations,
  SerialUnits,
  SerialSaleLinks,
  RmaCases,
  RmaEvents,
  RmaLifecycleEvents,
  SerialWarrantySnapshots,
  InboundRmaReplacements,
  Quotations,
  QuotationItems,
  Layaways,
  LayawayItems,
  LayawaySerials,
  LayawayPayments,
  PettyCashEntries,
  PriceHistory,
  BirComplianceState,
  ZReadings,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  AppDatabase.forTesting(super.executor);
  static Future<File> databaseFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'modern_offline_pos.sqlite'));
  }

  // Bump this on every schema change and add a migration step below.
  @override
  int get schemaVersion => 24;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement('CREATE UNIQUE INDEX cash_sessions_one_open '
              'ON cash_sessions ((1)) WHERE closed_at IS NULL');
          await _createBirGuards(this);
          await customStatement(
              'CREATE UNIQUE INDEX product_lots_product_number '
              'ON product_lots (product_id, batch_number)');
          await customStatement('CREATE INDEX tank_empty_movements_product '
              'ON tank_empty_movements (product_id)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS petty_cash_entries_session '
              'ON petty_cash_entries (cash_session_id)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS price_history_product '
              'ON price_history (product_id)');
          await customStatement('CREATE INDEX IF NOT EXISTS sales_cash_session '
              'ON sales (cash_session_id)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS customer_credit_entries_customer '
              'ON customer_credit_entries (customer_id)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS stock_receivings_supplier '
              'ON stock_receivings (supplier_id)');
          await customStatement('CREATE UNIQUE INDEX customer_refund_rma_case '
              'ON customer_refund_obligations (rma_case_id) '
              'WHERE rma_case_id IS NOT NULL');
          await _createLayerIndexes(this);
          await customStatement(
              'CREATE INDEX IF NOT EXISTS rma_lifecycle_case_action '
              'ON rma_lifecycle_events (case_id, action)');
          await customStatement(
              'CREATE INDEX IF NOT EXISTS serial_warranty_unit_created '
              'ON serial_warranty_snapshots (serial_unit_id, created_at)');
          await _createInventoryGuards(this);
          final saleTables = await customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table' AND name='sales'")
              .get();
          if (saleTables.isNotEmpty) await _createReceiptGuards(this);
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(categories);
            await m.addColumn(products, products.categoryId);
            await m.createTable(inventory);
            await m.addColumn(saleItems, saleItems.lineTotalCents);
            // Existing Phase 1 movement rows are the only prior stock source.
            await customStatement(
                'INSERT INTO inventory (product_id, quantity) '
                'SELECT product_id, SUM(quantity_delta) FROM inventory_movements '
                'GROUP BY product_id');
            await customStatement('UPDATE sale_items SET line_total_cents = '
                'quantity * unit_price_cents');
          }
          if (from < 3) {
            await m.addColumn(products, products.lowStockThreshold);
            await m.addColumn(users, users.failedAttempts);
            await m.addColumn(users, users.lockedUntil);
            await m.addColumn(users, users.recoveryQuestion);
            await m.addColumn(users, users.recoveryAnswerHash);
            await m.createTable(saleReversals);
          }
          if (from == 3) {
            await m.addColumn(saleReversals, saleReversals.stockRestored);
          }
          if (from < 5) {
            await m.addColumn(saleItems, saleItems.productName);
            await customStatement('UPDATE sale_items SET product_name = '
                'COALESCE((SELECT name FROM products WHERE products.id = sale_items.product_id), \'Unknown product\')');
          }
          if (from < 6) {
            await m.createTable(settings);
          }
          if (from < 7) {
            await m.createTable(cashMovements);
            final sessionsTable = await customSelect(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cash_sessions'")
                .get();
            if (sessionsTable.isNotEmpty) {
              await customStatement(
                  'CREATE UNIQUE INDEX cash_sessions_one_open '
                  'ON cash_sessions ((1)) WHERE closed_at IS NULL');
            }
          }
          if (from < 8) {
            // SQLite cannot add a UNIQUE column with ALTER TABLE.
            final oldTables = (await customSelect(
                        "SELECT name FROM sqlite_master WHERE type='table'")
                    .get())
                .map((row) => row.read<String>('name'))
                .toSet();
            if (oldTables.contains('sales')) {
              final saleColumns =
                  await customSelect('PRAGMA table_info(sales)').get();
              if (!saleColumns.any(
                  (row) => row.read<String>('name') == 'bir_invoice_number')) {
                await customStatement(
                    'ALTER TABLE sales ADD COLUMN bir_invoice_number INTEGER');
              }
              await customStatement(
                  'CREATE UNIQUE INDEX IF NOT EXISTS sales_bir_invoice_number_unique '
                  'ON sales (bir_invoice_number) WHERE bir_invoice_number IS NOT NULL');
            }
            if (!oldTables.contains('bir_compliance_state')) {
              await m.createTable(birComplianceState);
            }
            if (!oldTables.contains('z_readings')) {
              await m.createTable(zReadings);
            }
            if (oldTables.contains('sales')) await _createBirGuards(this);
          }
          if (from < 9) {
            final tables = (await customSelect(
                        "SELECT name FROM sqlite_master WHERE type='table'")
                    .get())
                .map((row) => row.read<String>('name'))
                .toSet();
            if (!tables.contains('business_feature_settings')) {
              await m.createTable(businessFeatureSettings);
            }
            if (!tables.contains('product_business_configurations')) {
              await m.createTable(productBusinessConfigurations);
            }
          }
          if (from < 10) {
            Future<bool> addIfMissing(String table, String column,
                Future<void> Function() add) async {
              final tables = await customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                  variables: [Variable.withString(table)]).get();
              if (tables.isEmpty) return false;
              final columns =
                  await customSelect('PRAGMA table_info($table)').get();
              if (columns.any((row) => row.read<String>('name') == column)) {
                return false;
              }
              await add();
              return true;
            }

            if (await addIfMissing('inventory', 'quantity_milli',
                () => m.addColumn(inventory, inventory.quantityMilli))) {
              await customStatement(
                  'UPDATE inventory SET quantity_milli = quantity * 1000');
            }
            if (await addIfMissing(
                'inventory_movements',
                'quantity_delta_milli',
                () => m.addColumn(inventoryMovements,
                    inventoryMovements.quantityDeltaMilli))) {
              await customStatement(
                  'UPDATE inventory_movements SET quantity_delta_milli = quantity_delta * 1000');
            }
            if (await addIfMissing('sale_items', 'quantity_milli',
                () => m.addColumn(saleItems, saleItems.quantityMilli))) {
              final saleColumns =
                  await customSelect('PRAGMA table_info(sale_items)').get();
              if (saleColumns
                  .any((row) => row.read<String>('name') == 'quantity')) {
                await customStatement(
                    'UPDATE sale_items SET quantity_milli = quantity * 1000');
              }
            }
            await addIfMissing('sale_items', 'sale_unit',
                () => m.addColumn(saleItems, saleItems.saleUnit));
            await addIfMissing('sale_items', 'sale_mode',
                () => m.addColumn(saleItems, saleItems.saleMode));
            await addIfMissing('sale_items', 'batch_id',
                () => m.addColumn(saleItems, saleItems.batchId));
            await addIfMissing('sale_items', 'batch_number',
                () => m.addColumn(saleItems, saleItems.batchNumber));
            await addIfMissing('sale_items', 'extra_cents',
                () => m.addColumn(saleItems, saleItems.extraCents));
            final tables = (await customSelect(
                        "SELECT name FROM sqlite_master WHERE type='table'")
                    .get())
                .map((row) => row.read<String>('name'))
                .toSet();
            if (!tables.contains('product_lots')) {
              await m.createTable(productLots);
            }
            if (!tables.contains('made_orders')) {
              await m.createTable(madeOrders);
            }
            if (!tables.contains('tank_empty_movements')) {
              await m.createTable(tankEmptyMovements);
            }
            // Phase 8 foundation could store batch-enabled product config
            // before lots existed. Preserve its existing stock as one
            // explicitly unnumbered legacy lot.
            if (tables.contains('inventory')) {
              await customStatement(
                  "INSERT INTO product_lots (id, product_id, batch_number, quantity_milli, received_at) "
                  "SELECT 'legacy-' || i.product_id, i.product_id, 'Legacy unassigned', "
                  "i.quantity_milli, strftime('%s','now') FROM inventory i "
                  "JOIN product_business_configurations c ON c.product_id = i.product_id "
                  "WHERE c.feature_id = 'expiryBatchTracking' "
                  "AND json_valid(c.configuration_json) "
                  "AND json_extract(c.configuration_json, '\$.enabled') = 1 "
                  "AND i.quantity_milli > 0");
            }
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS product_lots_product_number '
                'ON product_lots (product_id, batch_number)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS tank_empty_movements_product '
                'ON tank_empty_movements (product_id)');
          }
          if (from < 11) {
            await m.createTable(customers);
            await m.createTable(suppliers);
            await m.createTable(pettyCashEntries);
            await m.createTable(priceHistory);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS petty_cash_entries_session '
                'ON petty_cash_entries (cash_session_id)');
            await customStatement(
                'CREATE INDEX IF NOT EXISTS price_history_product '
                'ON price_history (product_id)');
          }
          if (from < 12) {
            final columns =
                (await customSelect('PRAGMA table_info(sales)').get())
                    .map((row) => row.read<String>('name'))
                    .toSet();
            if (columns.isNotEmpty) {
              if (!columns.contains('cash_session_id')) {
                await m.addColumn(sales, sales.cashSessionId);
              }
              await customStatement('UPDATE sales SET cash_session_id = '
                  '(SELECT session_id FROM cash_movements '
                  'WHERE cash_movements.sale_id = sales.id LIMIT 1) '
                  'WHERE EXISTS (SELECT 1 FROM cash_movements '
                  'WHERE cash_movements.sale_id = sales.id)');
              await customStatement(
                  'CREATE INDEX IF NOT EXISTS sales_cash_session '
                  'ON sales (cash_session_id)');
            }
          }
          if (from < 13) {
            final columns =
                (await customSelect('PRAGMA table_info(sales)').get())
                    .map((row) => row.read<String>('name'))
                    .toSet();
            if (columns.isNotEmpty && !columns.contains('customer_id')) {
              await m.addColumn(sales, sales.customerId);
            }
            await m.createTable(customerCreditEntries);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS customer_credit_entries_customer '
                'ON customer_credit_entries (customer_id)');
          }
          if (from < 14) {
            await m.createTable(stockReceivings);
            await m.createTable(stockReceivingItems);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS stock_receivings_supplier '
                'ON stock_receivings (supplier_id)');
          }
          if (from < 15) {
            final columns =
                await customSelect('PRAGMA table_info(customer_credit_entries)')
                    .get();
            if (!columns
                .any((row) => row.read<String>('name') == 'payment_method')) {
              await m.addColumn(
                  customerCreditEntries, customerCreditEntries.paymentMethod);
            }
          }
          if (from < 16) {
            final columns =
                (await customSelect('PRAGMA table_info(settings)').get())
                    .map((row) => row.read<String>('name'))
                    .toSet();
            if (!columns.contains('store_address')) {
              await m.addColumn(settings, settings.storeAddress);
            }
            if (!columns.contains('store_contact')) {
              await m.addColumn(settings, settings.storeContact);
            }
            if (!columns.contains('receipt_header')) {
              await m.addColumn(settings, settings.receiptHeader);
            }
            if (!columns.contains('receipt_footer')) {
              await m.addColumn(settings, settings.receiptFooter);
            }
          }
          if (from < 17) {
            final cashColumns =
                (await customSelect('PRAGMA table_info(cash_movements)').get())
                    .map((row) => row.read<String>('name'))
                    .toSet();
            if (cashColumns.isNotEmpty &&
                !cashColumns.contains('reference_id')) {
              await m.addColumn(cashMovements, cashMovements.referenceId);
            }
            final productColumns =
                (await customSelect('PRAGMA table_info(products)').get())
                    .map((row) => row.read<String>('name'))
                    .toSet();
            if (productColumns.isNotEmpty &&
                !productColumns.contains('serial_tracking')) {
              await m.addColumn(products, products.serialTracking);
            }
            await m.createTable(customerRefundObligations);
            await m.createTable(customerRefundSettlements);
            await m.createTable(serialUnits);
            await m.createTable(serialSaleLinks);
            await m.createTable(rmaCases);
            await m.createTable(rmaEvents);
            await m.createTable(quotations);
            await m.createTable(quotationItems);
            await m.createTable(layaways);
            await m.createTable(layawayItems);
            await m.createTable(layawaySerials);
            await m.createTable(layawayPayments);
          }
          if (from < 18) {
            final columns =
                (await customSelect('PRAGMA table_info(rma_cases)').get())
                    .map((row) => row.read<String>('name'))
                    .toSet();
            if (!columns.contains('replacement_serial_unit_id')) {
              await m.addColumn(rmaCases, rmaCases.replacementSerialUnitId);
            }
          }
          if (from < 19) {
            await m.createTable(saleItemRefunds);
            await m.createTable(inboundRmaReplacements);
            final columns = (await customSelect(
                        'PRAGMA table_info(customer_refund_obligations)')
                    .get())
                .map((row) => row.read<String>('name'))
                .toSet();
            if (!columns.contains('rma_case_id')) {
              await m.addColumn(customerRefundObligations,
                  customerRefundObligations.rmaCaseId);
            }
            await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS customer_refund_rma_case '
                'ON customer_refund_obligations (rma_case_id) '
                'WHERE rma_case_id IS NOT NULL');
          }
          if (from < 20) {
            Future<void> addLayerColumn(String table, String column,
                Future<void> Function() add) async {
              final columns =
                  (await customSelect('PRAGMA table_info($table)').get())
                      .map((row) => row.read<String>('name'))
                      .toSet();
              if (columns.isNotEmpty && !columns.contains(column)) await add();
            }

            await addLayerColumn('products', 'pricing_policy',
                () => m.addColumn(products, products.pricingPolicy));
            await addLayerColumn(
                'stock_receiving_items',
                'unit_selling_price_cents',
                () => m.addColumn(stockReceivingItems,
                    stockReceivingItems.unitSellingPriceCents));
            await m.createTable(inventoryLayers);
            await m.createTable(saleItemInventoryAllocations);
            await addLayerColumn('serial_units', 'inventory_layer_id',
                () => m.addColumn(serialUnits, serialUnits.inventoryLayerId));
            // Historical sales have no reliable source. Assign surviving stock
            // to receipt lines conservatively, then record any unresolved stock
            // as a clearly labelled opening balance.
            final hasInventory = (await customSelect(
                        "SELECT name FROM sqlite_master WHERE type='table' AND name='inventory'")
                    .get())
                .isNotEmpty;
            if (hasInventory) {
              await customStatement('''
              INSERT INTO inventory_layers
                (id, product_id, receiving_item_id, source,
                 quantity_received_milli, quantity_remaining_milli,
                 unit_cost_cents, received_at, batch_number, expiry_date)
              SELECT 'receipt-' || ri.id, ri.product_id, ri.id, 'receiving',
                ri.quantity_milli,
                MIN(ri.quantity_milli, MAX(0,
                  COALESCE((SELECT quantity_milli FROM inventory i
                    WHERE i.product_id = ri.product_id), 0) -
                  COALESCE((SELECT SUM(earlier.quantity_milli)
                    FROM stock_receiving_items earlier
                    JOIN stock_receivings er ON er.id = earlier.receiving_id
                    JOIN stock_receivings current_receipt ON current_receipt.id = ri.receiving_id
                    WHERE earlier.product_id = ri.product_id AND
                     (er.received_at > current_receipt.received_at OR
                      (er.received_at = current_receipt.received_at AND earlier.id > ri.id))), 0))),
                ri.unit_cost_cents, r.received_at, ri.batch_number, ri.expiry_date
              FROM stock_receiving_items ri
              JOIN stock_receivings r ON r.id = ri.receiving_id
            ''');
              await customStatement('''
              UPDATE inventory_layers SET quantity_remaining_milli =
                (SELECT COUNT(*) * 1000 FROM serial_units s
                 WHERE s.receiving_item_id = inventory_layers.receiving_item_id
                   AND s.status IN ('available', 'reserved'))
              WHERE receiving_item_id IS NOT NULL AND product_id IN
                (SELECT id FROM products WHERE serial_tracking = 1)
            ''');
              await customStatement('''
              UPDATE inventory_layers SET quantity_remaining_milli =
                MIN(quantity_received_milli, MAX(0,
                  COALESCE((SELECT pl.quantity_milli FROM product_lots pl
                    WHERE pl.product_id = inventory_layers.product_id
                      AND pl.batch_number = inventory_layers.batch_number), 0) -
                  COALESCE((SELECT SUM(ri.quantity_milli)
                    FROM stock_receiving_items ri
                    JOIN stock_receivings r ON r.id = ri.receiving_id
                    WHERE ri.product_id = inventory_layers.product_id
                      AND ri.batch_number = inventory_layers.batch_number
                      AND (r.received_at > inventory_layers.received_at OR
                        (r.received_at = inventory_layers.received_at AND
                         ri.id > inventory_layers.receiving_item_id))), 0)))
              WHERE batch_number IS NOT NULL
            ''');
              await customStatement('''
              INSERT INTO inventory_layers
                (id, product_id, source, quantity_received_milli,
                 quantity_remaining_milli, unit_cost_cents, received_at,
                 batch_number, expiry_date)
              SELECT 'opening-lot-' || pl.id, pl.product_id, 'legacy_opening',
                pl.quantity_milli - COALESCE((SELECT SUM(l.quantity_remaining_milli)
                  FROM inventory_layers l WHERE l.product_id = pl.product_id
                    AND l.batch_number = pl.batch_number), 0),
                pl.quantity_milli - COALESCE((SELECT SUM(l.quantity_remaining_milli)
                  FROM inventory_layers l WHERE l.product_id = pl.product_id
                    AND l.batch_number = pl.batch_number), 0),
                COALESCE(p.cost_cents, 0), p.created_at,
                pl.batch_number, pl.expiry_date
              FROM product_lots pl JOIN products p ON p.id = pl.product_id
              WHERE pl.quantity_milli > COALESCE((SELECT SUM(l.quantity_remaining_milli)
                FROM inventory_layers l WHERE l.product_id = pl.product_id
                  AND l.batch_number = pl.batch_number), 0)
            ''');
              await customStatement('''
              INSERT INTO inventory_layers
                (id, product_id, source, quantity_received_milli,
                 quantity_remaining_milli, unit_cost_cents, received_at)
              SELECT 'opening-' || i.product_id, i.product_id, 'legacy_opening',
                i.quantity_milli - COALESCE((SELECT SUM(l.quantity_remaining_milli)
                  FROM inventory_layers l WHERE l.product_id = i.product_id), 0),
                i.quantity_milli - COALESCE((SELECT SUM(l.quantity_remaining_milli)
                  FROM inventory_layers l WHERE l.product_id = i.product_id), 0),
                COALESCE(p.cost_cents, 0), p.created_at
              FROM inventory i JOIN products p ON p.id = i.product_id
              WHERE i.quantity_milli > COALESCE((SELECT SUM(l.quantity_remaining_milli)
                FROM inventory_layers l WHERE l.product_id = i.product_id), 0)
            ''');
              await customStatement(
                  'UPDATE serial_units SET inventory_layer_id = '
                  "'receipt-' || receiving_item_id WHERE receiving_item_id IS NOT NULL");
            }
            if (from < 21) {
              await customStatement('PRAGMA defer_foreign_keys = ON');
              await customStatement(
                  '''CREATE TABLE serial_units_opening_migration (
                id TEXT NOT NULL PRIMARY KEY,
                product_id TEXT NOT NULL REFERENCES products(id),
                serial_number TEXT NOT NULL UNIQUE,
                status TEXT NOT NULL DEFAULT 'available',
                receiving_item_id TEXT REFERENCES stock_receiving_items(id),
                inventory_layer_id TEXT REFERENCES inventory_layers(id),
                sale_item_id TEXT REFERENCES sale_items(id),
                created_at INTEGER NOT NULL
              )''');
              await customStatement(
                  '''INSERT INTO serial_units_opening_migration
                SELECT id, product_id, serial_number, status, receiving_item_id,
                  inventory_layer_id, sale_item_id, created_at FROM serial_units''');
              await customStatement('DROP TABLE serial_units');
              await customStatement(
                  'ALTER TABLE serial_units_opening_migration RENAME TO serial_units');
            }
            await _createLayerIndexes(this);
            await _createInventoryGuards(this);
          }
          if (from < 22) {
            await m.createTable(rmaLifecycleEvents);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS rma_lifecycle_case_action '
                'ON rma_lifecycle_events (case_id, action)');
          }
          if (from < 23) {
            await m.createTable(serialWarrantySnapshots);
            await customStatement(
                'CREATE INDEX IF NOT EXISTS serial_warranty_unit_created '
                'ON serial_warranty_snapshots (serial_unit_id, created_at)');
          }
          if (from < 24) {
            final tables = await customSelect(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name='sales'")
                .get();
            if (tables.isNotEmpty) {
              final columns =
                  await customSelect('PRAGMA table_info(sales)').get();
              if (!columns
                  .any((row) => row.read<String>('name') == 'receipt_number')) {
                await customStatement(
                    'ALTER TABLE sales ADD COLUMN receipt_number TEXT');
              }
              await _createReceiptGuards(this);
            }
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA busy_timeout = 5000');
          final layerTables = await customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
                  "('stock_receiving_items','inventory_layers','sale_item_inventory_allocations')")
              .get();
          if (layerTables.length == 3) await _createInventoryGuards(this);
          final saleTables = await customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table' AND name='sales'")
              .get();
          if (saleTables.isNotEmpty) {
            final columns =
                await customSelect('PRAGMA table_info(sales)').get();
            if (columns
                .any((row) => row.read<String>('name') == 'receipt_number')) {
              await _createReceiptGuards(this);
            }
          }
        },
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final file = await AppDatabase.databaseFile();
    return NativeDatabase.createInBackground(file);
  });
}

String _uuid() {
  return const Uuid().v4();
}

Future<void> _createReceiptGuards(AppDatabase db) async {
  await db.customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS sales_receipt_number_unique '
      'ON sales (receipt_number) WHERE receipt_number IS NOT NULL');
  await db
      .customStatement('CREATE TRIGGER IF NOT EXISTS sales_receipt_immutable '
          'BEFORE UPDATE OF receipt_number ON sales '
          'WHEN OLD.receipt_number IS NOT NEW.receipt_number '
          "BEGIN SELECT RAISE(ABORT, 'Receipt number is immutable'); END");
}

Future<void> _createLayerIndexes(AppDatabase db) async {
  await db.customStatement('CREATE INDEX IF NOT EXISTS inventory_layers_fifo '
      'ON inventory_layers (product_id, received_at, id)');
  await db.customStatement('CREATE INDEX IF NOT EXISTS sale_allocations_item '
      'ON sale_item_inventory_allocations (sale_item_id)');
}

Future<void> _createInventoryGuards(AppDatabase db) async {
  await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS receiving_item_source_immutable '
      'BEFORE UPDATE OF receiving_id, product_id, quantity_milli, unit_cost_cents, '
      'unit_selling_price_cents, batch_number, expiry_date ON stock_receiving_items '
      "BEGIN SELECT RAISE(ABORT, 'Receiving source cannot be changed'); END");
  await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS receiving_item_no_delete '
      'BEFORE DELETE ON stock_receiving_items '
      "BEGIN SELECT RAISE(ABORT, 'Receiving source cannot be deleted'); END");
  await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS inventory_layer_source_immutable '
      'BEFORE UPDATE OF product_id, receiving_item_id, source, quantity_received_milli, '
      'unit_cost_cents, unit_selling_price_cents, batch_number, expiry_date, received_at '
      'ON inventory_layers '
      "BEGIN SELECT RAISE(ABORT, 'Inventory layer source cannot be changed'); END");
  await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS inventory_layer_no_delete '
      'BEFORE DELETE ON inventory_layers '
      "BEGIN SELECT RAISE(ABORT, 'Inventory layer cannot be deleted'); END");
  await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS sale_allocation_no_update '
      'BEFORE UPDATE ON sale_item_inventory_allocations '
      "BEGIN SELECT RAISE(ABORT, 'Sale allocation cannot be changed'); END");
  await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS sale_allocation_no_delete '
      'BEFORE DELETE ON sale_item_inventory_allocations '
      "BEGIN SELECT RAISE(ABORT, 'Sale allocation cannot be deleted'); END");
}

Future<void> _createBirGuards(AppDatabase db) async {
  await db.customStatement('CREATE TRIGGER IF NOT EXISTS bir_state_no_decrease '
      'BEFORE UPDATE ON bir_compliance_state WHEN '
      'NEW.highest_invoice_number < OLD.highest_invoice_number OR '
      'NEW.grand_total_cents < OLD.grand_total_cents OR '
      'NEW.highest_z_number < OLD.highest_z_number '
      "BEGIN SELECT RAISE(ABORT, 'BIR state cannot decrease'); END");
  await db.customStatement('CREATE TRIGGER IF NOT EXISTS bir_state_no_delete '
      'BEFORE DELETE ON bir_compliance_state '
      "BEGIN SELECT RAISE(ABORT, 'BIR state cannot be deleted'); END");
  await db.customStatement('CREATE TRIGGER IF NOT EXISTS z_readings_no_update '
      'BEFORE UPDATE ON z_readings '
      "BEGIN SELECT RAISE(ABORT, 'Z-reading cannot be changed'); END");
  await db.customStatement('CREATE TRIGGER IF NOT EXISTS z_readings_no_delete '
      'BEFORE DELETE ON z_readings '
      "BEGIN SELECT RAISE(ABORT, 'Z-reading cannot be deleted'); END");
  await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS bir_sale_invoice_no_change '
      'BEFORE UPDATE OF bir_invoice_number ON sales '
      'WHEN OLD.bir_invoice_number IS NOT NULL AND '
      'NEW.bir_invoice_number IS NOT OLD.bir_invoice_number '
      "BEGIN SELECT RAISE(ABORT, 'BIR invoice cannot be changed'); END");
}
