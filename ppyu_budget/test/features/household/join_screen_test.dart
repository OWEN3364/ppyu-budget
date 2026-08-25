import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';

void main() {
  test('extractInviteCode reads the code query param from a deep link', () {
    final code = extractInviteCode(Uri.parse('ppyubudget://invite?code=123456'));
    expect(code, '123456');
  });

  test('extractInviteCode returns null for a link with no code', () {
    final code = extractInviteCode(Uri.parse('ppyubudget://invite'));
    expect(code, isNull);
  });
}
