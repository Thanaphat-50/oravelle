import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_helper.dart';
import '../services/chat_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_room_logic.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/user_avatar.dart';
import 'user_profile_page.dart';

// =======================================================
// ห้องแชทส่วนตัว (คนในกลุ่มเดียวกัน) และแชทลูกค้า-ร้านค้า
// - ข้อความเรา (ขวา) / ของอีกฝ่าย (ซ้าย) ส่งข้อความหรือรูปได้
// - ข้อความของเรา: กำลังส่ง… / ส่งไม่สำเร็จ / ส่งแล้ว / อ่านแล้ว (ตามตำแหน่งอ่านจริงของอีกฝ่าย)
// - กดค้าง: Reaction / ตอบกลับ / คัดลอก / ยกเลิกการส่ง (ข้อความของเรา)
// - ลูกค้าเห็นห้องร้านเป็นชื่อ/โลโก้ร้าน (เซิร์ฟเวอร์ส่งมา) ไม่แสดงสถานะออนไลน์
// ตรรกะส่ง/ตอบกลับ/Reaction/อ่านแล้ว อยู่ใน widgets/chat_room_logic.dart
// =======================================================

class ChatRoomPage extends StatefulWidget {
  final int conversationId;

  // ข้อมูลคู่สนทนาที่รู้อยู่แล้ว (แสดงระหว่างโหลด)
  final Map<String, dynamic>? user;

  // ข้อความที่พิมพ์ไว้ให้ก่อน (เช่น ทักร้านจากหน้าสินค้า)
  final String? draft;

  const ChatRoomPage({
    super.key,
    required this.conversationId,
    this.user,
    this.draft,
  });

  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage>
    with WidgetsBindingObserver, ChatRoomLogic<ChatRoomPage> {
  Map<String, dynamic>? conversation;

  @override
  void initState() {
    super.initState();
    ChatService.activeConversationId = widget.conversationId;
    startRoom();
  }

  @override
  void dispose() {
    if (ChatService.activeConversationId == widget.conversationId) {
      ChatService.activeConversationId = null;
    }

    disposeRoom();
    ChatService.refreshUnreadCount();
    super.dispose();
  }

  // =====================================================
  // ข้อมูลของห้องนี้
  // =====================================================

  Map<String, dynamic> get otherUser {
    final dynamic value = conversation?['user'];

    if (value is Map) return Map<String, dynamic>.from(value);

    return widget.user ?? {'name': 'แชท'};
  }

  String get otherName => otherUser['name']?.toString() ?? 'แชท';

  // UserAvatar อ่านรูปจาก profile_photo_url
  Map<String, dynamic> get otherAvatar => {
    ...otherUser,
    'profile_photo_url': otherUser['profile_image_url'],
  };

  bool get isShopRoom => conversation?['shop'] is Map;

  // ห้องแชทลูกค้า-ร้าน / คนในกลุ่ม (ไม่มีสถานะออนไลน์)
  String get roomSubtitle {
    final dynamic shop = conversation?['shop'];

    if (shop is Map) {
      return shop['is_mine'] == true
          ? 'ลูกค้าของร้าน ${shop['name'] ?? ''}'
          : 'ร้านค้า · แชทกับร้าน';
    }

    return canCompose ? 'สมาชิกในกลุ่ม · แชทส่วนตัว' : 'แชทส่วนตัว';
  }

  int get otherReadId {
    final dynamic value = conversation?['other_read_id'];

    return value is num ? value.toInt() : 0;
  }

  @override
  String? get draftKey => 'chat:${widget.conversationId}';

  // ข้อความที่หน้าก่อนเตรียมให้ (เช่น ทักร้านจากหน้าสินค้า) มาก่อนร่างเดิม
  @override
  String initialDraft() => widget.draft ?? super.initialDraft();

  @override
  bool get canCompose => conversation?['can_send'] != false;

  @override
  bool get canReact => canCompose;

  // mark_read=0: นับว่าอ่านเมื่อข้อความแสดงบนจอจริงเท่านั้น (POST /read)
  @override
  Future<Map<String, dynamic>> fetchLatest() =>
      ChatService.getMessages(widget.conversationId, markRead: false);

  @override
  Future<Map<String, dynamic>> fetchAfter(int afterId, int? statesFrom) =>
      ChatService.getMessages(
        widget.conversationId,
        afterId: afterId,
        markRead: false,
        statesFrom: statesFrom,
      );

  @override
  Future<Map<String, dynamic>> fetchBefore(int beforeId) =>
      ChatService.getMessages(
        widget.conversationId,
        beforeId: beforeId,
        markRead: false,
      );

  @override
  Future<Map<String, dynamic>> sendToServer(Map<String, dynamic> entry) {
    final String body = entry['body']?.toString() ?? '';

    return ChatService.sendMessage(
      widget.conversationId,
      body: body.isEmpty ? null : body,
      imagePath: (entry['image'] as XFile?)?.path,
      clientId: entry['client_id'] as String,
      replyToId: entry['reply_to_id'] as int?,
      filePath: (entry['file'] as Map?)?['path'] as String?,
      fileName: (entry['file'] as Map?)?['name'] as String?,
      voicePath: (entry['voice'] as Map?)?['path'] as String?,
      voiceDurationMs: (entry['voice'] as Map?)?['duration_ms'] as int?,
    );
  }

  @override
  Future<Map<String, dynamic>> fetchMessage(int messageId) =>
      ChatService.message(widget.conversationId, messageId);

  @override
  Future<Map<String, dynamic>> reactOnServer(int messageId, String? emoji) =>
      ChatService.react(widget.conversationId, messageId, emoji);

  @override
  Future<void> markReadOnServer(int messageId) async {
    final Map<String, dynamic> result = await ChatService.markRead(
      widget.conversationId,
      messageId,
    );

    if (result['status'] != true) throw StateError('read not saved');
  }

  @override
  void applyMeta(Map<String, dynamic> result) {
    final dynamic value = result['conversation'];

    if (value is Map) conversation = Map<String, dynamic>.from(value);
  }

  @override
  int? readIdOnOpen() {
    final dynamic value = conversation?['my_read_id'];

    return value is num ? value.toInt() : null;
  }

  @override
  Object? senderOf(Map<String, dynamic> message) =>
      message['is_mine'] == true ? 'me' : 'other';

  @override
  String senderNameOf(Map<String, dynamic> message) =>
      message['is_mine'] == true ? 'คุณ' : otherName;

  @override
  String readStatusOf(Map<String, dynamic> message) {
    final int? id = idOf(message);

    return id != null && id <= otherReadId ? 'อ่านแล้ว' : 'ส่งแล้ว';
  }

  @override
  List<ChatMenuAction> extraActionsFor(Map<String, dynamic> message) =>
      message['is_mine'] == true
      ? const [
          ChatMenuAction(
            'unsend',
            Icons.undo_rounded,
            'ยกเลิกการส่ง',
            danger: true,
            subtitle: 'ข้อความจะหายไปจากทั้งสองฝ่าย',
          ),
        ]
      : const [];

  @override
  Future<void> onExtraAction(
    String action,
    Map<String, dynamic> message,
  ) async {
    if (action == 'unsend') await unsend(message);
  }

  // ยกเลิกการส่ง (เฉพาะข้อความของเรา) → ข้อความที่อ้างถึงแสดง "ไม่พร้อมใช้งาน"
  Future<void> unsend(Map<String, dynamic> message) async {
    final int? id = idOf(message);

    if (id == null) return;

    try {
      final result = await ChatService.deleteMessage(widget.conversationId, id);

      if (!mounted) return;

      if (result['status'] != true) {
        showMessage(result['message']?.toString() ?? 'ยกเลิกไม่สำเร็จ');
        return;
      }

      setState(() {
        messages.removeWhere((m) => idOf(m) == id);

        if (idOf(replyingTo) == id) replyingTo = null;

        for (final other in messages) {
          final dynamic reply = other['reply_to'];

          if (reply is Map && reply['id'] is num && reply['id'] == id) {
            other['reply_to'] = {'available': false};
          }
        }
      });
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));
    }
  }

  void openProfile() {
    final dynamic id = otherUser['id'];

    if (id is! num) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfilePage(userId: id.toInt(), name: otherName),
      ),
    );
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildEmpty() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UserAvatar(user: otherAvatar, radius: 36),
            const SizedBox(height: 14),
            Text(
              'เริ่มคุยกับ $otherName ได้เลย 👋',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'ข้อความนี้เห็นกันแค่สองคน',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildCannotSend() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      color: AppColors.fill,
      child: SafeArea(
        top: false,
        child: Text(
          isShopRoom
              ? 'ส่งข้อความในห้องนี้ไม่ได้แล้ว'
              : 'ส่งข้อความไม่ได้ เพราะไม่ได้อยู่กลุ่มเดียวกันแล้ว',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return leaveGuard(
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Semantics(
            button: true,
            label: '$otherName, $roomSubtitle, เปิดโปรไฟล์',
            excludeSemantics: true,
            child: InkWell(
              onTap: openProfile,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Row(
                  children: [
                    UserAvatar(user: otherAvatar, radius: 19),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            otherName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.navy,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            roomSubtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: Column(
          children: [
            Expanded(child: buildMessageList(empty: buildEmpty())),
            buildComposer(hint: 'พิมพ์ข้อความ...', disabled: buildCannotSend()),
          ],
        ),
      ),
    );
  }
}
