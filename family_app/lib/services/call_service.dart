import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'api_helper.dart';
import 'auth_service.dart';

// =======================================================
// โทรเสียง/วิดีโอคอล 1 ต่อ 1 (CallController)
// API นี้ส่งแค่สถานะสาย + token อายุสั้น / เสียงและวิดีโอวิ่งผ่าน LiveKit (call_media.dart)
// =======================================================

class CallService {
  static const String baseUrl = ApiConfig.baseUrl;

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<Map<String, dynamic>> _post(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl$path'),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> _get(String path) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl$path'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // type: audio | video
  static Future<Map<String, dynamic>> start(int conversationId, String type) =>
      _post('/calls', {'conversation_id': conversationId, 'type': type});

  // สายที่กำลังเรียกเข้าหาเรา (null = ไม่มี)
  static Future<Map<String, dynamic>> active() => _get('/calls/active');

  static Future<Map<String, dynamic>> show(int callId) =>
      _get('/calls/$callId');

  static Future<Map<String, dynamic>> accept(int callId) =>
      _post('/calls/$callId/accept');

  static Future<Map<String, dynamic>> decline(int callId) =>
      _post('/calls/$callId/decline');

  static Future<Map<String, dynamic>> hangup(int callId) =>
      _post('/calls/$callId/hangup');

  // ระหว่างสาย: เซิร์ฟเวอร์ตรวจสิทธิ์/เซสชันซ้ำ (หมดสิทธิ์ → 403 + สายจบ)
  static Future<Map<String, dynamic>> heartbeat(int callId) =>
      _post('/calls/$callId/heartbeat');
}
