class CategorySummary {
  const CategorySummary({
    required this.categoryId,
    required this.categoryName,
    required this.type,
    required this.totalAmount,
  });

  final String categoryId;
  final String categoryName;
  final String type;
  final int totalAmount;

  factory CategorySummary.fromJson(Map<String, dynamic> json) => CategorySummary(
        categoryId: json['category_id'] as String,
        categoryName: json['category_name'] as String,
        type: json['type'] as String,
        totalAmount: (json['total_amount'] as num).toInt(),
      );
}
