class LedgerTransaction {
  const LedgerTransaction({
    required this.id,
    required this.accountId,
    required this.categoryId,
    required this.memberId,
    required this.type,
    required this.amount,
    required this.occurredAt,
    required this.source,
    this.memo,
    this.merchant,
  });

  final String id;
  final String accountId;
  final String categoryId;
  final String memberId;
  final String type;
  final int amount;
  final DateTime occurredAt;
  final String source;
  final String? memo;
  final String? merchant;

  factory LedgerTransaction.fromJson(Map<String, dynamic> json) => LedgerTransaction(
        id: json['id'] as String,
        accountId: json['account_id'] as String,
        categoryId: json['category_id'] as String,
        memberId: json['member_id'] as String,
        type: json['type'] as String,
        amount: json['amount'] as int,
        occurredAt: DateTime.parse(json['occurred_at'] as String),
        source: json['source'] as String,
        memo: json['memo'] as String?,
        merchant: json['merchant'] as String?,
      );
}
