# AdMob 배너 광고 (전역 하단 고정) 설계

## 1. 배경

쀼가계부는 향후 수익화를 위해 광고 배너를 넣기로 했다. 세 가지로 계획을 나눴다:

1. **AdMob 배너 (이 문서의 범위)** — Google AdMob 연동, 앱 전체 화면 하단 고정
2. 수동 광고 설정 시스템 (자체 계약 광고 관리) — 범위 밖, 별도 설계 예정
3. 유료 구독으로 광고 제거 + 구독자 편의기능 — 범위 밖, 별도 설계 예정

이 문서는 1번만 다룬다. 2, 3번은 이 문서의 전역 삽입 지점(§3)이 향후 조건 분기를 붙이기 쉬운 자리이므로, 지금 설계가 그 확장을 막지 않는 것만 확인한다.

AdMob 계정/앱 등록은 아직 없다 — 구글 공식 테스트 ID로 먼저 구현하고, 계정 발급이 끝나면 `.env`와 매니페스트의 값 두 곳만 교체하면 전환되게 만든다.

## 2. 위치

- **전역 하단 고정**: `MaterialApp`의 `builder` 파라미터로 모든 화면(로그인 화면 포함, 예외 없음)의 콘텐츠 아래에 배너를 고정한다. `showDialog`로 뜨는 다이얼로그는 별도 오버레이 레이어라 이 레이아웃과 겹치지 않는다.
- **홈 화면 인라인 배치**: 범위 밖 — 위치는 추후 디자인 패스 때 확정한다. 이 문서는 인라인 배치용 위젯을 만들지 않는다.

## 3. 아키텍처

```
main() → MobileAds.instance.initialize() (실패해도 앱 시작은 막지 않음)
       → runApp(PpyuApp)

PpyuApp.build() → MaterialApp(
  builder: (context, child) => Column(
    children: [
      Expanded(child: child!),   // 기존 라우트 콘텐츠 전체
      const AdBannerWidget(),    // 하단 고정 배너
    ],
  ),
  home: ...,
)
```

`builder`는 `MaterialApp`이 렌더링하는 모든 라우트(로그인/홈/다이얼로그가 아닌 모든 push된 화면 포함)를 감싸는 지점이므로, 새 화면을 추가해도 배너가 자동으로 적용된다. 향후 "구독자는 광고 제거"(계획 3번)를 붙일 때는 이 `builder`의 조건문 하나만 바꾸면 된다 — 예: `if (!isSubscriber) const AdBannerWidget()`.

## 4. 컴포넌트

### `AdBannerWidget` (`lib/features/ads/ad_banner_widget.dart`)

- `StatefulWidget`. `initState()`에서 `BannerAd`를 생성하고 `.load()` 호출.
- 배너 단위 ID는 `dotenv.env['ADMOB_BANNER_UNIT_ID']`에서 읽는다 (기존 `SUPABASE_URL` 패턴과 동일 — `main.dart`가 이미 `.env`를 로드해두므로 이 위젯이 별도로 로드할 필요 없음).
- 로드 성공(`onAdLoaded`) 시에만 `SizedBox(height: ad.size.height, child: AdWidget(ad: ad))`를 렌더링. 로드 실패(`onAdFailedToLoad`) 시 `SizedBox.shrink()` — 네트워크 없음/광고 재고 없음 등으로 실패해도 레이아웃이 깨지지 않고, 사용자에게 에러를 노출하지 않는다.
- `dispose()`에서 `BannerAd.dispose()` 호출 — 메모리 누수 방지.
- 표준 크기 배너(`AdSize.banner`, 320×50)만 사용한다. Adaptive banner는 범위 밖 (YAGNI — 화면 회전 대응이 필요해지면 그때 추가).

### `main.dart` 수정

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(...);
  try {
    await MobileAds.instance.initialize();
  } catch (e) {
    // 광고 SDK 초기화 실패가 앱 시작 자체를 막으면 안 됨 — 배너는 optional.
    debugPrint('AdMob 초기화 실패: $e');
  }
  runApp(const PpyuApp());
}
```

### `AndroidManifest.xml` 수정

`<application>` 태그 안에 추가:

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-3940256099942544~3347511713" />
```

(구글 공식 Android 테스트 App ID — 실제 계정 발급 후 이 값만 교체.)

### `.env` 추가

```
ADMOB_BANNER_UNIT_ID=ca-app-pub-3940256099942544/6300978111
```

(구글 공식 Android 배너 테스트 단위 ID.)

### `pubspec.yaml`

`google_mobile_ads` 의존성 추가 (`flutter pub add google_mobile_ads`로 최신 호환 버전 자동 해석).

## 5. 에러/엣지케이스

- 광고 SDK 초기화 실패 (오프라인 최초 실행 등): 앱은 정상 시작, 배너만 계속 빈 공간(`SizedBox.shrink()`)으로 남는다.
- 배너 로드 실패: 조용히 접힘, 재시도 로직 없음 (범위 밖 — 다음 화면 전환/재시작 때 자연스럽게 재시도됨).
- 위젯이 `dispose`될 일은 사실상 없다(`MaterialApp.builder`가 앱 생명주기 내내 유지) — 그래도 `dispose()`를 구현해 정석대로 정리한다.

## 6. 테스트 계획

`google_mobile_ads`는 네이티브 플랫폼 채널 기반이라 순수 Dart 유닛 테스트로 실제 광고 로드를 검증할 수 없다 — 이 코드베이스의 기존 `NotificationCaptureService`(마찬가지로 얇은 네이티브 wrapper, 테스트 없음)와 같은 전례를 따라 `AdBannerWidget`도 자동 테스트 없이 코드 리뷰로 검증하고, 실제 동작은 실기기/에뮬레이터에서 수동 확인한다.

## 7. 범위 밖

- 홈 화면 인라인 배너 위치/디자인 (디자인 패스 때 확정)
- 수동 광고 설정 시스템
- 유료 구독 광고 제거 + 구독자 편의기능
- Adaptive banner, 배너 로드 재시도, 여러 배너 단위(전면 광고 등)
