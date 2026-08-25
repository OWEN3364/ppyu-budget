import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/auth/auth_repository.dart';

final authRepository = AuthRepository(
  auth: supabase.auth,
  googleSignIn: GoogleSignIn.instance,
  serverClientId: dotenv.env['GOOGLE_WEB_CLIENT_ID'],
);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;

  // Guards against a double-tap starting two concurrent sign-ins, which would
  // call google_sign_in's non-idempotent initialize() twice, and surfaces
  // errors that a bare `Future<void> Function()` as VoidCallback would swallow.
  Future<void> _signIn(Future<void> Function() method) async {
    setState(() => _busy = true);
    try {
      await method();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('로그인 실패: 다시 시도해주세요')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed:
                  _busy ? null : () => _signIn(authRepository.signInWithGoogle),
              child: const Text('구글로 로그인'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed:
                  _busy ? null : () => _signIn(authRepository.signInWithKakao),
              child: const Text('카카오로 로그인'),
            ),
          ],
        ),
      ),
    );
  }
}
