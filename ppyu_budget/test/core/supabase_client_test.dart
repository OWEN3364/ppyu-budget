import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/core/supabase_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Mock the shared_preferences platform channel
    const platform = MethodChannel('plugins.flutter.io/shared_preferences');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platform, (MethodCall methodCall) async {
      if (methodCall.method == 'getAll') {
        return <String, dynamic>{};
      }
      return null;
    });
  });

  test('supabase client is reachable after init', () async {
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'dummy-anon-key',
    );
    expect(supabase, isA<SupabaseClient>());
  });
}
