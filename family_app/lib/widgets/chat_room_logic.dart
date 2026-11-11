import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../pages/chat_photo_preview_page.dart';
import '../services/api_helper.dart';
import '../theme/app_theme.dart';
import 'chat_media.dart';
import 'chat_widgets.dart';
import 'photo_viewer.dart';

// =======================================================
// ตรรกะห้องแชทที่ใช้ร่วมกัน (แชทส่วนตัว / ร้านค้า / กลุ่ม)
// - ส่ง: ย้ายข้อความเข้าคิวแล้วล้างช่องพิมพ์ทันที / ส่งทีละข้อความตามลำดับ
//   client_id เดิมเมื่อส่งซ้ำ → เซิร์ฟเวอร์ไม่สร้างซ้ำ / ไม่สำเร็จ → ข้อความและรูปยังอยู่ (ส่งอีกครั้ง/แก้ไข/ลบ)
// - ข้อความใหม่ตอนผู้ใช้เลื่อนอ่านข้างบน → พักไว้ก่อน (หน้าจอไม่กระโดด) + ปุ่ม "ข้อความใหม่"
// - โหลดข้อความเก่า: รายการกลับหัว ตำแหน่งที่อ่านอยู่ไม่เลื่อน / ไม่สำเร็จ → ปุ่มลองใหม่
// - อ่านแล้ว: บอกเซิร์ฟเวอร์เฉพาะตอนห้องอยู่ด้านหน้า แอปเปิดอยู่ และเห็นข้อความล่าสุดจริง (อยู่ล่างสุด)
// - เส้น "ข้อความที่ยังไม่ได้อ่าน": ตามตำแหน่งอ่านตอนเปิดห้อง (ไม่ขยับระหว่างอยู่ในห้อง)
// - ตอบกลับ: ปัดขวา/เมนู → แถบเหนือช่องพิมพ์ / แตะข้อความอ้างอิง → ไปยังต้นทาง
//   (ยังไม่ได้โหลด → โหลดย้อนหลังทีละหน้า สูงสุด 10 หน้า) ไม่เปลี่ยนตำแหน่งอ่าน
// - Reaction: เปลี่ยนบนจอทันที ไม่สำเร็จ → คืนค่าเดิม / ข้อความที่โหลดไว้แล้วอัปเดตตอนดึงข้อความใหม่
// - ดึงข้อความใหม่ทุก 4 วินาทีเฉพาะตอนห้องอยู่ด้านหน้าและแอปเปิดอยู่ (ไม่ยิงซ้อน)
// =======================================================

// ร่างข้อความต่อห้อง: จำในหน่วยความจำจนปิดแอป (ไม่บันทึกลงเครื่อง)
class ChatDrafts {
  static final Map<String, String> _drafts = {};

  static String? peek(String room) => _drafts[room];

  static void save(String room, String text) {
    if (text.trim().isEmpty) {
      _drafts.remove(room);
    } else {
      _drafts[room] = text;
    }
  }

  @visibleForTesting
  static void clear() => _drafts.clear();
}

mixin ChatRoomLogic<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  static const Duration pollInterval = Duration(seconds: 4);

  // แตะข้อความอ้างอิงที่ยังไม่ได้โหลด → โหลดย้อนหลังได้สูงสุดกี่หน้า
  static const int jumpPageLimit = 10;

  late final TextEditingController inputController = TextEditingController(
    text: initialDraft(),
  );
  final ScrollController scrollController = ScrollController();
  final FocusNode inputFocus = FocusNode();
  final ImagePicker imagePicker = ImagePicker();
  final Random random = Random();

  // จากเซิร์ฟเวอร์ เรียงเก่า → ใหม่ (ตาม id)
  List<Map<String, dynamic>> messages = [];

  // ข้อความใหม่ที่มาตอนผู้ใช้เลื่อนอ่านข้างบน (ยังไม่แทรกในรายการ)
  final List<Map<String, dynamic>> pendingNew = [];

  // กดส่งแล้วแต่ยังไม่ถึงเซิร์ฟเวอร์
  // {client_id, body, image, state: sending|failed, error, reply_to_id, reply_to}
  final List<Map<String, dynamic>> outbox = [];

  bool isLoading = true;
  String? loadError;
  bool hasMore = false;
  bool isLoadingOlder = false;
  bool olderFailed = false;
  bool isPolling = false;
  bool isFlushing = false;
  bool isJumping = false;
  bool appActive = true;
  bool showJumpDown = false;
  Timer? pollTimer;
  Timer? highlightTimer;
  XFile? pickedImage;
  Map<String, dynamic>? replyingTo;
  int? highlightId;
  int lastReportedRead = 0;

  bool unreadSnapshotTaken = false;
  int? unreadFrom;
  int unreadUntil = 0;

  final Map<int, GlobalKey> messageKeys = {};

  // ข้อความที่กำลังส่ง Reaction (ผลดึงข้อความใหม่ไม่ทับค่าบนจอระหว่างนี้)
  final Set<int> reacting = {};

  // =====================================================
  // แต่ละห้องกำหนดเอง
  // =====================================================

  String? get draftKey;

  bool get roomReady => true;

  bool get canCompose;

  bool get canReact;

  bool get isGroup => false;

  bool get canRefreshImages => false;

  String get loadFailedText => 'เปิดห้องแชทไม่สำเร็จ';

  Future<Map<String, dynamic>> fetchLatest();

  Future<Map<String, dynamic>> fetchAfter(int afterId, int? statesFrom);

  Future<Map<String, dynamic>> fetchBefore(int beforeId);

  Future<Map<String, dynamic>> sendToServer(Map<String, dynamic> entry);

  Future<Map<String, dynamic>> reactOnServer(int messageId, String? emoji);

  // ไม่สำเร็จ → throw (จะบอกใหม่รอบหน้า)
  Future<void> markReadOnServer(int messageId);

  // ข้อความเดียว (ลิงก์ไฟล์/เสียงใหม่เมื่อลิงก์เดิมหมดอายุ)
  Future<Map<String, dynamic>> fetchMessage(int messageId);

  // เรียกใน setState: ข้อมูลห้อง/คู่สนทนาจากผลลัพธ์
  void applyMeta(Map<String, dynamic> result);

  // ตำแหน่งที่เราอ่านถึงตอนเปิดห้อง (null = ไม่รู้ → ไม่แสดงเส้นยังไม่อ่าน)
  int? readIdOnOpen();

  // หมดสิทธิ์/ห้องหาย → ห้องจัดการเองแล้วคืน true
  bool handleLost(Map<String, dynamic> result) => false;

  Object? senderOf(Map<String, dynamic> message);

  String senderNameOf(Map<String, dynamic> message);

  Map<String, dynamic>? avatarOf(Map<String, dynamic> message) => null;

  // สถานะข้อความของเราที่ถึงเซิร์ฟเวอร์แล้ว: ส่งแล้ว / อ่านแล้ว / อ่านแล้ว X คน
  String readStatusOf(Map<String, dynamic> message);

  List<ChatMenuAction> extraActionsFor(Map<String, dynamic> message) =>
      const [];

  Future<void> onExtraAction(
    String action,
    Map<String, dynamic> message,
  ) async {}

  Future<void> refreshImage(Map<String, dynamic> message) async {}

  String initialDraft() {
    final String? key = draftKey;

    return key == null ? '' : (ChatDrafts.peek(key) ?? '');
  }

  // =====================================================
  // เริ่ม / จบ
  // =====================================================

  void startRoom() {
    WidgetsBinding.instance.addObserver(this);
    scrollController.addListener(onScroll);
    inputController.addListener(onInputChanged);
    load();
    pollTimer = Timer.periodic(pollInterval, (_) => poll());
  }

  void disposeRoom() {
    final String? key = draftKey;

    if (key != null) ChatDrafts.save(key, inputController.text);

    WidgetsBinding.instance.removeObserver(this);
    pollTimer?.cancel();
    highlightTimer?.cancel();
    inputController.dispose();
    scrollController.dispose();
    inputFocus.dispose();

    // ออกจากห้อง: หยุดอัด (ลบไฟล์ชั่วคราว) และหยุดเล่นเสียง
    recorder?.dispose();
    recorder = null;
    ChatVoicePlayer.instance.stop();
  }

  // ห้องที่รู้รหัสทีหลัง (แชทกลุ่มเปิดจากหน้ากลุ่ม) → คืนร่างข้อความถ้าช่องพิมพ์ยังว่าง
  void restoreDraftIfEmpty() {
    final String? key = draftKey;
    final String? draft = key == null ? null : ChatDrafts.peek(key);

    if (draft != null && inputController.text.isEmpty) {
      inputController.text = draft;
    }
  }

  void onInputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appActive = state == AppLifecycleState.resumed;

    if (appActive) {
      poll();
      return;
    }

    // แอปพัก / มีสายเข้า: หยุดอัด (เก็บส่วนที่อัดแล้วให้ฟังก่อนส่ง) และหยุดเล่นเสียง
    recorder?.stop();
    ChatVoicePlayer.instance.stop();
  }

  // =====================================================
  // ข้อมูล
  // =====================================================

  int? idOf(Map<String, dynamic>? message) {
    final dynamic value = message?['id'];

    return value is num ? value.toInt() : null;
  }

  List<Map<String, dynamic>> parseMessages(dynamic raw) {
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((item) => stamp(Map<String, dynamic>.from(item)))
        .where((message) => idOf(message) != null)
        .toList();
  }

  // เวลาที่ได้รับ (ลิงก์ไฟล์/เสียงมีอายุสั้น → ใกล้หมดค่อยขอใหม่)
  Map<String, dynamic> stamp(Map<String, dynamic> message) =>
      message..['_received_at'] = DateTime.now();

  Map<String, dynamic>? messageById(int id) {
    for (final message in messages) {
      if (idOf(message) == id) return message;
    }

    return null;
  }

  int get latestKnownId {
    int latest = 0;

    for (final message in [...messages, ...pendingNew]) {
      latest = max(latest, idOf(message) ?? 0);
    }

    return latest;
  }

  // เพิ่มข้อความที่ยังไม่มี แล้วเรียงตาม id (ข้อความซ้ำจากหลายทางแสดงครั้งเดียว)
  void addMessages(Iterable<Map<String, dynamic>> incoming) {
    final Set<int?> known = messages.map(idOf).toSet();
    final List<Map<String, dynamic>> added = [
      for (final message in incoming)
        if (known.add(idOf(message))) message,
    ];

    if (added.isEmpty) return;

    messages = [...messages, ...added]
      ..sort((a, b) => (idOf(a) ?? 0).compareTo(idOf(b) ?? 0));
  }

  void mergePending() {
    addMessages(pendingNew);
    pendingNew.clear();
  }

  bool get roomInFront =>
      mounted && appActive && (ModalRoute.of(context)?.isCurrent ?? true);

  bool get isAtBottom =>
      !scrollController.hasClients || scrollController.offset < 80;

  Future<void> load() async {
    try {
      final Map<String, dynamic> result = await fetchLatest();

      if (!mounted || handleLost(result)) return;

      if (result['status'] == true) {
        setState(() {
          messages = parseMessages(result['messages']);
          pendingNew.clear();
          hasMore = result['has_more'] == true;
          olderFailed = false;
          applyMeta(result);
          loadError = null;

          if (!unreadSnapshotTaken) {
            unreadSnapshotTaken = true;
            unreadFrom = readIdOnOpen();
            unreadUntil = latestKnownId;
          }
        });

        WidgetsBinding.instance.addPostFrameCallback((_) => markReadIfSeen());
      } else {
        setState(
          () => loadError = result['message']?.toString() ?? loadFailedText,
        );
      }
    } catch (e) {
      if (mounted) setState(() => loadError = ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ข้อความใหม่ + สถานะ (Reaction / อ่านแล้ว) ของข้อความที่โหลดไว้แล้ว
  Future<void> poll() async {
    if (isLoading ||
        isPolling ||
        loadError != null ||
        !roomReady ||
        !roomInFront) {
      return;
    }

    isPolling = true;

    try {
      // ข้อความล่าสุดที่โหลดไว้ไม่เกิน 100 ข้อความ
      final int? statesFrom = messages.isEmpty
          ? null
          : idOf(messages[max(0, messages.length - 100)]);

      final Map<String, dynamic> result = await fetchAfter(
        latestKnownId,
        statesFrom,
      );

      if (!mounted || handleLost(result) || result['status'] != true) return;

      final Set<int?> known = {...messages.map(idOf), ...pendingNew.map(idOf)};
      final List<Map<String, dynamic>> fresh = parseMessages(result['messages'])
          .where((message) => !known.contains(idOf(message)))
          .toList();

      // ข้อความที่เรากำลังส่ง (มาถึงทางนี้ก่อนผลการส่ง) → แทนที่ในจุดเดิม
      final Set<String> waiting = outbox
          .map((entry) => entry['client_id'].toString())
          .toSet();
      final List<Map<String, dynamic>> ours = fresh
          .where((m) => waiting.contains(m['client_id']?.toString()))
          .toList();

      final bool atBottom = isAtBottom;

      setState(() {
        removeDelivered(fresh);

        if (atBottom) {
          mergePending();
          addMessages(fresh);
        } else {
          addMessages(ours);
          pendingNew.addAll(fresh.where((m) => !ours.contains(m)));
        }

        applyStates(result['states']);
        applyMeta(result);
      });

      if (atBottom) markReadIfSeen();
    } catch (_) {
      // เน็ตหลุดชั่วคราว → รอบหน้าลองใหม่
    } finally {
      isPolling = false;
    }
  }

  void applyStates(dynamic raw) {
    if (raw is! List) return;

    final Map<int, Map<String, dynamic>> byId = {
      for (final message in [...messages, ...pendingNew])
        idOf(message)!: message,
    };

    for (final state in raw.whereType<Map>()) {
      final int? id = state['id'] is num ? (state['id'] as num).toInt() : null;
      final Map<String, dynamic>? message = id == null ? null : byId[id];

      if (message == null) continue;

      if (state['reactions'] is List && !reacting.contains(id)) {
        message['reactions'] = state['reactions'];
      }

      if (state['read_count'] is num) {
        message['read_count'] = state['read_count'];
      }
    }
  }

  // อยู่ล่างสุด (เห็นข้อความล่าสุด) + ห้องอยู่ด้านหน้า → อ่านถึงข้อความล่าสุด
  void markReadIfSeen() {
    if (!roomReady || !roomInFront || !isAtBottom || pendingNew.isNotEmpty) {
      return;
    }

    final int latest = messages.isEmpty ? 0 : (idOf(messages.last) ?? 0);

    if (latest <= lastReportedRead) return;

    lastReportedRead = latest;

    markReadOnServer(latest).catchError((_) {
      if (lastReportedRead == latest) lastReportedRead = 0;
    });
  }

  void onScroll() {
    if (!scrollController.hasClients) return;

    final bool farFromNewest = scrollController.offset > 600;

    if (farFromNewest != showJumpDown) {
      setState(() => showJumpDown = farFromNewest);
    }

    if (isAtBottom && !isJumping) {
      if (pendingNew.isNotEmpty) setState(mergePending);

      markReadIfSeen();
    }

    final ScrollPosition position = scrollController.position;

    if (hasMore &&
        !isLoadingOlder &&
        !olderFailed &&
        !isJumping &&
        position.pixels >= position.maxScrollExtent - 300) {
      loadOlder();
    }
  }

  // ข้อความเก่ากว่าที่มี (ไม่สำเร็จ → ข้อความเดิมยังอยู่ + ปุ่มลองใหม่)
  Future<bool> loadOlder() async {
    final int? firstId = messages.isEmpty ? null : idOf(messages.first);

    if (firstId == null || isLoadingOlder || !roomReady) return false;

    setState(() {
      isLoadingOlder = true;
      olderFailed = false;
    });

    try {
      final Map<String, dynamic> result = await fetchBefore(firstId);

      if (!mounted || handleLost(result)) return false;

      if (result['status'] != true) {
        setState(() => olderFailed = true);
        return false;
      }

      final Set<int?> known = messages.map(idOf).toSet();

      setState(() {
        messages = [
          ...parseMessages(result['messages'])
              .where((message) => !known.contains(idOf(message))),
          ...messages,
        ];
        hasMore = result['has_more'] == true;
      });

      return true;
    } catch (_) {
      if (mounted) setState(() => olderFailed = true);
      return false;
    } finally {
      if (mounted) setState(() => isLoadingOlder = false);
    }
  }

  void scrollToNewest() {
    if (!scrollController.hasClients) return;

    if (MediaQuery.of(context).disableAnimations) {
      scrollController.jumpTo(0);
      return;
    }

    scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void goToNewest() {
    setState(mergePending);
    scrollToNewest();
    WidgetsBinding.instance.addPostFrameCallback((_) => markReadIfSeen());
  }

  // =====================================================
  // ส่ง
  // =====================================================

  bool get hasDraft =>
      inputController.text.trim().isNotEmpty || pickedImage != null;

  // แถบอัดเสียง: หน้าห้องต้องสร้างใหม่เมื่อเริ่ม/หยุด/ทิ้ง เพื่อสลับกับช่องพิมพ์
  void onRecorderChanged() {
    if (mounted) setState(() {});
  }

  Future<void> pickImage() async {
    try {
      final XFile? image = await imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 80,
      );

      if (image != null && mounted) setState(() => pickedImage = image);
    } catch (_) {
      showMessage('เลือกรูปไม่สำเร็จ');
    }
  }

  String previewText(Map<String, dynamic> message) {
    final String body = message['body']?.toString() ?? '';

    if (body.isNotEmpty) return body;

    final String? url = message['image_url']?.toString();
    final String? kind = attachmentKindOf(message);

    if (kind == 'voice') return '🎤 ข้อความเสียง';
    if (kind == 'file') return '📎 ${attachmentNameOf(message)}';

    return (url != null && url.isNotEmpty) || message['image'] != null
        ? '📷 รูปภาพ'
        : '';
  }

  String? attachmentKindOf(Map<String, dynamic> message) {
    if (message['voice'] is Map) return 'voice';
    if (message['file'] is Map) return 'file';

    final dynamic attachment = message['attachment'];

    return attachment is Map ? attachment['kind']?.toString() : null;
  }

  String attachmentNameOf(Map<String, dynamic> message) {
    final dynamic local = message['file'];
    final dynamic attachment = message['attachment'];

    if (local is Map) return local['name']?.toString() ?? 'ไฟล์';

    return attachment is Map
        ? attachment['name']?.toString() ?? 'ไฟล์'
        : 'ไฟล์';
  }

  // ตัวอย่างข้อความต้นทางของข้อความที่กำลังส่ง (หลังส่งสำเร็จใช้ของเซิร์ฟเวอร์)
  Map<String, dynamic> replyPreviewOf(Map<String, dynamic> message) {
    final String body = message['body']?.toString() ?? '';
    final String? url = message['image_url']?.toString();

    return {
      'available': true,
      'id': idOf(message),
      'is_mine': message['is_mine'] == true,
      'sender_name': senderNameOf(message),
      'body': body.length > 100 ? '${body.substring(0, 100)}…' : body,
      'has_image': url != null && url.isNotEmpty,
      'attachment_kind': attachmentKindOf(message),
    };
  }

  // เข้าคิวส่ง (ข้อความ/รูป/ไฟล์/เสียง) พร้อมข้อความที่กำลังตอบกลับ
  void enqueue(Map<String, dynamic> content) {
    if (!canCompose || !roomReady) return;

    final Map<String, dynamic>? reply = replyingTo;

    setState(() {
      mergePending();

      outbox.add({
        'client_id':
            '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 30)}',
        'body': '',
        'image': null,
        'state': 'sending',
        'error': null,
        'is_mine': true,
        'created_at': DateTime.now().toIso8601String(),
        ...content,
        if (reply != null) 'reply_to_id': idOf(reply),
        if (reply != null) 'reply_to': replyPreviewOf(reply),
      });

      replyingTo = null;
    });

    scrollToNewest();
    flushOutbox();
  }

  void send() {
    if (!hasDraft || !canCompose || !roomReady) return;

    final String text = inputController.text.trim();
    final XFile? image = pickedImage;

    pickedImage = null;
    inputController.clear();
    enqueue({'body': text, 'image': image});
  }

  // ไฟล์ชั่วคราวของแอป (เสียงที่อัด / สำเนาไฟล์ที่เลือก) → ลบเมื่อส่งสำเร็จหรือทิ้ง
  void deleteTempFiles(Map<String, dynamic> entry) {
    final dynamic paths = entry['temp_paths'];

    if (paths is! List) return;

    for (final path in paths.whereType<String>()) {
      File(path).delete().catchError((_) => File(path));
    }
  }

  // =====================================================
  // แนบ: ถ่ายรูป / เลือกรูป / ส่งไฟล์ / แชร์ลิงก์
  // =====================================================

  Future<void> openAttachMenu() async {
    closeEmoji();

    final String? choice = await showChatAttachMenu(context);

    if (!mounted || choice == null) return;

    switch (choice) {
      case 'camera':
        await takePhoto();
      case 'gallery':
        await pickImage();
      case 'file':
        await pickDocument();
      case 'link':
        await shareLink();
    }
  }

  // ถ่ายรูป → ดูตัวอย่าง (ถ่ายใหม่ / ยกเลิก / ใส่คำบรรยาย) → ส่ง / ร่างในช่องพิมพ์ไม่ถูกแตะต้อง
  Future<void> takePhoto() async {
    if (!await ensureChatPermission(context, Permission.camera, 'กล้อง')) {
      return;
    }

    while (mounted) {
      XFile? shot;

      try {
        shot = await imagePicker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1600,
          imageQuality: 80,
        );
      } catch (_) {
        if (mounted) showMessage('เปิดกล้องไม่สำเร็จ');
        return;
      }

      if (shot == null || !mounted) return;

      final Object? result = await Navigator.of(context).push<Object?>(
        MaterialPageRoute(builder: (_) => ChatPhotoPreviewPage(image: shot!)),
      );

      if (result == 'retake') continue;

      if (result is Map) {
        enqueue({
          'body': (result['caption'] ?? '').toString().trim(),
          'image': shot,
        });
      }

      return;
    }
  }

  Future<void> pickDocument() async {
    PlatformFile? picked;

    try {
      picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: chatFileExtensions,
      );
    } catch (_) {
      if (mounted) showMessage('เลือกไฟล์ไม่สำเร็จ');
      return;
    }

    if (picked == null || !mounted) return;

    final String extension = (picked.extension ?? '').toLowerCase();

    if (!chatFileExtensions.contains(extension)) {
      showMessage('รองรับเฉพาะไฟล์ PDF, TXT, DOCX, XLSX และ PPTX');
      return;
    }

    final int size = await picked.length() ?? 0;

    if (size <= 0 || size > chatMaxFileBytes) {
      if (mounted) showMessage('ไฟล์ต้องมีขนาดไม่เกิน 10 MB');
      return;
    }

    String? path = picked.path;
    final List<String> temp = [];

    // ไฟล์จากผู้ให้บริการเอกสาร (content://) → คัดลอกไว้ชั่วคราวเพื่ออัปโหลด/ลองใหม่
    if (path == null) {
      try {
        final Directory dir = await getTemporaryDirectory();
        final File copy = File(
          '${dir.path}/upload_${DateTime.now().microsecondsSinceEpoch}.$extension',
        );
        final IOSink sink = copy.openWrite();

        await sink.addStream(picked.readAsByteStream());
        await sink.close();

        path = copy.path;
        temp.add(copy.path);
      } catch (_) {
        if (mounted) showMessage('อ่านไฟล์ไม่สำเร็จ');
        return;
      }
    }

    enqueue({
      'file': {'path': path, 'name': picked.name, 'size': size},
      'temp_paths': temp,
    });
  }

  Future<void> shareLink() async {
    final String? link = await showDialog<String>(
      context: context,
      builder: (_) => const ChatLinkDialog(),
    );

    if (link == null || !mounted) return;

    insertIntoComposer('$link ');
  }

  void insertIntoComposer(String text) {
    // ไม่เกินความยาวสูงสุดของข้อความ (นับตามตัวอักษรที่เห็น)
    if (inputController.text.characters.length + text.characters.length >
        2000) {
      showMessage('ข้อความยาวได้ไม่เกิน 2,000 ตัวอักษร');
      return;
    }

    chatInsertText(inputController, text);
  }

  // =====================================================
  // อีโมจิ
  // =====================================================

  bool emojiOpen = false;

  void toggleEmoji() {
    if (emojiOpen) {
      setState(() => emojiOpen = false);
      inputFocus.requestFocus();
      return;
    }

    inputFocus.unfocus();
    setState(() => emojiOpen = true);
  }

  void closeEmoji() {
    if (emojiOpen) setState(() => emojiOpen = false);
  }

  // =====================================================
  // ข้อความเสียง
  // =====================================================

  ChatVoiceRecorder? recorder;

  Future<void> startVoice() async {
    if (!canCompose || !roomReady) return;

    closeEmoji();

    if (!await ensureChatPermission(
      context,
      Permission.microphone,
      'ไมโครโฟน',
    )) {
      return;
    }

    if (!mounted) return;

    await ChatVoicePlayer.instance.stop();

    final ChatVoiceRecorder voice = recorder ??= (ChatVoiceRecorder()
      ..addListener(onRecorderChanged));

    try {
      await voice.start();
    } catch (_) {
      if (mounted) showMessage('เริ่มอัดเสียงไม่สำเร็จ');
    }

    if (mounted) setState(() {});
  }

  void sendVoice() {
    final Map<String, dynamic>? voice = recorder?.take();

    if (voice == null) return;

    ChatVoicePlayer.instance.stop();
    enqueue({
      'voice': voice,
      'temp_paths': [voice['path']],
    });
  }

  // =====================================================
  // เปิดไฟล์ / เล่นเสียงของข้อความ
  // =====================================================

  // ลิงก์ที่ยังใช้ได้ (ใกล้หมดอายุ → ขอข้อความนี้ใหม่ เซิร์ฟเวอร์ตรวจสิทธิ์อีกครั้ง)
  Future<String?> freshAttachmentUrl(Map<String, dynamic> message) async {
    final dynamic attachment = message['attachment'];

    if (attachment is! Map) return null;

    final dynamic received = message['_received_at'];
    final int lifetime = (attachment['expires_in'] as num?)?.toInt() ?? 600;

    if (received is DateTime &&
        DateTime.now().difference(received).inSeconds < lifetime - 60) {
      return attachment['url']?.toString();
    }

    final int? id = idOf(message);

    if (id == null) return null;

    final Map<String, dynamic> result = await fetchMessage(id);

    if (!mounted || handleLost(result)) return null;

    final dynamic fresh = result['message'];

    if (result['status'] != true ||
        fresh is! Map ||
        fresh['attachment'] is! Map) {
      return null;
    }

    message['attachment'] = fresh['attachment'];
    stamp(message);

    return (fresh['attachment'] as Map)['url']?.toString();
  }

  Future<void> openAttachment(Map<String, dynamic> message) async {
    String? url;

    try {
      url = await freshAttachmentUrl(message);
    } catch (_) {
      url = null;
    }

    if (!mounted) return;

    final Uri? uri = url == null ? null : Uri.tryParse(url);
    bool opened = false;

    if (uri != null) {
      try {
        // ดาวน์โหลดผ่านเบราว์เซอร์ด้วยลิงก์ชั่วคราว (หมดอายุใน 10 นาที)
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }

    if (!opened && mounted) showMessage('เปิดไฟล์ไม่สำเร็จ ลองใหม่อีกครั้ง');
  }

  String voiceCachePath(Directory dir, int id) =>
      '${dir.path}/chat_voice_${(draftKey ?? 'room').replaceAll(':', '_')}_$id.m4a';

  // เสียงของข้อความ: ไฟล์ในคิวส่ง / ดาวน์โหลดมาเก็บชั่วคราวในเครื่องแล้วเล่น
  Future<String?> voicePathOf(Map<String, dynamic> message) async {
    final dynamic local = message['voice'];

    if (local is Map) return local['path']?.toString();

    final int? id = idOf(message);

    if (id == null) return null;

    final Directory dir = await getTemporaryDirectory();
    final File file = File(voiceCachePath(dir, id));

    if (await file.exists() && await file.length() > 0) return file.path;

    final String? url = await freshAttachmentUrl(message);

    if (url == null) return null;

    final http.Response response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) return null;

    await file.writeAsBytes(response.bodyBytes, flush: true);

    return file.path;
  }

  // หมดสิทธิ์ห้อง → ลบเสียงที่แอปเก็บไว้ (ไฟล์ที่ผู้ใช้บันทึกเองนอกแอปเรียกคืนไม่ได้)
  Future<void> clearCachedMedia() async {
    await ChatVoicePlayer.instance.stop();

    try {
      final Directory dir = await getTemporaryDirectory();

      for (final message in [...messages, ...pendingNew]) {
        final int? id = idOf(message);

        if (id != null) {
          final File file = File(voiceCachePath(dir, id));

          if (await file.exists()) await file.delete();
        }
      }
    } catch (_) {}
  }

  Widget? buildAttachment(Map<String, dynamic> message, bool mine) {
    final String? state = message['state']?.toString();
    final dynamic localFile = message['file'];
    final dynamic localVoice = message['voice'];
    final dynamic attachment = message['attachment'];

    if (localFile is Map) {
      return ChatFileTile(
        name: localFile['name']?.toString() ?? 'ไฟล์',
        size: (localFile['size'] as num?)?.toInt() ?? 0,
        mine: mine,
        uploading: state == 'sending',
      );
    }

    if (localVoice is Map) {
      return ChatVoiceTile(
        playKey: 'out:${message['client_id']}',
        durationMs: (localVoice['duration_ms'] as num?)?.toInt() ?? 0,
        mine: mine,
        resolve: () async => localVoice['path']?.toString(),
      );
    }

    if (attachment is! Map) return null;

    if (attachment['kind'] == 'voice') {
      return ChatVoiceTile(
        playKey: 'msg:${draftKey ?? ''}:${idOf(message)}',
        durationMs: (attachment['duration_ms'] as num?)?.toInt() ?? 0,
        mine: mine,
        resolve: () => voicePathOf(message),
      );
    }

    return ChatFileTile(
      name: attachment['name']?.toString() ?? 'ไฟล์',
      size: (attachment['size'] as num?)?.toInt() ?? 0,
      mine: mine,
      onOpen: () => openAttachment(message),
    );
  }

  Future<void> flushOutbox() async {
    if (isFlushing) return;

    isFlushing = true;

    try {
      while (mounted) {
        final int index = outbox.indexWhere((m) => m['state'] == 'sending');

        if (index < 0) break;

        await deliver(outbox[index]);
      }
    } finally {
      isFlushing = false;
    }
  }

  Future<void> deliver(Map<String, dynamic> entry) async {
    String? error;

    try {
      final Map<String, dynamic> result = await sendToServer(entry);

      if (!mounted || handleLost(result)) return;

      final dynamic sent = result['message'];

      if (result['status'] == true && sent is Map) {
        setState(() {
          outbox.remove(entry);

          // ผลส่งชนกับข้อความจากการดึงข้อความใหม่ → ไม่แสดงซ้ำ
          addMessages([stamp(Map<String, dynamic>.from(sent))]);
        });

        deleteTempFiles(entry);

        markReadIfSeen();
        return;
      }

      if (result['code'] == 'reply_unavailable') {
        // ต้นทางถูกลบ/ไม่มีสิทธิ์แล้ว → ส่งอีกครั้งเป็นข้อความปกติ (ข้อความไม่หาย)
        entry.remove('reply_to_id');
        entry.remove('reply_to');
        error =
            '${result['message'] ?? 'ข้อความที่ต้องการตอบกลับไม่พร้อมใช้งานแล้ว'}'
            ' · ส่งอีกครั้งจะส่งเป็นข้อความปกติ';
      } else {
        error = result['message']?.toString() ?? 'ส่งข้อความไม่สำเร็จ';
      }
    } catch (e) {
      error = ApiHelper.messageOf(e);
    }

    if (!mounted || !outbox.contains(entry)) return;

    setState(() {
      entry['state'] = 'failed';
      entry['error'] = error;
    });
  }

  // ข้อความที่ client_id ตรงกับคิว (มาทางการดึงข้อความใหม่) → ส่งถึงแล้ว
  void removeDelivered(List<Map<String, dynamic>> incoming) {
    final Set<String> delivered = incoming
        .map((m) => m['client_id']?.toString())
        .whereType<String>()
        .toSet();

    if (delivered.isNotEmpty) {
      outbox.removeWhere((m) => delivered.contains(m['client_id']));
    }
  }

  // ส่งไม่สำเร็จ: ส่งอีกครั้ง / แก้ไข (กลับไปที่ช่องพิมพ์) / คัดลอก / ลบ
  Future<void> openFailedActions(Map<String, dynamic> entry) async {
    final String body = entry['body']?.toString() ?? '';

    // แก้ไขได้เมื่อช่องพิมพ์ว่าง (ไม่ทับข้อความที่กำลังพิมพ์อยู่)
    final bool canEdit =
        !hasDraft && entry['file'] == null && entry['voice'] == null;

    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry['error'] != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    entry['error'].toString(),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                ),
              ListTile(
                leading: Icon(Icons.refresh_rounded, color: AppColors.primary),
                title: const Text('ส่งอีกครั้ง'),
                onTap: () => Navigator.of(sheetContext).pop('retry'),
              ),
              ListTile(
                enabled: canEdit,
                leading: Icon(Icons.edit_outlined, color: AppColors.navy),
                title: const Text('แก้ไขข้อความ'),
                subtitle: canEdit
                    ? null
                    : const Text('ส่งหรือลบข้อความในช่องพิมพ์ก่อน'),
                onTap: () => Navigator.of(sheetContext).pop('edit'),
              ),
              if (body.isNotEmpty)
                ListTile(
                  leading: Icon(Icons.copy_rounded, color: AppColors.navy),
                  title: const Text('คัดลอกข้อความ'),
                  onTap: () => Navigator.of(sheetContext).pop('copy'),
                ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.danger,
                ),
                title: Text(
                  'ลบข้อความนี้',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: () => Navigator.of(sheetContext).pop('discard'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (!mounted || action == null || !outbox.contains(entry)) return;

    switch (action) {
      case 'retry':
        setState(() {
          entry['state'] = 'sending';
          entry['error'] = null;
        });

        flushOutbox();
      case 'edit':
        if (hasDraft) return;

        final dynamic replyId = entry['reply_to_id'];

        setState(() {
          outbox.remove(entry);
          inputController.text = body;
          pickedImage = entry['image'] as XFile?;
          replyingTo = replyId is int ? messageById(replyId) : null;
        });

        inputFocus.requestFocus();
      case 'copy':
        await Clipboard.setData(ClipboardData(text: body));

        if (mounted) showMessage('คัดลอกแล้ว');
      case 'discard':
        deleteTempFiles(entry);
        setState(() => outbox.remove(entry));
    }
  }

  // ออกจากห้องตอนยังมีข้อความค้าง → ถามก่อน (คิวไม่ได้บันทึกไว้)
  Future<void> confirmLeave() async {
    final bool sending = outbox.any((m) => m['state'] == 'sending');

    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          sending ? 'ยังส่งข้อความไม่เสร็จ' : 'มีข้อความที่ส่งไม่สำเร็จ',
        ),
        content: Text(
          sending
              ? 'ถ้าออกตอนนี้ ข้อความที่ยังไม่ได้ส่งอาจหายไป'
              : 'ถ้าออกตอนนี้ ข้อความที่ส่งไม่สำเร็จจะหายไป',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('ออก'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('อยู่ต่อ'),
          ),
        ],
      ),
    );

    if (leave == true && mounted) {
      setState(() => outbox.clear());
      Navigator.of(context).pop();
    }
  }

  Widget leaveGuard({required Widget child}) {
    return PopScope(
      canPop: outbox.isEmpty && !emojiOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        if (emojiOpen) {
          closeEmoji();
        } else {
          confirmLeave();
        }
      },
      child: child,
    );
  }

  void showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // =====================================================
  // ตอบกลับ
  // =====================================================

  bool canReplyTo(Map<String, dynamic> message) =>
      canCompose &&
      roomReady &&
      message['state'] == null &&
      idOf(message) != null;

  void startReply(Map<String, dynamic> message) {
    if (!canReplyTo(message)) return;

    setState(() => replyingTo = message);
    inputFocus.requestFocus();
  }

  GlobalKey keyFor(int id) => messageKeys.putIfAbsent(id, GlobalKey.new);

  // แตะข้อความอ้างอิง → ไปยังต้นทาง (ยังไม่ได้โหลด → โหลดย้อนหลังทีละหน้า)
  Future<void> jumpToMessage(int id) async {
    if (isJumping) return;

    isJumping = true;

    try {
      if (messageById(id) == null && pendingNew.any((m) => idOf(m) == id)) {
        setState(mergePending);
      }

      int pages = 0;

      while (mounted &&
          messageById(id) == null &&
          hasMore &&
          pages < jumpPageLimit) {
        final int? firstId = messages.isEmpty ? null : idOf(messages.first);

        // อยู่ในช่วงที่โหลดแล้วแต่ไม่มี = ถูกลบไปแล้ว
        if (firstId == null || id > firstId) break;

        if (!await loadOlder()) break;

        pages++;
      }

      if (!mounted) return;

      if (messageById(id) == null) {
        showMessage('ไม่พบข้อความต้นทาง อาจถูกลบหรือเก่าเกินไป');
        return;
      }

      await reveal(id);

      if (!mounted) return;

      setState(() => highlightId = id);

      highlightTimer?.cancel();
      highlightTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => highlightId = null);
      });
    } finally {
      isJumping = false;
    }
  }

  // เลื่อนหาจนข้อความถูกสร้างบนจอ แล้วเลื่อนให้อยู่กลางจอ
  Future<void> reveal(int id) async {
    final GlobalKey key = keyFor(id);

    await WidgetsBinding.instance.endOfFrame;

    for (
      int pass = 0;
      pass < 2 && mounted && key.currentContext == null;
      pass++
    ) {
      if (!scrollController.hasClients) return;

      if (pass == 1) {
        scrollController.jumpTo(0);
        await WidgetsBinding.instance.endOfFrame;
      }

      for (
        int step = 0;
        step < 80 && mounted && key.currentContext == null;
        step++
      ) {
        final ScrollPosition position = scrollController.position;
        final double next = min(
          position.pixels + position.viewportDimension * 0.8,
          position.maxScrollExtent,
        );

        if (next <= position.pixels) break;

        scrollController.jumpTo(next);
        await WidgetsBinding.instance.endOfFrame;
      }
    }

    if (!mounted) return;

    final bool reduceMotion = MediaQuery.of(context).disableAnimations;
    final BuildContext? target = key.currentContext;

    if (target == null || !target.mounted) return;

    await Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // =====================================================
  // Reaction
  // =====================================================

  bool canReactTo(Map<String, dynamic> message) =>
      canReact &&
      roomReady &&
      message['state'] == null &&
      idOf(message) != null;

  List<Map<String, dynamic>> reactionsOf(Map<String, dynamic> message) {
    final dynamic raw = message['reactions'];

    if (raw is! List) return const [];

    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  String? myReactionOf(Map<String, dynamic> message) {
    for (final reaction in reactionsOf(message)) {
      if (reaction['mine'] == true) return reaction['emoji']?.toString();
    }

    return null;
  }

  // ผลบนจอทันที: ถอนของเดิม (ถ้ามี) แล้วเพิ่มอันใหม่ เรียงตามลำดับอีโมจิ
  List<Map<String, dynamic>> withMyReaction(
    List<Map<String, dynamic>> current,
    String? emoji,
  ) {
    final Map<String, int> counts = {};
    String? mine;

    for (final reaction in current) {
      final String key = reaction['emoji'].toString();
      final dynamic count = reaction['count'];

      counts[key] = count is num ? count.toInt() : 0;

      if (reaction['mine'] == true) mine = key;
    }

    if (mine != null) counts[mine] = (counts[mine] ?? 1) - 1;
    if (emoji != null) counts[emoji] = (counts[emoji] ?? 0) + 1;

    return [
      for (final e in chatReactionEmojis)
        if ((counts[e] ?? 0) > 0)
          {'emoji': e, 'count': counts[e], 'mine': e == emoji},
    ];
  }

  Future<void> setReaction(Map<String, dynamic> message, String? emoji) async {
    final int? id = idOf(message);

    if (id == null || reacting.contains(id) || !canReactTo(message)) return;

    final dynamic previous = message['reactions'];

    reacting.add(id);
    setState(
      () => message['reactions'] = withMyReaction(reactionsOf(message), emoji),
    );

    try {
      final Map<String, dynamic> result = await reactOnServer(id, emoji);

      if (!mounted || handleLost(result)) return;

      if (result['status'] == true && result['reactions'] is List) {
        setState(() => message['reactions'] = result['reactions']);
      } else {
        setState(() => message['reactions'] = previous);
        showMessage(result['message']?.toString() ?? 'แสดงความรู้สึกไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) {
        setState(() => message['reactions'] = previous);
        showMessage(ApiHelper.messageOf(e));
      }
    } finally {
      reacting.remove(id);
    }
  }

  void toggleReaction(Map<String, dynamic> message, String emoji) {
    setReaction(message, myReactionOf(message) == emoji ? null : emoji);
  }

  // =====================================================
  // เมนูกดค้าง
  // =====================================================

  Future<void> openMessageMenu(Map<String, dynamic> message) async {
    if (message['state'] == 'failed') return openFailedActions(message);
    if (message['state'] != null) return;

    final String body = message['body']?.toString() ?? '';

    final String? choice = await showChatMessageMenu(
      context,
      canReact: canReactTo(message),
      myReaction: myReactionOf(message),
      canReply: canReplyTo(message),
      canCopy: body.isNotEmpty,
      extra: extraActionsFor(message),
    );

    if (!mounted || choice == null) return;

    if (choice.startsWith('emoji:')) {
      await setReaction(message, choice.substring(6));
    } else if (choice == 'unreact') {
      await setReaction(message, null);
    } else if (choice == 'reply') {
      startReply(message);
    } else if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: body));

      if (mounted) showMessage('คัดลอกแล้ว');
    } else {
      await onExtraAction(choice, message);
    }
  }

  // =====================================================
  // UI
  // =====================================================

  Widget? buildMessageImage(Map<String, dynamic> message) {
    final XFile? local = message['image'] as XFile?;
    final BorderRadius radius = BorderRadius.circular(18);

    if (local != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          File(local.path),
          width: 220,
          height: 230,
          fit: BoxFit.cover,
        ),
      );
    }

    final String? url = message['image_url']?.toString();

    if (url == null || url.isEmpty) return null;

    return Semantics(
      button: true,
      label: 'รูปภาพ แตะเพื่อดูรูปเต็ม',
      child: GestureDetector(
        onTap: () => showPhotoViewer(context, urls: [url]),
        child: ClipRRect(
          borderRadius: radius,
          child: Image.network(
            url,
            width: 220,
            height: 230,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => canRefreshImages
                ? InkWell(
                    onTap: () => refreshImage(message),
                    child: Container(
                      width: 220,
                      height: 120,
                      color: AppColors.fill,
                      alignment: Alignment.center,
                      child: Text(
                        'แตะเพื่อโหลดรูปใหม่',
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ),
                  )
                : Container(
                    width: 220,
                    height: 120,
                    color: AppColors.fill,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: AppColors.muted,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  // ข้อความแรกที่ยังไม่ได้อ่านตอนเปิดห้อง (ของคนอื่น)
  int? firstUnreadId() {
    final int? from = unreadFrom;

    if (from == null) return null;

    for (final message in messages) {
      final int? id = idOf(message);

      if (id != null &&
          id > from &&
          id <= unreadUntil &&
          message['is_mine'] != true) {
        return id;
      }
    }

    return null;
  }

  // ชุดเดียวกัน = ผู้ส่งเดียวกัน + สถานะเดียวกัน (ข้อความของเรา)
  Object runKeyOf(Map<String, dynamic> message) {
    final String? state = message['state']?.toString();

    if (state == 'failed') return 'failed:${message['client_id']}';
    if (state != null) return 'sending';

    return '${senderOf(message)}|${message['is_mine'] == true ? readStatusOf(message) : ''}';
  }

  Widget buildMessageRow(
    Map<String, dynamic> message, {
    required bool startOfRun,
    required bool endOfRun,
  }) {
    final bool mine = message['is_mine'] == true;
    final String body = message['body']?.toString() ?? '';
    final String? state = message['state']?.toString();
    final bool failed = state == 'failed';
    final int? id = idOf(message);
    final DateTime? time = ChatFormat.timeOf(message);
    final dynamic reply = message['reply_to'];
    final List<Map<String, dynamic>> reactions = reactionsOf(message);
    final String status = state == 'sending'
        ? 'กำลังส่ง…'
        : failed
        ? 'ส่งไม่สำเร็จ · แตะเพื่อส่งอีกครั้ง'
        : (mine ? readStatusOf(message) : '');

    final String footer = state != null
        ? status
        : [
            if (time != null) ChatFormat.time(time),
            if (mine) status,
          ].join(' · ');

    final String label = [
      mine ? 'ข้อความของคุณ' : 'ข้อความจาก ${senderNameOf(message)}',
      if (body.isNotEmpty) body,
      if (message['image_url'] != null || message['image'] != null) 'มีรูปภาพ',
      if (attachmentKindOf(message) == 'file')
        'ไฟล์ ${attachmentNameOf(message)}',
      if (attachmentKindOf(message) == 'voice') 'ข้อความเสียง',
      if (time != null) 'เวลา ${ChatFormat.time(time)}',
      if (status.isNotEmpty) status,
      if (reactions.isNotEmpty)
        'ความรู้สึก ${reactions.map((r) => '${r['emoji']} ${r['count']}').join(' ')}',
    ].join(', ');

    final Widget bubble = ChatBubble(
      mine: mine,
      body: body,
      semanticsLabel: label,
      senderName: isGroup && !mine ? senderNameOf(message) : null,
      senderAvatar: isGroup && !mine ? avatarOf(message) : null,
      showSenderName: isGroup && !mine && startOfRun,
      showAvatar: isGroup && !mine && endOfRun,
      reserveAvatarSpace: isGroup && !mine,
      image: buildMessageImage(message) ?? buildAttachment(message, mine),
      header: reply is Map
          ? ChatReplyPreview(
              reply: Map<String, dynamic>.from(reply),
              onTap: reply['available'] == true && reply['id'] is num
                  ? () => jumpToMessage((reply['id'] as num).toInt())
                  : null,
            )
          : null,
      below: reactions.isEmpty
          ? null
          : ChatReactionsRow(
              reactions: reactions,
              mine: mine,
              onTap: canReactTo(message)
                  ? (emoji) => toggleReaction(message, emoji)
                  : null,
            ),
      footer: endOfRun || state != null ? footer : null,
      footerColor: failed ? AppColors.danger : null,
      endOfRun: endOfRun,
      dim: state != null,
      highlight: id != null && id == highlightId,
      onTap: failed ? () => openFailedActions(message) : null,
      onLongPress: state == 'sending' ? null : () => openMessageMenu(message),
    );

    return KeyedSubtree(
      key: id != null ? keyFor(id) : ValueKey('out-${message['client_id']}'),
      child: SwipeToReply(
        onReply: canReplyTo(message) ? () => startReply(message) : null,
        child: bubble,
      ),
    );
  }

  Widget buildMessageList({required Widget empty}) {
    if (isLoading) return const Center(child: CircularProgressIndicator());

    final String? error = loadError;

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    isLoading = true;
                    loadError = null;
                  });
                  load();
                },
                child: const Text('ลองอีกครั้ง'),
              ),
            ],
          ),
        ),
      );
    }

    if (messages.isEmpty && outbox.isEmpty) return empty;

    final List<Map<String, dynamic>> shown = [...messages, ...outbox];
    final int? dividerId = firstUnreadId();
    final List<Widget> rows = [];

    bool breaksBefore(
      Map<String, dynamic>? previous,
      Map<String, dynamic> current,
    ) {
      if (previous == null) return true;

      final DateTime? time = ChatFormat.timeOf(current);

      return (time != null &&
              !ChatFormat.sameDay(ChatFormat.timeOf(previous), time)) ||
          (dividerId != null && idOf(current) == dividerId) ||
          !ChatFormat.sameRun(previous, current, runKeyOf);
    }

    for (int i = 0; i < shown.length; i++) {
      final Map<String, dynamic> message = shown[i];
      final Map<String, dynamic>? previous = i > 0 ? shown[i - 1] : null;
      final Map<String, dynamic>? next = i + 1 < shown.length
          ? shown[i + 1]
          : null;
      final DateTime? time = ChatFormat.timeOf(message);

      if (time != null &&
          (previous == null ||
              !ChatFormat.sameDay(ChatFormat.timeOf(previous), time))) {
        rows.add(ChatDayDivider(day: time));
      }

      if (dividerId != null && idOf(message) == dividerId) {
        rows.add(const ChatUnreadDivider());
      }

      rows.add(
        buildMessageRow(
          message,
          startOfRun: breaksBefore(previous, message),
          endOfRun: next == null || breaksBefore(message, next),
        ),
      );
    }

    final int newCount = pendingNew.where((m) => m['is_mine'] != true).length;

    return Stack(
      children: [
        ListView(
          controller: scrollController,
          reverse: true,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            ...rows.reversed,
            if (isLoadingOlder)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (olderFailed)
              Center(
                child: TextButton.icon(
                  onPressed: () {
                    setState(() => olderFailed = false);
                    loadOlder();
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('โหลดข้อความเก่าไม่สำเร็จ · ลองอีกครั้ง'),
                ),
              ),
          ],
        ),
        if (pendingNew.isNotEmpty)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: ChatNewMessagesButton(count: newCount, onTap: goToNewest),
            ),
          )
        else if (showJumpDown)
          Positioned(
            bottom: 12,
            right: 12,
            child: IconButton.filledTonal(
              tooltip: 'ไปข้อความล่าสุด',
              onPressed: goToNewest,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
          ),
      ],
    );
  }

  Widget buildComposer({required String hint, Widget? disabled}) {
    if (isLoading || loadError != null || !roomReady) {
      return const SizedBox.shrink();
    }

    if (!canCompose) return disabled ?? const SizedBox.shrink();

    final ChatVoiceRecorder? voice = recorder;

    // กำลังอัด / ฟังก่อนส่ง → แถบอัดเสียงแทนช่องพิมพ์ (ข้อความที่พิมพ์ไว้ยังอยู่)
    if (voice != null && voice.active) {
      return ChatVoiceRecorderBar(recorder: voice, onSend: sendVoice);
    }

    final Map<String, dynamic>? reply = replyingTo;

    final Widget composer = ChatComposer(
      controller: inputController,
      focusNode: inputFocus,
      image: pickedImage,
      canSend: hasDraft,
      hint: hint,
      onAttach: openAttachMenu,
      onMic: startVoice,
      onEmoji: toggleEmoji,
      emojiOpen: emojiOpen,
      onRemoveImage: () => setState(() => pickedImage = null),
      onSend: send,
      top: reply == null
          ? null
          : ChatReplyBar(
              name: reply['is_mine'] == true
                  ? 'ข้อความของคุณ'
                  : senderNameOf(reply),
              preview: previewText(reply),
              onCancel: () => setState(() => replyingTo = null),
            ),
    );

    if (!emojiOpen) return composer;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        composer,
        ChatEmojiPanel(onPick: insertIntoComposer),
      ],
    );
  }
}
