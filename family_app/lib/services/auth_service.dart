import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'api_helper.dart';
import 'app_log.dart';

// =======================================================
// เข้าสู่ระบบ / สมัคร / ตรวจเซสชันตอนเปิดแอป / ออกจากระบบ
// - ลบ token เฉพาะเมื่อเซิร์ฟเวอร์บอกว่า token ใช้ไม่ได้ (401) หรือผู้ใช้กดออกจากระบบ
// - เน็ตล่ม / หมดเวลารอ / เซิร์ฟเวอร์ผิดพลาด → เก็บ token ไว้ ให้ลองใหม่
// =======================================================

// ผลตรวจเซสชันตอนเปิดแอป
enum SessionState {
  // ไม่มี token ในเครื่อง → หน้าเข้าสู่ระบบ
  signedOut,
  // token ใช้ได้ → หน้าแรก
  signedIn,
  // token ไม่ถูกต้อง / หมดอายุ (ลบแล้ว) → หน้าเข้าสู่ระบบ + บอกเหตุผล
  expired,
  // มี token แต่ต่อเซิร์ฟเวอร์ไม่ได้ / ช้าเกินไป → ลองอีกครั้ง
  offline,
  // มี token แต่เซิร์ฟเวอร์ผิดพลาด → ลองอีกครั้ง
  serverError,
}

class SessionCheck {
  final SessionState state;
  final Map<String, dynamic>? user;
  final String? message;

  const SessionCheck(this.state, {this.user, this.message});
}

class AuthService {
  static const String baseUrl = ApiConfig.baseUrl;

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static const String _tokenKey = 'token';

  // ออกจากระบบ: รอเซิร์ฟเวอร์ยกเลิก token ไม่เกินเท่านี้
  static Duration logoutTimeLimit = const Duration(seconds: 5);

  static const Map<String, String> _jsonHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  // =====================================================
  // Register / Login
  // คืนข้อมูลจากเซิร์ฟเวอร์ (สำเร็จมี token / ไม่สำเร็จมี message ภาษาไทย)
  // เน็ตล่ม / หมดเวลา / เซิร์ฟเวอร์ผิดพลาด → ApiException
  // 401 / 422 / 429 ของหน้านี้ไม่ใช่ "เซสชันหมดอายุ" (session: false)
  // =====================================================

  static Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required String passwordConfirmation,
  }) async {
    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/register'),
        headers: _jsonHeaders,
        body: jsonEncode({
          'name': name,
          'email': email,
          'password': password,
          'password_confirmation': passwordConfirmation,
        }),
      ),
    );

    final data = ApiHelper.decode(response, session: false);

    await _saveTokenFrom(data);

    return data;
  }

  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/login'),
        headers: _jsonHeaders,
        body: jsonEncode({'email': email, 'password': password}),
      ),
    );

    final data = ApiHelper.decode(response, session: false);

    await _saveTokenFrom(data);

    return data;
  }

  static Future<void> _saveTokenFrom(Map<String, dynamic> data) async {
    final dynamic token = data['token'];

    if (token != null && token.toString().isNotEmpty) {
      await saveToken(token.toString());
    }
  }

  // =====================================================
  // บันทึก / อ่าน / ลบ Token
  // =====================================================

  // เช่น เข้าสู่ระบบด้วย Google / LINE / Facebook
  static Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  static Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  static Future<void> clearToken() async {
    await _storage.delete(key: _tokenKey);
  }

  // =====================================================
  // ตรวจเซสชันตอนเปิดแอป (GET /api/user)
  // =====================================================

  static Future<SessionCheck> checkSession() async {
    final String? token = await getToken();

    if (token == null || token.isEmpty) {
      return const SessionCheck(SessionState.signedOut);
    }

    try {
      final response = await ApiHelper.request(
        () => http.get(
          Uri.parse('$baseUrl/user'),
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ),
      );

      // token ไม่ถูกต้อง / หมดอายุ → ลบทิ้ง ให้เข้าสู่ระบบใหม่
      if (response.statusCode == 401) {
        await clearToken();

        return const SessionCheck(
          SessionState.expired,
          message: ApiHelper.sessionExpiredMessage,
        );
      }

      final data = ApiHelper.decode(response, session: false);

      if (response.statusCode == 200 && data['id'] != null) {
        return SessionCheck(SessionState.signedIn, user: data);
      }

      // 403 / 404 / อื่น ๆ: ไม่ใช่ token หมดอายุ → เก็บ token ไว้ ให้ลองใหม่
      AppLog.warn('Session check unexpected', response.statusCode);

      return SessionCheck(
        SessionState.serverError,
        message: data['message']?.toString() ?? ApiHelper.serverMessage,
      );
    } on ApiException catch (e) {
      final bool offline =
          e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout;

      return SessionCheck(
        offline ? SessionState.offline : SessionState.serverError,
        message: e.message,
      );
    }
  }

  // =====================================================
  // Logout
  // ลบ token ในเครื่องก่อน (ออกจากระบบทันทีแม้ไม่มีเน็ต)
  // แล้วขอให้เซิร์ฟเวอร์ยกเลิก token รอไม่เกิน logoutTimeLimit
  // =====================================================

  static Future<void> logout() async {
    final String? token = await getToken();

    await clearToken();

    if (token == null || token.isEmpty) {
      return;
    }

    try {
      await ApiHelper.request(
        () => http.post(
          Uri.parse('$baseUrl/logout'),
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ),
        timeLimit: logoutTimeLimit,
      );
    } catch (e) {
      // เซิร์ฟเวอร์ไม่ตอบ: ในเครื่องออกจากระบบแล้ว token ฝั่งเซิร์ฟเวอร์หมดอายุเองใน 30 วัน
      AppLog.warn('Logout request failed', e.runtimeType);
    }
  }

  // =====================================================
  // ลืมรหัสผ่าน (ยังไม่ได้เข้าสู่ระบบ → session: false)
  // 1) ขอรหัส 6 หลักทางอีเมล (ตอบข้อความเดียวกันเสมอ ไม่บอกว่ามีบัญชีหรือไม่)
  // 2) ตั้งรหัสผ่านใหม่ด้วยรหัสนั้น
  // =====================================================

  static Future<Map<String, dynamic>> requestPasswordCode(String email) async {
    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/password/forgot'),
        headers: _jsonHeaders,
        body: jsonEncode({'email': email}),
      ),
    );

    return ApiHelper.decode(response, session: false);
  }

  static Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String code,
    required String password,
    required String passwordConfirmation,
  }) async {
    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/password/reset'),
        headers: _jsonHeaders,
        body: jsonEncode({
          'email': email,
          'code': code,
          'password': password,
          'password_confirmation': passwordConfirmation,
        }),
      ),
    );

    return ApiHelper.decode(response, session: false);
  }
}
