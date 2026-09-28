import 'product.dart';

class CartLine {
  final PosProduct product;
  int quantity;
  CartLine(this.product, this.quantity);
  int get totalCents => product.priceCents * quantity;
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
      _lines[product.id] = CartLine(product, 1);
    } else {
      line.quantity++;
    }
  }

  void setQuantity(String productId, int quantity) {
    if (quantity < 0) throw ArgumentError.value(quantity, 'quantity');
    if (!_lines.containsKey(productId)) {
      throw StateError('Product is not in cart');
    }
    if (quantity == 0) {
      _lines.remove(productId);
    } else {
      _lines[productId]!.quantity = quantity;
    }
  }

  void remove(String productId) => _lines.remove(productId);
  void clear() => _lines.clear();
}
