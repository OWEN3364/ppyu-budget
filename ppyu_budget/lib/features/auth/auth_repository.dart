import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthRepository {
  AuthRepository({
    required GoTrueClient auth,
    required GoogleSignIn googleSignIn,
    this.serverClientId,
  })  : _auth = auth,
        _googleSignIn = googleSignIn;

  final GoTrueClient _auth;
  final GoogleSignIn _googleSignIn;
  final String? serverClientId;
  bool _initialized = false;

  Stream<AuthState> get authStateChanges => _auth.onAuthStateChange;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    // Initialize must be called exactly once before authenticate
    await _googleSignIn.initialize(serverClientId: serverClientId);
    _initialized = true;
  }

  Future<void> signInWithGoogle() async {
    await _ensureInitialized();

    try {
      final account = await _googleSignIn.authenticate();
      final googleAuth = account.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null) {
        throw StateError('Google sign-in did not return an ID token');
      }

      // Try to get accessToken from authorizationClient
      // authorizationForScopes returns null if authorization would require interaction
      String? accessToken;
      final authorization = await account.authorizationClient.authorizationForScopes([]);
      if (authorization != null) {
        accessToken = authorization.accessToken;
      }

      await _auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return; // User canceled - not an error
      }
      rethrow;
    }
  }

  Future<void> signInWithKakao() async {
    await _auth.signInWithOAuth(
      OAuthProvider.kakao,
      redirectTo: 'com.ppyubudget.app://login-callback',
    );
  }

  Future<void> signOut() => _auth.signOut();
}
