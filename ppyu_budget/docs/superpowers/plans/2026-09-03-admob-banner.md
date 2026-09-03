# AdMob 배너 (전역 하단 고정) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱의 모든 화면 하단에 AdMob 배너 광고를 고정 표시한다. 구글 공식 테스트 ID로 구현하고, 실제 AdMob 계정 발급이 끝나면 `.env` 값 교체만으로 전환되게 만든다.

**Architecture:** `MaterialApp`의 `builder` 파라미터로 모든 라우트를 감싸는 지점에 `AdBannerWidget`을 배치한다. 배너 단위 ID는 `.env`에서 읽고, App ID는 `AndroidManifest.xml`의 메타데이터로 고정한다.

**Tech Stack:** Flutter, `google_mobile_ads` ^9.1.0 (이미 `pubspec.yaml`에 추가됨, 아래 API는 이 버전의 실제 소스로 검증됨).

**Spec:** [docs/superpowers/specs/2026-09-03-admob-banner-design.md](../specs/2026-09-03-admob-banner-design.md)

## Global Constraints

- `AdWidget(ad: ...)`은 해당 `ad`가 `.load()`로 로드 완료된 **이후에만** 위젯 트리에 넣어야 한다 (google_mobile_ads 9.1.0 `ad_containers.dart:718`의 명시적 제약: "ad must be loaded before this is added to the widget tree"). 로드 전/실패 시엔 `AdWidget`을 렌더링하지 않는다.
- 광고 SDK 초기화 실패가 앱 시작(로그인 화면 포함) 자체를 막으면 안 된다.
- 배너 단위 ID는 `dotenv.env['ADMOB_BANNER_UNIT_ID']`로 런타임에 읽는다 (기존 `SUPABASE_URL` 패턴과 동일) — 코드에 하드코딩하지 않는다.
- App ID는 빌드타임에 고정되는 네이티브 매니페스트 값이라 `.env`로 읽을 수 없다 — `AndroidManifest.xml`에 직접 쓴다.
- 지금은 구글 공식 테스트 ID를 사용한다: App ID `ca-app-pub-3940256099942544~3347511713`, 배너 단위 ID `ca-app-pub-3940256099942544/6300978111`.
- 홈 화면 인라인 배치, 수동 광고 설정, 구독 광고 제거는 이 계획의 범위 밖이다 (스펙 §7).

---

### Task 1: `AdBannerWidget` 작성

**Files:**
- Create: `lib/features/ads/ad_banner_widget.dart`

**Interfaces:**
- Produces: `AdBannerWidget` — `StatelessWidget`이 아닌 `StatefulWidget`, 인자 없음(`const AdBannerWidget({super.key})`), 배너 단위 ID는 내부에서 `dotenv.env['ADMOB_BANNER_UNIT_ID']`로 읽는다.

- [ ] **Step 1: 위젯 작성**

```dart
// lib/features/ads/ad_banner_widget.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// A fixed-size (320x50) banner ad, meant to sit at the bottom of every
/// screen via MaterialApp's `builder`. Renders nothing until the ad has
/// actually loaded (AdWidget requires a loaded ad before it's mounted —
/// see this plan's Global Constraints), and collapses back to nothing if
/// the load fails, so a network hiccup never breaks layout or shows an
/// error to the user — the banner is a purely optional extra.
class AdBannerWidget extends StatefulWidget {
  const AdBannerWidget({super.key});

  @override
  State<AdBannerWidget> createState() => _AdBannerWidgetState();
}

class _AdBannerWidgetState extends State<AdBannerWidget> {
  BannerAd? _bannerAd;

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  void _loadAd() {
    final adUnitId = dotenv.env['ADMOB_BANNER_UNIT_ID'];
    if (adUnitId == null || adUnitId.isEmpty) return;
    BannerAd(
      adUnitId: adUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() => _bannerAd = ad as BannerAd);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
        },
      ),
    ).load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _bannerAd;
    if (ad == null) return const SizedBox.shrink();
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }
}
```

- [ ] **Step 2: 정적 분석**

Run: `flutter analyze lib/features/ads/ad_banner_widget.dart`
Expected: No issues found.

- [ ] **Step 3: 커밋**

```bash
git add lib/features/ads/ad_banner_widget.dart
git commit -m "feat(ads): AdBannerWidget — loads-then-shows banner, collapses on failure"
```

---

### Task 2: `main.dart` — 초기화 + 전역 삽입

**Files:**
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `AdBannerWidget` (Task 1).

- [ ] **Step 1: `MobileAds` 초기화 추가**

`main()` 함수에서 `Supabase.initialize(...)` 다음, `runApp(...)` 이전에 추가:

```dart
// lib/main.dart
import 'package:google_mobile_ads/google_mobile_ads.dart';
// (기존 import들 사이 적절한 위치에 알파벳 순으로 추가)

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  try {
    await MobileAds.instance.initialize();
  } catch (e) {
    // 광고 SDK 초기화 실패가 앱 시작 자체를 막으면 안 됨 — 배너는 optional.
    debugPrint('AdMob 초기화 실패: $e');
  }
  runApp(const PpyuApp());
}
```

- [ ] **Step 2: `MaterialApp.builder`에 배너 삽입**

`PpyuApp.build()`의 `MaterialApp(...)`에 `builder` 파라미터 추가 (기존 `home:` 등은 그대로 유지):

```dart
// lib/main.dart — import 추가:
import 'package:ppyu_budget/features/ads/ad_banner_widget.dart';

// MaterialApp(...) 안에 builder 추가:
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '쀼가계부',
      builder: (context, child) => Column(
        children: [
          Expanded(child: child ?? const SizedBox.shrink()),
          const AdBannerWidget(),
        ],
      ),
      localizationsDelegates: const [
        // ... 기존 그대로
```

- [ ] **Step 3: 정적 분석**

Run: `flutter analyze lib/main.dart`
Expected: No issues found.

- [ ] **Step 4: 커밋**

```bash
git add lib/main.dart
git commit -m "feat(ads): initialize AdMob and mount the banner under every screen"
```

---

### Task 3: `AndroidManifest.xml` + `.env` — 테스트 ID로 배선

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `.env`

**Interfaces:**
- Consumes: `AdBannerWidget` (Task 1)의 `dotenv.env['ADMOB_BANNER_UNIT_ID']` 참조.

- [ ] **Step 1: 매니페스트에 App ID 추가**

`android/app/src/main/AndroidManifest.xml`의 `<application ...>` 태그 안, 기존 `<meta-data android:name="flutterEmbedding" .../>` 근처에 추가:

```xml
        <!-- AdMob: 구글 공식 테스트 App ID. 실제 계정 발급 후 교체
             (docs/superpowers/specs/2026-09-03-admob-banner-design.md 참고). -->
        <meta-data
            android:name="com.google.android.gms.ads.APPLICATION_ID"
            android:value="ca-app-pub-3940256099942544~3347511713" />
```

- [ ] **Step 2: `.env`에 배너 단위 ID 추가**

`.env`는 `.gitignore`에 포함되어 커밋되지 않는다 (확인됨: `git check-ignore -q .env` → 무시됨). 그래도 로컬 개발/실행에 필요하므로 추가한다:

```
ADMOB_BANNER_UNIT_ID=ca-app-pub-3940256099942544/6300978111
```

- [ ] **Step 3: `.env.example`에도 키 추가 (이 파일은 커밋 대상)**

`.env.example`은 `.gitignore`에 없어 커밋된다 (확인됨). 기존 `SUPABASE_URL=https://your-project.supabase.co` 같은 플레이스홀더 패턴을 따라 추가:

```
ADMOB_BANNER_UNIT_ID=your-admob-banner-unit-id
```

- [ ] **Step 4: 전체 테스트 실행**

Run: `flutter test`
Expected: 기존 테스트 전부 통과 (이 태스크는 네이티브 매니페스트/환경변수만 건드리므로 Dart 테스트에 영향 없음 — 회귀 확인용).

- [ ] **Step 5: 커밋**

```bash
git add android/app/src/main/AndroidManifest.xml .env.example
git commit -m "feat(ads): wire AdMob test App ID and banner unit ID"
```

(`.env`는 gitignore 대상이라 이 커밋에 포함되지 않는다 — 로컬에만 남는다, 다른 워크트리로 옮길 때는 기존 관례대로 수동 복사한다.)

---

## 실제 ID로 전환 (wizard 완료 후, 별도 진행)

이 계획에 포함하지 않는다 — 사용자가 `scripts/admob-setup-wizard.sh`를 완료해 `.env`의 `ADMOB_APP_ID`/`ADMOB_BANNER_UNIT_ID`가 실제 값으로 채워지면, 그때 다음 두 곳만 교체한다:
1. `AndroidManifest.xml`의 `APPLICATION_ID` 메타데이터 값을 `.env`의 `ADMOB_APP_ID`로 교체
2. `.env`의 `ADMOB_BANNER_UNIT_ID`가 이미 실제 값으로 갱신되어 있으므로 추가 작업 없음 (Task 1의 위젯이 런타임에 읽으므로 자동 반영)
