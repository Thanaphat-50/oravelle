import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import 'api_helper.dart';
import 'auth_service.dart';

// =======================================================
// ศูนย์ช่วยเหลือ: แจ้งปัญหาและติดตามคำตอบจากทีมงาน
// - client_id: ส่งซ้ำ (กดซ้ำ / หมดเวลารอ) ได้คำร้อง/ข้อความเดิม ไม่สร้างซ้ำ
// - รูปแนบ: JPG / PNG / WEBP สูงสุด 4 รูป รูปละไม่เกิน 5 MB (เซิร์ฟเวอร์ตรวจซ้ำ)
// - รูปที่ได้กลับมาเป็นลิงก์ชั่วคราว (หมดอายุ → โหลดคำร้องใหม่)
// =======================================================

class SupportService {
  static const String baseUrl = ApiConfig.baseUrl;

  static const int maxImages = 4;
  static const int maxImageMb = 5;
  static const List<String> imageTypes = ['jpg', 'jpeg', 'png', 'webp'];

  // ประเภทปัญหา (ลำดับตามที่แสดง)
  static const Map<String, String> categories = {
    'account': 'บัญชี',
    'app': 'การใช้งานแอป',
    'order': 'คำสั่งซื้อ',
    'refund': 'คืนเงิน',
    'other': 'อื่น ๆ',
  };

  static const Duration _uploadTimeLimit = Duration(seconds: 90);

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // filter: all | open | closed
  static Future<Map<String, dynamic>> getTickets({
    String filter = 'all',
    int page = 1,
  }) async {
    final headers = await _headers();

    final uri = Uri.parse('$baseUrl/support/tickets')
        .replace(queryParameters: {'filter': filter, 'page': '$page'});

    final response = await ApiHelper.request(
      () => http.get(uri, headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // เรื่องที่ยังไม่ปิดของคำสั่งซื้อ + ประเภทนี้ (null = ไม่มี)
  static Future<Map<String, dynamic>> openTicketForOrder({
    required int orderId,
    required String category,
  }) async {
    final headers = await _headers();

    final uri = Uri.parse(
      '$baseUrl/support/tickets/open',
    ).replace(queryParameters: {'order_id': '$orderId', 'category': category});

    final response = await ApiHelper.request(
      () => http.get(uri, headers: headers),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> getTicket(int ticketId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/support/tickets/$ticketId'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // 409 code=open_ticket_exists → มีเรื่องเดิมที่ยังไม่ปิด (ส่ง confirmNew: true เพื่อสร้างเรื่องใหม่)
  static Future<Map<String, dynamic>> createTicket({
    required String clientId,
    required String category,
    required String subject,
    required String body,
    int? orderId,
    int? previousTicketId,
    bool confirmNew = false,
    List<String> imagePaths = const [],
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(() async {
      final request =
          http.MultipartRequest('POST', Uri.parse('$baseUrl/support/tickets'))
            ..headers.addAll(headers)
            ..fields.addAll({
              'client_id': clientId,
              'category': category,
              'subject': subject,
              'body': body,
              if (orderId != null) 'order_id': '$orderId',
              if (previousTicketId != null)
                'previous_ticket_id': '$previousTicketId',
              if (confirmNew) 'confirm_new': '1',
            });

      for (final path in imagePaths) {
        request.files.add(await http.MultipartFile.fromPath('images[]', path));
      }

      return http.Response.fromStream(await request.send());
    }, timeLimit: _uploadTimeLimit);

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> sendMessage({
    required int ticketId,
    required String clientId,
    String? body,
    List<String> imagePaths = const [],
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(() async {
      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('$baseUrl/support/tickets/$ticketId/messages'),
            )
            ..headers.addAll(headers)
            ..fields.addAll({
              'client_id': clientId,
              if (body != null && body.trim().isNotEmpty) 'body': body.trim(),
            });

      for (final path in imagePaths) {
        request.files.add(await http.MultipartFile.fromPath('images[]', path));
      }

      return http.Response.fromStream(await request.send());
    }, timeLimit: _uploadTimeLimit);

    return ApiHelper.decode(response);
  }
}
