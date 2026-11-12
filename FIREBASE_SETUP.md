# Firebase와 TMAP 연동 준비

이 문서는 구현 중인 로컬 개발용 연동의 준비 사항입니다. 실제 사용자 서비스로 배포하기 전에 신원 인증, 개인정보 처리, 접근 통제, 암호화, 데이터 보존 및 삭제 정책, 서버 운영과 알림 전달을 별도로 검증해야 합니다.

## 1. Firebase 프로젝트

1. [Firebase 콘솔](https://console.firebase.google.com/)에서 프로젝트를 만듭니다.
2. Authentication의 로그인 방법에서 휴대전화 번호를 활성화합니다. 실제 SMS 발송에는 Firebase의 현재 요금제 및 제한을 확인해야 합니다. 테스트에서는 [Firebase Authentication 에뮬레이터](https://firebase.google.com/docs/emulator-suite/connect_auth)를 사용하면 실제 SMS가 전송되지 않습니다.
3. Android 앱 두 개를 각각 등록합니다.
   - 탑승자 Flutter 앱: `io.pickupmate.pickup_passenger`
   - 운전자 PLEOS 앱: `com.example.pickuppleos`
   - iOS 탑승자 앱: `io.pickupmate.pickupPassenger` (Firebase에 iOS 앱으로 별도 등록)
4. 각 Android 앱의 실제 서명 인증서 지문을 Firebase 설정에 등록합니다. 테스트·배포 서명이 다르면 각각 확인합니다. iOS에서는 Xcode 서명, 푸시 기능, APNs 등 Apple 환경의 별도 설정이 필요합니다.

Firebase 프로젝트와 앱 식별자는 두 앱이 같은 프로젝트의 별도 앱으로 등록되어야 합니다. Google 서비스 계정 JSON이나 비밀 키를 저장소에 넣거나 채팅에 붙여 넣지 마세요.

## 2. 탑승자 앱 설정

Firebase 프로젝트의 공개 클라이언트 설정값을 각 빌드의 `--dart-define`으로 전달하는 방식이 준비되어 있습니다. Android와 iOS의 앱 ID는 서로 다릅니다. API 키는 프로젝트의 접근 제한과 사용량 정책을 설정해야 합니다.

```powershell
flutter run --dart-define=FIREBASE_PROJECT_ID=<프로젝트_ID> --dart-define=FIREBASE_API_KEY=<클라이언트_API_키> --dart-define=FIREBASE_SENDER_ID=<발신자_ID> --dart-define=FIREBASE_ANDROID_APP_ID=<안드로이드_앱_ID> --dart-define=PICKUP_API_URL=<HTTPS_서버_URL>
```

iOS 빌드에서는 Android 앱 ID 대신 `FIREBASE_IOS_APP_ID`를 설정합니다. iOS 푸시 알림에는 Apple 개발자 계정의 APNs 설정과 Xcode 권한이 추가로 필요하며, macOS에서 검증해야 합니다.

## 3. 운전자 앱 설정

차량 앱의 `app/src/main/res/values/firebase_config.xml`에 프로젝트 설정값을 넣는 방식이 준비되어 있습니다. 이 파일은 Git에서 제외해야 합니다.

```xml
<resources>
    <string name="pickup_firebase_api_key">클라이언트 API 키</string>
    <string name="pickup_firebase_app_id">운전자 Android 앱 ID</string>
    <string name="pickup_firebase_project_id">프로젝트 ID</string>
    <string name="pickup_firebase_sender_id">발신자 ID</string>
</resources>
```

PLEOS 기기에서 Google Play 서비스, Play Integrity 또는 대체 인증 경로가 실제로 동작하는지는 별도 테스트가 필요합니다. 전화 인증은 주차 중에 진행하도록 안내하며, 주행 중 사용 가능한 UI인지도 차량 앱 요구 사항에 맞춰 검증해야 합니다.

## 4. Go 서버 설정

Firebase Admin SDK가 검증한 ID 토큰의 사용자 ID와 전화번호로 픽업을 구분합니다. 서버에는 `FIREBASE_PROJECT_ID`와 Firebase Admin용 애플리케이션 기본 사용자 인증 정보가 필요합니다. 로컬 인증 에뮬레이터는 별도로 명시한 개발 테스트에서만 사용합니다.

Go 서버는 **127.0.0.1에만 바인딩**하며, 실제 휴대전화 간 연결을 위한 HTTPS 프록시 구성은 `deploy/README.md`에 준비했습니다. 실제 서버와 도메인, 자격 증명은 별도로 설정해야 합니다. `.data` 아래 로컬 상태 파일은 Git에 포함하지 않습니다. 파일 저장 자체가 운영 환경에 필요한 암호화나 접근 통제를 대신하지는 않습니다.

## 5. TMAP 보행 경로

[TMAP 보행자 경로 안내](https://tmap-skopenapi.readme.io/reference/%EA%B2%BD%EB%A1%9C%EC%95%88%EB%82%B4-%EC%83%98%ED%94%8C%EC%98%88%EC%A0%9C)를 사용하도록 준비했습니다. 서버의 `TMAP_APP_KEY` 환경 변수로 키를 설정하며 앱이나 저장소에 키를 넣지 않습니다. 요금, 사용량 제한과 데이터 사용 조건은 신청 전 [TMAP API 약관](https://tmapapi.tmapmobility.com/terms.html)을 확인합니다.

도보 경로 계산에는 사용자의 요청과 동의가 필요하며 그 시점의 위치와 승차 위치가 TMAP으로 전달됩니다. 차량의 신뢰할 수 있는 남은 시간이 제공되지 않을 때는 임의의 출발 시각을 표시하지 않습니다.

## 6. 검증 범위

로컬 가상 Firebase 전화 인증과 Go 서버의 ID 토큰 검증은 확인했습니다. 실제 SMS, FCM·APNs 발송, TMAP 실제 키 사용, PLEOS 기기의 Firebase 인증 및 iOS 실행은 각 서비스 설정과 기기를 준비한 다음 별도로 검증해야 합니다.
