import 'package:ppyu_budget/features/ledger/models/transaction.dart';

String buildTransactionsCsv({
  required List<LedgerTransaction> transactions,
  required Map<String, String> accountNames,
  required Map<String, String> categoryNames,
  required Map<String, String> tagNames,
  required Map<String, String> memberNicknames,
}) {
  final buffer = StringBuffer('날짜,구분,금액,계좌,카테고리,사용처,메모,태그,입력자\n');
  for (final t in transactions) {
    final tagLabel = t.tagIds.map((id) => tagNames[id] ?? '').where((n) => n.isNotEmpty).join('/');
    final fields = [
      t.occurredAt.toLocal().toIso8601String(),
      t.type == 'expense' ? '지출' : '수입',
      t.amount.toString(),
      accountNames[t.accountId] ?? '',
      categoryNames[t.categoryId] ?? '',
      t.merchant ?? '',
      t.memo ?? '',
      tagLabel,
      memberNicknames[t.memberId] ?? '가족 구성원',
    ];
    buffer.writeln(fields.map(_csvField).join(','));
  }
  return buffer.toString();
}

String _csvField(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}
