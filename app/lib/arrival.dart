/// Passenger-facing wording for the server's ETA and arrival fields.
library;

int roundUpMinutes(int seconds) => ((seconds + 59) ~/ 60).clamp(1, 9999);

String etaText(int? etaSeconds) => etaSeconds == null
    ? '도착 시간: 아직 제공되지 않음'
    : '도착까지 약 ${roundUpMinutes(etaSeconds)}분';

/// Null until the passenger has checked the walking time to the pickup point.
String? departureText(int? walkingSeconds, int? departureInSeconds) {
  if (walkingSeconds == null) return null;
  final walk = '도보 약 ${roundUpMinutes(walkingSeconds)}분';
  if (departureInSeconds == null) return '$walk · 차량 도착 시간 확인 중';
  if (departureInSeconds <= 0) return '$walk · 지금 승차 지점으로 출발하세요';
  return '$walk · 약 ${roundUpMinutes(departureInSeconds)}분 뒤 출발하면 돼요';
}

const _stages = ['none', 'departure', 'approaching', 'arrived'];

int stageRank(String? stage) {
  final i = _stages.indexOf(stage ?? 'none');
  return i < 0 ? 0 : i;
}

String? stageAlert(String? stage) => switch (stage) {
  'departure' => '지금 출발하면 차량 도착에 맞춰 승차 지점에 도착해요.',
  'approaching' => '차량이 곧 도착해요. 승차 지점을 확인해 주세요.',
  'arrived' => '차량이 승차 지점에 도착했어요.',
  _ => null,
};
