import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'arrival.dart';
import 'phone_auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureFirebase();
  runApp(const PickupPassengerApp());
}

const navy = Color(0xFF0B2D6B);
const mint = Color(0xFF00B9A7);

class PickupPassengerApp extends StatelessWidget {
  const PickupPassengerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '픽업메이트',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: navy,
        primary: navy,
        secondary: mint,
      ),
      scaffoldBackgroundColor: const Color(0xFFF4F7FB),
    ),
    home: const PassengerHome(),
  );
}

class PickupApi {
  PickupApi(this.base);
  final String base;
  String? id;
  String? token;
  bool accountMode = false;

  Future<Map<String, dynamic>> request(
    String method,
    String path, [
    Map<String, dynamic>? body,
    bool asAccount = false,
  ]) async {
    final uri = Uri.parse('$base$path');
    if (uri.scheme != 'https' &&
        !(kDebugMode && uri.scheme == 'http' && uri.host == '10.0.2.2')) {
      throw const FormatException(
        '서버는 HTTPS를 사용해야 합니다. Android 에뮬레이터의 로컬 시연만 HTTP를 허용합니다.',
      );
    }
    final authToken = (accountMode || asAccount)
        ? await FirebaseAuth.instance.currentUser?.getIdToken()
        : token;
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (authToken != null) 'Authorization': 'Bearer $authToken',
    };
    final Future<http.Response> pending;
    if (method == 'GET') {
      pending = http.get(uri, headers: headers);
    } else if (method == 'DELETE') {
      pending = http.delete(uri, headers: headers);
    } else {
      pending = http.post(uri, headers: headers, body: jsonEncode(body ?? {}));
    }
    final response = await pending.timeout(const Duration(seconds: 8));
    final result =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode >= 400) throw Exception(result['error'] ?? '서버 오류');
    return result;
  }

  Future<Map<String, dynamic>> demo() async {
    accountMode = false;
    token = null;
    final data = await request('POST', '/api/demo/request');
    id = data['id'] as String;
    token = data['passengerToken'] as String;
    return state();
  }

  Future<Map<String, dynamic>> inbox() async {
    accountMode = true;
    token = null;
    return request('GET', '/api/v1/inbox');
  }

  Future<Map<String, dynamic>> state() =>
      request('GET', accountMode ? '/api/v1/pickups/$id' : '/api/sessions/$id');
  Future<Map<String, dynamic>> update(
    String action,
    Map<String, dynamic> data,
  ) => request(
    'POST',
    accountMode ? '/api/v1/pickups/$id/$action' : '/api/sessions/$id/$action',
    data,
  );
}

class PassengerHome extends StatefulWidget {
  const PassengerHome({super.key});
  @override
  State<PassengerHome> createState() => _PassengerHomeState();
}

class _PassengerHomeState extends State<PassengerHome>
    with WidgetsBindingObserver {
  final PickupApi api = PickupApi(
    const String.fromEnvironment(
      'PICKUP_API_URL',
      defaultValue: 'http://10.0.2.2:8787',
    ),
  );
  final TextEditingController label = TextEditingController(text: '선택한 승차 위치');
  final TextEditingController message = TextEditingController();
  final MapController map = MapController();
  Map<String, dynamic>? state;
  List<dynamic> inbox = [];
  LatLng selected = const LatLng(37.4979, 127.0276);
  bool selectedByUser = false;
  bool busy = false;
  bool sharing = false;
  bool resumeSharing = false;
  int alertedStage = 0;
  Object? alertedRevision;
  bool foreground = true;
  bool locationBusy = false;
  bool inboxBusy = false;
  bool notificationsEnabled = false;
  final FlutterSecureStorage preferences = const FlutterSecureStorage();
  StreamSubscription<String>? tokenSubscription;
  StreamSubscription<RemoteMessage>? foregroundMessages;
  StreamSubscription<RemoteMessage>? notificationTaps;
  String? error;
  Timer? poll;
  DateTime? lastLocation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (firebaseReady) {
      notificationTaps = FirebaseMessaging.onMessageOpenedApp.listen((_) {
        refreshFromNotification();
      });
      FirebaseMessaging.instance.getInitialMessage().then((notification) {
        if (notification != null) refreshFromNotification();
      });
      foregroundMessages = FirebaseMessaging.onMessage.listen((_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('픽업 알림이 도착했어요.')));
          if (state == null && FirebaseAuth.instance.currentUser != null) {
            loadInbox();
          }
        }
      });
      tokenSubscription = FirebaseMessaging.instance.onRegistered.listen((
        token,
      ) async {
        if (notificationsEnabled && FirebaseAuth.instance.currentUser != null) {
          try {
            await api.request('POST', '/api/v1/device', {'token': token}, true);
          } catch (_) {}
        }
      });
    }
    if (firebaseReady && FirebaseAuth.instance.currentUser != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadInbox();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // `inactive` also fires for permission dialogs and the notification shade
    // while the app is still on screen, so only a real background stops sharing.
    final background =
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached;
    if (background) {
      foreground = false;
      if (sharing) {
        sharing = false;
        resumeSharing = true;
        api
            .update('location-consent', {'enabled': false})
            .catchError((_) => <String, dynamic>{});
        if (mounted) setState(() {});
      }
    } else if (lifecycle == AppLifecycleState.resumed) {
      foreground = true;
      if (resumeSharing) {
        resumeSharing = false;
        final status = state?['status'];
        if (status == 'active' || status == 'pickup_pending') setSharing(true);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    poll?.cancel();
    tokenSubscription?.cancel();
    foregroundMessages?.cancel();
    notificationTaps?.cancel();
    if (sharing) {
      api
          .update('location-consent', {'enabled': false})
          .catchError((_) => <String, dynamic>{});
    }
    label.dispose();
    message.dispose();
    map.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              '처리하지 못했습니다. ${e.toString().replaceFirst('Exception: ', '')}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void refreshFromNotification() {
    if (!mounted || FirebaseAuth.instance.currentUser == null) return;
    if (state == null) {
      loadInbox();
    } else {
      refresh();
    }
  }

  Future<void> loadDemo() => run(() async {
    if (sharing) {
      await api.update('location-consent', {'enabled': false});
      sharing = false;
    }
    state = await api.demo();
    resumeSharing = false;
    inbox = [];
    poll?.cancel();
    poll = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
    if (mounted) setState(() {});
  });

  Future<void> loadInbox() => run(() async {
    if (sharing) {
      await api.update('location-consent', {'enabled': false});
      sharing = false;
    }
    poll?.cancel();
    api.id = null;
    state = null;
    resumeSharing = false;
    final result = await api.inbox();
    inbox = (result['requests'] as List<dynamic>?) ?? [];
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null &&
        await preferences.read(key: 'notifications_$uid') == 'true') {
      try {
        await registerNotificationToken();
      } catch (_) {
        notificationsEnabled = false;
        error = '요청 목록은 확인할 수 있지만 알림을 등록하지 못했습니다.';
      }
    }
    poll = Timer.periodic(const Duration(seconds: 15), (_) => refreshInbox());
    if (mounted) setState(() {});
  });

  Future<void> refreshInbox() async {
    if (!foreground ||
        inboxBusy ||
        busy ||
        state != null ||
        !firebaseReady ||
        FirebaseAuth.instance.currentUser == null) {
      return;
    }
    inboxBusy = true;
    try {
      final result = await api.inbox();
      if (mounted && state == null) {
        setState(() {
          inbox = (result['requests'] as List<dynamic>?) ?? [];
          error = null;
        });
      }
    } catch (_) {
      if (mounted && state == null) {
        setState(() => error = '요청 목록을 새로고침하지 못했습니다. 서버 연결을 확인해 주세요.');
      }
    } finally {
      inboxBusy = false;
    }
  }

  Future<void> registerNotificationToken() async {
    final registration = FirebaseMessaging.instance.onRegistered.first.timeout(
      const Duration(seconds: 20),
    );
    await FirebaseMessaging.instance.register();
    final token = await registration;
    if (token.isEmpty) throw Exception('알림 기기 등록에 실패했습니다.');
    await api.request('POST', '/api/v1/device', {'token': token}, true);
    notificationsEnabled = true;
  }

  Future<void> enableNotifications() => run(() async {
    final settings = await FirebaseMessaging.instance.requestPermission();
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      throw Exception('기기 알림 권한이 허용되지 않았습니다.');
    }
    await registerNotificationToken();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      await preferences.write(key: 'notifications_$uid', value: 'true');
    }
    if (mounted) setState(() {});
  });

  Future<void> selectRequest(Map<String, dynamic> request) => run(() async {
    api.accountMode = true;
    api.id = request['id'] as String;
    state = await api.state();
    resumeSharing = false;
    inbox = [];
    poll?.cancel();
    poll = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
    if (mounted) setState(() {});
  });

  Future<void> refresh() async {
    if (api.id == null || busy) return;
    try {
      final current = await api.state();
      final isClosed =
          current['status'] == 'finished' || current['status'] == 'expired';
      if (isClosed) {
        poll?.cancel();
        sharing = false;
      }
      if (sharing && current['passengerLocationSharing'] != true) {
        sharing = false;
      }
      if (mounted) {
        setState(() {
          state = current;
          error = null;
        });
        announceStage(current);
      }
      if (sharing &&
          !locationBusy &&
          (lastLocation == null ||
              DateTime.now().difference(lastLocation!) >=
                  const Duration(seconds: 15))) {
        await updateLocation();
      }
    } catch (_) {
      if (mounted) setState(() => error = '서버 연결을 확인해 주세요. 잠시 후 다시 시도합니다.');
    }
  }

  Future<Position> position() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('기기의 위치 서비스를 켜 주세요.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('위치 권한이 필요합니다.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 12),
      ),
    );
  }

  Future<void> useCurrentLocation() => run(() async {
    final p = await position();
    selected = LatLng(p.latitude, p.longitude);
    selectedByUser = true;
    map.move(selected, 16);
    if (mounted) setState(() {});
  });

  Future<void> setPickup() => run(() async {
    if (!selectedByUser) throw Exception('지도에서 승차 지점을 선택해 주세요.');
    final name = label.text.trim();
    if (name.isEmpty) throw Exception('승차 지점 이름을 입력해 주세요.');
    state = await api.update('pickup', {
      'lat': selected.latitude,
      'lon': selected.longitude,
      'label': name,
    });
    if (mounted) setState(() {});
  });

  Future<void> estimateWalking() async {
    final consent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('도보 시간 확인'),
        content: const Text(
          '현재 위치와 승차 지점을 도보 경로 계산을 위해 TMAP에 전송합니다. 확인을 누르면 이번 한 번 위치를 조회합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    if (consent != true || !mounted) return;
    await run(() async {
      final p = await position();
      await api.update('walking-estimate', {
        'lat': p.latitude,
        'lon': p.longitude,
      });
      // The server keeps the walking time and recomputes departure as the car moves.
      state = await api.state();
      if (mounted) {
        setState(() {});
        announceStage(state!);
      }
    });
  }

  /// Alerts once per newly reached stage of the current pickup point, so the
  /// passenger is told even when push notifications are not configured.
  void announceStage(Map<String, dynamic> current) {
    final revision = (current['pickup'] as Map<String, dynamic>?)?['revision'];
    if (revision != alertedRevision) {
      alertedRevision = revision;
      alertedStage = 0;
    }
    final stage = current['arrivalStage'] as String?;
    final rank = stageRank(stage);
    final text = stageAlert(stage);
    if (rank <= alertedStage || text == null || !mounted) return;
    alertedStage = rank;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> setSharing(bool enabled) => run(() async {
    if (enabled) {
      final p = await position();
      if (!foreground || !mounted) return;
      state = await api.update('location-consent', {'enabled': true});
      try {
        if (!foreground || !mounted) {
          await api.update('location-consent', {'enabled': false});
          return;
        }
        state = await api.update('location', {
          'lat': p.latitude,
          'lon': p.longitude,
        });
        if (!foreground || !mounted) {
          await api.update('location-consent', {'enabled': false});
          return;
        }
        sharing = true;
        lastLocation = DateTime.now();
      } catch (_) {
        await api.update('location-consent', {'enabled': false});
        rethrow;
      }
    } else {
      state = await api.update('location-consent', {'enabled': false});
      sharing = false;
      lastLocation = null;
    }
    if (mounted) setState(() {});
  });

  Future<void> updateLocation() async {
    locationBusy = true;
    try {
      final p = await position();
      if (sharing) {
        await api.update('location', {'lat': p.latitude, 'lon': p.longitude});
        lastLocation = DateTime.now();
      }
    } catch (_) {
      sharing = false;
      try {
        await api.update('location-consent', {'enabled': false});
      } catch (_) {}
      if (mounted) setState(() => error = '위치를 가져오지 못해 위치 공유를 중지했습니다.');
    } finally {
      locationBusy = false;
    }
  }

  Future<void> sendMessage() => run(() async {
    final text = message.text.trim();
    if (text.isEmpty || text.runes.length > 160) {
      throw Exception('메시지는 1~160자로 입력해 주세요.');
    }
    state = await api.update('message', {'text': text});
    message.clear();
    if (mounted) setState(() {});
  });

  @override
  Widget build(BuildContext context) {
    final status = state?['status'];
    final active = status == 'active' || status == 'pickup_pending';
    final pickup = state?['pickup'] as Map<String, dynamic>?;
    final driver = state?['driverLocation'] as Map<String, dynamic>?;
    final eta = state?['etaSeconds'] as int?;
    final departure = departureText(
      state?['walkingSeconds'] as int?,
      state?['departureInSeconds'] as int?,
    );
    final stageMessage = stageAlert(state?['arrivalStage'] as String?);
    final messages = (state?['messages'] as List<dynamic>?) ?? [];
    final closed = status == 'finished' || status == 'expired';
    return Scaffold(
      appBar: AppBar(
        backgroundColor: navy,
        foregroundColor: Colors.white,
        title: const Text('픽업메이트'),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '탑승자 화면',
              style: TextStyle(
                color: navy,
                fontWeight: FontWeight.bold,
                fontSize: 25,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '서로의 위치를 확인하고 편하게 만나요.',
              style: TextStyle(color: Colors.blueGrey),
            ),
            const SizedBox(height: 16),
            if (firebaseReady)
              _card(
                FirebaseAuth.instance.currentUser == null
                    ? PhoneLogin(
                        onSignedIn: () {
                          setState(() {});
                          loadInbox();
                        },
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '내 픽업 요청',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: navy,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text('연락처에 등록된 번호로 보낸 요청을 확인합니다.'),
                          TextButton.icon(
                            onPressed: busy || notificationsEnabled
                                ? null
                                : enableNotifications,
                            icon: const Icon(Icons.notifications_outlined),
                            label: Text(
                              notificationsEnabled ? '알림이 켜져 있습니다' : '픽업 알림 켜기',
                            ),
                          ),
                          TextButton.icon(
                            onPressed: busy ? null : loadInbox,
                            icon: const Icon(Icons.refresh),
                            label: const Text('요청 새로고침'),
                          ),
                          if (inbox.isEmpty && state == null)
                            const Text('현재 받은 요청이 없습니다.'),
                          for (final request in inbox)
                            ListTile(
                              title: Text(
                                '${request['contactName'] ?? '픽업'} 요청',
                              ),
                              subtitle: Text('${request['pickupTime'] ?? ''}'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: busy
                                  ? null
                                  : () => selectRequest(
                                      request as Map<String, dynamic>,
                                    ),
                            ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => run(() async {
                                    if (sharing) {
                                      await api.update('location-consent', {
                                        'enabled': false,
                                      });
                                      sharing = false;
                                    }
                                    poll?.cancel();
                                    await api.request(
                                      'DELETE',
                                      '/api/v1/device',
                                      null,
                                      true,
                                    );
                                    final uid =
                                        FirebaseAuth.instance.currentUser?.uid;
                                    if (uid != null) {
                                      await preferences.delete(
                                        key: 'notifications_$uid',
                                      );
                                    }
                                    notificationsEnabled = false;
                                    await FirebaseAuth.instance.signOut();
                                    api.id = null;
                                    api.token = null;
                                    state = null;
                                    inbox = [];
                                    if (mounted) setState(() {});
                                  }),
                            child: const Text('로그아웃'),
                          ),
                        ],
                      ),
              )
            else
              _card(const Text('휴대전화 인증은 Firebase 프로젝트 설정 후 사용할 수 있습니다.')),
            const SizedBox(height: 12),
            if (kDebugMode)
              _card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '개발용 시연',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: navy,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '실제 탑승자 계정 연동 전까지 테스트 요청을 표시합니다. 실제 위치나 개인정보는 입력하지 마세요.',
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: busy ? null : loadDemo,
                      icon: const Icon(Icons.science_outlined),
                      label: const Text('데모 요청 확인'),
                    ),
                    if (kDebugMode && !kIsWeb && !Platform.isAndroid)
                      const Text('로컬 HTTP 시연은 Android 에뮬레이터에서 사용할 수 있습니다.'),
                  ],
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (state != null) ...[
              const SizedBox(height: 14),
              _card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      closed
                          ? '픽업이 종료됐어요'
                          : active
                          ? '픽업이 진행 중이에요'
                          : '픽업 요청이 도착했어요',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: navy,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      closed
                          ? '위치 공유가 종료되었습니다.'
                          : '대상: ${state!['contactName'] ?? '탑승자'}',
                    ),
                    if (active) Text(etaText(eta)),
                    if (active && departure != null) Text(departure),
                    if (active && stageMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          stageMessage,
                          style: const TextStyle(
                            color: mint,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    if (driver != null)
                      Text('차량 좌표: ${driver['lat']}, ${driver['lon']}'),
                  ],
                ),
              ),
              if (!closed) ...[
                const SizedBox(height: 14),
                _card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        active ? '승차 지점 변경' : '어디서 만날까요?',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: navy,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text('지도를 눌러 안전하게 만날 수 있는 장소를 직접 선택해 주세요.'),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 300,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: FlutterMap(
                            mapController: map,
                            options: MapOptions(
                              initialCenter: selected,
                              initialZoom: 15,
                              onTap: (_, point) => setState(() {
                                selected = point;
                                selectedByUser = true;
                              }),
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName:
                                    'io.pickupmate.pickup_passenger',
                              ),
                              MarkerLayer(
                                markers: [
                                  if (selectedByUser)
                                    Marker(
                                      point: selected,
                                      width: 45,
                                      height: 45,
                                      child: const Icon(
                                        Icons.location_on,
                                        size: 44,
                                        color: mint,
                                      ),
                                    ),
                                  if (driver != null)
                                    Marker(
                                      point: LatLng(
                                        (driver['lat'] as num).toDouble(),
                                        (driver['lon'] as num).toDouble(),
                                      ),
                                      width: 42,
                                      height: 42,
                                      child: const Icon(
                                        Icons.directions_car,
                                        size: 36,
                                        color: navy,
                                      ),
                                    ),
                                ],
                              ),
                              const RichAttributionWidget(
                                attributions: [
                                  TextSourceAttribution(
                                    'OpenStreetMap contributors',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: busy ? null : useCurrentLocation,
                        icon: const Icon(Icons.my_location),
                        label: const Text('현재 위치에서 선택'),
                      ),
                      Text(
                        selectedByUser
                            ? '선택: ${selected.latitude.toStringAsFixed(5)}, ${selected.longitude.toStringAsFixed(5)}'
                            : '지도에서 지점을 선택해 주세요.',
                        style: const TextStyle(color: Colors.blueGrey),
                      ),
                      if (pickup != null) Text('현재 승차 지점: ${pickup['label']}'),
                      const SizedBox(height: 8),
                      TextField(
                        controller: label,
                        maxLength: 120,
                        decoration: const InputDecoration(
                          labelText: '승차 지점 이름',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: busy ? null : setPickup,
                          child: Text(
                            active ? '변경한 승차 지점 전달' : '요청 수락하고 승차 지점 전달',
                          ),
                        ),
                      ),
                      if (!active)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  state = await api.update('decline', {});
                                  if (mounted) setState(() {});
                                }),
                          child: const Text('요청 거절'),
                        ),
                    ],
                  ),
                ),
              ],
              if (active) ...[
                const SizedBox(height: 14),
                _card(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('내 현재 위치 공유'),
                        subtitle: const Text(
                          '동의한 경우에만 앱을 보는 동안 공유합니다. 앱을 벗어나면 중지되고, 돌아오면 다시 공유합니다.',
                        ),
                        value: sharing,
                        onChanged: busy ? null : setSharing,
                      ),
                      if (api.accountMode && status == 'active') ...[
                        const Divider(),
                        TextButton.icon(
                          onPressed: busy ? null : estimateWalking,
                          icon: const Icon(Icons.directions_walk),
                          label: const Text('승차 지점까지 도보 시간 확인'),
                        ),
                        if (departure != null) Text(departure),
                      ],
                      const Divider(),
                      const Text(
                        '메시지',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: navy,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (messages.isEmpty) const Text('아직 주고받은 메시지가 없어요.'),
                      for (final item
                          in messages.reversed.take(10).toList().reversed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${item['sender'] == 'passenger' ? '나' : '운전자'}: ${item['text']}',
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: message,
                              maxLength: 160,
                              decoration: const InputDecoration(
                                hintText: '메시지 입력',
                                counterText: '',
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: busy ? null : sendMessage,
                            icon: const Icon(Icons.send, color: navy),
                            tooltip: '메시지 보내기',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _card(Widget child) => Card(
    elevation: 0,
    color: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
}
