import '../models/active_user.dart';
import '../models/cart.dart';
import '../models/promotion_evaluation.dart';
import '../../data/daos/promotion_repository.dart';
import 'promotion_engine.dart';

/// Read-only POS preview. The repository recalculates from resolved sale lines
/// in the checkout transaction before any amount is committed.
class PromotionCheckoutService {
  final PromotionRepository repository;
  const PromotionCheckoutService(this.repository);

  Future<PromotionEvaluationResult> evaluate(
      ActiveUser user, Cart cart, DateTime at) async {
    final context = PromotionEvaluationContext(
        at: at,
        lines: [
          for (final line in cart.lines)
            PromotionCartLine(
                id: line.id,
                productId: line.product.id,
                categoryId: line.product.categoryId,
                quantityMilli: line.quantityMilli,
                unitPriceCents: line.product.priceCents,
                subtotalCents: line.totalCents,
                merchandise: line.mode == 'ordinary')
        ],
        subtotalCents: cart.subtotalCents);
    final candidates = await repository.getPromotionCandidates(user, at);
    return const PromotionEngine().evaluate(context, candidates);
  }
}
