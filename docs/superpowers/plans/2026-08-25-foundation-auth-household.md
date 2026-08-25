# Foundation: Flutter Project + Supabase + Auth + Household Linking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Flutter app + Supabase backend, let a user log in with Google or Kakao, and let two users link into one shared `household` via a 6-digit invite code (with QR display/scan and deep-link sharing).

**Architecture:** Flutter (Android target) talks directly to Supabase (Postgres+Auth) via `supabase_flutter`. Auth state drives navigation via `StreamBuilder` on `supabase.auth.onAuthStateChange` — no extra state-management package. Household linking logic (invite code generation/redemption, 2-member cap, expiry) lives in Postgres `SECURITY DEFINER` RPC functions, not client code, so the rules can't be bypassed by a compromised client.

**Tech Stack:** Flutter, Supabase (Postgres + Auth), `supabase_flutter`, `google_sign_in`, `qr_flutter`, `mobile_scanner`, `app_links`, `flutter_dotenv`, `mocktail` (test mocking).

**Spec:** [docs/superpowers/specs/2026-08-25-ppyu-gagyebu-design.md](../specs/2026-08-25-ppyu-gagyebu-design.md)

## Global Constraints

- Platform: Android only for this phase (spec section 2).
- Login providers: Google and Kakao only — no Apple, no email/password (spec section 2).
- Invite codes: 6-digit numeric, single-use, expire 10 minutes after creation (spec section 7).
- Household size: hard cap of 2 active members in MVP, even though schema must support more later (spec section 6 & 7).
- No separate wallets — all members' transactions land in one household ledger (future phases; not touched here, but the `households`/`household_members` shape must not preclude it).
- Every table exposed to the client must have Row Level Security enabled (Supabase default posture; required since PostgREST exposes tables directly).

---

## Prerequisites (user actions before Task 2)

These require external accounts I cannot create on your behalf:

1. Create a free project at [supabase.com](https://supabase.com). Note the **Project URL** and **anon public key** (Project Settings → API).
2. Install the Supabase CLI (`npm install -g supabase` or see [supabase.com/docs/guides/cli](https://supabase.com/docs/guides/cli)) and run `supabase login`, then `supabase link --project-ref <your-project-ref>` from the project folder once Task 1 creates it.
3. In the Supabase dashboard: Authentication → Providers → enable **Google** and **Kakao**. Google needs a Web OAuth Client ID/Secret from [Google Cloud Console](https://console.cloud.google.com) (OAuth consent screen + Web application credential). Kakao needs a REST API key from [Kakao Developers](https://developers.kakao.com) (create app → enable Kakao Login → add redirect URI shown in the Supabase Kakao provider panel).
4. For native Google sign-in on Android specifically, also create an **Android** OAuth client in Google Cloud Console (package name `com.ppyubudget.app`, SHA-1 from your debug keystore: `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`).

Have the Supabase URL, anon key, and Google Web Client ID ready — Tasks 2 and 4 need them.

---

### Task 1: Flutter project scaffold

**Files:**
- Create: `pubspec.yaml` (via `flutter create`)
- Create: `lib/main.dart`
- Create: `test/widget_test.dart`

**Interfaces:**
- Produces: a runnable Flutter app with `MaterialApp` at the root, ready for later tasks to inject a home widget.

- [ ] **Step 1: Scaffold the project**

```bash
flutter create --org com.ppyubudget ppyu_budget
cd ppyu_budget
```

- [ ] **Step 2: Add dependencies**

```bash
flutter pub add supabase_flutter google_sign_in qr_flutter mobile_scanner app_links flutter_dotenv
flutter pub add --dev mocktail
```

- [ ] **Step 3: Replace the default counter app with a placeholder**

`lib/main.dart`:
```dart
import 'package:flutter/material.dart';

void main() {
  runApp(const PpyuApp());
}

class PpyuApp extends StatelessWidget {
  const PpyuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '쀼가계부',
      home: const Scaffold(
        body: Center(child: Text('쀼가계부')),
      ),
    );
  }
}
```

- [ ] **Step 4: Replace the default widget test**

`test/widget_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/main.dart';

void main() {
  testWidgets('app boots and shows title', (tester) async {
    await tester.pumpWidget(const PpyuApp());
    expect(find.text('쀼가계부'), findsOneWidget);
  });
}
```

- [ ] **Step 5: Run the test**

Run: `flutter test`
Expected: PASS (1 test)

- [ ] **Step 6: Commit**

```bash
git add ppyu_budget
git commit -m "chore: scaffold Flutter project"
```

---

### Task 2: Supabase connection + env config

**Files:**
- Create: `ppyu_budget/.env` (gitignored — real values)
- Create: `ppyu_budget/.env.example` (committed — placeholder values)
- Modify: `ppyu_budget/.gitignore`
- Create: `ppyu_budget/lib/core/supabase_client.dart`
- Modify: `ppyu_budget/lib/main.dart`
- Test: `ppyu_budget/test/core/supabase_client_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: `SupabaseClient get supabase` (top-level getter in `core/supabase_client.dart`) — every later feature reads/writes through this.

- [ ] **Step 1: Add env files**

`ppyu_budget/.env.example`:
```
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
```

`ppyu_budget/.env` (fill with your real Prerequisite-1 values, never commit):
```
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your-anon-key
```

Append to `ppyu_budget/.gitignore`:
```
.env
```

- [ ] **Step 2: Write the failing test**

`ppyu_budget/test/core/supabase_client_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/core/supabase_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('supabase client is reachable after init', () async {
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'dummy-anon-key',
    );
    expect(supabase, isA<SupabaseClient>());
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/core/supabase_client_test.dart`
Expected: FAIL — `core/supabase_client.dart` doesn't exist / `supabase` undefined.

- [ ] **Step 4: Implement the client accessor**

`ppyu_budget/lib/core/supabase_client.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient get supabase => Supabase.instance.client;
```

- [ ] **Step 5: Wire init into main.dart**

`ppyu_budget/lib/main.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  runApp(const PpyuApp());
}

class PpyuApp extends StatelessWidget {
  const PpyuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '쀼가계부',
      home: const Scaffold(
        body: Center(child: Text('쀼가계부')),
      ),
    );
  }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `flutter test test/core/supabase_client_test.dart`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add ppyu_budget/lib/core/supabase_client.dart ppyu_budget/lib/main.dart \
        ppyu_budget/test/core/supabase_client_test.dart ppyu_budget/.env.example ppyu_budget/.gitignore
git commit -m "feat: connect Supabase client via env config"
```

---

### Task 3: Household schema, RLS, and invite RPCs

**Files:**
- Create: `ppyu_budget/supabase/migrations/0001_household_schema.sql`
- Test: `ppyu_budget/supabase/tests/0001_household_schema_test.sql`

**Interfaces:**
- Produces (Postgres RPCs later tasks call via `supabase.rpc(...)`):
  - `create_household_and_owner() returns uuid` — creates a household, makes caller its owner, returns `household_id`.
  - `create_invite_code(p_household_id uuid) returns text` — returns a 6-digit code valid 10 minutes.
  - `join_household(p_code text) returns uuid` — validates and joins caller to the household, returns `household_id`. Raises `invalid_or_expired_code`, `household_full`, or `already_member`.

- [ ] **Step 1: Write the migration**

`ppyu_budget/supabase/migrations/0001_household_schema.sql`:
```sql
create table households (
  id uuid primary key default gen_random_uuid(),
  name text not null default '우리집',
  created_at timestamptz not null default now()
);

create table household_members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  unique (household_id, user_id)
);

create table invite_codes (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references households(id) on delete cascade,
  code text not null unique,
  created_by uuid not null references auth.users(id),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users(id)
);

alter table households enable row level security;
alter table household_members enable row level security;
alter table invite_codes enable row level security;

create policy "members can view own household"
  on households for select
  using (
    exists (
      select 1 from household_members hm
      where hm.household_id = households.id
        and hm.user_id = auth.uid()
        and hm.left_at is null
    )
  );

create policy "members can view household members"
  on household_members for select
  using (
    exists (
      select 1 from household_members hm
      where hm.household_id = household_members.household_id
        and hm.user_id = auth.uid()
        and hm.left_at is null
    )
  );

create policy "members can view own household invite codes"
  on invite_codes for select
  using (
    exists (
      select 1 from household_members hm
      where hm.household_id = invite_codes.household_id
        and hm.user_id = auth.uid()
        and hm.left_at is null
    )
  );

create or replace function create_household_and_owner()
returns uuid
language plpgsql
security definer
as $$
declare
  new_household_id uuid;
begin
  insert into households default values returning id into new_household_id;
  insert into household_members (household_id, user_id, role)
  values (new_household_id, auth.uid(), 'owner');
  return new_household_id;
end;
$$;

create or replace function create_invite_code(p_household_id uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_code text;
  v_is_member boolean;
begin
  select exists (
    select 1 from household_members
    where household_id = p_household_id and user_id = auth.uid() and left_at is null
  ) into v_is_member;

  if not v_is_member then
    raise exception 'not a member of this household';
  end if;

  v_code := lpad(floor(random() * 1000000)::text, 6, '0');

  insert into invite_codes (household_id, code, created_by, expires_at)
  values (p_household_id, v_code, auth.uid(), now() + interval '10 minutes');

  return v_code;
end;
$$;

create or replace function join_household(p_code text)
returns uuid
language plpgsql
security definer
as $$
declare
  v_invite invite_codes%rowtype;
  v_member_count int;
begin
  select * into v_invite from invite_codes
  where code = p_code and used_at is null and expires_at > now()
  for update;

  if not found then
    raise exception 'invalid_or_expired_code';
  end if;

  select count(*) into v_member_count
  from household_members
  where household_id = v_invite.household_id and left_at is null;

  if v_member_count >= 2 then
    raise exception 'household_full';
  end if;

  if exists (
    select 1 from household_members
    where household_id = v_invite.household_id and user_id = auth.uid() and left_at is null
  ) then
    raise exception 'already_member';
  end if;

  insert into household_members (household_id, user_id, role)
  values (v_invite.household_id, auth.uid(), 'member');

  update invite_codes set used_at = now(), used_by = auth.uid() where id = v_invite.id;

  return v_invite.household_id;
end;
$$;
```

- [ ] **Step 2: Apply the migration locally**

Run: `supabase start` (first time only, starts local Postgres) then `supabase db reset`
Expected: migration applies with no errors.

- [ ] **Step 3: Write the assertion-based SQL test**

`ppyu_budget/supabase/tests/0001_household_schema_test.sql`:
```sql
-- Run with: supabase db execute --file supabase/tests/0001_household_schema_test.sql
begin;

-- simulate user A
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111"}', true);
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'a@test.com')
  on conflict do nothing;

do $$
declare
  v_household_id uuid;
  v_code text;
begin
  v_household_id := create_household_and_owner();
  if v_household_id is null then
    raise exception 'TEST FAILED: household not created';
  end if;

  v_code := create_invite_code(v_household_id);
  if length(v_code) != 6 then
    raise exception 'TEST FAILED: invite code is not 6 digits';
  end if;
end $$;

rollback;
```

- [ ] **Step 4: Run the test**

Run: `supabase db execute --file supabase/tests/0001_household_schema_test.sql`
Expected: no `TEST FAILED` exception raised.

- [ ] **Step 5: Push migration to the linked cloud project**

Run: `supabase db push`
Expected: migration applied to your Supabase cloud project (from Prerequisite 2).

- [ ] **Step 6: Commit**

```bash
git add ppyu_budget/supabase
git commit -m "feat: add household schema, RLS, and invite RPCs"
```

---

### Task 4: Google login

**Files:**
- Create: `ppyu_budget/lib/features/auth/auth_repository.dart`
- Test: `ppyu_budget/test/features/auth/auth_repository_test.dart`

**Interfaces:**
- Consumes: `supabase` getter from Task 2 (`core/supabase_client.dart`).
- Produces: `class AuthRepository { Future<void> signInWithGoogle(); Stream<AuthState> get authStateChanges; }` — Task 6/7's home routing and later phases' "who am I" checks depend on `authStateChanges`.

- [ ] **Step 1: Write the failing test**

`ppyu_budget/test/features/auth/auth_repository_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:ppyu_budget/features/auth/auth_repository.dart';

class MockGoTrueClient extends Mock implements GoTrueClient {}
class MockGoogleSignIn extends Mock implements GoogleSignIn {}
class MockGoogleSignInAccount extends Mock implements GoogleSignInAccount {}
class MockGoogleSignInAuthentication extends Mock
    implements GoogleSignInAuthentication {}

void main() {
  late MockGoTrueClient auth;
  late MockGoogleSignIn googleSignIn;
  late AuthRepository repo;

  setUp(() {
    auth = MockGoTrueClient();
    googleSignIn = MockGoogleSignIn();
    repo = AuthRepository(auth: auth, googleSignIn: googleSignIn);
  });

  test('signInWithGoogle exchanges Google tokens for a Supabase session', () async {
    final account = MockGoogleSignInAccount();
    final googleAuth = MockGoogleSignInAuthentication();
    when(() => googleSignIn.signIn()).thenAnswer((_) async => account);
    when(() => account.authentication).thenAnswer((_) async => googleAuth);
    when(() => googleAuth.idToken).thenReturn('id-token');
    when(() => googleAuth.accessToken).thenReturn('access-token');
    when(() => auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: 'id-token',
          accessToken: 'access-token',
        )).thenAnswer((_) async => AuthResponse());

    await repo.signInWithGoogle();

    verify(() => auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: 'id-token',
          accessToken: 'access-token',
        )).called(1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/auth/auth_repository_test.dart`
Expected: FAIL — `AuthRepository` doesn't exist.

- [ ] **Step 3: Implement the repository**

`ppyu_budget/lib/features/auth/auth_repository.dart`:
```dart
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthRepository {
  AuthRepository({required GoTrueClient auth, required GoogleSignIn googleSignIn})
      : _auth = auth,
        _googleSignIn = googleSignIn;

  final GoTrueClient _auth;
  final GoogleSignIn _googleSignIn;

  Stream<AuthState> get authStateChanges => _auth.onAuthStateChange;

  Future<void> signInWithGoogle() async {
    final account = await _googleSignIn.signIn();
    if (account == null) return; // user cancelled
    final googleAuth = await account.authentication;
    final idToken = googleAuth.idToken;
    final accessToken = googleAuth.accessToken;
    if (idToken == null) {
      throw StateError('Google sign-in did not return an ID token');
    }
    await _auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  Future<void> signOut() => _auth.signOut();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/auth/auth_repository_test.dart`
Expected: PASS

- [ ] **Step 5: Wire a real instance + login button**

`ppyu_budget/lib/features/auth/login_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/auth/auth_repository.dart';

final authRepository = AuthRepository(
  auth: supabase.auth,
  googleSignIn: GoogleSignIn(
    serverClientId: 'YOUR_GOOGLE_WEB_CLIENT_ID', // from Prerequisite 3
  ),
);

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: authRepository.signInWithGoogle,
          child: const Text('구글로 로그인'),
        ),
      ),
    );
  }
}
```

Replace the `YOUR_GOOGLE_WEB_CLIENT_ID` placeholder with the Web Client ID from Prerequisite 3 before running on a device.

- [ ] **Step 6: Commit**

```bash
git add ppyu_budget/lib/features/auth ppyu_budget/test/features/auth
git commit -m "feat: add Google sign-in"
```

---

### Task 5: Kakao login

**Files:**
- Modify: `ppyu_budget/lib/features/auth/auth_repository.dart`
- Modify: `ppyu_budget/lib/features/auth/login_screen.dart`
- Modify: `ppyu_budget/android/app/src/main/AndroidManifest.xml`
- Test: `ppyu_budget/test/features/auth/auth_repository_test.dart`

**Interfaces:**
- Consumes: `AuthRepository` from Task 4.
- Produces: `AuthRepository.signInWithKakao()`.

Kakao is a built-in Supabase OAuth provider (browser-based flow), so this reuses `signInWithOAuth` — no custom backend code needed.

- [ ] **Step 1: Write the failing test**

Add to `ppyu_budget/test/features/auth/auth_repository_test.dart`:
```dart
  test('signInWithKakao delegates to Supabase OAuth with deep link redirect', () async {
    when(() => auth.signInWithOAuth(
          OAuthProvider.kakao,
          redirectTo: 'com.ppyubudget.app://login-callback',
        )).thenAnswer((_) async => true);

    await repo.signInWithKakao();

    verify(() => auth.signInWithOAuth(
          OAuthProvider.kakao,
          redirectTo: 'com.ppyubudget.app://login-callback',
        )).called(1);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/auth/auth_repository_test.dart`
Expected: FAIL — `signInWithKakao` undefined.

- [ ] **Step 3: Implement it**

Add to `ppyu_budget/lib/features/auth/auth_repository.dart` (inside `AuthRepository`):
```dart
  Future<void> signInWithKakao() {
    return _auth.signInWithOAuth(
      OAuthProvider.kakao,
      redirectTo: 'com.ppyubudget.app://login-callback',
    );
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/auth/auth_repository_test.dart`
Expected: PASS (both Google and Kakao tests)

- [ ] **Step 5: Register the redirect deep link on Android**

Add inside the `<activity>` tag of `ppyu_budget/android/app/src/main/AndroidManifest.xml`:
```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="com.ppyubudget.app" android:host="login-callback" />
</intent-filter>
```

- [ ] **Step 6: Add the login button**

In `ppyu_budget/lib/features/auth/login_screen.dart`, add below the Google button:
```dart
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: authRepository.signInWithKakao,
            child: const Text('카카오로 로그인'),
          ),
```

- [ ] **Step 7: Commit**

```bash
git add ppyu_budget/lib/features/auth ppyu_budget/test/features/auth ppyu_budget/android
git commit -m "feat: add Kakao sign-in via Supabase OAuth"
```

---

### Task 6: Household repository + auth-gated routing

**Files:**
- Create: `ppyu_budget/lib/features/household/household_repository.dart`
- Create: `ppyu_budget/lib/features/household/home_screen.dart`
- Modify: `ppyu_budget/lib/main.dart`
- Test: `ppyu_budget/test/features/household/household_repository_test.dart`

**Interfaces:**
- Consumes: `AuthRepository.authStateChanges` (Task 4).
- Produces: `class HouseholdRepository { Future<String> createHousehold(); Future<String> createInviteCode(String householdId); Future<String> joinHousehold(String code); }` — Task 7's invite/join screens call these directly.

- [ ] **Step 1: Write the failing test**

`ppyu_budget/test/features/household/household_repository_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';

class MockSupabaseClient extends Mock implements SupabaseClient {}

void main() {
  late MockSupabaseClient client;
  late HouseholdRepository repo;

  setUp(() {
    client = MockSupabaseClient();
    repo = HouseholdRepository(client: client);
  });

  test('createHousehold calls the create_household_and_owner RPC', () async {
    when(() => client.rpc('create_household_and_owner'))
        .thenAnswer((_) async => 'household-id-123');

    final id = await repo.createHousehold();

    expect(id, 'household-id-123');
  });

  test('joinHousehold passes the code to the join_household RPC', () async {
    when(() => client.rpc('join_household', params: {'p_code': '123456'}))
        .thenAnswer((_) async => 'household-id-456');

    final id = await repo.joinHousehold('123456');

    expect(id, 'household-id-456');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/household/household_repository_test.dart`
Expected: FAIL — `HouseholdRepository` doesn't exist.

- [ ] **Step 3: Implement it**

`ppyu_budget/lib/features/household/household_repository.dart`:
```dart
import 'package:supabase_flutter/supabase_flutter.dart';

class HouseholdRepository {
  HouseholdRepository({required SupabaseClient client}) : _client = client;

  final SupabaseClient _client;

  Future<String> createHousehold() async {
    final result = await _client.rpc('create_household_and_owner');
    return result as String;
  }

  Future<String> createInviteCode(String householdId) async {
    final result = await _client.rpc(
      'create_invite_code',
      params: {'p_household_id': householdId},
    );
    return result as String;
  }

  Future<String> joinHousehold(String code) async {
    final result = await _client.rpc(
      'join_household',
      params: {'p_code': code},
    );
    return result as String;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/household/household_repository_test.dart`
Expected: PASS

- [ ] **Step 5: Add a placeholder home screen and wire auth-gated routing**

`ppyu_budget/lib/features/household/home_screen.dart`:
```dart
import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('로그인됨 — 다음 단계에서 초대/참여 화면 연결')),
    );
  }
}
```

Update `ppyu_budget/lib/main.dart`'s `PpyuApp.build` to route on auth state:
```dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/auth/login_screen.dart';
import 'package:ppyu_budget/features/household/home_screen.dart';

// ... keep main() as in Task 2 ...

class PpyuApp extends StatelessWidget {
  const PpyuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '쀼가계부',
      home: StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, snapshot) {
          final session = supabase.auth.currentSession;
          return session == null ? const LoginScreen() : const HomeScreen();
        },
      ),
    );
  }
}
```

- [ ] **Step 6: Run the full test suite**

Run: `flutter test`
Expected: PASS (all tests from Tasks 1–6)

- [ ] **Step 7: Commit**

```bash
git add ppyu_budget/lib/features/household ppyu_budget/lib/main.dart \
        ppyu_budget/test/features/household
git commit -m "feat: add household repository and auth-gated routing"
```

---

### Task 7: Invite + join screens (code, QR, deep link)

**Files:**
- Create: `ppyu_budget/lib/features/household/invite_screen.dart`
- Create: `ppyu_budget/lib/features/household/join_screen.dart`
- Modify: `ppyu_budget/lib/features/household/home_screen.dart`
- Modify: `ppyu_budget/lib/main.dart`
- Modify: `ppyu_budget/android/app/src/main/AndroidManifest.xml`
- Test: `ppyu_budget/test/features/household/join_screen_test.dart`

**Interfaces:**
- Consumes: `HouseholdRepository` (Task 6).
- Produces: nothing consumed by later phases directly — this is the phase's final user-facing deliverable.

- [ ] **Step 1: Register a second deep-link scheme for invites**

Add another `<intent-filter>` inside the same `<activity>` in `ppyu_budget/android/app/src/main/AndroidManifest.xml` (alongside the one from Task 5):
```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="ppyubudget" android:host="invite" />
</intent-filter>
```
This makes links like `ppyubudget://invite?code=123456` open the app.

- [ ] **Step 2: Build the invite (generator) screen**

`ppyu_budget/lib/features/household/invite_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';

final householdRepository = HouseholdRepository(client: supabase);

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.householdId});

  final String householdId;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  String? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    try {
      final code = await householdRepository.createInviteCode(widget.householdId);
      setState(() => _code = code);
    } catch (e) {
      setState(() => _error = '초대 코드 생성 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    final link = code == null ? null : 'ppyubudget://invite?code=$code';
    return Scaffold(
      appBar: AppBar(title: const Text('배우자 초대')),
      body: Center(
        child: _error != null
            ? Text(_error!)
            : code == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(code, style: Theme.of(context).textTheme.headlineMedium),
                      const SizedBox(height: 16),
                      QrImageView(data: link!, size: 200),
                      const SizedBox(height: 16),
                      const Text('10분 안에 사용해야 합니다'),
                    ],
                  ),
      ),
    );
  }
}
```

- [ ] **Step 3: Write the failing test for the join screen's code validation**

`ppyu_budget/test/features/household/join_screen_test.dart`:
```dart
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
```

- [ ] **Step 4: Run test to verify it fails**

Run: `flutter test test/features/household/join_screen_test.dart`
Expected: FAIL — `extractInviteCode` undefined.

- [ ] **Step 5: Build the join screen (manual entry + QR scan + deep link)**

`ppyu_budget/lib/features/household/join_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart' show householdRepository;

String? extractInviteCode(Uri link) => link.queryParameters['code'];

class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _joining = false;

  Future<void> _join(String code) async {
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      await householdRepository.joinHousehold(code);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = '연동 실패: ${e.toString()}');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('배우자와 연동하기')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: '6자리 초대 코드'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _joining ? null : () => _join(_controller.text.trim()),
              child: const Text('코드로 연동'),
            ),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            const Divider(height: 32),
            SizedBox(
              height: 250,
              child: MobileScanner(
                onDetect: (capture) {
                  final value = capture.barcodes.first.rawValue;
                  if (value == null || _joining) return;
                  final code = extractInviteCode(Uri.parse(value));
                  if (code != null) _join(code);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `flutter test test/features/household/join_screen_test.dart`
Expected: PASS

- [ ] **Step 7: Handle incoming deep links while the app is running**

Update `ppyu_budget/lib/main.dart` — add `app_links` listener that opens `JoinScreen` pre-filled when a `ppyubudget://invite` link arrives:
```dart
import 'package:app_links/app_links.dart';
// ... existing imports ...
import 'package:ppyu_budget/features/household/join_screen.dart';

class PpyuApp extends StatefulWidget {
  const PpyuApp({super.key});

  @override
  State<PpyuApp> createState() => _PpyuAppState();
}

class _PpyuAppState extends State<PpyuApp> {
  final _appLinks = AppLinks();
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _appLinks.uriLinkStream.listen((uri) {
      if (uri.host == 'invite') {
        final code = extractInviteCode(uri);
        if (code != null) {
          _navigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => JoinScreen(prefillCode: code)),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '쀼가계부',
      home: StreamBuilder<AuthState>(
        stream: supabase.auth.onAuthStateChange,
        builder: (context, snapshot) {
          final session = supabase.auth.currentSession;
          return session == null ? const LoginScreen() : const HomeScreen();
        },
      ),
    );
  }
}
```

Add an optional `prefillCode` constructor param to `JoinScreen` and initialize `_controller.text` with it:
```dart
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, this.prefillCode});

  final String? prefillCode;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  late final _controller = TextEditingController(text: widget.prefillCode);
  // ...rest unchanged
```

- [ ] **Step 8: Link home screen buttons to both flows**

Update `ppyu_budget/lib/features/household/home_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:ppyu_budget/features/household/invite_screen.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () async {
                final householdId = await householdRepository.createHousehold();
                if (context.mounted) {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => InviteScreen(householdId: householdId),
                  ));
                }
              },
              child: const Text('배우자 초대하기'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const JoinScreen()),
              ),
              child: const Text('초대 코드로 연동하기'),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 9: Run the full test suite**

Run: `flutter test`
Expected: PASS (all tests from Tasks 1–7)

- [ ] **Step 10: Manual end-to-end check on two devices/emulators**

1. Install the app on two Android devices (or emulators) logged in as two different Google/Kakao accounts.
2. Device A: tap "배우자 초대하기" → note the 6-digit code / QR.
3. Device B: tap "초대 코드로 연동하기" → type the code (or scan the QR) → confirm it navigates back successfully.
4. In the Supabase dashboard Table Editor, confirm `household_members` now has 2 rows sharing one `household_id`.
5. Repeat step 3 with a 3rd device/account against the same code — expect a `household_full` error surfaced in `_error`.

- [ ] **Step 11: Commit**

```bash
git add ppyu_budget/lib/features/household ppyu_budget/lib/main.dart \
        ppyu_budget/test/features/household/join_screen_test.dart ppyu_budget/android
git commit -m "feat: add invite/join screens with code, QR, and deep link support"
```
