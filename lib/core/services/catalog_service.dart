import '../models/active_user.dart';
import '../../data/daos/pos_repository.dart';
import 'auth_service.dart';
import '../models/business_product.dart';

class CatalogService {
  final PosRepository repository;
  final AuthService auth;
  CatalogService(this.repository, this.auth);
  Future<String> addCategory(String name) async {
    final user = auth.requireSession(PosPermission.manageCatalog);
    await auth.repository.requireActive(user.id);
    return repository.addCategory(name);
  }

  Future<String> saveProduct(
      {String? id,
      required String name,
      String? sku,
      String? barcode,
      String? categoryId,
      required int priceCents,
      required int costCents,
      int startingStock = 0,
      int? startingStockMilli,
      int lowStockThreshold = 5,
      bool isActive = true,
      bool? serialTracking,
      List<String> openingSerials = const [],
      List<OpeningBatch> openingBatches = const [],
      int? openingCostCents,
      int? openingSellingPriceCents,
      String? pricingPolicy,
      String productType = 'standard',
      BusinessProduct? business,
      String? batchNumber,
      DateTime? batchExpiry}) async {
    final user = auth.requireSession(PosPermission.manageCatalog);
    await auth.repository.requireActive(user.id);
    return repository.saveProduct(
        id: id,
        name: name,
        sku: sku,
        barcode: barcode,
        categoryId: categoryId,
        priceCents: priceCents,
        costCents: costCents,
        startingStock: startingStock,
        startingStockMilli: startingStockMilli,
        lowStockThreshold: lowStockThreshold,
        isActive: isActive,
        serialTracking: serialTracking,
        openingSerials: openingSerials,
        openingBatches: openingBatches,
        openingCostCents: openingCostCents,
        openingSellingPriceCents: openingSellingPriceCents,
        pricingPolicy: pricingPolicy,
        productType: productType,
        business: business,
        batchNumber: batchNumber,
        batchExpiry: batchExpiry,
        actorId: user.id);
  }
}
