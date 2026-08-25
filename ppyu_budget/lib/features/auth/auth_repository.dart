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
    // Use dynamic dispatch to handle both mock and real GoogleSignIn implementations
    final account = await (_googleSignIn as dynamic).signIn() as GoogleSignInAccount?;
    if (account == null) return; // user cancelled
    final googleAuth = account.authentication;
    final idToken = googleAuth.idToken;
    if (idToken == null) {
      throw StateError('Google sign-in did not return an ID token');
    }

    // Get accessToken from the authorization client if available
    String? accessToken;
    try {
      final authorization = await (account as dynamic).authorizationClient?.authorizationForScopes([]);
      accessToken = authorization?.accessToken;
    } catch (_) {
      // Ignore errors getting access token - it's optional
    }

    await _auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  Future<void> signOut() => _auth.signOut();
}
