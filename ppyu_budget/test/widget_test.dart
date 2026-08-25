import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ppyu_budget/main.dart';

void main() {
  testWidgets('app boots and shows title', (tester) async {
    await tester.pumpWidget(const PpyuApp());
    expect(find.text('쀼가계부'), findsOneWidget);
  });
}
