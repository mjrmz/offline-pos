/// A database page and its count under the same search and filter conditions.
class PagedResult<T> {
  const PagedResult({
    required this.items,
    required this.totalCount,
    required this.page,
    this.pageSize = 50,
  });

  final List<T> items;
  final int totalCount;
  final int page;
  final int pageSize;

  bool get hasPrevious => page > 0;
  bool get hasNext => (page + 1) * pageSize < totalCount;
}
