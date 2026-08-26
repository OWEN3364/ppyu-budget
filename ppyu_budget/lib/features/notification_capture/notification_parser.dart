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
  //
  // Tuning checklist for the real-device pass:
  // - Cancellations/refunds (알림 containing 취소/환불) currently parse as
  //   positive expenses with the wrong sign — not yet handled, needs real
  //   samples to fix correctly.
  // - The amount regex uses `firstMatch`, which may grab a 누적/잔액 balance
  //   figure instead of the actual transaction amount on some notification
  //   formats — needs verification against real samples.
  // - `merchant` must never become the verbatim notification text (privacy
  //   constraint: raw notification text must not cross into Supabase). The
  //   digit-stripping + length cap below helps but is not a complete
  //   guarantee; anyone extending this parser must preserve that property.
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
    // Strip digit runs of 3+ (card last-4, other amounts, dates written as
    // digits) and cap the length so `merchant` can't carry near-verbatim
    // notification text — cardholder name, timestamps, cumulative balance —
    // into Supabase.
    merchant = merchant.replaceAll(RegExp(r'[\d,]{3,}'), '').trim();
    if (merchant.length > 40) merchant = merchant.substring(0, 40);
    if (merchant.isEmpty) merchant = issuerName;

    return ParsedNotification(
      amount: amount,
      merchant: merchant,
      occurredAt: DateTime.now(),
      issuerName: issuerName,
    );
  }
}
