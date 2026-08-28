import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/auth/login_screen.dart';
import 'package:ppyu_budget/features/household/home_screen.dart';
import 'package:ppyu_budget/features/household/join_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!,
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
  );
  runApp(const PpyuApp());
}

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
        // Joining needs auth.uid(); without a session the RPC would fail on a
        // NOT NULL constraint. Ignore the link for now.
        // ponytail: drops the link instead of replaying it after login —
        // Phase 2 can stash the code and reopen JoinScreen post-login.
        if (supabase.auth.currentSession == null) return;
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
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ko', 'KR')],
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
