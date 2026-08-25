import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:ppyu_budget/features/auth/auth_repository.dart';

class MockGoTrueClient extends Mock implements GoTrueClient {}

class MockGoogleSignIn extends Mock implements GoogleSignIn {
  @override
  Future<GoogleSignInAccount?> signIn() async => _signInAccount;

  GoogleSignInAccount? _signInAccount;

  void setSignInAccount(GoogleSignInAccount? account) {
    _signInAccount = account;
  }
}

class MockGoogleSignInAccount extends Mock implements GoogleSignInAccount {
  @override
  GoogleSignInAuthentication get authentication => _authentication!;

  late GoogleSignInAuthentication _authentication;

  void setAuthentication(GoogleSignInAuthentication authentication) {
    _authentication = authentication;
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
    final googleAuth = MockGoogleSignInAuthentication(
      idToken: 'id-token',
    );
    final account = MockGoogleSignInAccount();
    account.setAuthentication(googleAuth);
    googleSignIn.setSignInAccount(account);

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
}
