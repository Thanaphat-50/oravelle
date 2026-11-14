import 'dart:async';

import 'package:flutter/material.dart';

import '../services/chat_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_media.dart' show chatDuration;
import '../widgets/user_avatar.dart';
import 'chat_room_page.dart';
import 'group_chat_page.dart';

// =======================================================
// รายการแชท (Lavender)
// - หัวหน้า "แชท" + ปุ่มเริ่มแชทใหม่ / ช่องค้นหาชื่อหรือกลุ่ม / ตัวกรอง ทั้งหมด · ยังไม่อ่าน · กลุ่ม
// - สมาชิกในครอบครัว (แตะเพื่อเริ่มคุย) / ข้อความ: แชทกลุ่ม + แชทส่วนตัว/ร้านค้า เรียงตามข้อความล่าสุด
// - โหลดใหม่ทุก 15 วินาทีระหว่างเปิดหน้านี้
// =======================================================

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  final TextEditingController searchController = TextEditingController();

  List<Map<String, dynamic>> conversations = [];
  List<Map<String, dynamic>> contacts = [];

  // แชทกลุ่มของกลุ่มที่อยู่ตอนนี้ (null = ยังไม่มีกลุ่ม)
  Map<String, dynamic>? groupChat;

  bool isLoading = true;
  String? loadError;
  String query = '';

  // all | unread | group
  String filter = 'all';

  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();

    loadChats();

    refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => loadChats(),
    );
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    searchController.dispose();
    super.dispose();
  }

  // =====================================================
  // ข้อมูล
  // =====================================================

  List<Map<String, dynamic>> parseList(dynamic raw) {
    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> loadChats() async {
    try {
      final result = await ChatService.getChats();

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          conversations = parseList(result['conversations']);
          contacts = parseList(result['contacts']);
          final dynamic group = result['group_chat'];
          groupChat = group is Map ? Map<String, dynamic>.from(group) : null;
          loadError = null;
        });
      } else if (conversations.isEmpty) {
        setState(() {
          loadError = result['message']?.toString() ?? 'โหลดแชทไม่สำเร็จ';
        });
      }
    } catch (e) {
      if (mounted && conversations.isEmpty) {
        setState(() => loadError = e.toString());
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }

    ChatService.refreshUnreadCount();
  }

  // UserAvatar อ่านรูปจาก profile_photo_url
  Map<String, dynamic> avatarOf(dynamic user) {
    final Map<String, dynamic> data = user is Map
        ? Map<String, dynamic>.from(user)
        : {};

    return {...data, 'profile_photo_url': data['profile_image_url']};
  }

  int countOf(dynamic value) => value is num ? value.toInt() : 0;

  bool matches(String? name) =>
      query.isEmpty || (name ?? '').toLowerCase().contains(query.toLowerCase());

  // =====================================================
  // เปิดห้อง
  // =====================================================

  Future<void> openRoom(int conversationId, dynamic user) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomPage(
          conversationId: conversationId,
          user: user is Map ? Map<String, dynamic>.from(user) : null,
        ),
      ),
    );

    if (mounted) loadChats();
  }

  // เปิดห้องแชทกลุ่ม (ยังไม่มีห้อง → เซิร์ฟเวอร์สร้างตอนเปิด)
  Future<void> openGroupChat() async {
    final dynamic id = groupChat?['id'];

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GroupChatPage(chatId: id is num ? id.toInt() : null),
      ),
    );

    if (mounted) loadChats();
  }

  Future<void> startChat(Map<String, dynamic> contact) async {
    final dynamic existing = contact['conversation_id'];

    if (existing is num) {
      await openRoom(existing.toInt(), contact);
      return;
    }

    final dynamic id = contact['id'];

    if (id is! num) return;

    try {
      final result = await ChatService.openChat(id.toInt());

      if (!mounted) return;

      final dynamic room = result['conversation'];

      if (result['status'] == true && room is Map && room['id'] is num) {
        await openRoom((room['id'] as num).toInt(), room['user']);
      } else {
        showMessage(result['message']?.toString() ?? 'เปิดแชทไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    }
  }

  // เริ่มแชทใหม่ / ดูสมาชิกทั้งหมด: เลือกแชทกลุ่มหรือสมาชิกในครอบครัว
  Future<void> openPeoplePicker({required String title}) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  title,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (groupChat != null)
                ListTile(
                  leading: groupAvatar(22),
                  title: Text(groupChat?['name']?.toString() ?? 'แชทกลุ่ม'),
                  subtitle: const Text('คุยพร้อมกันทุกคนในครอบครัว'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    openGroupChat();
                  },
                ),
              for (final contact in contacts)
                ListTile(
                  leading: UserAvatar(user: avatarOf(contact), radius: 22),
                  title: Text(contact['name']?.toString() ?? ''),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    startChat(contact);
                  },
                ),
              if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'ยังไม่มีสมาชิกคนอื่นในครอบครัว ชวนคนที่รู้จักเข้ากลุ่มด้วยรหัสเชิญ',
                    style: TextStyle(color: AppColors.muted, height: 1.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // ข้อความ
  // =====================================================

  DateTime? timeOf(dynamic last) => last is Map
      ? DateTime.tryParse(last['created_at']?.toString() ?? '')?.toLocal()
      : null;

  String formatTime(DateTime? time) {
    if (time == null) return '';

    final DateTime now = DateTime.now();
    final int days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(time.year, time.month, time.day)).inDays;

    if (days == 0) {
      return '${time.hour.toString().padLeft(2, '0')}:'
          '${time.minute.toString().padLeft(2, '0')}';
    }

    if (days == 1) return 'เมื่อวาน';
    if (days < 7) return '$days วันก่อน';

    return '${time.day}/${time.month}/${time.year}';
  }

  // ตัวอย่างข้อความล่าสุด: ไอคอนชนิด (เสียง/ไฟล์/รูป) + ข้อความ
  ({IconData? icon, String text}) previewOf(dynamic last) {
    if (last is! Map) return (icon: null, text: '');

    final String body = last['body']?.toString() ?? '';

    if (body.isNotEmpty) return (icon: null, text: body);

    switch (last['attachment_kind']) {
      case 'voice':
        final dynamic ms = last['voice_duration_ms'];

        return (
          icon: Icons.mic_none_rounded,
          text: ms is num
              ? 'ข้อความเสียง · ${chatDuration(Duration(milliseconds: ms.toInt()))}'
              : 'ข้อความเสียง',
        );
      case 'file':
        return (icon: Icons.attach_file_rounded, text: 'ไฟล์');
    }

    return last['has_image'] == true
        ? (icon: Icons.photo_outlined, text: 'รูปภาพ')
        : (icon: null, text: '');
  }

  // =====================================================
  // UI
  // =====================================================

  Widget groupAvatar(double radius) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.softPrimary,
      child: Icon(
        Icons.groups_rounded,
        color: AppColors.primary,
        size: radius * 1.05,
      ),
    );
  }

  Widget buildHeader() {
    // ไม่มีปุ่มย้อนกลับบนหัว (ย้อนกลับด้วยปุ่ม/ท่าทางย้อนกลับของเครื่อง)
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'แชท',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Tooltip(
            message: 'เริ่มแชทใหม่',
            child: Material(
              color: AppColors.softPrimary,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => openPeoplePicker(title: 'เริ่มแชทใหม่'),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.edit_outlined, color: AppColors.primary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSearch() {
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(26),
      borderSide: BorderSide(color: AppColors.border),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: searchController,
        onChanged: (value) => setState(() => query = value.trim()),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'ค้นหาชื่อหรือกลุ่ม',
          prefixIcon: Icon(Icons.search_rounded, color: AppColors.muted),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'ล้างคำค้นหา',
                  onPressed: () {
                    searchController.clear();
                    setState(() => query = '');
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(color: AppColors.primary, width: 1.5),
          ),
        ),
      ),
    );
  }

  Widget filterChip(String value, String label, {int count = 0}) {
    final bool selected = filter == value;

    return Semantics(
      button: true,
      selected: selected,
      label: count > 0 ? '$label $count ห้อง' : label,
      excludeSemantics: true,
      child: Material(
        color: selected ? AppColors.primary : AppColors.surface,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? AppColors.primary : AppColors.border,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => setState(() => filter = value),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? AppColors.onPrimary : AppColors.navy,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    constraints: const BoxConstraints(minWidth: 22),
                    height: 22,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.onPrimary : AppColors.primary,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: TextStyle(
                        color: selected ? AppColors.primary : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildFilters(int unreadRooms) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          filterChip('all', 'ทั้งหมด'),
          const SizedBox(width: 10),
          filterChip('unread', 'ยังไม่อ่าน', count: unreadRooms),
          const SizedBox(width: 10),
          filterChip('group', 'กลุ่ม'),
        ],
      ),
    );
  }

  Widget sectionTitle(String title, {VoidCallback? onMore}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('ดูทั้งหมด'),
                  SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget buildMembers(List<Map<String, dynamic>> members) {
    if (members.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
        child: Text(
          query.isEmpty
              ? 'ยังไม่มีสมาชิกคนอื่นในครอบครัว ชวนคนที่รู้จักเข้ากลุ่มด้วยรหัสเชิญ แล้วคุยกันได้ที่นี่'
              : 'ไม่พบสมาชิกชื่อนี้',
          style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
        ),
      );
    }

    return SizedBox(
      height: 112,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: members.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final Map<String, dynamic> contact = members[index];
          final String name = contact['name']?.toString() ?? '';

          return Semantics(
            button: true,
            label: 'แชทกับ $name',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => startChat(contact),
              child: SizedBox(
                width: 80,
                child: Column(
                  children: [
                    const SizedBox(height: 4),
                    UserAvatar(user: avatarOf(contact), radius: 32),
                    const SizedBox(height: 8),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget messageRow({
    required Widget avatar,
    required String name,
    required dynamic last,
    required int unread,
    required VoidCallback onTap,
    String? prefix,
    String? tag,
    String fallback = '',
    bool muted = false,
  }) {
    final preview = previewOf(last);
    final String text = preview.text.isEmpty ? fallback : preview.text;
    final bool hasUnread = unread > 0;
    final TextStyle previewStyle = TextStyle(
      color: hasUnread ? AppColors.navy : AppColors.muted,
      fontSize: 14,
      fontWeight: hasUnread ? FontWeight.w700 : FontWeight.w400,
    );

    return Semantics(
      button: true,
      label: [
        name,
        if (prefix != null && preview.text.isNotEmpty) prefix,
        text,
        formatTime(timeOf(last)),
        if (hasUnread) 'ยังไม่อ่าน $unread ข้อความ',
      ].join(', '),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              avatar,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.navy,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (tag != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.market.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              tag,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.market,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                        if (muted) ...[
                          const SizedBox(width: 4),
                          Icon(
                            Icons.notifications_off_outlined,
                            size: 16,
                            color: AppColors.muted,
                          ),
                        ],
                        const Spacer(),
                        const SizedBox(width: 8),
                        Text(
                          formatTime(timeOf(last)),
                          style: TextStyle(
                            color: hasUnread
                                ? AppColors.primary
                                : AppColors.muted,
                            fontSize: 13,
                            fontWeight: hasUnread
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              style: previewStyle,
                              children: [
                                if (prefix != null && preview.text.isNotEmpty)
                                  TextSpan(text: '$prefix: '),
                                if (preview.icon != null)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Icon(
                                        preview.icon,
                                        size: 16,
                                        color: previewStyle.color,
                                      ),
                                    ),
                                  ),
                                TextSpan(text: text),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (hasUnread)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            constraints: const BoxConstraints(minWidth: 24),
                            height: 24,
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 7),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget groupRow(Map<String, dynamic> group) {
    final dynamic last = group['last_message'];

    return messageRow(
      avatar: groupAvatar(28),
      name: group['name']?.toString() ?? 'แชทกลุ่ม',
      last: last,
      unread: countOf(group['unread_count']),
      muted: group['muted'] == true,
      prefix: last is Map
          ? (last['is_mine'] == true
                ? 'คุณ'
                : (last['sender_name']?.toString() ?? 'สมาชิก'))
          : null,
      fallback: 'แชทพร้อมกันทุกคนในครอบครัว',
      onTap: openGroupChat,
    );
  }

  Widget conversationRow(Map<String, dynamic> conversation) {
    final dynamic user = conversation['user'];
    final dynamic last = conversation['last_message'];
    final dynamic shop = conversation['shop'];

    return messageRow(
      avatar: UserAvatar(user: avatarOf(user), radius: 28),
      name: user is Map ? (user['name']?.toString() ?? 'แชท') : 'แชท',
      last: last,
      unread: countOf(conversation['unread_count']),
      prefix: last is Map && last['is_mine'] == true ? 'คุณ' : null,
      tag: shop is Map
          ? (shop['is_mine'] == true
                ? 'ลูกค้าร้าน ${shop['name'] ?? ''}'
                : 'ร้านค้า')
          : null,
      onTap: () {
        final dynamic id = conversation['id'];

        if (id is num) openRoom(id.toInt(), user);
      },
    );
  }

  Widget buildBody() {
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
                  loadChats();
                },
                child: const Text('ลองอีกครั้ง'),
              ),
            ],
          ),
        ),
      );
    }

    final Map<String, dynamic>? group = groupChat;
    final int unreadRooms =
        (group != null && countOf(group['unread_count']) > 0 ? 1 : 0) +
        conversations.where((c) => countOf(c['unread_count']) > 0).length;

    // แถวข้อความ: แชทกลุ่ม + แชทส่วนตัว เรียงตามข้อความล่าสุด (ตามตัวกรองและคำค้นหา)
    final List<({DateTime? time, Widget row})> rows =
        [
          if (group != null &&
              matches(group['name']?.toString()) &&
              (filter != 'unread' || countOf(group['unread_count']) > 0))
            (time: timeOf(group['last_message']), row: groupRow(group)),
          if (filter != 'group')
            for (final conversation in conversations)
              if (matches(
                    (conversation['user'] is Map)
                        ? (conversation['user'] as Map)['name']?.toString()
                        : null,
                  ) &&
                  (filter != 'unread' ||
                      countOf(conversation['unread_count']) > 0))
                (
                  time: timeOf(conversation['last_message']),
                  row: conversationRow(conversation),
                ),
        ]..sort((a, b) {
          final DateTime? x = a.time;
          final DateTime? y = b.time;

          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;

          return y.compareTo(x);
        });

    final List<Map<String, dynamic>> members = contacts
        .where((contact) => matches(contact['name']?.toString()))
        .toList();

    return RefreshIndicator(
      onRefresh: loadChats,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          buildSearch(),
          buildFilters(unreadRooms),
          if (filter == 'all') ...[
            sectionTitle(
              'สมาชิกในครอบครัว',
              onMore: contacts.isEmpty
                  ? null
                  : () => openPeoplePicker(title: 'สมาชิกในครอบครัว'),
            ),
            buildMembers(members),
          ],
          sectionTitle('ข้อความ'),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                children: [
                  Icon(Icons.forum_outlined, size: 40, color: AppColors.muted),
                  const SizedBox(height: 10),
                  Text(
                    query.isNotEmpty || filter != 'all'
                        ? 'ไม่พบแชทที่ตรงกับเงื่อนไข'
                        : 'ยังไม่มีข้อความ\nแตะรูปสมาชิกในครอบครัวด้านบนเพื่อเริ่มคุย\nหรือกด "แชท" ในหน้าสินค้าเพื่อทักร้าน',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 13.5,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            )
          else
            for (int i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  indent: 20,
                  endIndent: 20,
                  color: AppColors.border,
                ),
              rows[i].row,
            ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            buildHeader(),
            Expanded(child: buildBody()),
          ],
        ),
      ),
    );
  }
}
