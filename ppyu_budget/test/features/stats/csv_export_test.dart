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

  test('starts with a UTF-8 BOM so Excel on Windows reads it as UTF-8', () {
    final csv = buildTransactionsCsv(
      transactions: const [],
      accountNames: const {},
      categoryNames: const {},
      tagNames: const {},
      memberNicknames: const {},
    );

    expect(csv.codeUnitAt(0), 0xFEFF);
    expect(csv, startsWith('\u{FEFF}날짜,'));
  });

  test('formats the timestamp as yyyy-MM-dd HH:mm, not ISO8601', () {
    final csv = buildTransactionsCsv(
      transactions: [
        LedgerTransaction(
          id: 't1',
          accountId: 'a1',
          categoryId: 'c1',
          memberId: 'm1',
          type: 'expense',
          amount: 1000,
          // local (not utc) so the expected string is timezone-independent
          occurredAt: DateTime(2026, 8, 26, 14, 33),
          source: 'manual',
        ),
      ],
      accountNames: const {},
      categoryNames: const {},
      tagNames: const {},
      memberNicknames: const {},
    );

    expect(csv, contains('2026-08-26 14:33'));
    expect(csv, isNot(contains('T14:33')));
    expect(csv, isNot(contains('.000')));
  });
}
