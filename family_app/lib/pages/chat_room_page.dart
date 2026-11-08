import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_helper.dart';
import '../services/chat_service.dart';
import '../theme/app_theme.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/user_avatar.dart';
import 'user_profile_page.dart';

// =======================================================
// ห้องแชทส่วนตัว
// - ข้อความเรา (ขวา) / ของอีกฝ่าย (ซ้าย) ส่งข้อความหรือรูปได้
// - ดึงข้อความใหม่ทุก 4 วินาทีขณะเปิดห้อง (หยุดเมื่อแอปอยู่เบื้องหลัง)
// - กดค้าง: คัดลอก / ยกเลิกการส่ง (ข้อความของเรา)
// - กดส่ง: ข้อความย้ายไปคิวส่ง (outbox) ทันที ช่องพิมพ์ว่าง พิมพ์ข้อความถัดไปได้เลย
//   ส่งทีละข้อความตามลำดับ แสดง "กำลังส่ง…" / "ส่งไม่สำเร็จ" (แตะเพื่อส่งอีกครั้ง/แก้ไข/ลบ)
//   แต่ละข้อความมี client_id: ส่งใหม่ด้วยรหัสเดิม เซิร์ฟเวอร์ไม่สร้างซ้ำ
//   ข้อความที่ดึงมาใหม่ (polling) ที่มี client_id ตรงกัน → นับว่าส่งแล้ว ไม่แสดงซ้ำ
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
    with WidgetsBindingObserver {
  static const Duration pollInterval = Duration(seconds: 4);

  late final TextEditingController inputController = TextEditingController(
    text: widget.draft ?? '',
  );

  final ScrollController scrollController = ScrollController();

  final ImagePicker imagePicker = ImagePicker();

  // เรียงเก่า → ใหม่
  List<Map<String, dynamic>> messages = [];

  Map<String, dynamic>? conversation;

  bool isLoading = true;

  String? loadError;

  bool hasMore = false;

  bool isLoadingOlder = false;

  // ข้อความที่กดส่งแล้วแต่ยังไม่ได้รับจากเซิร์ฟเวอร์ (เรียงตามที่กดส่ง)
  // {client_id, body, image (XFile?), state: sending | failed, error, created_at}
  final List<Map<String, dynamic>> outbox = [];

  // กำลังส่งคิว (ส่งทีละข้อความ ลำดับไม่สลับ)
  bool isFlushing = false;

  final Random random = Random();

  bool isPolling = false;

  XFile? pickedImage;

  Timer? pollTimer;

  @override
  void initState() {
    super.initState();

    ChatService.activeConversationId = widget.conversationId;

    WidgetsBinding.instance.addObserver(this);

    scrollController.addListener(onScroll);

    inputController.addListener(() => setState(() {}));

    loadMessages();

    startPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      pollNewMessages();
      startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      pollTimer?.cancel();
    }
  }

  void startPolling() {
    pollTimer?.cancel();

    pollTimer = Timer.periodic(pollInterval, (_) => pollNewMessages());
  }

  // =====================================================
  // ข้อมูล
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

  bool get canSend => conversation?['can_send'] != false;

  // ห้องแชทลูกค้า-ร้าน / คนในกลุ่ม
  String get roomSubtitle {
    final dynamic shop = conversation?['shop'];

    if (shop is Map) {
      return shop['is_mine'] == true
          ? 'ลูกค้าของร้าน ${shop['name'] ?? ''}'
          : 'ร้านค้า · แชทกับร้าน';
    }

    return canSend ? 'สมาชิกในกลุ่ม · แชทส่วนตัว' : 'แชทส่วนตัว';
  }

  int get otherReadId {
    final dynamic value = conversation?['other_read_id'];

    return value is num ? value.toInt() : 0;
  }

  int? idOf(Map<String, dynamic> message) {
    final dynamic value = message['id'];

    return value is num ? value.toInt() : null;
  }

  List<Map<String, dynamic>> parseMessages(dynamic raw) {
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  void applyConversation(dynamic raw) {
    if (raw is Map) conversation = Map<String, dynamic>.from(raw);
  }

  Future<void> loadMessages() async {
    try {
      final result = await ChatService.getMessages(widget.conversationId);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          messages = parseMessages(result['messages']);
          hasMore = result['has_more'] == true;
          applyConversation(result['conversation']);
          loadError = null;
        });

        ChatService.refreshUnreadCount();
      } else {
        setState(() {
          loadError = result['message']?.toString() ?? 'เปิดห้องแชทไม่สำเร็จ';
        });
      }
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> pollNewMessages() async {
    if (isLoading || isPolling || loadError != null) return;

    isPolling = true;

    try {
      final int? lastId = messages.isEmpty ? null : idOf(messages.last);

      final result = await ChatService.getMessages(
        widget.conversationId,
        afterId: lastId ?? 0,
      );

      if (!mounted || result['status'] != true) return;

      final List<Map<String, dynamic>> incoming = parseMessages(
        result['messages'],
      );

      final Set<int?> known = messages.map(idOf).toSet();

      setState(() {
        messages.addAll(incoming.where((m) => !known.contains(idOf(m))));
        removeDelivered(incoming);
        applyConversation(result['conversation']);
      });

      if (incoming.isNotEmpty) ChatService.refreshUnreadCount();
    } catch (_) {
      // เน็ตหลุดชั่วคราว → รอบหน้าลองใหม่
    } finally {
      isPolling = false;
    }
  }

  // เลื่อนถึงข้อความเก่าสุด → โหลดเพิ่ม (รายการกลับหัว: บนสุด = maxScrollExtent)
  void onScroll() {
    if (!hasMore || isLoadingOlder || !scrollController.hasClients) return;

    final position = scrollController.position;

    if (position.pixels >= position.maxScrollExtent - 300) {
      loadOlder();
    }
  }

  Future<void> loadOlder() async {
    final int? firstId = messages.isEmpty ? null : idOf(messages.first);

    if (firstId == null) return;

    setState(() => isLoadingOlder = true);

    try {
      final result = await ChatService.getMessages(
        widget.conversationId,
        beforeId: firstId,
      );

      if (!mounted || result['status'] != true) return;

      setState(() {
        messages.insertAll(0, parseMessages(result['messages']));
        hasMore = result['has_more'] == true;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => isLoadingOlder = false);
    }
  }

  // =====================================================
  // ส่ง / ยกเลิก
  // =====================================================

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

  bool get hasDraft =>
      inputController.text.trim().isNotEmpty || pickedImage != null;

  // กดส่ง: ย้ายข้อความ/รูปเข้าคิว แล้วล้างช่องพิมพ์ทันที
  // (ข้อความที่พิมพ์ต่อระหว่างรอส่ง ไม่ถูกล้างตอนข้อความก่อนหน้าส่งเสร็จ)
  void send() {
    if (!hasDraft || !canSend) return;

    final String text = inputController.text.trim();

    setState(() {
      outbox.add({
        'client_id': newClientId(),
        'body': text,
        'image': pickedImage,
        'state': 'sending',
        'error': null,
        'created_at': DateTime.now().toIso8601String(),
        'is_mine': true,
      });

      inputController.clear();
      pickedImage = null;
    });

    scrollToNewest();

    flushOutbox();
  }

  String newClientId() {
    return '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 30)}';
  }

  // ส่งข้อความในคิวทีละข้อความตามลำดับ
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
      final result = await ChatService.sendMessage(
        widget.conversationId,
        body: body.isEmpty ? null : body,
        imagePath: image?.path,
        clientId: entry['client_id'] as String,
      );

      final dynamic sent = result['message'];

      if (result['status'] == true && sent is Map) {
        if (!mounted) return;

        final Map<String, dynamic> message = Map<String, dynamic>.from(sent);

        setState(() {
          outbox.remove(entry);

          if (!messages.map(idOf).contains(idOf(message))) {
            messages.add(message);
          }
        });

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

  // ข้อความจากเซิร์ฟเวอร์ที่ client_id ตรงกับคิว → ส่งถึงแล้ว เอาออกจากคิว
  void removeDelivered(List<Map<String, dynamic>> incoming) {
    final Set<String> delivered = incoming
        .map((m) => m['client_id']?.toString())
        .whereType<String>()
        .toSet();

    if (delivered.isNotEmpty) {
      outbox.removeWhere((m) => delivered.contains(m['client_id']));
    }
  }

  // ข้อความที่ส่งไม่สำเร็จ: ส่งอีกครั้ง / แก้ไข (กลับไปที่ช่องพิมพ์) / คัดลอก / ลบ
  Future<void> openFailedActions(Map<String, dynamic> entry) async {
    final String body = entry['body']?.toString() ?? '';

    // แก้ไขได้เมื่อช่องพิมพ์ว่าง (ไม่ทับข้อความที่กำลังพิมพ์อยู่)
    final bool canEdit = !hasDraft;

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

        setState(() {
          outbox.remove(entry);
          inputController.text = body;
          pickedImage = entry['image'] as XFile?;
        });
      case 'copy':
        await Clipboard.setData(ClipboardData(text: body));

        showMessage('คัดลอกแล้ว');
      case 'discard':
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

  void scrollToNewest() {
    if (!scrollController.hasClients) return;

    scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Future<void> openMessageActions(Map<String, dynamic> message) async {
    final bool mine = message['is_mine'] == true;

    final String body = message['body']?.toString() ?? '';

    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (body.isNotEmpty)
              ListTile(
                leading: Icon(Icons.copy_rounded, color: AppColors.navy),
                title: const Text('คัดลอกข้อความ'),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
            if (mine)
              ListTile(
                leading: Icon(Icons.undo_rounded, color: AppColors.danger),
                title: Text(
                  'ยกเลิกการส่ง',
                  style: TextStyle(color: AppColors.danger),
                ),
                subtitle: const Text('ข้อความจะหายไปจากทั้งสองฝ่าย'),
                onTap: () => Navigator.of(sheetContext).pop('unsend'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted || action == null) return;

    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: body));
      showMessage('คัดลอกแล้ว');
      return;
    }

    final int? id = idOf(message);

    if (id == null) return;

    try {
      final result = await ChatService.deleteMessage(widget.conversationId, id);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() => messages.removeWhere((m) => idOf(m) == id));
      } else {
        showMessage(result['message']?.toString() ?? 'ยกเลิกไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
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

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // เวลา
  // =====================================================

  DateTime? timeOf(Map<String, dynamic> message) {
    return DateTime.tryParse(message['created_at']?.toString() ?? '')
        ?.toLocal();
  }

  String formatTime(DateTime time) {
    final String hour = time.hour.toString().padLeft(2, '0');

    final String minute = time.minute.toString().padLeft(2, '0');

    return '$hour:$minute';
  }

  String formatDay(DateTime time) {
    const months = [
      '',
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.',
    ];

    final DateTime now = DateTime.now();

    final DateTime today = DateTime(now.year, now.month, now.day);

    final DateTime day = DateTime(time.year, time.month, time.day);

    final int diff = today.difference(day).inDays;

    if (diff == 0) return 'วันนี้';

    if (diff == 1) return 'เมื่อวาน';

    return '${time.day} ${months[time.month]} ${time.year}';
  }

  bool sameDay(DateTime? a, DateTime? b) {
    if (a == null || b == null) return false;

    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildDayLabel(DateTime time) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.fill,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            formatDay(time),
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget buildBubble(Map<String, dynamic> message, {required bool showRead}) {
    final bool mine = message['is_mine'] == true;

    final String body = message['body']?.toString() ?? '';

    final String? imageUrl = message['image_url']?.toString();

    // ข้อความในคิว (ยังไม่ถึงเซิร์ฟเวอร์): รูปจากเครื่อง + สถานะ
    final String? state = message['state']?.toString();
    final bool failed = state == 'failed';
    final XFile? localImage = message['image'] as XFile?;

    final DateTime? time = timeOf(message);

    final Color textColor = mine ? Colors.white : AppColors.navy;

    // ข้อความเรา: ไล่สีม่วง / ของอีกฝ่าย: การ์ดสีพื้น
    final BoxDecoration bubbleDecoration = BoxDecoration(
      gradient: mine
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primary, const Color(0xFF7A5AF8)],
            )
          : null,
      color: mine ? null : AppColors.surface,
      border: mine ? null : AppDecorations.cardBorder,
      boxShadow: mine ? null : AppDecorations.cardShadow,
      borderRadius: BorderRadius.only(
        topLeft: const Radius.circular(20),
        topRight: const Radius.circular(20),
        bottomLeft: Radius.circular(mine ? 20 : 6),
        bottomRight: Radius.circular(mine ? 6 : 20),
      ),
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: GestureDetector(
          onTap: failed ? () => openFailedActions(message) : null,
          onLongPress: state == null
              ? () => openMessageActions(message)
              : failed
              ? () => openFailedActions(message)
              : null,
          child: Opacity(
            opacity: state == null ? 1 : 0.72,
            child: Column(
              crossAxisAlignment: mine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (localImage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.file(
                        File(localImage.path),
                        width: 230,
                        height: 250,
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
                        borderRadius: BorderRadius.circular(20),
                        child: Image.network(
                          imageUrl,
                          width: 230,
                          height: 250,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
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
                  ),
                if (body.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.fromLTRB(15, 10, 15, 11),
                    decoration: bubbleDecoration,
                    child: Text(
                      body,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 3, 4, 0),
                  child: state == null
                      ? Text(
                          [
                            if (time != null) formatTime(time),
                            if (showRead) 'อ่านแล้ว',
                          ].join(' · '),
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 11,
                          ),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              failed
                                  ? Icons.error_outline_rounded
                                  : Icons.schedule_rounded,
                              size: 13,
                              color: failed
                                  ? AppColors.danger
                                  : AppColors.muted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              failed
                                  ? 'ส่งไม่สำเร็จ · แตะเพื่อส่งอีกครั้ง'
                                  : 'กำลังส่ง…',
                              style: TextStyle(
                                color: failed
                                    ? AppColors.danger
                                    : AppColors.muted,
                                fontSize: 11.5,
                                fontWeight: failed
                                    ? FontWeight.w700
                                    : FontWeight.w500,
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
    );
  }

  List<Widget> buildMessageItems() {
    // "อ่านแล้ว" ใต้ข้อความล่าสุดของเราที่อีกฝ่ายอ่านแล้ว
    int? readMarkerId;

    for (final message in messages.reversed) {
      final int? id = idOf(message);

      if (message['is_mine'] == true && id != null && id <= otherReadId) {
        readMarkerId = id;
        break;
      }
    }

    final List<Widget> items = [];

    DateTime? previous;

    // ข้อความจากเซิร์ฟเวอร์ แล้วต่อด้วยข้อความในคิว (ล่างสุด)
    for (final message in [...messages, ...outbox]) {
      final DateTime? time = timeOf(message);

      if (time != null && !sameDay(previous, time)) {
        items.add(buildDayLabel(time));
      }

      previous = time ?? previous;

      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: buildBubble(message, showRead: idOf(message) == readMarkerId),
        ),
      );
    }

    // รายการกลับหัว (ข้อความใหม่อยู่ล่าง)
    return items.reversed.toList();
  }

  Widget buildEmpty() {
    return Center(
      child: Padding(
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
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildList() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

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
                  loadMessages();
                },
                child: const Text('ลองอีกครั้ง'),
              ),
            ],
          ),
        ),
      );
    }

    if (messages.isEmpty && outbox.isEmpty) return buildEmpty();

    return ListView(
      controller: scrollController,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      children: [
        ...buildMessageItems(),
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
          ),
      ],
    );
  }

  Widget buildInputBar() {
    if (!isLoading && loadError == null && !canSend) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        color: AppColors.fill,
        child: SafeArea(
          top: false,
          child: Text(
            'ส่งข้อความไม่ได้ เพราะไม่ได้อยู่กลุ่มเดียวกันแล้ว',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 13),
          ),
        ),
      );
    }

    final XFile? image = pickedImage;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(28),
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
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(image.path),
                          width: 84,
                          height: 84,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        right: -8,
                        top: -8,
                        child: Material(
                          color: AppColors.navy,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => setState(() => pickedImage = null),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
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
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'พิมพ์ข้อความ...',
                        counterText: '',
                        isDense: true,
                        filled: true,
                        fillColor: Colors.transparent,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: hasDraft
                            ? LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  AppColors.primary,
                                  const Color(0xFF7A5AF8),
                                ],
                              )
                            : null,
                        color: hasDraft ? null : AppColors.border,
                      ),
                      child: Material(
                        color: Colors.transparent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: hasDraft ? send : null,
                          child: const SizedBox(
                            width: 44,
                            height: 44,
                            child: Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
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
    return PopScope(
      canPop: outbox.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: InkWell(
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
        body: Column(
          children: [
            Expanded(child: buildList()),
            buildInputBar(),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (ChatService.activeConversationId == widget.conversationId) {
      ChatService.activeConversationId = null;
    }

    WidgetsBinding.instance.removeObserver(this);

    pollTimer?.cancel();

    inputController.dispose();

    scrollController.dispose();

    ChatService.refreshUnreadCount();

    super.dispose();
  }
}
