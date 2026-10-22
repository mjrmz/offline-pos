import '../models/cart.dart';
import '../../data/daos/pos_repository.dart';
import '../models/active_user.dart';
import 'auth_service.dart';
import '../models/manual_discount.dart';

class SaleResult {
  final String saleId;
  final int totalCents;
  final int changeCents;
  final bool protectionWarning;
  const SaleResult(this.saleId, this.totalCents, this.changeCents,
      [this.protectionWarning = false]);
}

class SaleService {
  final PosRepository repository;
  final AuthService auth;
  bool _inFlight = false;
  SaleService(this.repository, this.auth);
  Future<SaleResult> checkoutCredit(
      Cart cart, String customerId, int cashPaidCents,
      {ManualDiscount? manualDiscount, String? heldReference}) async {
    final user = auth.requireSession(PosPermission.sell);
    if (_inFlight) throw StateError('Checkout is already in progress');
    if (cart.isEmpty || cart.totalCents <= 0) {
      throw StateError('Cart requires a positive total');
    }
    final discountEffect = manualDiscount == null
        ? 0
        : manualDiscount.effectOn(manualDiscount.scope == 'line'
            ? cart.lines
                .where((l) => l.id == manualDiscount.lineKey)
                .fold<int>(0, (sum, l) => sum + l.totalCents)
            : cart.totalCents);
    if (cashPaidCents < 0 ||
        cashPaidCents >= cart.totalCents - discountEffect) {
      throw StateError('Cash portion must be below the sale total');
    }
    _inFlight = true;
    try {
      final items = cart.lines
          .map((line) => SaleLineRequest(line.product.id, line.quantity,
              quantityMilli: line.quantityMilli,
              lineKey: line.id,
              mode: line.mode,
              batchId: line.batchId,
              serialIds: line.serialIds))
          .toList();
      final committed = await repository.completeCreditSale(
          items, cashPaidCents, customerId, user.id,
          manualDiscount: manualDiscount, heldReference: heldReference);
      cart.clear();
      return SaleResult(committed.saleId, committed.totalCents, 0,
          committed.protectionWarning);
    } finally {
      _inFlight = false;
    }
  }

  Future<SaleResult> checkout(Cart cart, int cashReceivedCents,
      {String? quotationId,
      String? customerId,
      int redeemPoints = 0,
      int rewardDiscountCents = 0,
      ManualDiscount? manualDiscount,
      String? walkInName,
      String? walkInContact,
      String? heldReference}) async {
    final user = auth.requireSession(PosPermission.sell);
    if (_inFlight) throw StateError('Checkout is already in progress');
    if (cart.isEmpty) throw StateError('Cart is empty');
    if (cart.totalCents <= 0) throw StateError('Sale total must be positive');
    if (cashReceivedCents < 0) {
      throw StateError('Cash received cannot be negative');
    }
    final discountEffect = manualDiscount == null
        ? 0
        : manualDiscount.effectOn(manualDiscount.scope == 'line'
            ? cart.lines
                .where((l) => l.id == manualDiscount.lineKey)
                .fold<int>(0, (sum, l) => sum + l.totalCents)
            : cart.totalCents);
    if (cashReceivedCents <
        cart.totalCents - rewardDiscountCents - discountEffect) {
      throw StateError('Insufficient cash');
    }
    _inFlight = true;
    try {
      final items = cart.lines
          .map((line) => SaleLineRequest(line.product.id, line.quantity,
              quantityMilli: line.quantityMilli,
              lineKey: line.id,
              mode: line.mode,
              batchId: line.batchId,
              serialIds: line.serialIds))
          .toList();
      final committed = await repository.completeCashSale(
          items, cashReceivedCents, user.id,
          quotationId: quotationId,
          customerId: customerId,
          redeemPoints: redeemPoints,
          manualDiscount: manualDiscount,
          walkInName: walkInName,
          walkInContact: walkInContact,
          heldReference: heldReference);
      cart.clear();
      return SaleResult(
          committed.saleId,
          committed.totalCents,
          cashReceivedCents - committed.totalCents,
          committed.protectionWarning);
    } finally {
      _inFlight = false;
    }
  }
}
