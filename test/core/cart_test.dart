import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/core/models/cart.dart';
import 'package:modern_offline_pos/core/models/product.dart';

void main() {
  test('cart operations and integer totals', () {
    final cart = Cart();
    const coke = PosProduct('1', 'Coke', '123', 4000, true);
    cart.add(coke);
    cart.add(coke);
    expect(cart.lines.single.quantity, 2);
    expect(cart.subtotalCents, 8000);
    expect(cart.totalCents, 8000);
    cart.setQuantity('1', 3);
    expect(cart.totalCents, 12000);
    expect(() => cart.setQuantity('1', -1), throwsArgumentError);
    cart.setQuantity('1', 0);
    expect(cart.isEmpty, true);
    cart.add(coke);
    cart.remove('1');
    expect(cart.isEmpty, true);
    cart.add(coke);
    cart.clear();
    expect(cart.isEmpty, true);
    expect(() => cart.add(const PosProduct('2', 'Inactive', null, 100, false)),
        throwsStateError);
  });
}
