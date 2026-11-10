import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'api_helper.dart';
import 'auth_service.dart';

// =======================================================
// ค้นหาโพสต์และผู้ใช้ (SearchController)
// - เซิร์ฟเวอร์ค้นจากข้อมูลทั้งหมดที่ผู้ใช้มีสิทธิ์เห็น (ไม่กรองเฉพาะที่โหลดในเครื่อง)
// - แบ่งหน้าแบบ cursor: ส่ง next_cursor ของหน้าก่อนเพื่อโหลดหน้าถัดไป
// =======================================================

class SearchService {
  static const String baseUrl = ApiConfig.baseUrl;

  // ตรงกับ Laravel (SearchController::MAX_LENGTH)
  static const int maxLength = 100;

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // scope: community = โพสต์ชุมชน / family = โพสต์ในกลุ่มที่อยู่ตอนนี้
  static Future<Map<String, dynamic>> posts({
    required String query,
    String scope = 'community',
    String? cursor,
  }) {
    return _get('search/posts', {
      'q': query,
      'scope': scope,
      'cursor': ?cursor,
    });
  }

  static Future<Map<String, dynamic>> users({
    required String query,
    String? cursor,
  }) {
    return _get('search/users', {'q': query, 'cursor': ?cursor});
  }

  static Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> params,
  ) async {
    final headers = await _headers();

    final Uri uri = Uri.parse('$baseUrl/$path')
        .replace(queryParameters: params);

    final response = await ApiHelper.request(
      () => http.get(uri, headers: headers),
    );

    return ApiHelper.decode(response);
  }
}
