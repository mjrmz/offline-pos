import '../models/cart.dart';
import '../../data/daos/pos_repository.dart';

class SaleResult {
  final String saleId;
  final int totalCents;
  final int changeCents;
  const SaleResult(this.saleId, this.totalCents, this.changeCents);
}

class SaleService {
  final PosRepository repository;
  bool _inFlight = false;
  SaleService(this.repository);
  Future<SaleResult> checkout(Cart cart, int cashReceivedCents) async {
    if (_inFlight) throw StateError('Checkout is already in progress');
    if (cart.isEmpty) throw StateError('Cart is empty');
    if (cashReceivedCents < cart.totalCents) {
      throw StateError('Insufficient cash');
    }
    _inFlight = true;
    try {
      final items = cart.lines
          .map((line) => SaleLineRequest(line.product.id, line.quantity))
          .toList();
      final committed =
          await repository.completeCashSale(items, cashReceivedCents);
      cart.clear();
      return SaleResult(committed.saleId, committed.totalCents,
          cashReceivedCents - committed.totalCents);
    } finally {
      _inFlight = false;
    }
  }
}
