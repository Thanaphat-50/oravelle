import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'app_log.dart';

// =======================================================
// เรียก API + แปลงผลลัพธ์ให้ทุกหน้าใช้แบบเดียวกัน
//
// request(): จำกัดเวลารอ (timeout) และแปลงปัญหาการเชื่อมต่อเป็น ApiException ภาษาไทย
// decode():  แปลง JSON
//   - 2xx                 → ข้อมูลจากเซิร์ฟเวอร์
//   - 4xx (ยกเว้น 401)     → ข้อมูลจากเซิร์ฟเวอร์ + message ภาษาไทยเสมอ (status: false)
//   - 401 ของคำขอที่ใช้ token → เซสชันหมดอายุ: ลบ token แล้วไปหน้าเข้าสู่ระบบ
//     (หน้า Login / สมัคร ใช้ session: false → 401 ไม่ทำให้ออกจากระบบ)
//   - 5xx / ไม่ใช่ JSON     → ApiException (ไม่ลบ token)
// รายละเอียดทางเทคนิคเก็บใน AppLog ผู้ใช้เห็นแต่ข้อความภาษาไทย
// =======================================================

enum ApiErrorKind {
  // ไม่มีเน็ต / ต่อเซิร์ฟเวอร์ไม่ได้
  network,
  // เซิร์ฟเวอร์ตอบช้าเกินเวลาที่รอ
  timeout,
  // เซิร์ฟเวอร์ผิดพลาด (5xx)
  server,
  // ได้ข้อมูลที่ไม่ใช่ JSON (เช่น หน้าเว็บของ Wi-Fi สาธารณะ)
  invalidResponse,
  // token ไม่ถูกต้อง / หมดอายุ (401)
  sessionExpired,
  other,
}

class ApiException implements Exception {
  final String message;
  final ApiErrorKind kind;
  final int? statusCode;

  ApiException(this.message, {this.kind = ApiErrorKind.other, this.statusCode});

  // ปัญหาชั่วคราว (เน็ต / เซิร์ฟเวอร์) → ลองใหม่ได้ ไม่ใช่ปัญหาของบัญชี
  bool get isTemporary =>
      kind == ApiErrorKind.network ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.server ||
      kind == ApiErrorKind.invalidResponse;

  @override
  String toString() {
    return message;
  }
}

class SessionExpiredException extends ApiException {
  SessionExpiredException()
    : super(
        ApiHelper.sessionExpiredMessage,
        kind: ApiErrorKind.sessionExpired,
        statusCode: 401,
      );
}

class ApiHelper {
  // เวลารอสูงสุดต่อคำขอ (เผื่อเซิร์ฟเวอร์ตื่นจาก Scale to zero) — ทดสอบปรับให้สั้นลงได้
  static Duration timeout = const Duration(seconds: 15);

  static const String networkMessage =
      'เชื่อมต่อไม่ได้ ตรวจสอบอินเทอร์เน็ตแล้วลองอีกครั้ง';
  static const String timeoutMessage =
      'เซิร์ฟเวอร์ตอบช้าเกินไป กรุณาลองอีกครั้ง';
  static const String serverMessage =
      'ระบบขัดข้องชั่วคราว กรุณาลองใหม่อีกสักครู่';
  static const String invalidResponseMessage =
      'ได้รับข้อมูลไม่ถูกต้อง อินเทอร์เน็ตอาจไม่เสถียร กรุณาลองอีกครั้ง';
  static const String sessionExpiredMessage =
      'เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่';
  static const String unknownMessage = 'ทำรายการไม่สำเร็จ กรุณาลองอีกครั้ง';

  // กำหนดใน main.dart: ลบ token แล้วไปหน้าเข้าสู่ระบบ
  static Future<void> Function()? onUnauthorized;

  static bool _handlingUnauthorized = false;

  static Future<void> _handleUnauthorized() async {
    if (_handlingUnauthorized) {
      return;
    }

    _handlingUnauthorized = true;

    try {
      if (onUnauthorized != null) {
        await onUnauthorized!();
      }
    } finally {
      await Future.delayed(const Duration(seconds: 1));

      _handlingUnauthorized = false;
    }
  }

  // ข้อความสำหรับแสดงผู้ใช้จาก error ใด ๆ (ไม่แสดงรายละเอียดภายในของโปรแกรม)
  static String messageOf(Object error) {
    if (error is ApiException) {
      return error.message;
    }

    AppLog.warn('Unexpected error', error.runtimeType);

    return unknownMessage;
  }

  // =====================================================
  // ส่ง Request
  // timeLimit: เวลารอสูงสุดของ Request นี้ (เช่น อัปโหลดรูปใช้นานกว่าปกติ)
  // =====================================================

  static Future<http.Response> request(
    Future<http.Response> Function() action, {
    Duration? timeLimit,
  }) async {
    try {
      return await action().timeout(timeLimit ?? timeout);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      AppLog.warn('API timeout', (timeLimit ?? timeout).inSeconds);

      throw ApiException(timeoutMessage, kind: ApiErrorKind.timeout);
    } on SocketException catch (e) {
      AppLog.warn('API network error', e.osError?.message ?? e.message);

      throw ApiException(networkMessage, kind: ApiErrorKind.network);
    } on HandshakeException catch (e) {
      AppLog.warn('API TLS error', e.message);

      throw ApiException(networkMessage, kind: ApiErrorKind.network);
    } on http.ClientException catch (e) {
      AppLog.warn('API client error', e.message);

      throw ApiException(networkMessage, kind: ApiErrorKind.network);
    } on HttpException catch (e) {
      AppLog.warn('API connection closed', e.message);

      throw ApiException(networkMessage, kind: ApiErrorKind.network);
    } catch (e) {
      AppLog.warn('API request failed', e.runtimeType);

      throw ApiException(unknownMessage);
    }
  }

  // =====================================================
  // แปลง Response เป็น JSON
  // session: false = คำขอที่ไม่ได้ใช้ token ของผู้ใช้ (เข้าสู่ระบบ / สมัคร)
  //          → 401 คืนข้อความให้หน้าแสดง ไม่ทำให้ออกจากระบบ
  // =====================================================

  static Map<String, dynamic> decode(
    http.Response response, {
    bool session = true,
  }) {
    final int code = response.statusCode;
    final Map<String, dynamic>? data = _json(response);

    if (code == 401 && session) {
      _log(response, 'unauthorized');

      _handleUnauthorized();

      throw SessionExpiredException();
    }

    if (code >= 500) {
      _log(response, 'server error');

      throw ApiException(
        code == 503 && data != null
            ? _thaiOr(data['message'], serverMessage)
            : serverMessage,
        kind: ApiErrorKind.server,
        statusCode: code,
      );
    }

    if (data == null) {
      // 204 / ตอบว่าง = สำเร็จ
      if (code >= 200 && code < 300 && response.body.trim().isEmpty) {
        return {'status': true};
      }

      _log(response, 'not JSON');

      throw ApiException(
        code >= 400 ? _fallbackMessage(code, response) : invalidResponseMessage,
        kind: code >= 400 ? ApiErrorKind.other : ApiErrorKind.invalidResponse,
        statusCode: code,
      );
    }

    if (code >= 400) {
      final String message = _errorMessage(data, code, response);

      return {...data, 'status': data['status'] ?? false, 'message': message};
    }

    return data;
  }

  // =====================================================
  // HELPERS
  // =====================================================

  static Map<String, dynamic>? _json(http.Response response) {
    final String body = response.body.trim();

    if (!body.startsWith('{')) {
      return null;
    }

    try {
      final dynamic decoded = jsonDecode(body);

      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static final RegExp _thai = RegExp(r'[฀-๿]');

  // ข้อความภาษาไทยจากเซิร์ฟเวอร์ใช้ได้เลย / ภาษาอังกฤษของ Laravel → ข้อความไทยตามรหัส HTTP
  static String _errorMessage(
    Map<String, dynamic> data,
    int code,
    http.Response response,
  ) {
    String? message;

    // 422: ใช้ข้อความของช่องแรกที่ผิด (ไม่เอา "(and 1 more error)" ของ Laravel)
    final dynamic errors = data['errors'];

    if (code == 422 && errors is Map && errors.isNotEmpty) {
      final dynamic first = errors.values.first;

      message = first is List && first.isNotEmpty
          ? first.first?.toString()
          : first?.toString();
    }

    message ??= data['message']?.toString();

    if (message != null && _thai.hasMatch(message)) {
      return message;
    }

    _log(response, 'non-Thai message');

    return _fallbackMessage(code, response);
  }

  static String _thaiOr(dynamic message, String fallback) {
    final String text = message?.toString() ?? '';

    return _thai.hasMatch(text) ? text : fallback;
  }

  static String _fallbackMessage(int code, http.Response response) {
    switch (code) {
      case 400:
      case 422:
        return 'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองอีกครั้ง';
      case 401:
        return 'เข้าสู่ระบบไม่สำเร็จ กรุณาตรวจสอบอีเมลและรหัสผ่าน';
      case 403:
        return 'คุณไม่มีสิทธิ์ทำรายการนี้';
      case 404:
        return 'ไม่พบข้อมูลที่ต้องการ อาจถูกลบไปแล้ว';
      case 409:
        return 'ข้อมูลเปลี่ยนไปแล้ว กรุณาโหลดใหม่แล้วลองอีกครั้ง';
      case 413:
        return 'ไฟล์ใหญ่เกินไป กรุณาเลือกไฟล์ที่เล็กลง';
      case 429:
        final int? seconds = int.tryParse(
          response.headers['retry-after'] ?? '',
        );

        return seconds == null
            ? 'ทำรายการบ่อยเกินไป กรุณารอสักครู่แล้วลองใหม่'
            : 'ทำรายการบ่อยเกินไป กรุณารอ $seconds วินาทีแล้วลองใหม่';
      default:
        return unknownMessage;
    }
  }

  // path + รหัส HTTP เท่านั้น (ไม่บันทึก query, token หรือเนื้อหา)
  static void _log(http.Response response, String what) {
    final Uri? url = response.request?.url;

    AppLog.warn(
      'API $what',
      '${response.request?.method ?? ''} ${url?.path ?? ''} → ${response.statusCode}',
    );
  }
}
