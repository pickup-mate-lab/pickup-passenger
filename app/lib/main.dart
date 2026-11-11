import 'package:flutter/material.dart';

void main() => runApp(const PickupPassengerApp());

class PickupPassengerApp extends StatelessWidget {
  const PickupPassengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '픽업메이트',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B2D6B)),
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.directions_car_filled, size: 64),
                  SizedBox(height: 16),
                  Text('픽업메이트', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                  SizedBox(height: 12),
                  Text('탑승자 앱을 준비하고 있어요.', textAlign: TextAlign.center),
                  SizedBox(height: 8),
                  Text('픽업 요청과 승차 위치 기능은 개발 예정입니다.', textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
