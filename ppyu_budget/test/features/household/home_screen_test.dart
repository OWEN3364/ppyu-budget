// HomeScreen's conditional rendering is tested against a lightweight fake
// HouseholdRepository (not the real-HttpServer pattern used in
// household_repository_test.dart) — that pattern exists to prove
// HouseholdRepository itself talks to Postgrest's rpc() correctly, which is
// already covered there. Here we only need to control what getMyHousehold()
// returns, and constructing a real SupabaseClient starts a GoTrueClient
// auto-refresh Timer that must be disposed, or testWidgets' fake-async
// environment flags it as a leaked timer after the test.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ppyu_budget/features/household/home_screen.dart';
import 'package:ppyu_budget/features/household/household_repository.dart';

class _FakeHouseholdRepository extends HouseholdRepository {
  _FakeHouseholdRepository({required SupabaseClient client, String? household})
      : _future = Future.value(household),
        super(client: client);

  _FakeHouseholdRepository.pending({required SupabaseClient client})
      : _future = Completer<String?>().future,
        super(client: client);

  final Future<String?> _future;

  @override
  Future<String?> getMyHousehold() => _future;
}

void main() {
  late SupabaseClient client;

  setUp(() {
    client = SupabaseClient('http://localhost:0', 'unused-key');
  });

  tearDown(() async {
    await client.dispose();
  });

  testWidgets('shows invite/join buttons when the user has no household',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        repository: _FakeHouseholdRepository(client: client, household: null),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('배우자 초대하기'), findsOneWidget);
    expect(find.text('초대 코드로 연동하기'), findsOneWidget);
  });

  testWidgets('hides invite/join buttons when the user already has a household',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        repository: _FakeHouseholdRepository(
          client: client,
          household: 'household-id-123',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('배우자 초대하기'), findsNothing);
    expect(find.text('초대 코드로 연동하기'), findsNothing);
    expect(find.text('거래 내역'), findsOneWidget);
  });

  testWidgets('shows a loading indicator while the household lookup is in flight',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        repository: _FakeHouseholdRepository.pending(client: client),
      ),
    ));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
