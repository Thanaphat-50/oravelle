import 'package:flutter/material.dart';

import '../services/chat_service.dart';
import '../services/family_service.dart';
import '../services/post_service.dart';
import '../services/profile_service.dart';
import '../services/social_service.dart';
import '../theme/app_theme.dart';
import '../widgets/community_sheets.dart';
import '../widgets/profile_intro.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/user_avatar.dart';
import 'chat_room_page.dart';
import 'edit_profile_page.dart';
import 'feed_page.dart';

// =======================================================
// โปรไฟล์ในชุมชน (กดชื่อ/รูปในโพสต์หรือความคิดเห็นชุมชน)
// - รูป ชื่อ วันที่เข้าร่วม ตัวเลข และข้อมูลแนะนำตัว
// - โพสต์ชุมชนของคนนี้ (ถูกใจ/แสดงความคิดเห็นได้เหมือนฟีด)
// - รายงาน / บล็อก / เลิกบล็อก
// ไม่แสดงอีเมลหรือครอบครัวของเขา
// =======================================================

class UserProfilePage extends StatefulWidget {
  final int userId;

  // ชื่อที่รู้อยู่แล้ว แสดงระหว่างโหลด
  final String? name;

  // บล็อก (true) / เลิกบล็อก (false) จากหน้านี้
  // หน้าที่เปิดมา (ฟีด) ใช้ซ่อน/โหลดโพสต์ของคนนี้ใหม่
  final ValueChanged<bool>? onBlockChanged;

  const UserProfilePage({
    super.key,
    required this.userId,
    this.name,
    this.onBlockChanged,
  });

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  static const Color likeColor = Color(0xFFE5486B);

  // รูปโปรไฟล์ที่เปิดเต็มจอ (Hero)
  final Object avatarHeroTag = Object();

  Map<String, dynamic>? profile;

  bool isLoading = true;

  String? loadError;

  // กำลังรายงาน / บล็อก / เลิกบล็อก
  bool isBusy = false;

  // เพิ่มค่าหลังเลิกบล็อก → โหลดโพสต์ใหม่
  int feedVersion = 0;

  @override
  void initState() {
    super.initState();

    loadProfile();
  }

  // =====================================================
  // โหลดข้อมูล
  // =====================================================

  Future<void> loadProfile() async {
    try {
      final result = await ProfileService.getPublicProfile(widget.userId);

      if (!mounted) return;

      final dynamic raw = result['profile'];

      if (result['status'] == true && raw is Map) {
        setState(() {
          profile = Map<String, dynamic>.from(raw);
          loadError = null;
        });
      } else {
        setState(() {
          loadError = result['message']?.toString() ?? 'ไม่พบผู้ใช้นี้';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loadError = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> retryLoad() async {
    setState(() {
      isLoading = true;
      loadError = null;
    });

    await loadProfile();
  }

  String get name =>
      profile?['name']?.toString() ?? widget.name ?? 'ผู้ใช้ในชุมชน';

  bool get isMe => profile?['is_me'] == true;

  bool get isBlocked => profile?['blocked'] == true;

  bool get isFollowing => profile?['is_following'] == true;

  Map<String, String> get intro => introFrom(profile?['intro']);

  // โปรไฟล์ของเราเอง → แก้ไขข้อมูลแนะนำตัวได้จากหน้านี้
  Future<void> openEditProfile() async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditProfilePage(name: name, intro: intro),
      ),
    );

    if (saved == true && mounted) loadProfile();
  }

  bool followBusy = false;

  bool familyBusy = false;

  // คำเชิญ/คำขอที่ค้างอยู่ระหว่างเรากับคนนี้ ({id, type})
  Map<String, dynamic>? get pendingInvitation {
    final dynamic raw = profile?['pending_invitation'];

    return raw is Map ? Map<String, dynamic>.from(raw) : null;
  }

  // ชวนเข้าครอบครัว (เรามีครอบครัว เขาไม่มี) / ขอเข้าครอบครัว (กลับกัน)
  Future<void> sendFamilyInvitation() async {
    if (familyBusy) return;

    setState(() => familyBusy = true);

    try {
      final bool invite = profile?['can_invite'] == true;

      final result = invite
          ? await FamilyService.invite(userId: widget.userId)
          : await FamilyService.requestJoin(widget.userId);

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ทำรายการไม่สำเร็จ');

      if (result['joined'] == true) {
        // อีกฝ่ายชวน/ขอไว้แล้ว → เข้าครอบครัวทันที
        FamilyService.changes.value++;

        await loadProfile();
        return;
      }

      final dynamic invitation = result['invitation'];

      if (result['status'] == true && invitation is Map) {
        setState(() {
          profile = {
            ...?profile,
            'pending_invitation': {
              'id': invitation['id'],
              'type': invitation['type'],
            },
          };
        });
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => familyBusy = false);
    }
  }

  Future<void> cancelFamilyInvitation() async {
    final dynamic id = pendingInvitation?['id'];

    if (id is! num || familyBusy) return;

    setState(() => familyBusy = true);

    try {
      final result = await FamilyService.cancelInvitation(id.toInt());

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ทำรายการไม่สำเร็จ');

      if (result['status'] == true) {
        setState(() {
          profile = {...?profile, 'pending_invitation': null};
        });
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => familyBusy = false);
    }
  }

  Widget? buildFamilyInviteButton() {
    final bool canInvite = profile?['can_invite'] == true;

    final bool canRequest = profile?['can_request_join'] == true;

    if (!canInvite && !canRequest) return null;

    if (pendingInvitation != null) {
      return OutlinedButton.icon(
        onPressed: familyBusy ? null : cancelFamilyInvitation,
        icon: const Icon(Icons.hourglass_top_rounded, size: 18),
        label: Text(canInvite ? 'ชวนแล้ว · ยกเลิก' : 'ส่งคำขอแล้ว · ยกเลิก'),
      );
    }

    return FilledButton.tonalIcon(
      onPressed: familyBusy ? null : sendFamilyInvitation,
      icon: const Icon(Icons.group_add_rounded, size: 18),
      label: Text(canInvite ? 'ชวนเข้ากลุ่ม' : 'ขอเข้ากลุ่ม'),
    );
  }

  // ติดตาม / เลิกติดตาม (ไม่ต้องรออนุมัติ)
  Future<void> toggleFollow() async {
    if (followBusy) return;

    setState(() => followBusy = true);

    try {
      final result = await SocialService.setFollowing(
        widget.userId,
        !isFollowing,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          profile = {
            ...?profile,
            'is_following': result['is_following'] == true,
            'followers_count': result['followers_count'],
          };
        });
      } else {
        showMessage(result['message']?.toString() ?? 'ทำรายการไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => followBusy = false);
    }
  }

  int countOf(String key) {
    final dynamic value = profile?[key];

    return value is num ? value.toInt() : 0;
  }

  // บทบาทในครอบครัวเดียวกัน (null = คนนอกครอบครัว)
  String? get familyRoleText {
    switch (profile?['family_role']) {
      case 'owner':
        return 'เจ้าของกลุ่ม';
      case 'member':
        return 'สมาชิกกลุ่ม';
    }

    return null;
  }

  String? get joinedText {
    final DateTime? date = DateTime.tryParse(
      profile?['joined_at']?.toString() ?? '',
    )?.toLocal();

    if (date == null) return null;

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

    return 'เข้าร่วม ${months[date.month]} ${date.year}';
  }

  // =====================================================
  // รายงาน / บล็อก
  // =====================================================

  Future<void> reportUser() async {
    final String? reason = await showReportReasonSheet(
      context,
      title: 'รายงาน $name',
      reasons: userReportReasons,
      note: 'ผู้ใช้นี้จะไม่รู้ว่าใครเป็นคนรายงาน',
    );

    if (reason == null || !mounted) return;

    setState(() => isBusy = true);

    try {
      final result = await ProfileService.reportUser(
        userId: widget.userId,
        reason: reason,
      );

      if (!mounted) return;

      showMessage(
        result['message']?.toString() ??
            (result['status'] == true ? 'ขอบคุณที่รายงาน' : 'รายงานไม่สำเร็จ'),
      );
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isBusy = false);
    }
  }

  Future<void> blockUser() async {
    final bool confirmed = await showBlockUserDialog(context, name);

    if (!confirmed || !mounted) return;

    setState(() => isBusy = true);

    try {
      final result = await PostService.blockUser(widget.userId);

      if (!mounted) return;

      if (result['status'] == true) {
        markBlocked();
      }

      showMessage(
        result['message']?.toString() ??
            (result['status'] == true ? 'บล็อก $name แล้ว' : 'บล็อกไม่สำเร็จ'),
      );
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isBusy = false);
    }
  }

  Future<void> unblockUser() async {
    setState(() => isBusy = true);

    try {
      final result = await PostService.unblockUser(widget.userId);

      if (!mounted) return;

      if (result['status'] == true) {
        // โหลดตัวเลขใหม่ แล้วแสดงโพสต์ของเขาอีกครั้ง
        await loadProfile();

        if (!mounted) return;

        setState(() => feedVersion++);

        widget.onBlockChanged?.call(false);
      }

      showMessage(
        result['message']?.toString() ??
            (result['status'] == true ? 'เลิกบล็อกแล้ว' : 'เลิกบล็อกไม่สำเร็จ'),
      );
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isBusy = false);
    }
  }

  // บล็อกจากหน้านี้ หรือจากเมนูของโพสต์ในหน้านี้
  void markBlocked() {
    setState(() {
      profile = {...?profile, 'blocked': true};
    });

    widget.onBlockChanged?.call(true);
  }

  // แชทส่วนตัว (เฉพาะคนในครอบครัวเดียวกัน)
  bool get canChat => profile?['is_family'] == true && !isMe && !isBlocked;

  Future<void> openChat() async {
    setState(() => isBusy = true);

    try {
      final result = await ChatService.openChat(widget.userId);

      if (!mounted) return;

      final dynamic room = result['conversation'];

      if (result['status'] == true && room is Map && room['id'] is num) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatRoomPage(
              conversationId: (room['id'] as num).toInt(),
              user: room['user'] is Map
                  ? Map<String, dynamic>.from(room['user'])
                  : null,
            ),
          ),
        );
      } else {
        showMessage(result['message']?.toString() ?? 'เปิดแชทไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isBusy = false);
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildMenu() {
    return PopupMenuButton<String>(
      tooltip: 'ตัวเลือก',
      enabled: !isBusy,
      position: PopupMenuPosition.under,
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) {
        switch (value) {
          case 'report':
            reportUser();
          case 'block':
            blockUser();
          case 'unblock':
            unblockUser();
        }
      },
      itemBuilder: (context) => [
        buildMenuItem(
          'report',
          Icons.flag_outlined,
          'รายงานผู้ใช้',
          AppColors.navy,
        ),
        if (isBlocked)
          buildMenuItem(
            'unblock',
            Icons.lock_open_rounded,
            'เลิกบล็อก',
            AppColors.navy,
          )
        else
          buildMenuItem(
            'block',
            Icons.block_rounded,
            'บล็อก',
            AppColors.danger,
          ),
      ],
    );
  }

  PopupMenuItem<String> buildMenuItem(
    String value,
    IconData icon,
    String label,
    Color color,
  ) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget buildChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildStat({
    required IconData icon,
    required Color color,
    required int value,
    required String label,
  }) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 5),
            Text(
              '$value',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: AppColors.muted, fontSize: 12)),
      ],
    );
  }

  Widget buildHeader() {
    final String? joined = joinedText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: AppDecorations.cardBorder,
            boxShadow: AppDecorations.cardShadow,
          ),
          child: Column(
            children: [
              // แตะรูปโปรไฟล์ → ดูเต็มจอ (ขยายต่อเนื่อง) เฉพาะเมื่อมีรูป
              Builder(
                builder: (context) {
                  final UserAvatar avatar = UserAvatar(
                    user: {
                      'name': name,
                      'profile_photo_url': profile?['profile_image_url'],
                    },
                    radius: 42,
                    showBorder: true,
                    heroTag: avatarHeroTag,
                  );

                  final String? url = avatar.photoUrl;

                  if (url == null) return avatar;

                  return Semantics(
                    button: true,
                    label: 'ดูรูปโปรไฟล์ของ $name',
                    child: GestureDetector(
                      onTap: () => showPhotoViewer(
                        context,
                        urls: [url],
                        heroTags: [avatarHeroTag],
                      ),
                      child: avatar,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                name,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (isMe)
                    buildChip(
                      Icons.visibility_outlined,
                      'คนในชุมชนเห็นโปรไฟล์ของคุณแบบนี้',
                      AppColors.primary,
                    ),
                  if (profile?['is_family'] == true)
                    buildChip(
                      Icons.groups_rounded,
                      familyRoleText == null
                          ? 'กลุ่มเดียวกัน'
                          : 'กลุ่มเดียวกัน · $familyRoleText',
                      AppColors.success,
                    ),
                  if (joined != null)
                    buildChip(
                      Icons.calendar_month_outlined,
                      joined,
                      AppColors.muted,
                    ),
                ],
              ),
              if (!isMe && !isBlocked) ...[
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    isFollowing
                        ? OutlinedButton.icon(
                            onPressed: followBusy ? null : toggleFollow,
                            icon: const Icon(Icons.check_rounded, size: 18),
                            label: const Text('ติดตามแล้ว'),
                          )
                        : FilledButton.icon(
                            onPressed: followBusy ? null : toggleFollow,
                            icon: const Icon(
                              Icons.person_add_alt_1_rounded,
                              size: 18,
                            ),
                            label: const Text('ติดตาม'),
                          ),
                    if (canChat)
                      FilledButton.tonalIcon(
                        onPressed: isBusy ? null : openChat,
                        icon: const Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('ส่งข้อความ'),
                      ),
                    ?buildFamilyInviteButton(),
                  ],
                ),
              ],
              if (!isBlocked) ...[
                const SizedBox(height: 16),
                Divider(height: 1, color: AppColors.border),
                const SizedBox(height: 14),
                // ตัวเลขนับที่เซิร์ฟเวอร์ เฉพาะโพสต์ที่ผู้ชมคนนี้เห็นได้
                Row(
                  children: [
                    Expanded(
                      child: buildStat(
                        icon: Icons.article_outlined,
                        color: AppColors.primary,
                        value: profile?['posts'] is num
                            ? countOf('posts')
                            : countOf('community_posts'),
                        label: 'โพสต์',
                      ),
                    ),
                    Container(width: 1, height: 36, color: AppColors.border),
                    Expanded(
                      child: buildStat(
                        icon: Icons.people_alt_rounded,
                        color: AppColors.sky,
                        value: countOf('followers_count'),
                        label: 'ผู้ติดตาม',
                      ),
                    ),
                    Container(width: 1, height: 36, color: AppColors.border),
                    Expanded(
                      child: buildStat(
                        icon: Icons.person_add_alt_rounded,
                        color: AppColors.sky,
                        value: countOf('following_count'),
                        label: 'กำลังติดตาม',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.favorite_rounded,
                      size: 13,
                      color: likeColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'ได้รับถูกใจ ${countOf('likes_received')} ครั้ง',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
                if (isMe) ...[
                  const SizedBox(height: 8),
                  Text(
                    'โพสต์ในกลุ่มไม่แสดงที่นี่ (เห็นเฉพาะสมาชิกในกลุ่ม) และไม่แสดงอีเมลหรือชื่อกลุ่มของคุณ',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        if (!isBlocked) ...[
          if (isMe || intro.isNotEmpty) ...[
            const SizedBox(height: 14),
            ProfileIntroCard(
              intro: intro,
              onEdit: isMe ? openEditProfile : null,
              showPublicNote: isMe,
            ),
          ],
          const SizedBox(height: 20),
          Padding(
            padding: EdgeInsets.only(left: 4),
            child: Text(
              'โพสต์',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget buildBlockedCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: AppDecorations.cardBorder,
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Column(
        children: [
          Icon(Icons.block_rounded, size: 36, color: AppColors.danger),
          const SizedBox(height: 12),
          Text(
            'คุณบล็อก $name อยู่',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'คุณจะไม่เห็นโพสต์และความคิดเห็นของผู้ใช้นี้ในชุมชน',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: isBusy ? null : unblockUser,
            icon: const Icon(Icons.lock_open_rounded, size: 18),
            label: const Text('เลิกบล็อก'),
          ),
        ],
      ),
    );
  }

  Widget buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_off_outlined, size: 44, color: AppColors.muted),
            const SizedBox(height: 12),
            Text(
              loadError ?? 'ไม่พบผู้ใช้นี้',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.navy, fontSize: 15),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: retryLoad,
              child: const Text('ลองอีกครั้ง'),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildBody() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (profile == null) {
      return buildError();
    }

    if (isBlocked) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          buildHeader(),
          const SizedBox(height: 14),
          buildBlockedCard(),
        ],
      );
    }

    return FeedPage(
      key: ValueKey('user-${widget.userId}-$feedVersion'),
      scope: FeedScope.community,
      authorId: widget.userId,
      header: buildHeader(),
      onUserBlocked: (_) => markBlocked(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isMe ? 'โปรไฟล์ที่คนอื่นเห็น' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [if (profile != null && !isMe) buildMenu()],
      ),
      body: buildBody(),
    );
  }
}
