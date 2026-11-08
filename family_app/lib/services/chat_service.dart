import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_helper.dart';
import 'auth_service.dart';
import '../config/api_config.dart';

// =======================================================
// แชทส่วนตัว (คนในครอบครัวเดียวกัน)
// =======================================================

class ChatService {
  static const String baseUrl = ApiConfig.baseUrl;

  static const Duration _uploadTimeLimit = Duration(seconds: 90);

  // จำนวนข้อความที่ยังไม่อ่าน (ตัวเลขบนไอคอนแชท)
  static final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);

  // ห้องที่เปิดดูอยู่ (แจ้งเตือนของห้องนี้ไม่ต้องขึ้นแถบข้อความ)
  static int? activeConversationId;

  static Future<Map<String, String>> _headers({bool json = true}) async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      if (json) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // GET /api/chats → ห้องแชท + คนในครอบครัว
  static Future<Map<String, dynamic>> getChats() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl/chats'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  static Future<void> refreshUnreadCount() async {
    try {
      final headers = await _headers();

      final response = await ApiHelper.request(
        () => http.get(
          Uri.parse('$baseUrl/chats/unread-count'),
          headers: headers,
        ),
      );

      final result = ApiHelper.decode(response);

      final dynamic count = result['unread_count'];

      if (result['status'] == true && count is num) {
        unreadCount.value = count.toInt();
      }
    } catch (_) {
      // โหลดไม่ได้ → ใช้ตัวเลขเดิมไปก่อน
    }
  }

  // เปิดห้องแชทกับคนนี้ (ยังไม่มี → Server สร้างให้)
  static Future<Map<String, dynamic>> openChat(int userId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/chats'),
        headers: headers,
        body: jsonEncode({'user_id': userId}),
      ),
    );

    return ApiHelper.decode(response);
  }

  // ทักร้าน (ลูกค้าคุยกับเจ้าของร้านได้แม้ไม่ได้อยู่กลุ่มเดียวกัน)
  static Future<Map<String, dynamic>> openShopChat(int shopId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/chats'),
        headers: headers,
        body: jsonEncode({'shop_id': shopId}),
      ),
    );

    return ApiHelper.decode(response);
  }

  // แชทจากหน้าคำสั่งซื้อ (ผู้ซื้อ → ร้าน / ร้าน → ลูกค้า)
  static Future<Map<String, dynamic>> openOrderChat(int orderId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/chats'),
        headers: headers,
        body: jsonEncode({'order_id': orderId}),
      ),
    );

    return ApiHelper.decode(response);
  }

  // afterId: ข้อความใหม่กว่านี้ / beforeId: ข้อความเก่ากว่านี้
  static Future<Map<String, dynamic>> getMessages(
    int conversationId, {
    int? afterId,
    int? beforeId,
  }) async {
    final headers = await _headers();

    final uri = Uri.parse('$baseUrl/chats/$conversationId/messages').replace(
      queryParameters: {
        if (afterId != null) 'after_id': '$afterId',
        if (beforeId != null) 'before_id': '$beforeId',
      },
    );

    final response = await ApiHelper.request(
      () => http.get(uri, headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // clientId: รหัสที่แอปสร้างก่อนส่ง → ส่งใหม่ด้วยรหัสเดิมได้ข้อความเดิม (ไม่ซ้ำ)
  static Future<Map<String, dynamic>> sendMessage(
    int conversationId, {
    String? body,
    String? imagePath,
    String? clientId,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/chats/$conversationId/messages');

    // ข้อความล้วน: JSON
    if (imagePath == null) {
      final headers = await _headers();

      final response = await ApiHelper.request(
        () => http.post(
          uri,
          headers: headers,
          body: jsonEncode({'body': body, 'client_id': ?clientId}),
        ),
      );

      return ApiHelper.decode(response);
    }

    // มีรูป: multipart (ไม่ใส่ Content-Type เพราะ MultipartRequest สร้างให้เอง)
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(await _headers(json: false));

    if (body != null && body.trim().isNotEmpty) {
      request.fields['body'] = body;
    }

    if (clientId != null) {
      request.fields['client_id'] = clientId;
    }

    request.files.add(await http.MultipartFile.fromPath('image', imagePath));

    final response = await ApiHelper.request(
      () async => http.Response.fromStream(await request.send()),
      timeLimit: _uploadTimeLimit,
    );

    if (response.statusCode == 413) {
      return {'status': false, 'message': 'รูปมีขนาดใหญ่เกินไป'};
    }

    return ApiHelper.decode(response);
  }

  // ยกเลิกการส่ง (เฉพาะข้อความของเรา)
  static Future<Map<String, dynamic>> deleteMessage(
    int conversationId,
    int messageId,
  ) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.delete(
        Uri.parse('$baseUrl/chats/$conversationId/messages/$messageId'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }
}
