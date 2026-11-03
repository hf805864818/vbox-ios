/// 数据层模型：`search_history`（搜索历史）。
///
/// 唯一真相源：`contract/schema/schema_v1.sql`
/// 索引：idx_search_history_time(searchedAt DESC)（v3 新增）
library;


class SearchHistory {
  static const String table = 'search_history';

  const SearchHistory({
    this.id,
    required this.keyword,
    required this.searchedAt,
  });

  final int? id;
  final String keyword;
  final int searchedAt;

  Map<String, Object?> toMap() => <String, Object?>{
        if (id != null) 'id': id,
        'keyword': keyword,
        'searchedAt': searchedAt,
      };

  factory SearchHistory.fromMap(Map<String, Object?> m) => SearchHistory(
        id: m['id'] as int?,
        keyword: m['keyword'] as String,
        searchedAt: m['searchedAt'] as int,
      );

  SearchHistory copyWith({int? id, String? keyword, int? searchedAt}) =>
      SearchHistory(
        id: id ?? this.id,
        keyword: keyword ?? this.keyword,
        searchedAt: searchedAt ?? this.searchedAt,
      );
}
