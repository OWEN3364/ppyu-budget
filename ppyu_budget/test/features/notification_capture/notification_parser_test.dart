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
}
