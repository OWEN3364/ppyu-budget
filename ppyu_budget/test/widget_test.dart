import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
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
