class RecurringTransaction {
  const RecurringTransaction({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.createdBy,
    required this.type,
    required this.amount,
    required this.intervalRule,
    required this.nextRunAt,
    this.memo,
  });

  final String id;
  final String accountId;
  final String categoryId;
  final String createdBy;
  final String type;
  final int amount;
  final String intervalRule;
  final DateTime nextRunAt;
  final String? memo;

  factory RecurringTransaction.fromJson(Map<String, dynamic> json) => RecurringTransaction(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        categoryId: json['category_id'] as String,
        createdBy: json['created_by'] as String,
        type: json['type'] as String,
        amount: json['amount'] as int,
        intervalRule: json['interval_rule'] as String,
        // See Global Constraints: PostgREST returns timestamptz with a UTC
        // suffix — .toLocal() here is what keeps every downstream date
        // calculation and display consistent (this is the exact bug class
        // caught in the shared-calendar phase; fixed at the model boundary
        // from the start this time).
        nextRunAt: DateTime.parse(json['next_run_at'] as String).toLocal(),
        memo: json['memo'] as String?,
      );
}
