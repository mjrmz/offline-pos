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

  test('specialty configurations and serials remain separate', () {
    final cart = Cart();
    const tank = PosProduct('tank', 'LPG', null, 10000, true);
    const refill = PosProduct('refill', 'Water', null, 2000, true);
    const serialized = PosProduct('serial', 'Board', null, 50000, true);
    const made = PosProduct('made', 'Custom', null, 30000, true);
    final exchange = cart.addSpecial(tank, 1000, mode: 'exchange');
    final deposit =
        cart.addSpecial(tank, 1000, mode: 'deposit', extraCents: 5000);
    cart.addSpecial(refill, 1000, mode: 'refill');
    cart.addSpecial(refill, 1000, mode: 'container', extraCents: 1000);
    cart.addSpecial(serialized, 1000, serialIds: ['S1']);
    cart.addSpecial(serialized, 1000, serialIds: ['S2']);
    cart.addSpecial(made, 1000, mode: 'made_order');
    cart.addSpecial(made, 2000, mode: 'made_order');
    expect(cart.lines.length, 8);
    expect(exchange.id, isNot(deposit.id));
    cart.remove(exchange.id);
    expect(cart.lines.where((line) => line.product.id == 'tank').single.mode,
        'deposit');
  });
}
