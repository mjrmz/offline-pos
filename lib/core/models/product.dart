class PosProduct {
  final String id;
  final String name;
  final String? barcode;
  final int priceCents;
  final bool isActive;
  final String? sku;
  final String? categoryId;
  final int costCents;
  const PosProduct(
      this.id, this.name, this.barcode, this.priceCents, this.isActive,
      [this.sku, this.categoryId, this.costCents = 0]);
}
