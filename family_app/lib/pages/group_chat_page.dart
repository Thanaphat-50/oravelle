import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_helper.dart';
import '../services/chat_service.dart';
import '../services/group_chat_service.dart';
import '../theme/app_theme.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/user_avatar.dart';

// =======================================================
// ห้องแชทกลุ่มครอบครัว
// - เห็นเฉพาะข้อความหลังเข้ากลุ่มรอบนี้ (เซิร์ฟเวอร์กรอง) / หมดสิทธิ์ → ล้างข้อความและรูปที่แสดง
// - ส่งทีละข้อความตามลำดับ (client_id เดิมเมื่อส่งซ้ำ → ไม่ซ้ำ) / ช่องพิมพ์ล้างทันทีที่กดส่ง
// - ดึงข้อความใหม่ทุก 4 วินาทีเฉพาะตอนหน้านี้อยู่ด้านหน้าและแอปเปิดอยู่ (ไม่ยิงซ้อน)
// - อ่านอยู่ด้านบน → ไม่เลื่อนลงเอง แสดงปุ่ม "ข้อความใหม่" / อยู่ล่างสุด → นับว่าอ่านแล้ว
// - ปิดเสียงห้อง = ไม่ส่ง Push ของห้องนี้ (ยังรับข้อความและนับยังไม่อ่าน)
// =======================================================

class GroupChatPage extends StatefulWidget {
  // null = ห้องของกลุ่มที่อยู่ตอนนี้ (เปิดจากหน้ากลุ่ม)
  final int? chatId;

  const GroupChatPage({super.key, this.chatId});

  static const Duration pollInterval = Duration(seconds: 4);

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage>
    with WidgetsBindingObserver {
  final TextEditingController inputController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final ImagePicker imagePicker = ImagePicker();
  final Random random = Random();

  int? chatId;
  Map<String, dynamic>? room;

  // เรียงเก่า → ใหม่
  List<Map<String, dynamic>> messages = [];

  // กดส่งแล้วแต่ยังไม่ถึงเซิร์ฟเวอร์ {client_id, body, image, state: sending|failed, error}
  final List<Map<String, dynamic>> outbox = [];

  bool isLoading = true;
  String? loadError;

  // หมดสิทธิ์ / ห้องถูกลบ → ข้อความแจ้งแทนห้อง
  String? lostAccess;

  bool hasMore = false;
  bool isLoadingOlder = false;
  bool olderFailed = false;

  bool isPolling = false;
  bool isFlushing = false;
  bool appActive = true;
  Timer? pollTimer;

  // ข้อความใหม่จากคนอื่นที่มาตอนผู้ใช้เลื่อนอ่านข้างบน
  int newBelow = 0;

  int lastReportedRead = 0;

  XFile? pickedImage;

  @override
  void initState() {
    super.initState();
    chatId = widget.chatId;
    GroupChatService.activeChatId = chatId;
    WidgetsBinding.instance.addObserver(this);
    scrollController.addListener(onScroll);
    inputController.addListener(() => setState(() {}));
    load();
    pollTimer = Timer.periodic(GroupChatPage.pollInterval, (_) => poll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appActive = state == AppLifecycleState.resumed;

    if (appActive) poll();
  }

  @override
  void dispose() {
    if (GroupChatService.activeChatId == chatId) {
      GroupChatService.activeChatId = null;
    }

    WidgetsBinding.instance.removeObserver(this);
    pollTimer?.cancel();
    inputController.dispose();
    scrollController.dispose();
    ChatService.refreshUnreadCount();
    super.dispose();
  }

  // =====================================================
  // ข้อมูล
  // =====================================================

  int? idOf(Map<String, dynamic> message) {
    final dynamic value = message['id'];

    return value is num ? value.toInt() : null;
  }

  List<Map<String, dynamic>> parse(dynamic raw) {
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  String get roomName => room?['name']?.toString() ?? 'แชทกลุ่ม';

  bool get muted => room?['muted'] == true;

  // หมดสิทธิ์ (403 not_member / 404 ห้องถูกลบ) → ล้างข้อความและรูปที่แอปแสดงไว้
  bool handleLost(Map<String, dynamic> result) {
    final dynamic code = result['code'];

    if (code != 'not_member' && code != 'room_gone') return false;

    for (final message in messages) {
      final String? url = message['image_url']?.toString();

      if (url != null && url.isNotEmpty) NetworkImage(url).evict();
    }

    pollTimer?.cancel();

    setState(() {
      lostAccess =
          result['message']?.toString() ?? 'คุณไม่ได้อยู่ในกลุ่มนี้แล้ว';
      messages = [];
      outbox.clear();
      room = null;
      isLoading = false;
    });

    ChatService.refreshUnreadCount();

    return true;
  }

  Future<void> load() async {
    try {
      if (chatId == null) {
        final opened = await GroupChatService.open();

        if (!mounted) return;

        if (handleLost(opened)) return;

        final dynamic openedRoom = opened['room'];

        if (opened['status'] != true || openedRoom is! Map) {
          setState(
            () => loadError =
                opened['message']?.toString() ?? 'เปิดแชทกลุ่มไม่สำเร็จ',
          );
          return;
        }

        chatId = (openedRoom['id'] as num).toInt();
        GroupChatService.activeChatId = chatId;
      }

      final result = await GroupChatService.messages(chatId!);

      if (!mounted || handleLost(result)) return;

      if (result['status'] == true) {
        setState(() {
          messages = parse(result['messages']);
          hasMore = result['has_more'] == true;
          room = Map<String, dynamic>.from(result['room'] as Map);
          loadError = null;
        });

        markReadIfAtBottom();
      } else {
        setState(
          () => loadError =
              result['message']?.toString() ?? 'เปิดแชทกลุ่มไม่สำเร็จ',
        );
      }
    } catch (e) {
      if (mounted) setState(() => loadError = ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ข้อความใหม่หลังข้อความล่าสุดที่มี (เฉพาะตอนหน้านี้อยู่ด้านหน้า / ไม่ยิงซ้อน)
  Future<void> poll() async {
    final int? id = chatId;

    if (id == null ||
        isLoading ||
        isPolling ||
        loadError != null ||
        lostAccess != null ||
        !appActive ||
        !mounted ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }

    isPolling = true;

    try {
      final int lastId = messages.isEmpty ? 0 : (idOf(messages.last) ?? 0);

      final result = await GroupChatService.messages(id, afterId: lastId);

      if (!mounted || handleLost(result) || result['status'] != true) return;

      final List<Map<String, dynamic>> incoming = parse(result['messages']);
      final Set<int?> known = messages.map(idOf).toSet();
      final List<Map<String, dynamic>> fresh = incoming
          .where((m) => !known.contains(idOf(m)))
          .toList();

      final bool atBottom = isAtBottom;

      setState(() {
        messages.addAll(fresh);
        removeDelivered(fresh);
        room = Map<String, dynamic>.from(result['room'] as Map);

        if (!atBottom) {
          newBelow += fresh.where((m) => m['is_mine'] != true).length;
        }
      });

      if (atBottom) markReadIfAtBottom();
    } catch (_) {
      // เน็ตหลุดชั่วคราว → รอบหน้าลองใหม่
    } finally {
      isPolling = false;
    }
  }

  bool get isAtBottom =>
      !scrollController.hasClients || scrollController.offset < 80;

  // แสดงข้อความล่าสุดอยู่ → บอกเซิร์ฟเวอร์ว่าอ่านแล้ว (ดูรายการห้องเฉย ๆ ไม่นับ)
  void markReadIfAtBottom() {
    final int? id = chatId;
    final int? latest = messages.isEmpty ? null : idOf(messages.last);

    if (id == null || latest == null || latest <= lastReportedRead) return;
    if (!isAtBottom) return;

    lastReportedRead = latest;

    GroupChatService.read(
      id,
      latest,
    ).then((_) => ChatService.refreshUnreadCount()).catchError((_) {
      lastReportedRead = 0;
    });
  }

  void onScroll() {
    if (!scrollController.hasClients) return;

    // กลับลงมาล่างสุด (เลื่อนเอง / กดปุ่มข้อความใหม่) → อ่านถึงข้อความล่าสุด
    if (isAtBottom) {
      if (newBelow > 0) setState(() => newBelow = 0);

      markReadIfAtBottom();
    }

    final position = scrollController.position;

    if (hasMore &&
        !isLoadingOlder &&
        !olderFailed &&
        position.pixels >= position.maxScrollExtent - 300) {
      loadOlder();
    }
  }

  // โหลดข้อความเก่า (ไม่สำเร็จ → ข้อความเดิมยังอยู่ + ปุ่มลองใหม่)
  Future<void> loadOlder() async {
    final int? id = chatId;
    final int? firstId = messages.isEmpty ? null : idOf(messages.first);

    if (id == null || firstId == null || isLoadingOlder) return;

    setState(() {
      isLoadingOlder = true;
      olderFailed = false;
    });

    try {
      final result = await GroupChatService.messages(id, beforeId: firstId);

      if (!mounted || handleLost(result)) return;

      if (result['status'] != true) {
        setState(() => olderFailed = true);
        return;
      }

      final Set<int?> known = messages.map(idOf).toSet();

      setState(() {
        messages.insertAll(
          0,
          parse(result['messages']).where((m) => !known.contains(idOf(m))),
        );
        hasMore = result['has_more'] == true;
      });
    } catch (_) {
      if (mounted) setState(() => olderFailed = true);
    } finally {
      if (mounted) setState(() => isLoadingOlder = false);
    }
  }

  void scrollToNewest() {
    if (!scrollController.hasClients) return;

    scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  // =====================================================
  // ส่ง
  // =====================================================

  bool get hasDraft =>
      inputController.text.trim().isNotEmpty || pickedImage != null;

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

  // ย้ายข้อความเข้าคิวแล้วล้างช่องพิมพ์ทันที (พิมพ์ข้อความถัดไประหว่างรอได้ ไม่หาย)
  void send() {
    if (!hasDraft || chatId == null || lostAccess != null) return;

    setState(() {
      outbox.add({
        'client_id':
            '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 30)}',
        'body': inputController.text.trim(),
        'image': pickedImage,
        'state': 'sending',
        'error': null,
        'is_mine': true,
        'created_at': DateTime.now().toIso8601String(),
      });

      inputController.clear();
      pickedImage = null;
      newBelow = 0;
    });

    scrollToNewest();
    flushOutbox();
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
    final String body = entry['body']?.toString() ?? '';
    final XFile? image = entry['image'] as XFile?;
    String? error;

    try {
      final result = await GroupChatService.send(
        chatId!,
        body: body.isEmpty ? null : body,
        imagePath: image?.path,
        clientId: entry['client_id'] as String,
      );

      if (!mounted) return;

      if (handleLost(result)) return;

      final dynamic sent = result['message'];

      if (result['status'] == true && sent is Map) {
        final Map<String, dynamic> message = Map<String, dynamic>.from(sent);

        setState(() {
          outbox.remove(entry);

          // ผลส่งกลับมาชนกับข้อความจากการดึงข้อความใหม่ → ไม่แสดงซ้ำ
          if (!messages.map(idOf).contains(idOf(message))) {
            messages.add(message);
          }
        });

        markReadIfAtBottom();
        return;
      }

      error = result['message']?.toString() ?? 'ส่งข้อความไม่สำเร็จ';
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

  Future<void> retryOrDiscard(Map<String, dynamic> entry) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
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
    );

    if (!mounted || action == null || !outbox.contains(entry)) return;

    if (action == 'retry') {
      setState(() {
        entry['state'] = 'sending';
        entry['error'] = null;
      });

      flushOutbox();
    } else {
      setState(() => outbox.remove(entry));
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

  // ลิงก์รูปหมดอายุ (เปิดห้องค้างไว้นาน) → ขอลิงก์ใหม่ของข้อความนี้
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

  void showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> confirmLeave() async {
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ยังส่งข้อความไม่เสร็จ'),
        content: const Text('ถ้าออกตอนนี้ ข้อความที่ยังไม่ได้ส่งจะหายไป'),
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

  // =====================================================
  // UI
  // =====================================================

  static String two(int value) => value.toString().padLeft(2, '0');

  DateTime? timeOf(Map<String, dynamic> message) =>
      DateTime.tryParse(message['created_at']?.toString() ?? '')?.toLocal();

  Widget buildBubble(Map<String, dynamic> message, {required bool showSender}) {
    final bool mine = message['is_mine'] == true;
    final String body = message['body']?.toString() ?? '';
    final String? imageUrl = message['image_url']?.toString();
    final String? state = message['state']?.toString();
    final bool failed = state == 'failed';
    final XFile? localImage = message['image'] as XFile?;
    final DateTime? time = timeOf(message);
    final dynamic sender = message['sender'];
    final Map<String, dynamic> senderData = sender is Map
        ? Map<String, dynamic>.from(sender)
        : {};

    final Widget content = Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (!mine && showSender)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 3),
            child: Text(
              senderData['name']?.toString() ?? 'สมาชิก',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        if (localImage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.file(
                File(localImage.path),
                width: 220,
                height: 230,
                fit: BoxFit.cover,
              ),
            ),
          ),
        if (imageUrl != null && imageUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: GestureDetector(
              onTap: () => showPhotoViewer(context, urls: [imageUrl]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.network(
                  imageUrl,
                  width: 220,
                  height: 230,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => InkWell(
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
                  ),
                ),
              ),
            ),
          ),
        if (body.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
            decoration: BoxDecoration(
              color: mine ? AppColors.primary : AppColors.surface,
              border: mine ? null : AppDecorations.cardBorder,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(mine ? 18 : 6),
                bottomRight: Radius.circular(mine ? 6 : 18),
              ),
            ),
            child: Text(
              body,
              style: TextStyle(
                color: mine ? Colors.white : AppColors.navy,
                fontSize: 15,
                height: 1.4,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 3, 4, 0),
          child: Text(
            state == null
                ? (time == null
                      ? ''
                      : '${time.day}/${time.month} ${two(time.hour)}:${two(time.minute)}')
                : failed
                ? 'ส่งไม่สำเร็จ · แตะเพื่อส่งอีกครั้ง'
                : 'กำลังส่ง…',
            style: TextStyle(
              color: failed ? AppColors.danger : AppColors.muted,
              fontSize: 11,
              fontWeight: failed ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 18),
              child: showSender
                  ? UserAvatar(
                      user: {
                        'name': senderData['name'],
                        'profile_photo_url': senderData['profile_image_url'],
                      },
                      radius: 15,
                    )
                  : const SizedBox(width: 30),
            ),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              child: GestureDetector(
                onTap: failed ? () => retryOrDiscard(message) : null,
                child: Opacity(
                  opacity: state == null ? 1 : 0.72,
                  child: content,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> buildItems() {
    final List<Widget> items = [];
    final List<Map<String, dynamic>> all = [...messages, ...outbox];

    for (int i = 0; i < all.length; i++) {
      final dynamic previousSender = i == 0 ? null : all[i - 1]['sender'];
      final dynamic sender = all[i]['sender'];

      // ชื่อผู้ส่งเฉพาะข้อความแรกของช่วงที่คนเดียวกันส่งติดกัน
      final bool showSender =
          i == 0 ||
          previousSender is! Map ||
          sender is! Map ||
          previousSender['id'] != sender['id'];

      items.add(buildBubble(all[i], showSender: showSender));
    }

    return items.reversed.toList();
  }

  Widget buildBody() {
    final String? lost = lostAccess;

    if (lost != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 44,
                color: AppColors.muted,
              ),
              const SizedBox(height: 12),
              Text(
                lost,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.navy, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    if (isLoading) return const Center(child: CircularProgressIndicator());

    if (loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(loadError!, textAlign: TextAlign.center),
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

    if (messages.isEmpty && outbox.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'ยังไม่มีข้อความในกลุ่ม ทักทายสมาชิกได้เลย\n'
            'สมาชิกที่เข้ากลุ่มทีหลังจะเห็นเฉพาะข้อความหลังเข้ากลุ่ม',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        ListView(
          controller: scrollController,
          reverse: true,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          children: [
            ...buildItems(),
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
        if (newBelow > 0)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: FilledButton.icon(
                onPressed: () {
                  setState(() => newBelow = 0);
                  scrollToNewest();
                  markReadIfAtBottom();
                },
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                label: Text('ข้อความใหม่ $newBelow'),
              ),
            ),
          ),
      ],
    );
  }

  Widget buildInput() {
    if (lostAccess != null || isLoading || loadError != null) {
      return const SizedBox.shrink();
    }

    final XFile? image = pickedImage;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(26),
            border: AppDecorations.cardBorder,
            boxShadow: AppDecorations.cardShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (image != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          File(image.path),
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                        ),
                      ),
                      IconButton(
                        tooltip: 'เอารูปออก',
                        onPressed: () => setState(() => pickedImage = null),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'ส่งรูป',
                    onPressed: pickImage,
                    icon: Icon(Icons.photo_outlined, color: AppColors.primary),
                  ),
                  Expanded(
                    child: TextField(
                      controller: inputController,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                        hintText: 'พิมพ์ข้อความถึงกลุ่ม...',
                        counterText: '',
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'ส่ง',
                    onPressed: hasDraft ? send : null,
                    icon: Icon(
                      Icons.send_rounded,
                      color: hasDraft ? AppColors.primary : AppColors.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dynamic count = room?['members_count'];

    return PopScope(
      canPop: outbox.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Column(
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
                count is num ? 'แชทกลุ่ม · สมาชิก $count คน' : 'แชทกลุ่ม',
                style: TextStyle(color: AppColors.muted, fontSize: 11.5),
              ),
            ],
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
          ],
        ),
        body: Column(
          children: [
            Expanded(child: buildBody()),
            buildInput(),
          ],
        ),
      ),
    );
  }
}
