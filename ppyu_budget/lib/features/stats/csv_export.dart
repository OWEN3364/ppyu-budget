import 'package:ppyu_budget/features/ledger/models/transaction.dart';

String buildTransactionsCsv({
  required List<LedgerTransaction> transactions,
  required Map<String, String> accountNames,
  required Map<String, String> categoryNames,
  required Map<String, String> tagNames,
  required Map<String, String> memberNicknames,
}) {
  // Leading BOM: without it Excel on Windows opens a UTF-8 CSV in the system
  // ANSI codepage and every Korean string comes out as mojibake.
  final buffer = StringBuffer('\u{FEFF}날짜,구분,금액,계좌,카테고리,사용처,메모,태그,입력자\n');
  for (final t in transactions) {
    final tagLabel = t.tagIds.map((id) => tagNames[id] ?? '').where((n) => n.isNotEmpty).join('/');
    final fields = [
      _formatTimestamp(t.occurredAt),
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

// Excel reads an ISO8601 timestamp as plain text; "yyyy-MM-dd HH:mm" it parses
// as a date, so the exported ledger stays sortable/filterable.
String _formatTimestamp(DateTime dt) {
  final local = dt.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final mm = local.month.toString().padLeft(2, '0');
  final dd = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final min = local.minute.toString().padLeft(2, '0');
  return '$y-$mm-$dd $hh:$min';
}
