import 'package:flutter/material.dart';
import 'package:ppyu_budget/core/app_fonts.dart';

/// 다이어리 컨셉 색 팔레트 (2026-09-03 확정, Orange/Beige/Grey/Teal).
class AppColors {
  AppColors._();

  static const orange = Color(0xFFE2A16F);
  static const beige = Color(0xFFFFF0DD);
  static const grey = Color(0xFFD1D3D4);
  static const teal = Color(0xFF86B0BD);

  /// 카드/타일처럼 배경(beige)보다 한 단계 밝게 얹히는 종이색.
  static const paper = Colors.white;

  /// 본문 텍스트 — 순검정 대신 부드러운 다크그레이.
  static const ink = Color(0xFF444444);

  /// 부가 설명/보조 텍스트.
  static const muted = Color(0xFF8A8A8A);

  /// 에러 메시지.
  static const error = Colors.red;

  /// 형광펜 강조.
  static const highlight = Color(0xFFFFE08A);

  /// 통계 차트에서 카테고리를 구분하는 색상들 (브랜드 팔레트와 별개로,
  /// 서로 뚜렷이 구분되는 색 8개가 필요해서 유지).
  static const chartColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.brown,
    Colors.pink,
  ];
}

class AppTheme {
  AppTheme._();

  static ThemeData get light => ThemeData(
        useMaterial3: true,
        fontFamily: AppFonts.main.family,
        colorScheme: ColorScheme.light(
          primary: AppColors.orange,
          onPrimary: Colors.white,
          secondary: AppColors.teal,
          onSecondary: Colors.white,
          surface: AppColors.beige,
          onSurface: AppColors.ink,
          outline: AppColors.grey,
          surfaceContainerHighest: AppColors.grey,
        ),
        // 투명 — 실제 배경(줄노트 무늬)은 MaterialApp.builder의
        // NotebookBackground가 그린다. 여기서 불투명하게 칠하면 그 위에
        // Scaffold가 덮어써서 줄무늬가 안 보인다.
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.orange,
          foregroundColor: Colors.white,
        ),
        cardTheme: CardThemeData(
          color: AppColors.paper,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.grey),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: AppColors.teal,
          foregroundColor: Colors.white,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.teal,
            foregroundColor: Colors.white,
          ),
        ),
      );
}
