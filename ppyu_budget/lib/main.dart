import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/auth/login_screen.dart';
import 'package:ppyu_budget/features/household/home_screen.dart';

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
