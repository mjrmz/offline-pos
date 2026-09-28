import '../models/cart.dart';
import '../../data/daos/pos_repository.dart';
import '../models/active_user.dart';
import 'auth_service.dart';

class SaleResult {
  final String saleId;
  final int totalCents;
  final int changeCents;
  const SaleResult(this.saleId, this.totalCents, this.changeCents);
}

class SaleService {
  final PosRepository repository;
  final AuthService auth;
  bool _inFlight = false;
  SaleService(this.repository, this.auth);
  Future<SaleResult> checkout(Cart cart, int cashReceivedCents) async {
    final user = auth.requireSession(PosPermission.sell);
    if (_inFlight) throw StateError('Checkout is already in progress');
    if (cart.isEmpty) throw StateError('Cart is empty');
    if (cart.totalCents <= 0) throw StateError('Sale total must be positive');
    if (cashReceivedCents <= 0) {
      throw StateError('Cash received must be positive');
    }
    if (cashReceivedCents < cart.totalCents) {
      throw StateError('Insufficient cash');
    }
    _inFlight = true;
    try {
      final items = cart.lines
          .map((line) => SaleLineRequest(line.product.id, line.quantity))
          .toList();
      final committed =
          await repository.completeCashSale(items, cashReceivedCents, user.id);
      cart.clear();
      return SaleResult(committed.saleId, committed.totalCents,
          cashReceivedCents - committed.totalCents);
    } finally {
      _inFlight = false;
    }
  }
}
