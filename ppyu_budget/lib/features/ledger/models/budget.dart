class Budget {
  const Budget({
    required this.id,
    required this.month,
    required this.amount,
    this.categoryId,
  });

  final String id;
  final String? categoryId;
  final DateTime month;
  final int amount;

  factory Budget.fromJson(Map<String, dynamic> json) => Budget(
        id: json['id'] as String,
        categoryId: json['category_id'] as String?,
        month: DateTime.parse(json['month'] as String),
        amount: json['amount'] as int,
      );
}
