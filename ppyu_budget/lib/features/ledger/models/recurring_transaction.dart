class RecurringTransaction {
  const RecurringTransaction({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.createdBy,
    required this.ownerMemberId,
    required this.type,
    required this.amount,
    required this.intervalRule,
    required this.startAt,
    required this.autoRegister,
    this.memo,
  });

  final String id;
  final String accountId;
  final String categoryId;
  final String createdBy;
  final String ownerMemberId;
  final String type;
  final int amount;
  final String intervalRule;
  final DateTime startAt;
  final bool autoRegister;
  final String? memo;

  factory RecurringTransaction.fromJson(Map<String, dynamic> json) => RecurringTransaction(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        categoryId: json['category_id'] as String,
        createdBy: json['created_by'] as String,
        ownerMemberId: json['owner_member_id'] as String,
        type: json['type'] as String,
        amount: json['amount'] as int,
        intervalRule: json['interval_rule'] as String,
        // See Global Constraints: PostgREST returns timestamptz with a UTC
        // suffix — .toLocal() keeps every downstream date calculation and
        // display consistent.
        startAt: DateTime.parse(json['start_at'] as String).toLocal(),
        autoRegister: json['auto_register'] as bool,
        memo: json['memo'] as String?,
      );
}
