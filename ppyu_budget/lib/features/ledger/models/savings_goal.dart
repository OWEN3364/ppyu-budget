class SavingsGoal {
  const SavingsGoal({
    required this.id,
    required this.name,
    required this.targetAmount,
    required this.currentAmount,
    this.targetDate,
  });

  final String id;
  final String name;
  final int targetAmount;
  final int currentAmount;
  final DateTime? targetDate;

  factory SavingsGoal.fromJson(Map<String, dynamic> json) => SavingsGoal(
        id: json['id'] as String,
        name: json['name'] as String,
        targetAmount: json['target_amount'] as int,
        currentAmount: json['current_amount'] as int,
        targetDate: json['target_date'] == null
            ? null
            : DateTime.parse(json['target_date'] as String),
      );
}
