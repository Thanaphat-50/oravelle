import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_helper.dart';
import '../services/profile_service.dart';
import '../theme/app_theme.dart';
import '../widgets/profile_intro.dart';
import 'edit_profile_page.dart';
import 'feed_page.dart';
import 'follow_list_page.dart';
import 'my_shop_page.dart';
import 'orders_page.dart';
import 'photo_crop_page.dart';
import 'saved_products_page.dart';
import 'settings_page.dart';
import 'user_profile_page.dart';

// =======================================================
// โปรไฟล์ของฉัน (เปิดจากเมนูบัญชี)
// บนลงล่าง: รูป ชื่อ แนะนำตัว → ตัวเลข → แก้ไข / ดูที่คนอื่นเห็น
//           → ข้อมูลเพิ่มเติม (กดขยาย) → ทางลัดร้านค้า → โพสต์ของฉัน + ตัวกรอง
// ข้อมูลทั้งหมดมาจาก GET /api/profile (ตัวเลขนับที่เซิร์ฟเวอร์)
// =======================================================

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const Color likeColor = Color(0xFFE5486B);

  final ImagePicker _imagePicker = ImagePicker();

  // ส่วน "โพสต์ของฉัน" (กดจำนวนโพสต์ → เลื่อนมาที่นี่)
  final GlobalKey postsKey = GlobalKey();

  bool isLoading = true;
  bool isUploadingPhoto = false;

  // null = ยังโหลดไม่สำเร็จเลย (แสดงหน้าลองอีกครั้ง ไม่แสดงชื่อสำรอง/ตัวเลข 0)
  Map<String, dynamic>? profileData;
  String? loadError;

  // ตัวกรองโพสต์ของฉัน: null = ทั้งหมด / community / family
  String? postFilter;

  // =====================================================
  // โหลดข้อมูล
  // =====================================================

  @override
  void initState() {
    super.initState();

    loadProfile();
  }

  Future<void> loadProfile() async {
    try {
      final result = await ProfileService.getProfile();

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          profileData = Map<String, dynamic>.from(result);
          loadError = null;
        });
      } else {
        reportLoadError(
          result['message']?.toString() ?? 'โหลดข้อมูลโปรไฟล์ไม่สำเร็จ',
        );
      }
    } catch (_) {
      // ไม่แสดงข้อความเทคนิคของระบบให้ผู้ใช้
      if (mounted) {
        reportLoadError('เชื่อมต่อไม่ได้ ตรวจสอบอินเทอร์เน็ตแล้วลองอีกครั้ง');
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ยังไม่มีข้อมูล → หน้าลองอีกครั้ง / มีข้อมูลเดิม → คงไว้แล้วแจ้ง
  void reportLoadError(String message) {
    if (profileData == null) {
      setState(() => loadError = message);
    } else {
      showMessage('อัปเดตข้อมูลโปรไฟล์ไม่สำเร็จ: $message');
    }
  }

  Future<void> retryLoad() async {
    setState(() {
      isLoading = true;
      loadError = null;
    });

    await loadProfile();
  }

  // =====================================================
  // ข้อมูลที่ใช้แสดง
  // =====================================================

  Map<String, dynamic> get user {
    final value = profileData?['user'];

    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  Map<String, dynamic>? get family {
    final value = profileData?['family'];

    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  bool get hasShop => profileData?['shop'] is Map;

  String get userName => user['name']?.toString() ?? '';

  String get email => user['email']?.toString() ?? '';

  String get roleText =>
      profileData?['role'] == 'owner' ? 'เจ้าของกลุ่ม' : 'สมาชิก';

  String? get photoUrl {
    final String text = user['profile_photo_url']?.toString().trim() ?? '';

    return text.isEmpty ? null : text;
  }

  bool get hasPhoto => photoUrl != null;

  int? get userId {
    final dynamic value = user['id'];

    return value is num ? value.toInt() : null;
  }

  // ตัวเลขจาก /api/profile (posts, community_posts, group_posts,
  // likes_received, followers, following)
  int stat(String key) {
    final dynamic stats = profileData?['stats'];

    final dynamic value = stats is Map ? stats[key] : null;

    return value is num ? value.toInt() : 0;
  }

  Map<String, String> get intro => introFrom(user['intro']);

  String get initial {
    final name = userName.trim();

    return name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
  }

  // =====================================================
  // เปิดหน้าอื่น (กลับมาแล้วโหลดใหม่ให้ข้อมูลตรงกัน)
  // =====================================================

  Future<void> openEditProfile() async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => EditProfilePage(name: userName, intro: intro),
      ),
    );

    if (saved == true && mounted) await loadProfile();
  }

  // แก้ไขโปรไฟล์จากหน้ามุมมองของคนอื่นได้ด้วย → กลับมาแล้วโหลดใหม่เสมอ
  Future<void> openPublicProfile() async {
    final int? id = userId;

    if (id == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => UserProfilePage(userId: id, name: userName),
      ),
    );

    if (mounted) await loadProfile();
  }

  Future<void> openFollowList(bool followers) async {
    final dynamic changed = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => FollowListPage(followers: followers),
      ),
    );

    if (changed == true && mounted) await loadProfile();
  }

  Future<void> openPage(Widget page, {bool reload = false}) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (context) => page));

    if (reload && mounted) await loadProfile();
  }

  void scrollToPosts() {
    final BuildContext? target = postsKey.currentContext;

    if (target == null) return;

    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  // =====================================================
  // PHOTO MENU
  // =====================================================

  Future<void> showPhotoMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 5, 18, 25),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'รูปโปรไฟล์',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  'เลือกรูปที่ต้องการใช้เป็นรูปบัญชี',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.photo_library_outlined),
                  ),
                  title: const Text('เลือกรูปจาก Gallery'),
                  subtitle: const Text('รองรับ JPG, PNG และ WEBP'),
                  onTap: () {
                    Navigator.of(sheetContext).pop();

                    pickPhoto();
                  },
                ),
                if (hasPhoto)
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppColors.softDanger,
                      child: Icon(
                        Icons.delete_outline_rounded,
                        color: AppColors.danger,
                      ),
                    ),
                    title: Text(
                      'ลบรูปโปรไฟล์',
                      style: TextStyle(color: AppColors.danger),
                    ),
                    subtitle: const Text('กลับไปใช้ตัวอักษรแทนรูป'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();

                      deletePhoto();
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> pickPhoto() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1600,
      );

      if (image == null || !mounted) return;

      // ครอปเป็นสี่เหลี่ยมจัตุรัสและดูตัวอย่างในวงกลมก่อนอัปโหลด
      final Uint8List original = await image.readAsBytes();

      if (!mounted) return;

      final Uint8List? cropped = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(builder: (_) => PhotoCropPage(bytes: original)),
      );

      if (cropped == null || !mounted) return;

      setState(() => isUploadingPhoto = true);

      final result = await ProfileService.uploadProfilePhotoBytes(cropped);

      if (!mounted) return;

      if (result['status'] == true) {
        await loadProfile();

        if (!mounted) return;

        showMessage('เปลี่ยนรูปโปรไฟล์เรียบร้อยแล้ว');
      } else {
        showMessage(result['message'] ?? 'อัปโหลดรูปไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage(ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isUploadingPhoto = false);
    }
  }

  Future<void> deletePhoto() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: Icon(
            Icons.delete_outline_rounded,
            color: AppColors.danger,
            size: 38,
          ),
          title: const Text('ลบรูปโปรไฟล์?'),
          content: const Text(
            'รูปปัจจุบันจะถูกลบ และบัญชีจะกลับไปใช้ตัวอักษรแทนรูป',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ยกเลิก'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('ลบรูป'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) return;

    await Future<void>.delayed(const Duration(milliseconds: 250));

    setState(() => isUploadingPhoto = true);

    try {
      final result = await ProfileService.deleteProfilePhoto();

      if (!mounted) return;

      if (result['status'] == true) {
        await loadProfile();

        if (!mounted) return;

        showMessage('ลบรูปโปรไฟล์เรียบร้อยแล้ว');
      } else {
        showMessage(result['message'] ?? 'ลบรูปไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('ลบรูปไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => isUploadingPhoto = false);
    }
  }

  // =====================================================
  // UI: รูป ชื่อ แนะนำตัว
  // =====================================================

  Widget buildAvatar() {
    final url = photoUrl;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 84,
          height: 84,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.sky, AppColors.primary],
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
            ),
            padding: const EdgeInsets.all(2),
            child: ClipOval(
              child: url != null
                  ? Image.network(
                      url,
                      width: 74,
                      height: 74,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          buildInitialAvatar(),
                    )
                  : buildInitialAvatar(),
            ),
          ),
        ),
        Positioned(
          right: -4,
          bottom: 0,
          child: Material(
            color: AppColors.primary,
            shape: const CircleBorder(),
            elevation: 3,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: isUploadingPhoto ? null : showPhotoMenu,
              child: SizedBox(
                width: 30,
                height: 30,
                child: isUploadingPhoto
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Icon(
                        Icons.photo_camera_rounded,
                        color: Colors.white,
                        size: 16,
                        semanticLabel: 'เปลี่ยนรูปโปรไฟล์',
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildInitialAvatar() {
    return Container(
      color: AppColors.softPrimary,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: AppColors.primary,
          fontSize: 30,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget buildIdentity() {
    final String? bio = intro['bio'];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        buildAvatar(),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                userName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 20,
                  height: 1.3,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              if (bio != null)
                Text(
                  bio,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.subtle,
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                )
              else
                InkWell(
                  onTap: openEditProfile,
                  child: Text(
                    '+ เพิ่มคำแนะนำตัวสั้น ๆ',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.public_rounded, size: 13, color: AppColors.muted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'ข้อมูลนี้แสดงในชุมชน',
                      style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =====================================================
  // UI: ตัวเลข (กดได้) + ถูกใจที่ได้รับ (ข้อมูลรอง ไม่ใช่ปุ่ม)
  // =====================================================

  Widget buildStats() {
    Widget cell(int value, String label, VoidCallback onTap) {
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
                Text(
                  '$value',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget divider() =>
        Container(width: 1, height: 30, color: AppColors.border);

    final int likes = stat('likes_received');

    return Container(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
      decoration: AppDecorations.card(radius: 20),
      child: Column(
        children: [
          Row(
            children: [
              cell(stat('posts'), 'โพสต์', scrollToPosts),
              divider(),
              cell(stat('followers'), 'ผู้ติดตาม', () => openFollowList(true)),
              divider(),
              cell(
                stat('following'),
                'กำลังติดตาม',
                () => openFollowList(false),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.favorite_rounded, size: 13, color: likeColor),
              const SizedBox(width: 4),
              Text(
                'ได้รับถูกใจ $likes ครั้ง',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    // ปุ่มของธีมกว้างเต็มจอ → ในแถวต้องกำหนดขนาดเอง
    const Size size = Size(0, 46);
    const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 10);

    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(minimumSize: size, padding: padding),
            onPressed: openEditProfile,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text(
              'แก้ไขโปรไฟล์',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: size,
              padding: padding,
            ),
            onPressed: openPublicProfile,
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text(
              'ดูโปรไฟล์ที่คนอื่นเห็น',
              maxLines: 2,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }

  // =====================================================
  // UI: ข้อมูลเพิ่มเติม (แสดงในชุมชน) + ข้อมูลบัญชี (เห็นเฉพาะคุณ)
  // =====================================================

  Widget buildInfoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$label  ',
                    style: TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildExpandable({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return ExpansionTile(
      shape: const Border(),
      collapsedShape: const Border(),
      leading: Icon(icon, color: AppColors.primary),
      title: Text(
        title,
        style: TextStyle(
          color: AppColors.navy,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: AppColors.muted, fontSize: 12),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget buildMoreInfo() {
    final List<IntroField> details = introDetailFields
        .where((field) => intro[field.key] != null)
        .toList();

    final Map<String, dynamic>? group = family;

    return Container(
      decoration: AppDecorations.card(radius: 20),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          children: [
            buildExpandable(
              icon: Icons.badge_outlined,
              title: 'ข้อมูลเพิ่มเติม',
              subtitle: details.isEmpty
                  ? 'อาชีพ การศึกษา จังหวัด ความสนใจ · ยังไม่ได้กรอก'
                  : 'แสดงในชุมชน · ${details.length} รายการ',
              children: [
                for (final field in details)
                  buildInfoRow(field.icon, field.label, intro[field.key]!),
                if (details.isEmpty) ...[
                  Text(
                    'ข้อมูลเหล่านี้ช่วยให้คนในชุมชนรู้จักคุณมากขึ้น ไม่ต้องกรอกครบ',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: openEditProfile,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('เพิ่มข้อมูล'),
                  ),
                ],
              ],
            ),
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: AppColors.border,
            ),
            buildExpandable(
              icon: Icons.lock_outline_rounded,
              title: 'ข้อมูลบัญชี',
              subtitle: 'เห็นเฉพาะคุณ · ไม่แสดงในโปรไฟล์ที่คนอื่นเห็น',
              children: [
                buildInfoRow(
                  Icons.email_outlined,
                  'อีเมล',
                  email.isEmpty
                      ? 'ไม่มีอีเมล (เข้าสู่ระบบด้วยบัญชีอื่น)'
                      : email,
                ),
                buildInfoRow(
                  Icons.groups_outlined,
                  'กลุ่ม',
                  group == null
                      ? 'ยังไม่มีกลุ่ม'
                      : '${group['name'] ?? ''} · $roleText',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // UI: ทางลัด (ใช้หน้าเดิมของระบบ)
  // =====================================================

  Widget buildShortcuts() {
    Widget shortcut(IconData icon, String label, VoidCallback onTap) {
      return Expanded(
        child: Material(
          color: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: AppColors.border),
          ),
          child: InkWell(
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
              child: Column(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppColors.market.withValues(alpha: 0.10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, color: AppColors.market, size: 20),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        shortcut(
          Icons.receipt_long_outlined,
          'คำสั่งซื้อของฉัน',
          () => openPage(const OrdersPage()),
        ),
        const SizedBox(width: 10),
        shortcut(
          Icons.bookmark_border_rounded,
          'สินค้าที่บันทึก',
          () => openPage(const SavedProductsPage()),
        ),
        const SizedBox(width: 10),
        shortcut(
          hasShop ? Icons.storefront_rounded : Icons.add_business_outlined,
          hasShop ? 'ร้านค้าของฉัน' : 'เปิดร้านค้า',
          // เปิดร้านแล้วกลับมา → เปลี่ยนเป็น "ร้านค้าของฉัน"
          () => openPage(const MyShopPage(), reload: true),
        ),
      ],
    );
  }

  // =====================================================
  // UI: หัวข้อโพสต์ของฉัน + ตัวกรอง
  // =====================================================

  Widget buildPostsHeader() {
    Widget chip(String? key, String label, int count) {
      return ChoiceChip(
        label: Text('$label $count'),
        selected: postFilter == key,
        onSelected: (_) {
          if (postFilter == key) return;

          setState(() => postFilter = key);
        },
      );
    }

    // ยังไม่มีกลุ่ม และไม่มีโพสต์ในกลุ่ม → ไม่ต้องมีตัวกรอง "ในกลุ่ม"
    final bool showGroup = family != null || stat('group_posts') > 0;

    return Column(
      key: postsKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            'โพสต์ของฉัน',
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            chip(null, 'ทั้งหมด', stat('posts')),
            chip('community', 'ชุมชน', stat('community_posts')),
            if (showGroup) chip('family', 'ในกลุ่ม', stat('group_posts')),
          ],
        ),
      ],
    );
  }

  Widget buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 4),
        buildIdentity(),
        const SizedBox(height: 14),
        buildStats(),
        const SizedBox(height: 12),
        buildActions(),
        const SizedBox(height: 12),
        buildMoreInfo(),
        const SizedBox(height: 12),
        buildShortcuts(),
        const SizedBox(height: 20),
        buildPostsHeader(),
      ],
    );
  }

  Widget buildLoadError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 46, color: AppColors.muted),
            const SizedBox(height: 12),
            Text(
              'โหลดข้อมูลโปรไฟล์ไม่สำเร็จ',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              loadError ?? 'กรุณาลองใหม่อีกครั้ง',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(170, 46)),
              onPressed: retryLoad,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('ลองอีกครั้ง'),
            ),
          ],
        ),
      ),
    );
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;

    if (profileData == null) {
      body = isLoading
          ? const Center(child: CircularProgressIndicator())
          : buildLoadError();
    } else {
      body = FeedPage(
        scope: FeedScope.mine,
        mineVisibility: postFilter,
        header: buildHeader(),
        onRefresh: loadProfile,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('โปรไฟล์'),
        actions: [
          IconButton(
            tooltip: 'ตั้งค่า',
            onPressed: () => openPage(const SettingsPage(), reload: true),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: body,
    );
  }
}
