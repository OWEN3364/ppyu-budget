import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/stats/csv_export.dart';

void main() {
  test('builds a CSV row per transaction with resolved names', () {
    final csv = buildTransactionsCsv(
      transactions: [
        LedgerTransaction(
          id: 't1',
          accountId: 'a1',
          categoryId: 'c1',
          memberId: 'm1',
          type: 'expense',
          amount: 12000,
          occurredAt: DateTime.utc(2026, 8, 26, 14, 33),
          source: 'manual',
          merchant: '스타벅스',
          tagIds: const ['tag1'],
        ),
      ],
      accountNames: const {'a1': '신한카드'},
      categoryNames: const {'c1': '식비'},
      tagNames: const {'tag1': '카페'},
      memberNicknames: const {'m1': '민수'},
    );

    final lines = csv.trim().split('\n');
    expect(lines, hasLength(2));
    expect(lines[1], contains('지출'));
    expect(lines[1], contains('12000'));
    expect(lines[1], contains('신한카드'));
    expect(lines[1], contains('식비'));
    expect(lines[1], contains('스타벅스'));
    expect(lines[1], contains('카페'));
    expect(lines[1], contains('민수'));
  });

  test('quotes a field containing a comma', () {
    final csv = buildTransactionsCsv(
      transactions: [
        LedgerTransaction(
          id: 't1',
          accountId: 'a1',
          categoryId: 'c1',
          memberId: 'm1',
          type: 'expense',
          amount: 1000,
          occurredAt: DateTime.utc(2026, 8, 26),
          source: 'manual',
          memo: '점심, 저녁',
        ),
      ],
      accountNames: const {'a1': '카드'},
      categoryNames: const {'c1': '식비'},
      tagNames: const {},
      memberNicknames: const {},
    );

    expect(csv, contains('"점심, 저녁"'));
  });
}
