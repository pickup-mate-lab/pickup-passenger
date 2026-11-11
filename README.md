# 픽업메이트 탑승자 앱

Flutter로 Android와 iOS를 지원하는 탑승자 앱을 개발하는 프로젝트입니다. `app/`은 Flutter 앱, `server/`는 Go 서버입니다. 현재는 개발 환경과 서버 상태 확인용 시작 프로젝트이며 탑승자 기능이나 차량 앱과의 연동은 아직 구현하지 않았습니다.

## 요구 사항

- Flutter SDK (Dart SDK 포함), Android Studio와 Android SDK
- Go 1.27 이상
- iOS 빌드와 테스트에는 macOS, Xcode 및 필요한 Apple 개발 환경

## Android 실행

Android Studio에서 `app/` 폴더를 열고 Flutter 및 Dart 플러그인을 설치합니다. Android 휴대전화 에뮬레이터 또는 기기를 선택한 뒤 실행하거나 PowerShell에서 다음 명령을 사용합니다.

```powershell
cd app
flutter doctor
flutter pub get
flutter run
```

Android Automotive 에뮬레이터는 차량용 기기이므로 탑승자 앱은 일반 Android 휴대전화 에뮬레이터로 테스트합니다.

## iOS 실행

Mac에서 Flutter와 Xcode를 설치한 뒤 `app/`에서 `flutter pub get`, `flutter run`을 실행합니다. 실제 iPhone에 설치할 때는 Xcode 서명 설정이 필요합니다. Windows에서는 iOS 빌드와 iOS 시뮬레이터 실행을 검증할 수 없습니다.

## Go 개발 서버

```powershell
cd server
go run .
```

`http://127.0.0.1:8080/health`에서 상태를 확인할 수 있습니다. 이 서버에는 인증, 픽업 데이터 저장, 차량 앱과의 연동이 없으며 로컬 개발용입니다. 차량 앱의 기존 Python 데모 서버를 대체하지 않습니다.

## 다음 개발 범위

- 탑승자 인증 및 운전자 요청 확인·수락
- 탑승자 지정 승차 지점과 위치 공유
- 운전자 앱과 서버 간 픽업 상태 및 메시지 연동
- 도착 알림과 개인정보 보호 설계

실제 연동에 필요한 API 규약과 운영용 인증은 이후 함께 설계합니다.
