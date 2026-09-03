import 'package:flutter/material.dart';

/// 형광펜으로 강조한 것처럼 텍스트 뒤에 노란 배경을 까는 위젯.
/// 예: Highlight(child: Text('이번 달 지출이 늘었어요'))
class Highlight extends StatelessWidget {
  const Highlight({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFFFFE08A)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: child,
      ),
    );
  }
}
