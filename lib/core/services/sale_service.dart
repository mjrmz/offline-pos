import '../models/cart.dart';
import '../../data/daos/pos_repository.dart';
import '../models/active_user.dart';
import 'auth_service.dart';
import '../models/manual_discount.dart';
import '../../data/daos/promotion_repository.dart';
import 'promotion_checkout_service.dart';

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
  Future<int> _promotionDiscount(
      ActiveUser user, Cart cart, ManualDiscount? manualDiscount) async {
    if (manualDiscount != null) return 0;
    final result =
        await PromotionCheckoutService(PromotionRepository(repository.db))
            .evaluate(user, cart, DateTime.now());
    return result.totalDiscountCents;
  }

  Future<SaleResult> checkoutCredit(
      Cart cart, String customerId, int cashPaidCents,
      {ManualDiscount? manualDiscount, String? heldReference,
      String? salesOrderId}) async {
    final user = auth.requireSession(PosPermission.sell);
    if (_inFlight) throw StateError('Checkout is already in progress');
    _inFlight = true;
    try {
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
      final promotionDiscount = salesOrderId == null
          ? await _promotionDiscount(user, cart, manualDiscount) : 0;
      if (cashPaidCents < 0 ||
          cashPaidCents >=
              cart.totalCents - discountEffect - promotionDiscount) {
        throw StateError('Cash portion must be below the sale total');
      }
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
          manualDiscount: manualDiscount, heldReference: heldReference,
          salesOrderId: salesOrderId);
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
      String? heldReference,
      String? salesOrderId}) async {
    final user = auth.requireSession(PosPermission.sell);
    if (_inFlight) throw StateError('Checkout is already in progress');
    _inFlight = true;
    try {
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
      final promotionDiscount = salesOrderId == null
          ? await _promotionDiscount(user, cart, manualDiscount) : 0;
      if (cashReceivedCents <
          cart.totalCents -
              rewardDiscountCents -
              discountEffect -
              promotionDiscount) {
        throw StateError('Insufficient cash');
      }
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
          heldReference: heldReference,
          salesOrderId: salesOrderId);
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
