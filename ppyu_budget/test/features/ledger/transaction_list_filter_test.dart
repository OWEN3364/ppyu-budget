import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/models/transaction.dart';
import 'package:ppyu_budget/features/ledger/transaction_list_screen.dart';

LedgerTransaction _txn(
  String id, {
  String? memo,
  String? merchant,
  List<String> tagIds = const [],
}) =>
    LedgerTransaction(
      id: id,
      accountId: 'a1',
      categoryId: 'c1',
      memberId: 'm1',
      type: 'expense',
      amount: 1000,
      occurredAt: DateTime(2026, 8, 26),
      source: 'manual',
      memo: memo,
      merchant: merchant,
      tagIds: tagIds,
    );

List<String> _ids(List<LedgerTransaction> ts) => ts.map((t) => t.id).toList();

void main() {
  final all = [
    _txn('t1', memo: '점심 김밥', tagIds: const ['tag-a']),
    _txn('t2', merchant: '스타벅스', tagIds: const ['tag-b']),
    _txn('t3', memo: 'Taxi ride', merchant: 'KAKAO T'),
    _txn('t4', memo: '스타벅스 기프티콘', tagIds: const ['tag-a', 'tag-b']),
  ];

  test('no query and no tag selection returns everything', () {
    expect(_ids(filterTransactions(all, '', const {})), ['t1', 't2', 't3', 't4']);
  });

  test('query matches on memo', () {
    expect(_ids(filterTransactions(all, '김밥', const {})), ['t1']);
  });

  test('query matches on merchant', () {
    expect(_ids(filterTransactions(all, 'kakao', const {})), ['t3']);
  });

  test('query matching is case-insensitive', () {
    expect(_ids(filterTransactions(all, 'taxi', const {})), ['t3']);
  });

  test('tag filter is OR: any selected tag matches', () {
    expect(
      _ids(filterTransactions(all, '', {'tag-a', 'tag-b'})),
      ['t1', 't2', 't4'],
    );
  });

  test('a transaction with none of the selected tags is excluded', () {
    expect(_ids(filterTransactions(all, '', {'tag-b'})), ['t2','t4']);
    expect(_ids(filterTransactions(all, '', {'tag-zzz'})), isEmpty);
  });

  test('query and tag filter must both pass', () {
    // 스타벅스 matches t2 and t4, but only t4 carries tag-a
    expect(_ids(filterTransactions(all, '스타벅스', {'tag-a'})), ['t4']);
  });
}
