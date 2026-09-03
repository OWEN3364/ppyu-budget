/// 앱에서 쓰는 손글씨/본문 폰트들의 등록부.
///
/// 새 손글씨 TTF를 추가하는 절차 (pubspec.yaml의 fonts 섹션 주석과 동일):
///   1. assets/fonts/handwriting/에 영문 파일명으로 복사
///   2. pubspec.yaml의 fonts 섹션에 family 항목 추가
///   3. 여기 AppFonts.handwritingOptions에 한글 표시 이름과 함께 추가
/// 세 곳만 맞추면 폰트 선택 화면 등 앱 전체에 자동으로 나타난다.
class AppFont {
  const AppFont(this.family, this.displayName);

  /// pubspec.yaml에 등록된 family 이름 — TextStyle(fontFamily: ...)에 그대로 쓴다.
  final String family;

  /// 사용자에게 보여줄 한글 이름.
  final String displayName;
}

class AppFonts {
  AppFonts._();

  /// 지금 앱 전체 기본 폰트로 쓰는 메인 손글씨.
  static const main = AppFont('HandwritingMain', '왼손잡이도 예뻐');

  /// 메인 외에 고를 수 있는 손글씨 폰트들 — 다이어리 꾸미기 단계에서
  /// 선택지로 쓸 예정, 지금은 등록만 해둔 상태.
  static const handwritingOptions = [
    AppFont('HandwritingWarmFarewell', '따뜻한 작별'),
    AppFont('HandwritingDadsLoveLetter', '아빠의 연애편지'),
    AppFont('HandwritingBigTree', '아름드리 꽃나무'),
    AppFont('HandwritingLoveSon', '사랑해 아들'),
    AppFont('HandwritingBaeeunhye', '배은혜체'),
    AppFont('HandwritingSparklingStar', '반짝반짝 별'),
    AppFont('HandwritingUprightSpirit', '바른정신'),
    AppFont('HandwritingNeat', '또박또박'),
    AppFont('HandwritingDaughterToMom', '딸에게 엄마가'),
  ];

  /// 가독성이 중요한 곳(숫자, 본문, 설정 메뉴 등)에 쓰는 표준 한글 폰트.
  static const sans = AppFont('NotoSansKR', '고딕');
  static const serif = AppFont('NotoSerifKR', '명조');
}
