import '../models/active_user.dart';
import '../../data/daos/sales_repository.dart';
import 'auth_service.dart';

class SalesService {
  final SalesRepository repository;
  final AuthService auth;
  SalesService(this.repository, this.auth);
  Future<List<SaleSummary>> history() {
    return repository.history(auth.requireSession(PosPermission.viewOwnSales));
  }

  Future<SaleDetail> detail(String saleId) {
    return repository.detail(
        auth.requireSession(PosPermission.viewOwnSales), saleId);
  }

  Future<void> voidSale(String saleId) {
    return repository.reverse(
        auth.requireSession(PosPermission.reverseSale), saleId, 'void',
        stockRestored: true);
  }

  Future<void> refundSale(String saleId,
      {required bool returnToSellableStock}) {
    return repository.reverse(
        auth.requireSession(PosPermission.reverseSale), saleId, 'refund',
        stockRestored: returnToSellableStock);
  }

  Future<DailyReport> report(DateTime date) {
    return repository.report(auth.requireSession(PosPermission.reports), date);
  }
}
