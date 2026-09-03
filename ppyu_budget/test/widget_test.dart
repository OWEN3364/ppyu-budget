import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // main() normally loads .env before PpyuApp is built; this test builds
    // PpyuApp directly, so AdBannerWidget would otherwise hit dotenv before
    // it's ever initialized. Load an empty env so its null-guard applies.
    dotenv.loadFromString(isOptional: true);
    // Mock the shared_preferences platform channel so Supabase.initialize
    // doesn't hit a real platform channel in the unit test environment.
    const platform = MethodChannel('plugins.flutter.io/shared_preferences');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (MethodCall methodCall) async {
      if (methodCall.method == 'getAll') {
        return <String, dynamic>{};
      }
      return null;
    });
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'dummy-anon-key',
    );
  });

  testWidgets('app boots and shows login screen when logged out',
      (tester) async {
    await tester.pumpWidget(const PpyuApp());
    await tester.pump();
    expect(find.text('구글로 로그인'), findsOneWidget);
  });
}
