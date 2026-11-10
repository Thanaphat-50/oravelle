import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'api_helper.dart';
import 'auth_service.dart';
import 'device_info_service.dart';

// =======================================================
// อุปกรณ์ที่เข้าสู่ระบบ (SessionController)
// - รายการเซสชันของบัญชีนี้ / ออกจากระบบเครื่องอื่น (รายเครื่อง / ทั้งหมด)
// - เครื่องนี้ใช้ปุ่ม "ออกจากระบบ" เดิม (AuthService.logout)
// =======================================================

class SessionService {
  static const String baseUrl = ApiConfig.baseUrl;

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<Map<String, dynamic>> list() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl/sessions'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // ยกเลิกสิทธิ์อุปกรณ์อื่นหนึ่งเครื่อง (ส่งซ้ำได้ ไม่กระทบเครื่องอื่น)
  static Future<Map<String, dynamic>> revoke(int sessionId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.delete(
        Uri.parse('$baseUrl/sessions/$sessionId'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // ยกเลิกสิทธิ์อุปกรณ์อื่นทั้งหมด (คงเครื่องนี้ไว้)
  static Future<Map<String, dynamic>> revokeOthers() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/sessions/revoke-others'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  static bool _reported = false;

  // บอกข้อมูลอุปกรณ์ของเซสชันนี้ (เซสชันที่เข้าสู่ระบบจากแอปเวอร์ชันเก่ายังไม่มีชื่อ)
  // ครั้งเดียวต่อการเปิดแอป / ไม่สำเร็จก็ไม่เป็นไร
  static Future<void> reportCurrentDevice() async {
    if (_reported) return;

    _reported = true;

    try {
      final Map<String, String> device = await DeviceInfoService.payload();

      if (device.isEmpty) return;

      final headers = await _headers();

      if (!headers.containsKey('Authorization')) return;

      await ApiHelper.request(
        () => http.put(
          Uri.parse('$baseUrl/sessions/current'),
          headers: headers,
          body: jsonEncode(device),
        ),
      );
    } catch (_) {
      _reported = false;
    }
  }
}
