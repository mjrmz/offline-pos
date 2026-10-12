import 'business_feature.dart';

enum SaleUnit {
  piece('pcs', false),
  kilogram('kg', true),
  gram('g', true),
  meter('m', true),
  centimeter('cm', true),
  liter('L', true),
  milliliter('mL', true),
  box('box', false),
  pack('pack', false),
  roll('roll', false),
  bottle('bottle', false);

  const SaleUnit(this.label, this.fractional);
  final String label;
  final bool fractional;
}

class BusinessProduct {
  final SaleUnit unit;
  final bool weight;
  final bool refill;
  final int containerPriceCents;
  final bool tank;
  final int depositCents;
  final bool batch;
  final bool madeToOrder;

  const BusinessProduct({
    this.unit = SaleUnit.piece,
    this.weight = false,
    this.refill = false,
    this.containerPriceCents = 0,
    this.tank = false,
    this.depositCents = 0,
    this.batch = false,
    this.madeToOrder = false,
  });

  bool get fractional => weight || unit.fractional;

  void validate(int priceCents) {
    if (weight && unit != SaleUnit.kilogram && unit != SaleUnit.gram) {
      throw ArgumentError('Weight products must use kg or g');
    }
    if ((weight || refill || tank) && priceCents <= 0) {
      throw ArgumentError('Specialty price must be positive');
    }
    if (containerPriceCents < 0 || depositCents < 0) {
      throw ArgumentError('Extra price cannot be negative');
    }
    if (refill && tank) {
      throw ArgumentError('Refill and tank modes cannot overlap');
    }
    if ((refill || tank) && unit.fractional) {
      throw ArgumentError('Refill and tank quantities must be whole');
    }
    if (batch && madeToOrder) {
      throw ArgumentError('Batch and made-to-order modes cannot overlap');
    }
    if (madeToOrder && (refill || tank)) {
      throw ArgumentError('Made-to-order cannot overlap refill or tank mode');
    }
  }

  Map<BusinessFeature, Map<String, Object?>> toFeatureMaps() => {
        BusinessFeature.weightBasedPricing: {
          'enabled': weight,
          'unit': unit.name
        },
        BusinessFeature.containerRefillPricing: {
          'enabled': refill,
          'containerPriceCents': containerPriceCents,
          'unit': unit.name,
        },
        BusinessFeature.tankDepositExchange: {
          'enabled': tank,
          'depositCents': depositCents,
        },
        BusinessFeature.expiryBatchTracking: {'enabled': batch},
        BusinessFeature.unitOfMeasureVariety: {
          'enabled': unit != SaleUnit.piece,
          'unit': unit.name,
        },
        BusinessFeature.madeToOrderTracking: {'enabled': madeToOrder},
      };

  factory BusinessProduct.fromFeatureMaps(
      Map<BusinessFeature, Map<String, Object?>> maps) {
    final weight = maps[BusinessFeature.weightBasedPricing] ?? {};
    final uom = maps[BusinessFeature.unitOfMeasureVariety] ?? {};
    final refill = maps[BusinessFeature.containerRefillPricing] ?? {};
    final unitName = (weight['enabled'] == true ? weight['unit'] : null) ??
        (refill['enabled'] == true ? refill['unit'] : null) ??
        (uom['enabled'] == true ? uom['unit'] : null);
    return BusinessProduct(
      unit: SaleUnit.values.where((u) => u.name == unitName).firstOrNull ??
          SaleUnit.piece,
      weight: weight['enabled'] == true,
      refill: maps[BusinessFeature.containerRefillPricing]?['enabled'] == true,
      containerPriceCents: (maps[BusinessFeature.containerRefillPricing]
                  ?['containerPriceCents'] as num?)
              ?.toInt() ??
          0,
      tank: maps[BusinessFeature.tankDepositExchange]?['enabled'] == true,
      depositCents:
          (maps[BusinessFeature.tankDepositExchange]?['depositCents'] as num?)
                  ?.toInt() ??
              0,
      batch: maps[BusinessFeature.expiryBatchTracking]?['enabled'] == true,
      madeToOrder:
          maps[BusinessFeature.madeToOrderTracking]?['enabled'] == true,
    );
  }
}
