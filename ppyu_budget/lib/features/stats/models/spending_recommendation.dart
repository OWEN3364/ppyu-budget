class SpendingRecommendation {
  const SpendingRecommendation({
    required this.categoryId,
    required this.categoryName,
    required this.currentAmount,
    required this.previousAmount,
    required this.changeRatio,
  });

  final String categoryId;
  final String categoryName;
  final int currentAmount;
  final int previousAmount;
  final double changeRatio;

  factory SpendingRecommendation.fromJson(Map<String, dynamic> json) => SpendingRecommendation(
        categoryId: json['category_id'] as String,
        categoryName: json['category_name'] as String,
        currentAmount: (json['current_amount'] as num).toInt(),
        previousAmount: (json['previous_amount'] as num).toInt(),
        changeRatio: (json['change_ratio'] as num).toDouble(),
      );
}
