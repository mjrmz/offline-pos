import 'business_product.dart';

class PosProduct {
  final String id;
  final String name;
  final String? barcode;
  final int priceCents;
  final bool isActive;
  final String? sku;
  final String? categoryId;
  final int costCents;
  final int lowStockThreshold;
  final BusinessProduct business;
  final bool serialTracking;
  final String pricingPolicy;
  final String productType;
  const PosProduct(
      this.id, this.name, this.barcode, this.priceCents, this.isActive,
      [this.sku,
      this.categoryId,
      this.costCents = 0,
      this.lowStockThreshold = 5,
      this.business = const BusinessProduct(),
      this.serialTracking = false,
      this.pricingPolicy = 'current',
      this.productType = 'standard']);
}
