import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_passenger/main.dart';

void main() {
  testWidgets('initial screen shows a clearly labeled demo request', (
    tester,
  ) async {
    await tester.pumpWidget(const PickupPassengerApp());
    expect(find.text('픽업메이트'), findsOneWidget);
    expect(find.text('데모 요청 확인'), findsOneWidget);
    expect(find.textContaining('실제 탑승자 계정 연동 전'), findsOneWidget);
    expect(find.text('요청 수락하고 승차 지점 전달'), findsNothing);
  });
}
