import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_helper.dart';
import 'auth_service.dart';
import '../config/api_config.dart';

class ActivityService {
  static const String baseUrl = ApiConfig.baseUrl;

  // =====================================================
  // HEADERS
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
  // GET ACTIVITIES
  // =====================================================

  static Future<Map<String, dynamic>> getActivities() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl/activities'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // CREATE
  // =====================================================

  static Future<Map<String, dynamic>> createActivity({
    required String title,
    String? description,
    DateTime? activityDate,
    String visibility = 'private',
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/activities'),

        headers: headers,

        body: jsonEncode({
          'title': title,

          'description': description,

          'activity_date': activityDate?.toIso8601String(),

          'visibility': visibility,
        }),
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // TOGGLE
  // =====================================================

  static Future<Map<String, dynamic>> toggleActivity(int activityId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.patch(
        Uri.parse(
          '$baseUrl/activities/'
          '$activityId/toggle',
        ),

        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // UPDATE VISIBILITY
  // =====================================================

  static Future<Map<String, dynamic>> updateVisibility({
    required int activityId,
    required String visibility,
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.patch(
        Uri.parse(
          '$baseUrl/activities/'
          '$activityId/visibility',
        ),

        headers: headers,

        body: jsonEncode({'visibility': visibility}),
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // DELETE
  // =====================================================

  static Future<Map<String, dynamic>> deleteActivity(int activityId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.delete(
        Uri.parse(
          '$baseUrl/activities/'
          '$activityId',
        ),

        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }
}
