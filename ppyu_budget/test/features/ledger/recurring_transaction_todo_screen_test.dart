import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/ledger/models/recurring_transaction.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_todo_screen.dart';

RecurringTransaction _template({
  required String id,
  required String ownerMemberId,
  bool autoRegister = false,
}) =>
    RecurringTransaction(
      id: id,
      accountId: 'account-1',
      categoryId: 'category-1',
      createdBy: 'member-1',
      ownerMemberId: ownerMemberId,
      type: 'expense',
      amount: 1000,
      intervalRule: 'DAILY',
      startAt: DateTime(2026, 9, 1),
      autoRegister: autoRegister,
    );

void main() {
  test('buckets a missing occurrence under "mine" when the template owner is me', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'me')],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {},
    );
    expect(result.mine, hasLength(1));
    expect(result.spouse, isEmpty);
  });

  test('buckets a missing occurrence under "spouse" when the template owner is not me', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'spouse-id')],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {},
    );
    expect(result.mine, isEmpty);
    expect(result.spouse, hasLength(1));
  });

  test('excludes an auto_register template entirely — it has no todo items', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'me', autoRegister: true)],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {},
    );
    expect(result.mine, isEmpty);
    expect(result.spouse, isEmpty);
  });

  test('excludes a date already covered by an existing transaction', () {
    final result = splitTodoItems(
      [_template(id: 'rt-1', ownerMemberId: 'me')],
      'me',
      now: DateTime(2026, 9, 1),
      existingOccurredAtByTemplateId: {
        'rt-1': {DateTime(2026, 9, 1)},
      },
    );
    expect(result.mine, isEmpty);
  });
}
