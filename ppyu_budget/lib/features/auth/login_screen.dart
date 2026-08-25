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
