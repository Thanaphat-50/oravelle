import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_helper.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_room_logic.dart';

// =======================================================
// ห้องแชทกลุ่มครอบครัว
// - เห็นเฉพาะข้อความหลังเข้ากลุ่มรอบนี้ (เซิร์ฟเวอร์กรอง รวมถึงข้อความอ้างอิงของ Reply)
// - หมดสิทธิ์ / ห้องถูกลบ → ล้างข้อความและรูปที่แสดง
// - ข้อความของเรา: กำลังส่ง… / ส่งไม่สำเร็จ / ส่งแล้ว / อ่านแล้ว X คน
//   (นับเฉพาะสมาชิกรอบปัจจุบันที่เห็นข้อความนั้นได้ ไม่นับผู้ส่ง ไม่แสดงรายชื่อผู้อ่าน)
// - ปิดเสียงห้อง = ไม่ส่ง Push ของห้องนี้ (ยังรับข้อความและนับยังไม่อ่าน)
// ตรรกะส่ง/ตอบกลับ/Reaction/อ่านแล้ว อยู่ใน widgets/chat_room_logic.dart
// =======================================================

class GroupChatPage extends StatefulWidget {
  // null = ห้องของกลุ่มที่อยู่ตอนนี้ (เปิดจากหน้ากลุ่ม)
  final int? chatId;

  const GroupChatPage({super.key, this.chatId});

  static const Duration pollInterval = ChatRoomLogic.pollInterval;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage>
    with WidgetsBindingObserver, ChatRoomLogic<GroupChatPage> {
  int? chatId;
  Map<String, dynamic>? room;

  // หมดสิทธิ์ / ห้องถูกลบ → ข้อความแจ้งแทนห้อง
  String? lostAccess;

  @override
  void initState() {
    super.initState();
    chatId = widget.chatId;
    GroupChatService.activeChatId = chatId;
    startRoom();
  }

  @override
  void dispose() {
    if (GroupChatService.activeChatId == chatId) {
      GroupChatService.activeChatId = null;
    }

    disposeRoom();
    ChatService.refreshUnreadCount();
    super.dispose();
  }

  // =====================================================
  // ข้อมูลของห้องนี้
  // =====================================================

  String get roomName => room?['name']?.toString() ?? 'แชทกลุ่ม';

  bool get muted => room?['muted'] == true;

  @override
  String? get draftKey => chatId == null ? null : 'group:$chatId';

  @override
  bool get roomReady => chatId != null && lostAccess == null;

  @override
  bool get canCompose => lostAccess == null;

  @override
  bool get canReact => lostAccess == null;

  @override
  bool get isGroup => true;

  @override
  bool get canRefreshImages => true;

  @override
  String get loadFailedText => 'เปิดแชทกลุ่มไม่สำเร็จ';

  @override
  Future<Map<String, dynamic>> fetchLatest() async {
    if (chatId == null) {
      final Map<String, dynamic> opened = await GroupChatService.open();
      final dynamic openedRoom = opened['room'];

      if (opened['status'] != true || openedRoom is! Map) return opened;

      chatId = (openedRoom['id'] as num).toInt();
      GroupChatService.activeChatId = chatId;
      if (mounted) restoreDraftIfEmpty();
    }

    return GroupChatService.messages(chatId!);
  }

  @override
  Future<Map<String, dynamic>> fetchAfter(int afterId, int? statesFrom) =>
      GroupChatService.messages(
        chatId!,
        afterId: afterId,
        statesFrom: statesFrom,
      );

  @override
  Future<Map<String, dynamic>> fetchBefore(int beforeId) =>
      GroupChatService.messages(chatId!, beforeId: beforeId);

  @override
  Future<Map<String, dynamic>> sendToServer(Map<String, dynamic> entry) {
    final String body = entry['body']?.toString() ?? '';

    return GroupChatService.send(
      chatId!,
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
      GroupChatService.message(chatId!, messageId);

  @override
  Future<Map<String, dynamic>> reactOnServer(int messageId, String? emoji) =>
      GroupChatService.react(chatId!, messageId, emoji);

  @override
  Future<void> markReadOnServer(int messageId) async {
    final Map<String, dynamic> result = await GroupChatService.read(
      chatId!,
      messageId,
    );

    if (result['status'] != true) throw StateError('read not saved');

    ChatService.refreshUnreadCount();
  }

  @override
  void applyMeta(Map<String, dynamic> result) {
    final dynamic value = result['room'];

    if (value is Map) room = Map<String, dynamic>.from(value);
  }

  @override
  int? readIdOnOpen() {
    final dynamic value = room?['last_read_id'];

    return value is num ? value.toInt() : null;
  }

  @override
  Object? senderOf(Map<String, dynamic> message) {
    if (message['is_mine'] == true) return 'me';

    final dynamic sender = message['sender'];

    return sender is Map ? sender['id'] : null;
  }

  @override
  String senderNameOf(Map<String, dynamic> message) {
    if (message['is_mine'] == true) return 'คุณ';

    final dynamic sender = message['sender'];

    return (sender is Map ? sender['name']?.toString() : null) ?? 'สมาชิก';
  }

  @override
  Map<String, dynamic>? avatarOf(Map<String, dynamic> message) {
    final dynamic sender = message['sender'];

    if (sender is! Map) return null;

    return {
      'name': sender['name'],
      'profile_photo_url': sender['profile_image_url'],
    };
  }

  @override
  String readStatusOf(Map<String, dynamic> message) {
    final dynamic count = message['read_count'];

    return count is num && count > 0
        ? 'อ่านแล้ว ${count.toInt()} คน'
        : 'ส่งแล้ว';
  }

  // หมดสิทธิ์ (403 not_member / 404 ห้องถูกลบ) → ล้างข้อความและรูปที่แอปแสดงไว้
  @override
  bool handleLost(Map<String, dynamic> result) {
    final dynamic code = result['code'];

    if (code != 'not_member' && code != 'room_gone') return false;

    for (final message in [...messages, ...pendingNew]) {
      final String? url = message['image_url']?.toString();

      if (url != null && url.isNotEmpty) NetworkImage(url).evict();
    }

    pollTimer?.cancel();
    clearCachedMedia();

    setState(() {
      lostAccess =
          result['message']?.toString() ?? 'คุณไม่ได้อยู่ในกลุ่มนี้แล้ว';
      messages = [];
      pendingNew.clear();
      outbox.clear();
      replyingTo = null;
      room = null;
      isLoading = false;
    });

    ChatService.refreshUnreadCount();

    return true;
  }

  // ลิงก์รูปหมดอายุ (เปิดห้องค้างไว้นาน) → ขอลิงก์ใหม่ของข้อความนี้
  @override
  Future<void> refreshImage(Map<String, dynamic> message) async {
    final int? id = idOf(message);

    if (chatId == null || id == null) return;

    try {
      final result = await GroupChatService.message(chatId!, id);

      if (!mounted || handleLost(result)) return;

      final dynamic fresh = result['message'];

      if (result['status'] == true && fresh is Map) {
        setState(() => message['image_url'] = fresh['image_url']);
      }
    } catch (_) {
      if (mounted) showMessage('โหลดรูปไม่สำเร็จ');
    }
  }

  Future<void> toggleMute() async {
    final int? id = chatId;

    if (id == null) return;

    try {
      final result = await GroupChatService.mute(id, !muted);

      if (!mounted || handleLost(result)) return;

      if (result['status'] == true) {
        setState(() => room = {...?room, 'muted': result['muted'] == true});
      }

      showMessage(result['message']?.toString() ?? 'บันทึกแล้ว');
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));
    }
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildLost(String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded, size: 44, color: AppColors.muted),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.navy, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildEmpty() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: AppColors.primary.withValues(alpha: 0.12),
              child: Icon(
                Icons.groups_rounded,
                size: 34,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'ยังไม่มีข้อความในกลุ่ม ทักทายสมาชิกได้เลย\n'
              'สมาชิกที่เข้ากลุ่มทีหลังจะเห็นเฉพาะข้อความหลังเข้ากลุ่ม',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 13.5,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dynamic count = room?['members_count'];
    final String? lost = lostAccess;
    final String subtitle = count is num
        ? 'แชทกลุ่ม · สมาชิก $count คน'
        : 'แชทกลุ่ม';

    return leaveGuard(
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Semantics(
            header: true,
            label: '$roomName, $subtitle',
            excludeSemantics: true,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 19,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                  child: Icon(
                    Icons.groups_rounded,
                    size: 22,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        roomName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 16.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (room != null)
              IconButton(
                tooltip: muted
                    ? 'เปิดเสียงแจ้งเตือนห้องนี้'
                    : 'ปิดเสียงแจ้งเตือนห้องนี้',
                onPressed: toggleMute,
                icon: Icon(
                  muted
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_active_outlined,
                ),
              ),
            if (room != null)
              PopupMenuButton<String>(
                tooltip: 'ตัวเลือกห้อง',
                onSelected: (_) => openBackgroundSettings(),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'background',
                    child: ListTile(
                      leading: Icon(Icons.wallpaper_rounded),
                      title: Text('พื้นหลังแชท'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: lost != null
                  ? buildLost(lost)
                  : buildMessageList(empty: buildEmpty()),
            ),
            buildComposer(hint: 'พิมพ์ข้อความถึงกลุ่ม...'),
          ],
        ),
      ),
    );
  }
}
