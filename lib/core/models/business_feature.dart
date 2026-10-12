enum BusinessFeature {
  weightBasedPricing(
      'Products sold by weight', 'Price and sell fractional weights.'),
  containerRefillPricing('Water refills / containers',
      'Price a refill separately from its container.'),
  tankDepositExchange(
      'LPG tanks / exchanges', 'Track exchange and deposit choices.'),
  expiryBatchTracking(
      'Products with batch or expiry dates', 'Track separate stock batches.'),
  unitOfMeasureVariety(
      'Products sold in different units', 'Choose each product’s sale unit.'),
  madeToOrderTracking(
      'Made-to-order products', 'Distinguish orders from stocked items.');

  const BusinessFeature(this.displayName, this.description);
  final String displayName;
  final String description;
}
