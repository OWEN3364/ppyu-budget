import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/features/notification_capture/notification_parser.dart';

void main() {
  test('isKnownSource is true for a recognized package', () {
    expect(NotificationParser.isKnownSource('com.samsung.android.spay'), isTrue);
  });

  test('isKnownSource is false for an unrecognized package', () {
    expect(NotificationParser.isKnownSource('com.some.other.app'), isFalse);
  });

  test('parse returns null for an unrecognized package', () {
    final result = NotificationParser.parse('com.some.other.app', '12,000원 결제되었습니다');
    expect(result, isNull);
  });

  test('parse returns null when no amount pattern is found', () {
    final result = NotificationParser.parse('com.samsung.android.spay', '알림 내용에 금액이 없음');
    expect(result, isNull);
  });

  test('parse extracts the amount from a recognized package\'s notification', () {
    final result = NotificationParser.parse(
      'com.samsung.android.spay',
      '삼성페이 12,000원 승인 스타벅스 강남점',
    );
    expect(result, isNotNull);
    expect(result!.amount, 12000);
    expect(result.issuerName, '삼성페이');
  });

  test('parse strips common boilerplate words from the merchant text', () {
    final result = NotificationParser.parse(
      'com.samsung.android.spay',
      '5,000원 승인 스타벅스',
    );
    expect(result, isNotNull);
    expect(result!.merchant, contains('스타벅스'));
    expect(result.merchant, isNot(contains('승인')));
  });

  test('parse falls back to the issuer name when merchant text is empty after stripping', () {
    final result = NotificationParser.parse('com.samsung.android.spay', '1,000원 승인');
    expect(result, isNotNull);
    expect(result!.merchant, '삼성페이');
  });

  // Partial guarantee only — see the parser's tuning checklist. Short digit
  // groups (e.g. "14:33") still survive; the strip covers card last-4 and
  // amount/balance figures, and the cap bounds how much text can escape.
  test('merchant does not leak the card last-4 or the cumulative balance', () {
    final result = NotificationParser.parse(
      'com.shinhancard.smartshinhan',
      '신한카드(1234) 12,000원 일시불승인 홍길동님 08/26 14:33 스타벅스강남점 누적 350,000원',
    );
    expect(result, isNotNull);
    expect(result!.amount, 12000);
    expect(result.merchant, contains('스타벅스강남점'));
    expect(result.merchant, isNot(contains('1234')));
    expect(result.merchant, isNot(contains('350,000')));
    expect(result.merchant.length, lessThanOrEqualTo(40));
  });

  test('merchant falls back to the issuer name when digit-stripping empties it', () {
    final result = NotificationParser.parse('com.shinhancard.smartshinhan', '1,000원 승인 1234');
    expect(result, isNotNull);
    expect(result!.merchant, '신한카드');
  });
}
