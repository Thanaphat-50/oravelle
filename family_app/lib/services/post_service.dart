import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'api_helper.dart';
import 'auth_service.dart';
import '../config/api_config.dart';

class PostService {
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
  // GET POSTS
  // =====================================================

  // scope: 'family' (ครอบครัว) หรือ 'community' (ชุมชน แบ่งหน้า)
  // category: กรองฟีดชุมชนตามหมวด (null = ทุกหมวด)
  // scope: family / community / mine (โพสต์ของฉัน)
  //        user (หน้าโปรไฟล์: โพสต์ของ userId ที่เราเห็นได้)
  static Future<Map<String, dynamic>> getPosts({
    String scope = 'family',
    int page = 1,
    String? category,
    int? userId,
    // ฟีดชุมชน: for_you = เรียงตามความสนใจ / ไม่ส่ง = ล่าสุด
    String? sort,
    // ฟีดชุมชน: video = เฉพาะโพสต์ที่มีวิดีโอ
    String? media,
    // ฟีดชุมชน: เฉพาะโพสต์ที่มีแฮชแท็กนี้
    String? hashtag,
    // โพสต์ของฉัน: community = เฉพาะชุมชน / family = เฉพาะในกลุ่ม / null = ทั้งหมด
    String? visibility,
  }) async {
    final headers = await _headers();

    final bool paged =
        scope == 'community' || scope == 'mine' || scope == 'user';

    final uri = Uri.parse('$baseUrl/posts').replace(
      queryParameters: {
        'scope': scope,
        if (paged) 'page': '$page',
        if (scope == 'community' && category != null) 'category': category,
        if (userId != null) 'user_id': '$userId',
        if (scope == 'community' && sort != null) 'sort': sort,
        if (scope == 'community' && media != null) 'media': media,
        if (scope == 'community' && hashtag != null) 'hashtag': hashtag,
        if (scope == 'mine' && visibility != null) 'visibility': visibility,
      },
    );

    final response = await ApiHelper.request(
      () => http.get(uri, headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // แฮชแท็กยอดนิยมในชุมชน (ปุ่มลัดตอนเขียนโพสต์)
  static Future<Map<String, dynamic>> popularHashtags() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl/hashtags/popular'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // GET ONE POST (เปิดจากการแจ้งเตือน)
  // ไม่พบ / ไม่มีสิทธิ์เห็น → status false + message
  // =====================================================

  static Future<Map<String, dynamic>> getPost(int postId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl/posts/$postId'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // CREATE POST
  // visibility: 'family' (ค่าเริ่มต้น) หรือ 'community'
  // category: หมวดของโพสต์ชุมชน (general, qa, news, help, event)
  // imagePaths: ไฟล์รูปในเครื่อง (สูงสุด 10 รูป)
  //             มีรูป → ส่งแบบ multipart / ไม่มีรูป → JSON เหมือนเดิม
  // =====================================================

  // showOnMap = โพสต์ครอบครัว แสดงข้อความนี้ข้างตำแหน่งของเราบนแผนที่ด้วย
  static Future<Map<String, dynamic>> createPost(
    String content, {
    String visibility = 'family',
    String? category,
    List<String> imagePaths = const [],
    bool showOnMap = false,
    PostVideoFile? video,
  }) async {
    if (imagePaths.isNotEmpty || video != null) {
      return _createPostWithImages(
        content,
        visibility: visibility,
        category: category,
        imagePaths: imagePaths,
        showOnMap: showOnMap,
        video: video,
      );
    }

    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/posts'),
        headers: headers,
        body: jsonEncode({
          'content': content,
          'visibility': visibility,
          'category': ?category,
          if (showOnMap) 'show_on_map': true,
        }),
      ),
    );

    return ApiHelper.decode(response);
  }

  // อัปโหลดหลายรูป/วิดีโอใช้เวลานานกว่า Request ปกติ
  static const Duration _uploadTimeLimit = Duration(seconds: 90);

  static const Duration _videoUploadTimeLimit = Duration(minutes: 5);

  static Future<Map<String, dynamic>> _createPostWithImages(
    String content, {
    required String visibility,
    String? category,
    required List<String> imagePaths,
    bool showOnMap = false,
    PostVideoFile? video,
  }) async {
    final token = await AuthService.getToken();

    // ไม่ใส่ Content-Type เพราะ MultipartRequest สร้างให้เอง
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/posts'))
      ..headers.addAll({
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      })
      ..fields['content'] = content
      ..fields['visibility'] = visibility;

    if (category != null) {
      request.fields['category'] = category;
    }

    if (showOnMap) {
      request.fields['show_on_map'] = '1';
    }

    for (final path in imagePaths) {
      request.files.add(await http.MultipartFile.fromPath('images[]', path));
    }

    if (video != null) {
      // อัปโหลดเข้า Bucket ไว้แล้ว → ส่งแค่ที่อยู่ / ไม่งั้นส่งไฟล์มากับโพสต์
      if (video.uploadedPath != null) {
        request.fields['video_path'] = video.uploadedPath!;
      } else {
        request.files.add(
          await http.MultipartFile.fromPath(
            'video',
            video.filePath,
            contentType: MediaType('video', 'mp4'),
          ),
        );
      }

      if (video.thumbnailPath != null) {
        request.files.add(
          await http.MultipartFile.fromPath(
            'video_thumbnail',
            video.thumbnailPath!,
          ),
        );
      }

      if (video.durationSeconds != null) {
        request.fields['video_duration'] = '${video.durationSeconds}';
      }

      if (video.width != null) request.fields['video_width'] = '${video.width}';

      if (video.height != null) {
        request.fields['video_height'] = '${video.height}';
      }
    }

    final response = await ApiHelper.request(
      () async => http.Response.fromStream(await request.send()),
      timeLimit: video?.uploadedPath == null && video != null
          ? _videoUploadTimeLimit
          : _uploadTimeLimit,
    );

    // ไฟล์รวมใหญ่เกินที่ Server รับได้
    if (response.statusCode == 413) {
      return {
        'status': false,
        'message': video != null
            ? 'วิดีโอมีขนาดใหญ่เกินไป กรุณาเลือกวิดีโอที่สั้นลง'
            : 'รูปมีขนาดรวมใหญ่เกินไป กรุณาเลือกรูปให้น้อยลง',
      };
    }

    return ApiHelper.decode(response);
  }

  // =====================================================
  // วิดีโอ: ขอลิงก์อัปโหลดตรงเข้า Bucket แล้วส่งไฟล์ขึ้นไป
  // upload = null → Server ให้ส่งไฟล์มากับโพสต์แทน
  // =====================================================

  static Future<Map<String, dynamic>> videoUploadTicket() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () =>
          http.post(Uri.parse('$baseUrl/posts/video-upload'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // PUT ไฟล์ไปที่ลิงก์ (ส่งทีละส่วน ไม่โหลดทั้งไฟล์เข้าหน่วยความจำ)
  static Future<bool> uploadVideoFile({
    required String url,
    required Map<String, String> headers,
    required String filePath,
  }) async {
    final File file = File(filePath);

    final http.StreamedRequest request =
        http.StreamedRequest('PUT', Uri.parse(url))
          ..headers.addAll(headers)
          ..contentLength = await file.length();

    file.openRead().listen(
      request.sink.add,
      onDone: request.sink.close,
      onError: (Object error) => request.sink.addError(error),
      cancelOnError: true,
    );

    try {
      final http.StreamedResponse response = await request.send().timeout(
        _videoUploadTimeLimit,
      );

      await response.stream.drain<void>();

      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // =====================================================
  // ข้อความบนแผนที่ (โพสต์ครอบครัวของเรา)
  // show = true → แสดงข้างตำแหน่งของเรา 12 ชั่วโมง / false → เอาออก
  // =====================================================

  static Future<Map<String, dynamic>> setOnMap(int postId, bool show) async {
    final headers = await _headers();

    final Uri uri = Uri.parse('$baseUrl/posts/$postId/map-status');

    final response = await ApiHelper.request(
      () => show
          ? http.post(uri, headers: headers)
          : http.delete(uri, headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // LIKE / UNLIKE (กดซ้ำ = ยกเลิก)
  // ตอบกลับ liked และ likes_count
  // =====================================================

  static Future<Map<String, dynamic>> toggleLike(int postId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () =>
          http.post(Uri.parse('$baseUrl/posts/$postId/like'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // REPORT POST (เฉพาะโพสต์ชุมชน)
  // reason: spam, inappropriate, harassment, scam, other
  // =====================================================

  static Future<Map<String, dynamic>> reportPost({
    required int postId,
    required String reason,
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/posts/$postId/report'),
        headers: headers,
        body: jsonEncode({'reason': reason}),
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // REPORT COMMENT (เฉพาะความคิดเห็นในโพสต์ชุมชน)
  // =====================================================

  static Future<Map<String, dynamic>> reportComment({
    required int commentId,
    required String reason,
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/comments/$commentId/report'),
        headers: headers,
        body: jsonEncode({'reason': reason}),
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // COMMUNITY: กฎชุมชน และการบล็อก
  // =====================================================

  static Future<Map<String, dynamic>> acceptCommunityTerms() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/community/accept-terms'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> getBlockedUsers() async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.get(Uri.parse('$baseUrl/blocks'), headers: headers),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> blockUser(int userId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/users/$userId/block'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> unblockUser(int userId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.delete(
        Uri.parse('$baseUrl/users/$userId/block'),
        headers: headers,
      ),
    );

    return ApiHelper.decode(response);
  }

  // =====================================================
  // DELETE POST
  // =====================================================

  // =====================================================
  // แก้ไขข้อความโพสต์ของตัวเอง
  // version = edit_version ที่เห็นตอนเปิดฟอร์ม
  // 409 (code edit_conflict) = มีการแก้จากอีกเครื่อง → result['post'] คือข้อความล่าสุด
  // =====================================================

  static Future<Map<String, dynamic>> updatePost({
    required int postId,
    required String content,
    required int version,
  }) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.patch(
        Uri.parse('$baseUrl/posts/$postId'),
        headers: headers,
        body: jsonEncode({'content': content, 'version': version}),
      ),
    );

    // โพสต์ถูกลบไประหว่างแก้
    if (response.statusCode == 404) {
      return {
        'status': false,
        'code': 'post_missing',
        'message': 'ไม่พบโพสต์นี้ หรือโพสต์ถูกลบไปแล้ว',
      };
    }

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> deletePost(int postId) async {
    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.delete(Uri.parse('$baseUrl/posts/$postId'), headers: headers),
    );

    // โพสต์ถูกลบไปแล้ว (เช่น กดลบซ้ำจากอีกเครื่อง)
    if (response.statusCode == 404) {
      return {'status': true, 'message': 'โพสต์นี้ถูกลบไปแล้ว'};
    }

    return ApiHelper.decode(response);
  }

  // =====================================================
  // CREATE COMMENT
  // =====================================================

  // ความคิดเห็น: ข้อความ และ/หรือ ไฟล์แนบ 1 ไฟล์ (รูป / GIF / วิดีโอ)
  static Future<Map<String, dynamic>> createComment({
    required int postId,
    required String content,
    CommentMediaFile? media,
  }) async {
    if (media != null) {
      return _createCommentWithMedia(postId, content, media);
    }

    final headers = await _headers();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/posts/$postId/comments'),
        headers: headers,
        body: jsonEncode({'content': content}),
      ),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> _createCommentWithMedia(
    int postId,
    String content,
    CommentMediaFile media,
  ) async {
    final token = await AuthService.getToken();

    // ไม่ใส่ Content-Type เพราะ MultipartRequest สร้างให้เอง
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('$baseUrl/posts/$postId/comments'),
          )
          ..headers.addAll({
            'Accept': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          })
          ..fields['content'] = content;

    request.files.add(
      await http.MultipartFile.fromPath(
        'media',
        media.path,
        contentType: MediaType.parse(media.mimeType),
      ),
    );

    if (media.thumbnailPath != null) {
      request.files.add(
        await http.MultipartFile.fromPath(
          'media_thumbnail',
          media.thumbnailPath!,
        ),
      );
    }

    if (media.width != null) request.fields['media_width'] = '${media.width}';

    if (media.height != null) {
      request.fields['media_height'] = '${media.height}';
    }

    final response = await ApiHelper.request(
      () async => http.Response.fromStream(await request.send()),
      timeLimit: _uploadTimeLimit,
    );

    if (response.statusCode == 413) {
      return {
        'status': false,
        'message': 'ไฟล์ใหญ่เกินไป กรุณาเลือกไฟล์ที่เล็กลง',
      };
    }

    return ApiHelper.decode(response);
  }
}

// ไฟล์แนบในความคิดเห็น
// type: image / gif / video (ใช้แสดงตัวอย่างในแอป Server ตรวจชนิดจากไฟล์เอง)
class CommentMediaFile {
  final String path;
  final String type;
  final String mimeType;
  final String? thumbnailPath;
  final int? width;
  final int? height;

  const CommentMediaFile({
    required this.path,
    required this.type,
    required this.mimeType,
    this.thumbnailPath,
    this.width,
    this.height,
  });
}

// วิดีโอที่จะแนบกับโพสต์
// uploadedPath: อัปโหลดเข้า Bucket ไว้แล้ว / ไม่งั้นส่ง filePath มากับโพสต์
class PostVideoFile {
  final String filePath;
  final String? uploadedPath;
  final String? thumbnailPath;
  final int? durationSeconds;
  final int? width;
  final int? height;

  const PostVideoFile({
    required this.filePath,
    this.uploadedPath,
    this.thumbnailPath,
    this.durationSeconds,
    this.width,
    this.height,
  });

  PostVideoFile withUploadedPath(String path) {
    return PostVideoFile(
      filePath: filePath,
      uploadedPath: path,
      thumbnailPath: thumbnailPath,
      durationSeconds: durationSeconds,
      width: width,
      height: height,
    );
  }
}
