import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:ppyu_budget/features/auth/auth_repository.dart';

class MockGoTrueClient extends Mock implements GoTrueClient {}

class MockGoogleSignInAuthorizationClient extends Mock
    implements GoogleSignInAuthorizationClient {}

class MockGoogleSignInAccount extends Mock implements GoogleSignInAccount {
  @override
  GoogleSignInAuthentication get authentication => _authentication!;

  @override
  GoogleSignInAuthorizationClient get authorizationClient =>
      _authorizationClient;

  late GoogleSignInAuthentication _authentication;
  late MockGoogleSignInAuthorizationClient _authorizationClient;

  void setAuthentication(GoogleSignInAuthentication authentication) {
    _authentication = authentication;
  }

  void setAuthorizationClient(MockGoogleSignInAuthorizationClient client) {
    _authorizationClient = client;
  }
}

class MockGoogleSignInAuthentication extends Mock
    implements GoogleSignInAuthentication {
  MockGoogleSignInAuthentication({
    required this.idToken,
  });

  @override
  final String? idToken;
}

class MockGoogleSignIn extends Mock implements GoogleSignIn {
  @override
  Future<void> initialize({
    String? clientId,
    String? serverClientId,
    String? nonce,
    String? hostedDomain,
  }) async {}

  @override
  Future<GoogleSignInAccount> authenticate({
    List<String> scopeHint = const <String>[],
  }) async => _account!;

  GoogleSignInAccount? _account;

  void setAccount(GoogleSignInAccount account) {
    _account = account;
  }
}

void main() {
  late MockGoTrueClient auth;
  late MockGoogleSignIn googleSignIn;
  late AuthRepository repo;

  setUp(() {
    registerFallbackValue(OAuthProvider.google);
    auth = MockGoTrueClient();
    googleSignIn = MockGoogleSignIn();
    repo = AuthRepository(
      auth: auth,
      googleSignIn: googleSignIn,
      serverClientId: 'test-client-id',
    );
  });

  test('signInWithGoogle exchanges Google tokens for a Supabase session',
      () async {
    final googleAuth = MockGoogleSignInAuthentication(
      idToken: 'id-token',
    );
    final authClient = MockGoogleSignInAuthorizationClient();
    final account = MockGoogleSignInAccount();
    account.setAuthentication(googleAuth);
    account.setAuthorizationClient(authClient);

    when(() => authClient.authorizationForScopes(any()))
        .thenAnswer((_) async => null);

    googleSignIn.setAccount(account);

    when(() => auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: 'id-token',
          accessToken: null,
        )).thenAnswer((_) async => AuthResponse());

    await repo.signInWithGoogle();

    verify(() => auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: 'id-token',
          accessToken: null,
        )).called(1);
  });

  test('signInWithKakao delegates to Supabase OAuth with deep link redirect',
      () async {
    when(() => auth.getOAuthSignInUrl(
          provider: OAuthProvider.kakao,
          redirectTo: 'com.ppyubudget.app://login-callback',
        )).thenAnswer((_) async => OAuthResponse(
          provider: OAuthProvider.kakao,
          url: 'https://kakao.example.com',
        ));

    // The OAuth flow tries to launch a URL, which will fail in unit tests
    // because the platform channel isn't initialized, but we can verify
    // that the method tries to set it up with the correct parameters
    expect(
      () => repo.signInWithKakao(),
      throwsA(isA<Object>()),
    );

    verify(() => auth.getOAuthSignInUrl(
          provider: OAuthProvider.kakao,
          redirectTo: 'com.ppyubudget.app://login-callback',
        )).called(1);
  });
}
