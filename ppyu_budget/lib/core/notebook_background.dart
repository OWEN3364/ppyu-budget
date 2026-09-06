import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/app_theme.dart';

/// 다이어리 속지 느낌의 배경 — 흰 바탕 위에 옅은 가로줄.
///
/// [lined]를 false로 주면 줄 없는 무지 배경이 된다. 지금은 파라미터로만
/// 제어하고, "줄 있음/없음" 사용자 설정 화면은 다이어리 꾸미기 단계에서
/// 만든다 — 그때는 이 파라미터에 저장된 설정값을 넘기기만 하면 된다.
class NotebookBackground extends StatelessWidget {
  const NotebookBackground({super.key, required this.child, this.lined = true});

  final Widget child;
  final bool lined;

  @override
  Widget build(BuildContext context) {
    if (!lined) return ColoredBox(color: AppColors.beige, child: child);
    return CustomPaint(
      painter: _LinedPaperPainter(),
      child: child,
    );
  }
}

class _LinedPaperPainter extends CustomPainter {
  static const double _lineSpacing = 28;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.beige);
    final linePaint = Paint()
      ..color = AppColors.grey.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    for (double y = _lineSpacing; y < size.height; y += _lineSpacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
