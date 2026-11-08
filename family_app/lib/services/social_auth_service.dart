import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_line_sdk/flutter_line_sdk.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'api_helper.dart';
import 'auth_service.dart';
import '../config/api_config.dart';

// =======================================================
// เข้าสู่ระบบด้วย Google / LINE / Facebook
//
// 1) ให้ผู้ให้บริการยืนยันตัวตน (แอปของเจ้านั้น / หน้าเว็บ)
// 2) ส่งหลักฐาน (id_token / code) ให้ Server ตรวจกับผู้ให้บริการเอง
// 3) Server ตอบ token ของแอปกลับมา
//
// ค่าตั้งค่า (Client ID ต่าง ๆ) อ่านจาก Server → เปิด/ปิดได้โดยไม่ต้องสร้างแอปใหม่
// =======================================================

enum SocialProvider { google, line, facebook }

extension SocialProviderInfo on SocialProvider {
  String get key => name;

  String get label {
    switch (this) {
      case SocialProvider.google:
        return 'Google';
      case SocialProvider.line:
        return 'LINE';
      case SocialProvider.facebook:
        return 'Facebook';
    }
  }
}

// ผู้ใช้ปิดหน้าล็อกอินเอง → ไม่ต้องแสดงข้อผิดพลาด
class SocialLoginCanceled implements Exception {}

class SocialAuthService {
  static const String baseUrl = ApiConfig.baseUrl;

  static Map<String, dynamic>? _providers;

  static bool _googleReady = false;

  static String? _lineChannelReady;

  // =====================================================
  // ตั้งค่าจาก Server
  // =====================================================

  static Future<Map<String, dynamic>> providers({bool refresh = false}) async {
    final Map<String, dynamic>? cached = _providers;

    if (cached != null && !refresh) return cached;

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/auth/providers'),
        headers: {'Accept': 'application/json'},
      ),
    );

    final result = ApiHelper.decode(response);

    final dynamic raw = result['providers'];

    final Map<String, dynamic> providers = raw is Map
        ? Map<String, dynamic>.from(raw)
        : {};

    _providers = providers;

    return providers;
  }

  static Future<List<SocialProvider>> enabledProviders() async {
    final providers = await SocialAuthService.providers();

    return SocialProvider.values
        .where((provider) => providers[provider.key] is Map)
        .toList();
  }

  static Future<Map<String, dynamic>> _configOf(SocialProvider provider) async {
    final dynamic config = (await providers())[provider.key];

    if (config is! Map) {
      throw ApiException(
        'ยังไม่ได้เปิดใช้การเข้าสู่ระบบด้วย ${provider.label}',
      );
    }

    return Map<String, dynamic>.from(config);
  }

  // =====================================================
  // ขอหลักฐานจากผู้ให้บริการ
  // =====================================================

  static Future<Map<String, String>> _credential(
    SocialProvider provider,
  ) async {
    final config = await _configOf(provider);

    switch (provider) {
      case SocialProvider.google:
        return {'id_token': await _googleIdToken(config)};

      case SocialProvider.line:
        return {'id_token': await _lineIdToken(config)};

      case SocialProvider.facebook:
        return {'code': await _facebookCode(config)};
    }
  }

  static Future<String> _googleIdToken(Map<String, dynamic> config) async {
    final GoogleSignIn google = GoogleSignIn.instance;

    if (!_googleReady) {
      await google.initialize(
        serverClientId: config['server_client_id']?.toString(),
      );

      _googleReady = true;
    }

    try {
      final GoogleSignInAccount account = await google.authenticate();

      final String? idToken = account.authentication.idToken;

      if (idToken == null || idToken.isEmpty) {
        throw ApiException('ไม่ได้รับข้อมูลการเข้าสู่ระบบจาก Google');
      }

      return idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        throw SocialLoginCanceled();
      }

      throw ApiException('เข้าสู่ระบบด้วย Google ไม่สำเร็จ (${e.code.name})');
    } finally {
      // ครั้งหน้าให้เลือกบัญชีใหม่ได้
      google.signOut().catchError((_) {});
    }
  }

  static Future<String> _lineIdToken(Map<String, dynamic> config) async {
    final String channelId = config['channel_id']?.toString() ?? '';

    if (_lineChannelReady != channelId) {
      await LineSDK.instance.setup(channelId);
      _lineChannelReady = channelId;
    }

    try {
      final LoginResult result = await LineSDK.instance.login(
        scopes: const ['profile', 'openid'],
      );

      final String? idToken = result.accessToken.idTokenRaw;

      if (idToken == null || idToken.isEmpty) {
        throw ApiException('ไม่ได้รับข้อมูลการเข้าสู่ระบบจาก LINE');
      }

      // ใช้แค่ยืนยันตัวตน ไม่ต้องเก็บการล็อกอิน LINE ไว้ในเครื่อง
      LineSDK.instance.logout().catchError((_) {});

      return idToken;
    } on PlatformException catch (e) {
      if (e.code == 'CANCEL') throw SocialLoginCanceled();

      throw ApiException('เข้าสู่ระบบด้วย LINE ไม่สำเร็จ (${e.code})');
    }
  }

  // Facebook ใช้หน้าเว็บ: เข้าสู่ระบบ → Server ส่งกลับเข้าแอปด้วย klaikan://
  static Future<String> _facebookCode(Map<String, dynamic> config) async {
    final String state = _randomState();

    final String url = '${config['auth_url']}&state=$state';

    final String scheme = config['callback_scheme']?.toString() ?? 'klaikan';

    String callback;

    try {
      callback = await FlutterWebAuth2.authenticate(
        url: url,
        callbackUrlScheme: scheme,
      );
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') throw SocialLoginCanceled();

      throw ApiException('เข้าสู่ระบบด้วย Facebook ไม่สำเร็จ (${e.code})');
    }

    final Uri uri = Uri.parse(callback);

    // กันหน้าเว็บอื่นส่งผลการล็อกอินปลอมเข้ามา
    if (uri.queryParameters['state'] != state) {
      throw ApiException('การเข้าสู่ระบบด้วย Facebook ไม่ถูกต้อง กรุณาลองใหม่');
    }

    if (uri.queryParameters['error'] != null) throw SocialLoginCanceled();

    final String? code = uri.queryParameters['code'];

    if (code == null || code.isEmpty) {
      throw ApiException('ไม่ได้รับข้อมูลการเข้าสู่ระบบจาก Facebook');
    }

    return code;
  }

  static String _randomState() {
    final Random random = Random.secure();

    return base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  // =====================================================
  // เข้าสู่ระบบ / สมัคร
  // คืนค่าผลจาก Server (มี user + token) / ผู้ใช้ยกเลิก → SocialLoginCanceled
  // =====================================================

  static Future<Map<String, dynamic>> signIn(SocialProvider provider) async {
    final credential = await _credential(provider);

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/auth/social/${provider.key}'),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(credential),
      ),
    );

    // ยังไม่ได้เข้าสู่ระบบ → 401 ไม่ใช่ "เซสชันหมดอายุ"
    final result = ApiHelper.decode(response, session: false);

    final dynamic token = result['token'];

    if (token != null) {
      await AuthService.saveToken(token.toString());
    }

    return result;
  }

  // =====================================================
  // บัญชีที่เชื่อมไว้ (หน้าตั้งค่า)
  // =====================================================

  static Future<Map<String, String>> _authHeaders() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<Map<String, dynamic>> linkedAccounts() async {
    final headers = await _authHeaders();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl/social-accounts'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> link(SocialProvider provider) async {
    final credential = await _credential(provider);

    final headers = await _authHeaders();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/social-accounts/${provider.key}'),
        headers: headers,
        body: jsonEncode(credential),
      ),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> unlink(SocialProvider provider) async {
    final headers = await _authHeaders();

    final response = await ApiHelper.request(
      () => http.delete(
        Uri.parse('$baseUrl/social-accounts/${provider.key}'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }
}
