import '../models/active_user.dart';
import '../../data/daos/pos_repository.dart';
import 'auth_service.dart';

class CatalogService {
  final PosRepository repository;
  final AuthService auth;
  CatalogService(this.repository, this.auth);
  Future<String> addCategory(String name) async {
    final user = auth.requireSession(PosPermission.manageCatalog);
    await auth.repository.requireActive(user.id);
    return repository.addCategory(name);
  }
  Future<String> saveProduct({String? id, required String name, String? sku, String? barcode, String? categoryId, required int priceCents, required int costCents, int startingStock = 0, int lowStockThreshold = 5, bool isActive = true}) async {
    final user = auth.requireSession(PosPermission.manageCatalog);
    await auth.repository.requireActive(user.id);
    return repository.saveProduct(id: id, name: name, sku: sku, barcode: barcode, categoryId: categoryId, priceCents: priceCents, costCents: costCents, startingStock: startingStock, lowStockThreshold: lowStockThreshold, isActive: isActive);
  }
}
