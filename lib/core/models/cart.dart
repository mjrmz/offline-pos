import 'product.dart';
import 'quantity.dart';

class CartLine {
  final PosProduct product;
  int quantityMilli;
  String mode;
  String? batchId;
  List<String> serialIds;
  int extraCents;
  int? pricedTotalCents;
  CartLine(this.product, this.quantityMilli,
      {this.mode = 'ordinary',
      this.batchId,
      this.extraCents = 0,
      this.serialIds = const []});
  int get quantity => quantityMilli ~/ Quantity.scale;
  int get totalCents => pricedTotalCents ??
      Quantity.lineCents(product.priceCents, quantityMilli) +
      extraCents * quantity;
}

class Cart {
  final Map<String, CartLine> _lines = {};
  List<CartLine> get lines => List.unmodifiable(_lines.values);
  bool get isEmpty => _lines.isEmpty;
  int get subtotalCents =>
      _lines.values.fold(0, (sum, line) => sum + line.totalCents);
  int get totalCents => subtotalCents;
  void add(PosProduct product) {
    if (!product.isActive || product.priceCents < 0) {
      throw StateError('Product is not sellable');
    }
    final line = _lines[product.id];
    if (line == null) {
      _lines[product.id] = CartLine(product, Quantity.scale);
    } else {
      line.quantityMilli += Quantity.scale;
      line.pricedTotalCents = null;
    }
  }

  void addSpecial(PosProduct product, int quantityMilli,
      {String mode = 'ordinary',
      String? batchId,
      int extraCents = 0,
      List<String> serialIds = const []}) {
    if (!product.isActive || product.priceCents < 0 || quantityMilli <= 0) {
      throw StateError('Invalid specialty item');
    }
    if (!product.business.fractional && quantityMilli % Quantity.scale != 0) {
      throw StateError('This product requires a whole quantity');
    }
    _lines[product.id] = CartLine(product, quantityMilli,
        mode: mode,
        batchId: batchId,
        extraCents: extraCents,
        serialIds: List.unmodifiable(serialIds));
  }

  void setQuantity(String productId, int quantity) {
    if (quantity < 0) throw ArgumentError.value(quantity, 'quantity');
    if (!_lines.containsKey(productId)) {
      throw StateError('Product is not in cart');
    }
    if (quantity == 0) {
      _lines.remove(productId);
    } else {
      _lines[productId]!.quantityMilli = quantity * Quantity.scale;
      _lines[productId]!.pricedTotalCents = null;
    }
  }

  void setQuantityMilli(String productId, int quantityMilli) {
    final line = _lines[productId];
    if (line == null) throw StateError('Product is not in cart');
    if (quantityMilli < 0) throw ArgumentError.value(quantityMilli);
    if (!line.product.business.fractional &&
        quantityMilli % Quantity.scale != 0) {
      throw StateError('This product requires a whole quantity');
    }
    if (quantityMilli == 0) {
      remove(productId);
    } else {
      line.quantityMilli = quantityMilli;
      line.pricedTotalCents = null;
    }
  }

  void remove(String productId) => _lines.remove(productId);
  void clear() => _lines.clear();
}
