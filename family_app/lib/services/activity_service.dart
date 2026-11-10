import 'dart:convert';

import 'package:flutter_timezone/flutter_timezone.dart';
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
  // เวลา: starts_at (UTC) + เขตเวลา IANA ของเครื่อง
  // activity_date (นาฬิกาเครื่อง) ส่งต่อไว้ให้เซิร์ฟเวอร์/แอปเวอร์ชันเก่า
  // =====================================================

  // ทดสอบ: กำหนดเขตเวลาเอง (ไม่เรียกเครื่อง)
  static String? timezoneOverride;

  // เขตเวลาของเครื่อง เช่น Asia/Bangkok
  // อ่านไม่ได้ → ใช้ส่วนต่างเวลาเต็มชั่วโมง (Etc/GMT-7 = UTC+7) / ไม่ลงตัว → null (ไม่ส่งเวลาจริง ไม่เดา)
  static Future<String?> deviceTimezone() async {
    if (timezoneOverride != null) return timezoneOverride;

    try {
      // เครื่องตอบช้า/ไม่ตอบ → ไม่ค้างการบันทึก
      final TimezoneInfo info = await FlutterTimezone.getLocalTimezone()
          .timeout(const Duration(seconds: 2));

      if (info.identifier.isNotEmpty) return info.identifier;
    } catch (_) {}

    final Duration offset = DateTime.now().timeZoneOffset;

    if (offset.inMinutes % 60 != 0) return null;

    final int hours = offset.inHours;

    if (hours == 0) return 'UTC';

    return 'Etc/GMT${hours > 0 ? '-' : '+'}${hours.abs()}';
  }

  static Future<Map<String, dynamic>> _timeFields(DateTime? when) async {
    if (when == null) {
      return {'activity_date': null, 'starts_at': null, 'timezone': null};
    }

    final String? timezone = await deviceTimezone();

    return {
      'activity_date': when.toIso8601String(),
      if (timezone != null) 'starts_at': when.toUtc().toIso8601String(),
      'timezone': ?timezone,
    };
  }

  // =====================================================
  // GET ACTIVITIES
  // =====================================================

  // page: หน้าละ 20 รายการ / filter: all | mine | family | today | overdue | completed
  // now: เวลาตามนาฬิกาเครื่อง (ใช้ตัดสิน "วันนี้" / "เกินกำหนด" บนเซิร์ฟเวอร์)
  static Future<Map<String, dynamic>> getActivities({
    int page = 1,
    String filter = 'all',
  }) async {
    final headers = await _headers();

    final Uri uri = Uri.parse('$baseUrl/activities').replace(
      queryParameters: {
        'page': '$page',
        'filter': filter,
        'now': DateTime.now().toIso8601String(),
      },
    );

    final response = await ApiHelper.request(
      () => http.get(uri, headers: headers),
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
    int? reminderOffset,
  }) async {
    final headers = await _headers();
    final time = await _timeFields(activityDate);

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/activities'),

        headers: headers,

        body: jsonEncode({
          'title': title,

          'description': description,

          ...time,

          'visibility': visibility,

          // ค่าเริ่มต้น = ไม่เตือน (ไม่ส่ง)
          'reminder_offset': ?reminderOffset,
        }),
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // แก้ไขชื่อ / รายละเอียด / วันเวลา (activityDate null = ล้างวันเวลา)
  // วันเวลา: ช่วงเวลาจริง + เขตเวลาเครื่อง เหมือนตอนสร้าง
  // changeReminder: ส่งการเตือนของตัวเองไปด้วย (reminderOffset null = ไม่เตือน)
  // =====================================================

  static Future<Map<String, dynamic>> updateActivity({
    required int activityId,
    required String title,
    String? description,
    DateTime? activityDate,
    bool changeReminder = false,
    int? reminderOffset,
  }) async {
    final headers = await _headers();
    final time = await _timeFields(activityDate);

    final response = await ApiHelper.request(
      () => http.patch(
        Uri.parse('$baseUrl/activities/$activityId'),
        headers: headers,
        body: jsonEncode({
          'title': title,
          'description': description,
          ...time,
          if (changeReminder) 'reminder_offset': reminderOffset,
        }),
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // รายละเอียด (เปิดจากแจ้งเตือน) / ตั้งเตือนของตัวเอง
  // =====================================================

  static Future<Map<String, dynamic>> getActivity(int activityId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/activities/$activityId'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // offset: null = ไม่เตือน / 0 / 15 / 30 / 1440 นาที
  static Future<Map<String, dynamic>> setReminder({
    required int activityId,
    required int? offset,
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.put(
        Uri.parse('$baseUrl/activities/$activityId/reminder'),
        headers: headers,
        body: jsonEncode({'offset': offset}),
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
