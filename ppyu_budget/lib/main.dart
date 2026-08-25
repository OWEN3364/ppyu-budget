import 'package:flutter/material.dart';

void main() {
  runApp(const PpyuApp());
}

class PpyuApp extends StatelessWidget {
  const PpyuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '쀼가계부',
      home: const Scaffold(
        body: Center(child: Text('쀼가계부')),
      ),
    );
  }
}
