import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Configuration is supplied at build time; no service-account keys belong in the app.
bool firebaseReady = false;

Future<void> configureFirebase() async {
  const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  const senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  const androidAppId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
  const iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;
  final appId = Platform.isAndroid ? androidAppId : iosAppId;
  if (projectId.isEmpty ||
      apiKey.isEmpty ||
      senderId.isEmpty ||
      appId.isEmpty) {
    return;
  }
  try {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: senderId,
        projectId: projectId,
      ),
    );
    firebaseReady = true;
  } on FirebaseException {
    firebaseReady = false;
  }
}

class PhoneLogin extends StatefulWidget {
  const PhoneLogin({super.key, required this.onSignedIn});
  final VoidCallback onSignedIn;
  @override
  State<PhoneLogin> createState() => _PhoneLoginState();
}

class _PhoneLoginState extends State<PhoneLogin> {
  final phone = TextEditingController();
  final code = TextEditingController();
  String? verificationId;
  String? status;
  bool busy = false;

  @override
  void dispose() {
    phone.dispose();
    code.dispose();
    super.dispose();
  }

  String normalized(String raw) {
    final trimmed = raw.replaceAll(RegExp(r'[\s-]'), '');
    if (RegExp(r'^010\d{8}$').hasMatch(trimmed)) {
      return '+82${trimmed.substring(1)}';
    }
    if (RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(trimmed)) return trimmed;
    throw const FormatException('휴대전화 번호를 01012345678 또는 국제번호로 입력해 주세요.');
  }

  Future<void> send() async {
    if (busy) return;
    setState(() {
      busy = true;
      status = null;
    });
    try {
      final number = normalized(phone.text);
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: number,
        verificationCompleted: (credential) async {
          try {
            await FirebaseAuth.instance.signInWithCredential(credential);
            if (mounted) widget.onSignedIn();
          } on FirebaseAuthException catch (e) {
            if (mounted) {
              setState(() {
                busy = false;
                status = '인증에 실패했습니다: ${e.code}';
              });
            }
          }
        },
        verificationFailed: (e) {
          if (mounted) {
            setState(() {
              busy = false;
              status = '인증번호를 보내지 못했습니다: ${e.code}';
            });
          }
        },
        codeSent: (id, _) {
          if (mounted) {
            setState(() {
              verificationId = id;
              busy = false;
              status = '인증번호를 보냈습니다.';
            });
          }
        },
        codeAutoRetrievalTimeout: (id) {
          if (mounted) {
            setState(() {
              verificationId = id;
              busy = false;
            });
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          status = e is FormatException ? e.message : '인증을 시작하지 못했습니다.';
        });
      }
    }
  }

  Future<void> confirm() async {
    final id = verificationId;
    if (busy || id == null) return;
    setState(() {
      busy = true;
      status = null;
    });
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: id,
        smsCode: code.text.trim(),
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      if (mounted) widget.onSignedIn();
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          status = '인증에 실패했습니다: ${e.code}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '휴대전화 인증',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text('전화번호는 본인 확인과 픽업 요청 연결에 사용됩니다. 인증을 위해 Firebase에 전화번호가 전달됩니다.'),
      const SizedBox(height: 12),
      TextField(
        controller: phone,
        keyboardType: TextInputType.phone,
        enabled: !busy,
        decoration: const InputDecoration(
          labelText: '휴대전화 번호',
          hintText: '01012345678',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      FilledButton(onPressed: busy ? null : send, child: const Text('인증번호 받기')),
      if (verificationId != null) ...[
        TextField(
          controller: code,
          keyboardType: TextInputType.number,
          enabled: !busy,
          decoration: const InputDecoration(
            labelText: '인증번호',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: busy ? null : confirm,
          child: const Text('인증하기'),
        ),
      ],
      if (status != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(status!)),
    ],
  );
}
