import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'phone_auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureFirebase();
  runApp(const PickupPassengerApp());
}

const navy = Color(0xFF243B34);
const mint = Color(0xFFC84D36);
const ink = Color(0xFF253B34);
const softInk = Color(0xFF777B6E);
const canvas = Color(0xFFF7F5EF);

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
      scaffoldBackgroundColor: canvas,
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: navy,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: mint,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF4F1E9),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE5E1D6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: mint, width: 1.5),
        ),
      ),
    ),
    home: const PassengerHome(),
  );
}

class PickupRequestException implements Exception {
  const PickupRequestException(this.statusCode, this.message);
  final int statusCode;
  final String message;
  @override
  String toString() => message;
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
    if (response.statusCode >= 400) {
      throw PickupRequestException(
        response.statusCode,
        (result['error'] ?? '서버 오류').toString(),
      );
    }
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
  final FlutterTts voiceReader = FlutterTts();
  final stt.SpeechToText voiceInput = stt.SpeechToText();
  bool listening = false;
  Map<String, dynamic>? state;
  Map<String, dynamic>? walking;
  List<dynamic> inbox = [];
  LatLng selected = const LatLng(37.4979, 127.0276);
  LatLng? waitingLocation;
  bool selectedByUser = false;
  bool editingPickup = false;
  bool busy = false;
  bool sharing = false;
  bool foreground = true;
  bool locationBusy = false;
  bool inboxBusy = false;
  bool notificationsEnabled = false;
  final FlutterSecureStorage preferences = const FlutterSecureStorage();
  StreamSubscription<String>? tokenSubscription;
  StreamSubscription<RemoteMessage>? foregroundMessages;
  StreamSubscription<RemoteMessage>? notificationTaps;
  StreamSubscription<Position>? locationStream;
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
    foreground = lifecycle == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    poll?.cancel();
    tokenSubscription?.cancel();
    foregroundMessages?.cancel();
    notificationTaps?.cancel();
    locationStream?.cancel();
    if (sharing) {
      api
          .update('location-consent', {'enabled': false})
          .catchError((_) => <String, dynamic>{});
    }
    voiceInput.cancel();
    voiceReader.stop();
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
      await locationStream?.cancel();
      locationStream = null;
    }
    state = await api.demo();
    selectedByUser = false;
    editingPickup = false;
    walking = null;
    waitingLocation = null;
    inbox = [];
    poll?.cancel();
    poll = Timer.periodic(const Duration(seconds: 4), (_) => refresh());
    if (mounted) setState(() {});
  });

  Future<void> loadInbox() => run(() async {
    if (sharing) {
      await api.update('location-consent', {'enabled': false});
      sharing = false;
      await locationStream?.cancel();
      locationStream = null;
    }
    poll?.cancel();
    api.id = null;
    state = null;
    walking = null;
    waitingLocation = null;
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
    selectedByUser = false;
    editingPickup = false;
    walking = null;
    waitingLocation = null;
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
        await locationStream?.cancel();
        locationStream = null;
      }
      if (sharing && current['passengerLocationSharing'] != true) {
        sharing = false;
        await locationStream?.cancel();
        locationStream = null;
      }
      if (mounted) {
        setState(() {
          final currentPickup = current['pickup'] as Map<String, dynamic>?;
          if (walking != null &&
              currentPickup?['revision'] != walking!['pickupRevision']) {
            walking = null;
          }
          state = current;
          error = null;
        });
      }
      if (sharing &&
          !locationBusy &&
          (lastLocation == null ||
              DateTime.now().difference(lastLocation!) >=
                  const Duration(seconds: 15))) {
        await updateLocation();
      }
    } catch (e) {
      if (e is PickupRequestException &&
          (e.statusCode == 404 || e.statusCode == 410)) {
        poll?.cancel();
        sharing = false;
        await locationStream?.cancel();
        locationStream = null;
        if (mounted) {
          setState(() {
            state = {...?state, 'status': 'finished'};
            error = '픽업이 종료되어 위치 공유를 중지했습니다.';
          });
        }
      } else if (mounted) {
        setState(() => error = '서버 연결을 확인해 주세요. 잠시 후 다시 시도합니다.');
      }
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
    if (state?['status'] == 'active' || state?['status'] == 'pickup_pending') {
      editingPickup = true;
    }
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
    walking = null;
    selectedByUser = false;
    editingPickup = false;
    if (mounted) setState(() {});
  });

  Future<void> estimateWalking() async {
    LatLng? candidate = waitingLocation;
    final waitingMap = MapController();
    String? dialogError;
    bool locating = false;
    final chosen = await showDialog<LatLng>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('기다리는 장소 선택'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '기다릴 장소를 지도에서 선택하거나 현재 위치를 사용하세요. 확인하면 선택한 장소와 승차 지점을 도보 시간 계산을 위해 TMAP에 전송합니다.',
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 260,
                    child: FlutterMap(
                      mapController: waitingMap,
                      options: MapOptions(
                        initialCenter: candidate ?? selected,
                        initialZoom: 15,
                        onTap: (_, point) => setDialogState(() {
                          candidate = point;
                          dialogError = null;
                        }),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName:
                              'io.pickupmate.pickup_passenger',
                        ),
                        MarkerLayer(
                          markers: [
                            if (candidate != null)
                              Marker(
                                point: candidate!,
                                width: 45,
                                height: 45,
                                child: const Icon(
                                  Icons.person_pin_circle,
                                  size: 42,
                                  color: navy,
                                ),
                              ),
                            if (state?['pickup'] is Map<String, dynamic>)
                              Marker(
                                point: LatLng(
                                  (state!['pickup']['lat'] as num).toDouble(),
                                  (state!['pickup']['lon'] as num).toDouble(),
                                ),
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  Icons.location_on,
                                  color: mint,
                                  size: 38,
                                ),
                              ),
                          ],
                        ),
                        const RichAttributionWidget(
                          attributions: [
                            TextSourceAttribution('OpenStreetMap contributors'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (dialogError != null)
                    Text(
                      dialogError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  if (candidate != null)
                    Text(
                      '대기 장소: ${candidate!.latitude.toStringAsFixed(5)}, ${candidate!.longitude.toStringAsFixed(5)}',
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: locating ? null : () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: locating
                  ? null
                  : () async {
                      setDialogState(() {
                        locating = true;
                        dialogError = null;
                      });
                      try {
                        final current = await position();
                        if (!dialogContext.mounted) return;
                        final point = LatLng(
                          current.latitude,
                          current.longitude,
                        );
                        setDialogState(() {
                          candidate = point;
                          locating = false;
                        });
                        waitingMap.move(point, 16);
                      } catch (_) {
                        if (dialogContext.mounted) {
                          setDialogState(() {
                            locating = false;
                            dialogError = '현재 위치를 확인하지 못했습니다. 위치 권한을 확인해 주세요.';
                          });
                        }
                      }
                    },
              child: Text(locating ? '위치 확인 중' : '현재 위치 사용'),
            ),
            FilledButton(
              onPressed: locating || candidate == null
                  ? null
                  : () => Navigator.pop(dialogContext, candidate),
              child: const Text('선택한 장소 사용'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await run(() async {
      final result = await api.update('walking-estimate', {
        'lat': chosen.latitude,
        'lon': chosen.longitude,
      });
      waitingLocation = chosen;
      walking = result;
      if (mounted) setState(() {});
    });
  }

  Future<void> setSharing(bool enabled) async {
    if (!enabled) {
      await run(() async {
        sharing = false;
        await locationStream?.cancel();
        locationStream = null;
        state = await api.update('location-consent', {'enabled': false});
        lastLocation = null;
      });
      return;
    }
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('백그라운드 위치 공유'),
        content: const Text(
          '픽업 중에는 다른 앱을 사용하거나 화면이 꺼져도 현재 위치를 운전자에게 보냅니다. 스위치를 끄거나 픽업을 마치면 공유가 중단됩니다. 앱을 강제 종료하면 중단될 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('동의하고 계속'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    await run(() async {
      final p = await position();
      var permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.always) {
        throw Exception('백그라운드 공유를 위해 기기 설정에서 위치 권한을 항상 허용해 주세요.');
      }
      if (!foreground || !mounted) return;
      state = await api.update('location-consent', {'enabled': true});
      try {
        await api.update('location', {'lat': p.latitude, 'lon': p.longitude});
        sharing = true;
        lastLocation = DateTime.now();
        final LocationSettings settings;
        if (Platform.isAndroid) {
          settings = AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            intervalDuration: const Duration(seconds: 15),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: '픽업메이트 위치 공유 중',
              notificationText: '픽업 중 운전자에게 위치를 공유하고 있습니다.',
              enableWakeLock: true,
            ),
          );
        } else if (Platform.isIOS) {
          settings = AppleSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
          );
        } else {
          settings = const LocationSettings(accuracy: LocationAccuracy.high);
        }
        locationStream =
            Geolocator.getPositionStream(locationSettings: settings).listen(
              (position) async {
                if (!sharing || locationBusy) return;
                if (lastLocation != null &&
                    DateTime.now().difference(lastLocation!) <
                        const Duration(seconds: 15)) {
                  return;
                }
                locationBusy = true;
                try {
                  await api.update('location', {
                    'lat': position.latitude,
                    'lon': position.longitude,
                  });
                  lastLocation = DateTime.now();
                } catch (_) {
                  if (mounted) {
                    setState(() => error = '위치 전송에 실패했습니다. 연결을 다시 확인합니다.');
                  }
                } finally {
                  locationBusy = false;
                }
              },
              onError: (_) async {
                sharing = false;
                await locationStream?.cancel();
                locationStream = null;
                try {
                  await api.update('location-consent', {'enabled': false});
                } catch (_) {}
                if (mounted) {
                  setState(() => error = '위치 권한 또는 위치 서비스를 확인해 주세요.');
                }
              },
            );
      } catch (_) {
        sharing = false;
        await api.update('location-consent', {'enabled': false});
        rethrow;
      }
    });
  }

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
      await locationStream?.cancel();
      locationStream = null;
      try {
        await api.update('location-consent', {'enabled': false});
      } catch (_) {}
      if (mounted) setState(() => error = '위치를 가져오지 못해 위치 공유를 중지했습니다.');
    } finally {
      locationBusy = false;
    }
  }

  Future<void> dictateMessage() async {
    try {
      if (listening) {
        await voiceInput.stop();
        if (mounted) setState(() => listening = false);
        return;
      }
      final available = await voiceInput.initialize(
        onStatus: (status) {
          if (mounted && (status == 'done' || status == 'notListening')) {
            setState(() => listening = false);
          }
        },
        onError: (_) {
          if (mounted) {
            setState(() {
              listening = false;
              error = '음성 인식에 실패했습니다. 마이크 권한과 연결 상태를 확인해 주세요.';
            });
          }
        },
      );
      if (!available) {
        throw Exception('기기의 음성 인식을 사용할 수 없습니다.');
      }
      if (mounted) {
        setState(() {
          listening = true;
          error = null;
        });
      }
      await voiceInput.listen(
        listenOptions: stt.SpeechListenOptions(
          localeId: 'ko_KR',
          listenFor: const Duration(seconds: 30),
        ),
        onResult: (result) {
          if (!mounted) return;
          final text = result.recognizedWords;
          setState(() {
            message.text = text.runes.take(160).map(String.fromCharCode).join();
            message.selection = TextSelection.collapsed(
              offset: message.text.length,
            );
          });
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          listening = false;
          error = '음성 인식을 시작하지 못했습니다. 마이크 권한을 확인해 주세요.';
        });
      }
    }
  }

  Future<void> readMessage(String text) async {
    try {
      await voiceReader.stop();
      await voiceReader.setLanguage('ko-KR');
      await voiceReader.speak(text);
    } catch (_) {
      if (mounted) {
        setState(() => error = '메시지를 읽지 못했습니다. 기기의 한국어 음성 설정을 확인해 주세요.');
      }
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
    final walkSeconds = walking?['walkingSeconds'] as int?;
    final departure = eta != null && walkSeconds != null
        ? eta - walkSeconds - 120
        : null;
    final messages = (state?['messages'] as List<dynamic>?) ?? [];
    final closed = status == 'finished' || status == 'expired';
    if (state != null && !closed) {
      return _tripExperience(
        active: active,
        pickup: pickup,
        driver: driver,
        eta: eta,
        departure: departure,
        messages: messages,
      );
    }
    return Scaffold(
      appBar: AppBar(
        backgroundColor: canvas,
        foregroundColor: navy,
        leadingWidth: 64,
        leading: Padding(
          padding: const EdgeInsets.only(left: 18, top: 8, bottom: 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: navy,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Text(
                'p.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 23,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.5,
                ),
              ),
            ),
          ),
        ),
        title: const Text(
          '픽업메이트',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (state == null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: mint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'PICKUP MATE  /  PASSENGER',
                    style: TextStyle(
                      color: Color(0xFF8B6655),
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                '오늘의 만남을\n준비해 볼까요?',
                style: TextStyle(
                  color: navy,
                  fontSize: 29,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.2,
                  height: 1.22,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '요청을 확인하고 만날 장소를 정해주세요.',
                style: TextStyle(color: softInk, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 27),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '내 픽업',
                      style: TextStyle(
                        color: navy,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Container(
                    width: 30,
                    height: 30,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE9EDE2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.north_east_rounded,
                      size: 16,
                      color: navy,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ] else ...[
              const SizedBox(height: 8),
              const Text(
                'PICKUP MATE  ·  탑승자',
                style: TextStyle(
                  color: mint,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '픽업이 종료됐어요',
                style: TextStyle(
                  color: navy,
                  fontWeight: FontWeight.w800,
                  fontSize: 27,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (firebaseReady && state == null)
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
                                      await locationStream?.cancel();
                                      locationStream = null;
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
            else if (!firebaseReady && state == null)
              _card(
                const Row(
                  children: [
                    _IconBadge(icon: Icons.phonelink_lock_rounded),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '휴대전화 인증',
                            style: TextStyle(
                              color: ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Firebase 설정 후 이용할 수 있어요.',
                            style: TextStyle(color: softInk, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (kDebugMode && state == null)
              _card(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '개발용 시연',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: navy,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '실제 탑승자 계정 연동 전까지 테스트 요청을 표시합니다. 실제 위치나 개인정보는 입력하지 마세요.',
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: busy ? null : loadDemo,
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: const Text('데모 요청 확인'),
                      ),
                    ),
                    if (kDebugMode && !kIsWeb && !Platform.isAndroid)
                      const Text('로컬 HTTP 시연은 Android 에뮬레이터에서 사용할 수 있습니다.'),
                  ],
                ),
              ),
            if (state == null) ...[const SizedBox(height: 22), _homeHero()],
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
              if (firebaseReady && FirebaseAuth.instance.currentUser != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: busy ? null : loadInbox,
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('요청 목록'),
                  ),
                ),
              const SizedBox(height: 14),
              _statusCard(
                status: status?.toString(),
                closed: closed,
                active: active,
                pickupLabel: pickup?['label']?.toString(),
                eta: eta,
              ),
              if (closed && kDebugMode && !api.accountMode)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FilledButton.icon(
                    onPressed: busy ? null : loadDemo,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('데모 요청 다시 보기'),
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
                      const Text(
                        '지도를 눌러 안전하게 만날 수 있는 장소를 선택해 주세요.',
                        style: TextStyle(color: softInk, height: 1.4),
                      ),
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
                            ? '선택한 위치를 확인해 주세요.'
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
                          '동의하면 픽업 중 다른 앱을 사용할 때도 위치를 공유합니다.',
                        ),
                        value: sharing,
                        onChanged: busy ? null : setSharing,
                      ),
                      if (!sharing)
                        TextButton.icon(
                          onPressed: busy
                              ? null
                              : () => Geolocator.openAppSettings(),
                          icon: const Icon(Icons.settings),
                          label: const Text('위치 권한 설정 열기'),
                        ),
                      if (api.accountMode && status == 'active') ...[
                        const Divider(),
                        TextButton.icon(
                          onPressed: busy ? null : estimateWalking,
                          icon: const Icon(Icons.directions_walk),
                          label: const Text('대기 장소 선택하고 도보 시간 확인'),
                        ),
                        if (waitingLocation != null && walking != null)
                          Text(
                            '선택한 대기 장소: ${waitingLocation!.latitude.toStringAsFixed(5)}, ${waitingLocation!.longitude.toStringAsFixed(5)}',
                          ),
                        if (walking != null)
                          Text(
                            '도보 약 ${((walking!['walkingSeconds'] as int) / 60).ceil()}분 · ${departure == null
                                ? '차량 도착 시간 확인 중'
                                : departure <= 0
                                ? '지금 출발을 준비해 주세요'
                                : '약 ${(departure / 60).ceil()}분 뒤 출발 준비'}',
                          ),
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
                        _messageBubble(item as Map<String, dynamic>),
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
                            onPressed: busy ? null : dictateMessage,
                            icon: Icon(
                              listening ? Icons.mic_off : Icons.mic,
                              color: navy,
                            ),
                            tooltip: listening ? '음성 입력 중지' : '음성으로 입력',
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

  Widget _homeHero() => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
    decoration: BoxDecoration(
      color: navy,
      borderRadius: BorderRadius.circular(22),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '가까워지는 세 단계',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF465D52),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'HOW IT WORKS',
                style: TextStyle(
                  color: Color(0xFFD9E7D5),
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .6,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _HomeStep(
                number: '01',
                title: '요청 확인',
                icon: Icons.notifications_none_rounded,
              ),
            ),
            Expanded(
              child: _HomeStep(
                number: '02',
                title: '장소 선택',
                icon: Icons.place_outlined,
              ),
            ),
            Expanded(
              child: _HomeStep(
                number: '03',
                title: '서로 위치 확인',
                icon: Icons.near_me_outlined,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Future<void> _leaveTrip() async {
    if (api.accountMode &&
        firebaseReady &&
        FirebaseAuth.instance.currentUser != null) {
      await loadInbox();
      return;
    }
    await run(() async {
      if (sharing) {
        await api.update('location-consent', {'enabled': false});
        sharing = false;
        await locationStream?.cancel();
        locationStream = null;
      }
      poll?.cancel();
      api.id = null;
      api.token = null;
      state = null;
      walking = null;
      waitingLocation = null;
      if (mounted) setState(() {});
    });
  }

  Widget _tripExperience({
    required bool active,
    required Map<String, dynamic>? pickup,
    required Map<String, dynamic>? driver,
    required int? eta,
    required int? departure,
    required List<dynamic> messages,
  }) {
    final topInset = MediaQuery.paddingOf(context).top;
    final routePending = state?['status'] == 'pickup_pending';
    final pickupPoint = pickup == null
        ? null
        : LatLng(
            (pickup['lat'] as num).toDouble(),
            (pickup['lon'] as num).toDouble(),
          );
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: map,
              options: MapOptions(
                initialCenter: pickupPoint ?? selected,
                initialZoom: 15,
                onTap: (_, point) => setState(() {
                  selected = point;
                  selectedByUser = true;
                  if (active) editingPickup = true;
                }),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'io.pickupmate.pickup_passenger',
                ),
                MarkerLayer(
                  markers: [
                    if (pickupPoint != null && !selectedByUser)
                      Marker(
                        point: pickupPoint,
                        width: 54,
                        height: 54,
                        child: const Icon(
                          Icons.location_on_rounded,
                          color: mint,
                          size: 50,
                        ),
                      ),
                    if (selectedByUser)
                      Marker(
                        point: selected,
                        width: 54,
                        height: 54,
                        child: const Icon(
                          Icons.location_on_rounded,
                          color: mint,
                          size: 50,
                        ),
                      ),
                    if (driver != null)
                      Marker(
                        point: LatLng(
                          (driver['lat'] as num).toDouble(),
                          (driver['lon'] as num).toDouble(),
                        ),
                        width: 48,
                        height: 48,
                        child: Container(
                          decoration: BoxDecoration(
                            color: navy,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: [
                              BoxShadow(
                                color: navy.withValues(alpha: .25),
                                blurRadius: 12,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.directions_car_filled_rounded,
                            size: 23,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
                const RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: topInset + 12,
            left: 16,
            right: 16,
            child: Row(
              children: [
                _floatingIcon(
                  icon: Icons.arrow_back_rounded,
                  label: '요청 목록',
                  onTap: busy ? null : _leaveTrip,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: navy.withValues(alpha: .12),
                          blurRadius: 20,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: const BoxDecoration(
                            color: mint,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            active
                                ? (routePending ? '승차 위치 확인 중' : '운전자와 만나는 중')
                                : '픽업 위치를 정해주세요',
                            style: const TextStyle(
                              color: navy,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(
                          Icons.near_me_rounded,
                          color: mint,
                          size: 20,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: topInset + 78,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .9),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Text(
                '© OpenStreetMap contributors',
                style: TextStyle(color: Color(0xFF4C594D), fontSize: 10),
              ),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: .46,
            minChildSize: .27,
            maxChildSize: .88,
            builder: (context, scrollController) => Container(
              decoration: BoxDecoration(
                color: const Color(0xFFFEFCF7),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: navy.withValues(alpha: .16),
                    blurRadius: 24,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.fromLTRB(
                  22,
                  10,
                  22,
                  24 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFD8D6CC),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              active ? 'PICKUP IN PROGRESS' : 'PICKUP REQUEST',
                              style: const TextStyle(
                                color: mint,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              active
                                  ? (routePending
                                        ? '경로를 확인하고 있어요'
                                        : (eta == null
                                              ? '차량 위치를 확인하고 있어요'
                                              : '약 ${(eta / 60).ceil().clamp(1, 9999)}분 후 도착'))
                                  : '어디서 만날까요?',
                              style: const TextStyle(
                                color: navy,
                                fontSize: 25,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -.8,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              active
                                  ? (pickup?['label']?.toString() ??
                                        '승차 위치를 확인하고 있어요')
                                  : '지도를 눌러 안전한 승차 위치를 선택해요',
                              style: const TextStyle(
                                color: softInk,
                                fontSize: 13.5,
                                height: 1.35,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8E6DB),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          active
                              ? Icons.directions_car_filled_rounded
                              : Icons.location_on_rounded,
                          color: mint,
                          size: 25,
                        ),
                      ),
                    ],
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  ],
                  if (busy) const LinearProgressIndicator(),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F2EA),
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(color: const Color(0xFFEAE5DA)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.place_rounded,
                            color: mint,
                            size: 21,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '승차 위치',
                                style: TextStyle(
                                  color: softInk,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                selectedByUser
                                    ? '지도에서 선택한 위치'
                                    : (pickup?['label']?.toString() ??
                                          '지도에서 위치를 선택해 주세요'),
                                style: const TextStyle(
                                  color: ink,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: busy ? null : useCurrentLocation,
                          icon: const Icon(
                            Icons.my_location_rounded,
                            color: navy,
                          ),
                          tooltip: '현재 위치에서 선택',
                        ),
                      ],
                    ),
                  ),
                  if (active && !editingPickup) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                editingPickup = true;
                                selectedByUser = false;
                              }),
                        icon: const Icon(Icons.edit_location_alt_outlined),
                        label: const Text('승차 위치 변경'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: navy,
                          minimumSize: const Size(0, 48),
                          side: const BorderSide(color: Color(0xFFDADBCF)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (!active || editingPickup) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: label,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: '승차 지점 이름',
                        hintText: '예: 강남역 2번 출구',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: busy ? null : setPickup,
                        child: Text(
                          active ? '변경한 승차 위치 보내기' : '이 위치로 픽업 요청 수락',
                        ),
                      ),
                    ),
                    if (active)
                      Center(
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  editingPickup = false;
                                  selectedByUser = false;
                                }),
                          child: const Text('변경 취소'),
                        ),
                      ),
                  ],
                  if (!active)
                    Center(
                      child: TextButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                state = await api.update('decline', {});
                                if (mounted) setState(() {});
                              }),
                        child: const Text('요청 거절'),
                      ),
                    ),
                  if (active) ...[
                    const SizedBox(height: 22),
                    const Text(
                      '함께 만날 준비',
                      style: TextStyle(
                        color: navy,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('내 현재 위치 공유'),
                      subtitle: const Text('동의하면 다른 앱을 사용할 때도 공유해요.'),
                      value: sharing,
                      onChanged: busy ? null : setSharing,
                    ),
                    if (!sharing)
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => Geolocator.openAppSettings(),
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('위치 권한 설정 열기'),
                      ),
                    if (api.accountMode && state?['status'] == 'active') ...[
                      TextButton.icon(
                        onPressed: busy ? null : estimateWalking,
                        icon: const Icon(Icons.directions_walk_rounded),
                        label: const Text('대기 장소와 도보 시간 설정'),
                      ),
                      if (waitingLocation != null && walking != null)
                        const Text(
                          '대기 장소를 선택했어요',
                          style: TextStyle(color: softInk),
                        ),
                      if (walking != null)
                        Text(
                          '도보 약 ${((walking!['walkingSeconds'] as int) / 60).ceil()}분 · ${departure == null
                              ? '차량 도착 시간 확인 중'
                              : departure <= 0
                              ? '지금 출발을 준비해 주세요'
                              : '약 ${(departure / 60).ceil()}분 뒤 출발 준비'}',
                          style: const TextStyle(
                            color: ink,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                    const SizedBox(height: 20),
                    const Divider(color: Color(0xFFE7E3D9)),
                    const SizedBox(height: 14),
                    const Text(
                      '메시지',
                      style: TextStyle(
                        color: navy,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (messages.isEmpty)
                      const Text(
                        '아직 주고받은 메시지가 없어요.',
                        style: TextStyle(color: softInk),
                      ),
                    for (final item
                        in messages.reversed.take(10).toList().reversed)
                      _messageBubble(item as Map<String, dynamic>),
                    const SizedBox(height: 8),
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
                          onPressed: busy ? null : dictateMessage,
                          icon: Icon(
                            listening ? Icons.mic_off : Icons.mic_none_rounded,
                            color: navy,
                          ),
                          tooltip: listening ? '음성 입력 중지' : '음성으로 입력',
                        ),
                        IconButton(
                          onPressed: busy ? null : sendMessage,
                          icon: const Icon(Icons.send_rounded, color: mint),
                          tooltip: '메시지 보내기',
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _floatingIcon({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(15),
    elevation: 3,
    child: IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: navy),
      tooltip: label,
    ),
  );

  Widget _statusCard({
    required String? status,
    required bool closed,
    required bool active,
    required String? pickupLabel,
    required int? eta,
  }) {
    final title = closed
        ? '픽업이 종료됐어요'
        : active
        ? '픽업 진행 중'
        : '요청 확인 대기';
    final subtitle = closed
        ? '위치 공유가 종료되었습니다.'
        : active
        ? '운전자와 만날 준비를 해요'
        : '승차 지점을 선택하고 요청을 수락해 주세요.';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: navy,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: navy.withValues(alpha: .12),
            blurRadius: 22,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: closed ? Colors.white54 : mint,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.directions_car_rounded,
                color: Color(0xFF8FDCDA),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Text(
            active && eta != null
                ? '약 ${(eta / 60).ceil().clamp(1, 9999)}분 후 도착'
                : subtitle,
            style: TextStyle(
              color: Colors.white,
              fontSize: active && eta != null ? 26 : 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -.5,
            ),
          ),
          if (pickupLabel != null && !closed) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.location_on_rounded,
                  size: 16,
                  color: Color(0xFF83DFD2),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    pickupLabel,
                    style: const TextStyle(
                      color: Color(0xFFDFECF8),
                      fontSize: 13,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (active && eta == null) ...[
            const SizedBox(height: 8),
            const Text(
              '도착 시간 확인 중',
              style: TextStyle(color: Color(0xFFB4C9DF), fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _messageBubble(Map<String, dynamic> item) {
    final mine = item['sender'] == 'passenger';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconBadge(
            icon: mine ? Icons.person_rounded : Icons.directions_car_rounded,
            small: true,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mine ? '나' : '운전자',
                  style: const TextStyle(
                    color: softInk,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: mine
                        ? const Color(0xFFF8E6DB)
                        : const Color(0xFFF3F0E8),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Text(
                    item['text']?.toString() ?? '',
                    style: const TextStyle(color: ink, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => readMessage(item['text']?.toString() ?? ''),
            icon: const Icon(Icons.volume_up_outlined, color: softInk),
            tooltip: '메시지 읽기',
          ),
        ],
      ),
    );
  }

  Widget _card(Widget child) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFE8E3D8)),
      boxShadow: [
        BoxShadow(
          color: navy.withValues(alpha: .035),
          blurRadius: 18,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    child: child,
  );
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, this.small = false});
  final IconData icon;
  final bool small;
  @override
  Widget build(BuildContext context) => Container(
    width: small ? 34 : 44,
    height: small ? 34 : 44,
    decoration: BoxDecoration(
      color: const Color(0xFFF8E6DB),
      borderRadius: BorderRadius.circular(small ? 11 : 14),
    ),
    child: Icon(icon, size: small ? 18 : 22, color: const Color(0xFFC84D36)),
  );
}

class _HomeStep extends StatelessWidget {
  const _HomeStep({
    required this.number,
    required this.title,
    required this.icon,
  });
  final String number, title;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF445C51),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: const Color(0xFFF5D2B8), size: 20),
      ),
      const SizedBox(height: 10),
      Text(
        number,
        style: const TextStyle(
          color: Color(0xFFA8BFAE),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}
