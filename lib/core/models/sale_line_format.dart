import 'quantity.dart';

String saleQuantityLabel(int quantityMilli, String unit) =>
    '${Quantity.format(quantityMilli)} $unit';

String saleModeLabel(String mode, {String? batchNumber}) {
  final parts = <String>[];
  switch (mode) {
    case 'exchange':
      parts.add('Empty tank returned');
    case 'deposit':
      parts.add('New tank + deposit');
    case 'refill':
      parts.add('Refill');
    case 'container':
      parts.add('Refill + container');
    case 'made_order':
      parts.add('Made to order');
  }
  if (batchNumber != null) parts.add('Batch $batchNumber');
  return parts.join(' · ');
}
