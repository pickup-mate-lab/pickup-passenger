import 'package:flutter_test/flutter_test.dart';
import 'package:pickup_passenger/arrival.dart';

void main() {
  test('ETA is rounded up to whole minutes and never shows 0', () {
    expect(etaText(null), '도착 시간: 아직 제공되지 않음');
    expect(etaText(0), '도착까지 약 1분');
    expect(etaText(61), '도착까지 약 2분');
    expect(etaText(600), '도착까지 약 10분');
  });

  test('departure guidance follows the server values', () {
    expect(departureText(null, 100), isNull);
    expect(departureText(180, null), '도보 약 3분 · 차량 도착 시간 확인 중');
    expect(departureText(180, 0), '도보 약 3분 · 지금 승차 지점으로 출발하세요');
    expect(departureText(180, 400), '도보 약 3분 · 약 7분 뒤 출발하면 돼요');
  });

  test('stages are ordered and only real stages produce an alert', () {
    expect(stageRank(null), 0);
    expect(stageRank('unknown'), 0);
    expect(stageRank('departure') < stageRank('approaching'), isTrue);
    expect(stageRank('approaching') < stageRank('arrived'), isTrue);
    expect(stageAlert('none'), isNull);
    expect(stageAlert('arrived'), '차량이 승차 지점에 도착했어요.');
  });
}
