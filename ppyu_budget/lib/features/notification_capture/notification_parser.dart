class ParsedNotification {
  const ParsedNotification({
    required this.amount,
    required this.merchant,
    required this.occurredAt,
    required this.issuerName,
  });

  final int amount;
  final String merchant;
  final DateTime occurredAt;
  final String issuerName;
}

class NotificationParser {
  // ponytail: small, hand-picked allowlist to start — extend as the user's
  // actual bank/card apps turn out to post notifications this feature
  // should react to. Find a package name via `adb shell dumpsys
  // notification` while the real notification is showing, or the app's
  // Play Store URL (id=... query param).
  static const _knownIssuers = <String, String>{
    'com.samsung.android.spay': '삼성페이',
    'viva.republica.toss': '토스',
    'com.kbcard.cxh.appcard': 'KB국민카드',
    'com.shinhancard.smartshinhan': '신한카드',
    'kr.co.samsungcard.mpocket': '삼성카드',
  };

  static bool isKnownSource(String packageName) => _knownIssuers.containsKey(packageName);

  // ponytail: naive heuristic, not a real NLP parser. Strips the matched
  // amount and a few common Korean payment-notification boilerplate words,
  // then uses whatever's left as the merchant name. Tune the boilerplate
  // list (or add per-issuer overrides keyed on packageName) once real
  // notification samples from the user's own bank/card apps are collected —
  // this is expected to need iteration, not a one-shot solution.
  static ParsedNotification? parse(String packageName, String text) {
    final issuerName = _knownIssuers[packageName];
    if (issuerName == null) return null;

    final amountMatch = RegExp(r'([\d,]+)\s*원').firstMatch(text);
    if (amountMatch == null) return null;
    final amount = int.parse(amountMatch.group(1)!.replaceAll(',', ''));

    var merchant = text
        .replaceAll(amountMatch.group(0)!, '')
        .replaceAll(RegExp(r'(승인|결제|사용|일시불|누적|완료)'), '')
        .trim();
    if (merchant.isEmpty) merchant = issuerName;

    return ParsedNotification(
      amount: amount,
      merchant: merchant,
      occurredAt: DateTime.now(),
      issuerName: issuerName,
    );
  }
}
