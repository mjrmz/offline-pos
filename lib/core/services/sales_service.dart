import '../models/active_user.dart';
import '../../data/daos/sales_repository.dart';
import 'auth_service.dart';

class SalesService {
  final SalesRepository repository;
  final AuthService auth;
  final DateTime Function() now;
  SalesService(this.repository, this.auth, {DateTime Function()? clock})
      : now = clock ?? DateTime.now;
  Future<List<SaleSummary>> history() {
    return repository.history(auth.requireSession(PosPermission.viewOwnSales));
  }

  Future<SaleDetail> detail(String saleId) {
    return repository.detail(
        auth.requireSession(PosPermission.viewOwnSales), saleId);
  }

  Future<void> voidSale(String saleId) {
    return repository.reverse(
        auth.requireSession(PosPermission.reverseSale), saleId, 'void', now());
  }

  Future<void> refundSale(String saleId) {
    return repository.reverse(auth.requireSession(PosPermission.reverseSale),
        saleId, 'refund', now());
  }

  Future<DailyReport> report(DateTime date) {
    return repository.report(auth.requireSession(PosPermission.reports), date);
  }
}
