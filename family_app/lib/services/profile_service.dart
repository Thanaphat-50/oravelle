import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_helper.dart';
import 'auth_service.dart';
import '../config/api_config.dart';

class ProfileService {
  static const String baseUrl = ApiConfig.baseUrl;

  // =====================================================
  // JSON HEADERS
  // =====================================================

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',

      'Content-Type': 'application/json',

      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // =====================================================
  // MULTIPART HEADERS
  // ไม่ใส่ Content-Type
  // เพราะ MultipartRequest จะสร้างให้เอง
  // =====================================================

  static Future<Map<String, String>> _multipartHeaders() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',

      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // =====================================================
  // GET PROFILE
  // =====================================================

  static Future<Map<String, dynamic>> getProfile() async {
    final response = await http.get(
      Uri.parse('$baseUrl/profile'),

      headers: await _headers(),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // UPDATE NAME / ข้อมูลแนะนำตัว
  // ส่งเฉพาะช่องที่แก้ (ค่าว่าง = ลบช่องนั้น)
  // =====================================================

  static Future<Map<String, dynamic>> updateProfile({
    String? name,
    Map<String, String>? intro,
  }) async {
    final response = await http.put(
      Uri.parse('$baseUrl/profile'),

      headers: await _headers(),

      body: jsonEncode({'name': ?name, ...?intro}),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // UPDATE PASSWORD
  // =====================================================

  static Future<Map<String, dynamic>> updatePassword({
    // บัญชีที่ยังไม่มีรหัสผ่าน (สมัครด้วย Google / LINE / Facebook) ส่ง null
    String? currentPassword,
    required String password,
    required String passwordConfirmation,
  }) async {
    final response = await http.put(
      Uri.parse('$baseUrl/profile/password'),

      headers: await _headers(),

      body: jsonEncode({
        'current_password': ?currentPassword,

        'password': password,

        'password_confirmation': passwordConfirmation,
      }),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // UPLOAD PROFILE PHOTO
  // =====================================================

  static Future<Map<String, dynamic>> uploadProfilePhoto(
    String filePath,
  ) async {
    final request = http.MultipartRequest(
      'POST',

      Uri.parse('$baseUrl/profile/photo'),
    );

    request.headers.addAll(await _multipartHeaders());

    request.files.add(await http.MultipartFile.fromPath('photo', filePath));

    final streamedResponse = await request.send();

    final response = await http.Response.fromStream(streamedResponse);

    return ApiHelper.decode(response);
  }

  // รูปที่ครอปแล้ว (PNG จากหน้า PhotoCropPage)
  static Future<Map<String, dynamic>> uploadProfilePhotoBytes(
    Uint8List bytes,
  ) async {
    final headers = await _multipartHeaders();

    final response = await ApiHelper.request(() async {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/profile/photo'),
      )..headers.addAll(headers);

      request.files.add(
        http.MultipartFile.fromBytes('photo', bytes, filename: 'avatar.png'),
      );

      return http.Response.fromStream(await request.send());
    }, timeLimit: const Duration(seconds: 60));

    return ApiHelper.decode(response);
  }

  // =====================================================
  // DELETE PROFILE PHOTO
  // =====================================================

  static Future<Map<String, dynamic>> deleteProfilePhoto() async {
    final response = await http.delete(
      Uri.parse('$baseUrl/profile/photo'),

      headers: await _headers(),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // ACCOUNT DELETION REQUEST
  // ผู้ใช้ส่งคำขอ → ทีมงานลบบัญชีและข้อมูลทั้งหมดให้ (ภายใน 30 วัน)
  // =====================================================

  // คำขอที่รออยู่ → request: {id, status, created_at, process_within_days} หรือ null
  static Future<Map<String, dynamic>> getDeletionRequest() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/account/deletion-request'),

        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // มีรหัสผ่าน → password / ไม่มีรหัสผ่าน → confirmText = "ลบบัญชี"
  static Future<Map<String, dynamic>> requestAccountDeletion({
    String? password,
    String? confirmText,
    String? reason,
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/account/deletion-request'),

        headers: headers,

        body: jsonEncode({
          'password': ?password,
          'confirm_text': ?confirmText,
          'reason': ?reason,
        }),
      ),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> cancelDeletionRequest() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.delete(
        Uri.parse('$baseUrl/account/deletion-request'),

        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // PUBLIC PROFILE (โปรไฟล์ในชุมชนของผู้ใช้คนอื่น)
  // ไม่พบ / ไม่มีสิทธิ์ดู → status false + message
  // =====================================================

  static Future<Map<String, dynamic>> getPublicProfile(int userId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/users/$userId/profile'),

        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // REPORT USER
  // =====================================================

  static Future<Map<String, dynamic>> reportUser({
    required int userId,
    required String reason,
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/users/$userId/report'),

        headers: headers,

        body: jsonEncode({'reason': reason}),
      ),
    );

    return ApiHelper.decode(response);
  }
}
