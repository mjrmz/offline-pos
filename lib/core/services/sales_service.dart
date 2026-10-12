import '../models/active_user.dart';
import '../../data/daos/sales_repository.dart';
import 'auth_service.dart';

class SalesService {
  final SalesRepository repository;
  final AuthService auth;
  SalesService(this.repository, this.auth);
  Future<Set<String>> searchSaleIds(String query) {
    auth.requireSession(PosPermission.viewOwnSales);
    return repository.searchSaleIds(query);
  }

  Future<List<SaleSummary>> history() {
    return repository.history(auth.requireSession(PosPermission.viewOwnSales));
  }

  Future<SaleDetail> detail(String saleId) {
    return repository.detail(
        auth.requireSession(PosPermission.viewOwnSales), saleId);
  }

  Future<List<MadeOrderSummary>> madeOrders() =>
      repository.madeOrders(auth.requireSession(PosPermission.manageCatalog));

  Future<void> advanceMadeOrder(String id) => repository.advanceMadeOrder(
      auth.requireSession(PosPermission.manageCatalog), id);

  Future<void> voidSale(String saleId, {bool cashRefundConfirmed = false}) {
    return repository.reverse(
        auth.requireSession(PosPermission.reverseSale), saleId, 'void',
        stockRestored: true, cashRefundConfirmed: cashRefundConfirmed);
  }

  Future<void> refundSale(String saleId,
      {required bool returnToSellableStock, bool cashRefundConfirmed = false}) {
    return repository.reverse(
        auth.requireSession(PosPermission.reverseSale), saleId, 'refund',
        stockRestored: returnToSellableStock,
        cashRefundConfirmed: cashRefundConfirmed);
  }

  Future<DailyReport> report(DateTime date) {
    return repository.report(auth.requireSession(PosPermission.reports), date);
  }
}
