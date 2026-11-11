import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'api_helper.dart';
import 'auth_service.dart';

// =======================================================
// แชทกลุ่มครอบครัว (GroupChatController)
// - 1 กลุ่ม = 1 ห้อง / สิทธิ์ตามสมาชิกกลุ่มปัจจุบัน (เซิร์ฟเวอร์ตรวจทุกครั้ง)
// - หมดสิทธิ์ → 403 code not_member / กลุ่มถูกลบ → 404 (ส่งต่อเป็น code room_gone)
// =======================================================

class GroupChatService {
  static const String baseUrl = ApiConfig.baseUrl;

  static const Duration _uploadTimeLimit = Duration(seconds: 90);

  // ห้องที่เปิดอยู่ (แจ้งเตือนของห้องนี้ตอนเปิดแอปอยู่ ไม่ต้องขึ้นแถบข้อความ)
  static int? activeChatId;

  static Future<Map<String, String>> _headers({bool json = true}) async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      if (json) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Map<String, dynamic> _decode(http.Response response) {
    // ห้องถูกลบไปแล้ว (ลบกลุ่ม)
    if (response.statusCode == 404) {
      return {
        'status': false,
        'code': 'room_gone',
        'message': 'ไม่พบห้องแชทนี้ กลุ่มอาจถูกลบไปแล้ว',
      };
    }

    return ApiHelper.decode(response);
  }

  // ห้องของกลุ่มที่อยู่ตอนนี้ (ยังไม่มี → เซิร์ฟเวอร์สร้างให้)
  static Future<Map<String, dynamic>> open() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(Uri.parse('$baseUrl/group-chat/open'), headers: headers),
    );

    return _decode(response);
  }

  // beforeId = เก่ากว่านี้ / afterId = ใหม่กว่านี้ (ไม่ส่งทั้งคู่ = ล่าสุด)
  static Future<Map<String, dynamic>> messages(
    int chatId, {
    int? beforeId,
    int? afterId,
    // สถานะ (Reaction / อ่านแล้ว X คน) ของข้อความที่โหลดไว้แล้ว ตั้งแต่ id นี้
    int? statesFrom,
  }) async {
    final headers = await _headers();

    final Uri uri = Uri.parse('$baseUrl/group-chats/$chatId/messages').replace(
      queryParameters: {
        if (beforeId != null) 'before_id': '$beforeId',
        if (afterId != null) 'after_id': '$afterId',
        if (statesFrom != null) 'states_from': '$statesFrom',
      },
    );

    final response = await ApiHelper.request(
      () => http.get(uri, headers: headers),
    );

    return _decode(response);
  }

  // ข้อความเดียว (ลิงก์รูปใหม่ เมื่อลิงก์เดิมหมดอายุ)
  static Future<Map<String, dynamic>> message(int chatId, int messageId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/group-chats/$chatId/messages/$messageId'),
        headers: headers,
      ),
    );

    return _decode(response);
  }

  static Future<Map<String, dynamic>> send(
    int chatId, {
    String? body,
    String? imagePath,
    required String clientId,
    int? replyToId,
    String? filePath,
    String? fileName,
    String? voicePath,
    int? voiceDurationMs,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/group-chats/$chatId/messages');

    if (imagePath == null && filePath == null && voicePath == null) {
      final headers = await _headers();

      final response = await ApiHelper.request(
        () => http.post(
          uri,
          headers: headers,
          body: jsonEncode({
            'body': body,
            'client_id': clientId,
            'reply_to_id': ?replyToId,
          }),
        ),
      );

      return _decode(response);
    }

    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(await _headers(json: false))
      ..fields['client_id'] = clientId;

    if (replyToId != null) request.fields['reply_to_id'] = '$replyToId';

    if (body != null && body.trim().isNotEmpty) {
      request.fields['body'] = body;
    }

    if (imagePath != null) {
      request.files.add(await http.MultipartFile.fromPath('image', imagePath));
    }

    if (filePath != null) {
      request.files.add(
        await http.MultipartFile.fromPath('file', filePath, filename: fileName),
      );
    }

    if (voicePath != null) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'voice',
          voicePath,
          filename: 'voice.m4a',
        ),
      );
      request.fields['voice_duration_ms'] = '${voiceDurationMs ?? 0}';
    }

    final response = await ApiHelper.request(
      () async => http.Response.fromStream(await request.send()),
      timeLimit: _uploadTimeLimit,
    );

    if (response.statusCode == 413) {
      return {'status': false, 'message': 'ไฟล์มีขนาดใหญ่เกินไป'};
    }

    return _decode(response);
  }

  // อ่านถึงข้อความนี้ (เซิร์ฟเวอร์ไม่ถอยตำแหน่งอ่าน)
  static Future<Map<String, dynamic>> read(int chatId, int messageId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/group-chats/$chatId/read'),
        headers: headers,
        body: jsonEncode({'message_id': messageId}),
      ),
    );

    return _decode(response);
  }

  // Reaction ของเรา: emoji = ตั้ง / null = ถอน (ส่งซ้ำได้ ผลเหมือนเดิม)
  static Future<Map<String, dynamic>> react(
    int chatId,
    int messageId,
    String? emoji,
  ) async {
    final headers = await _headers();
    final Uri uri = Uri.parse(
      '$baseUrl/group-chats/$chatId/messages/$messageId/reaction',
    );

    final response = await ApiHelper.request(
      () => emoji == null
          ? http.delete(uri, headers: headers)
          : http.put(uri, headers: headers, body: jsonEncode({'emoji': emoji})),
    );

    return _decode(response);
  }

  static Future<Map<String, dynamic>> mute(int chatId, bool muted) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.put(
        Uri.parse('$baseUrl/group-chats/$chatId/mute'),
        headers: headers,
        body: jsonEncode({'muted': muted}),
      ),
    );

    return _decode(response);
  }
}
