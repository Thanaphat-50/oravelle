import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_theming.dart';
import 'user_avatar.dart';

// =======================================================
// เมนูบัญชี (เลื่อนออกมาจากด้านซ้าย เมื่อกดรูปโปรไฟล์มุมซ้ายบน)
// - หัวเมนู: รูป + ชื่อ + กลุ่ม (กดแล้วเปิดหน้าโปรไฟล์) และปุ่มปิด
// - หมวด: บัญชีและกิจกรรม / กลุ่ม / การซื้อสินค้า / การขายสินค้า / การตั้งค่า
// ปิดได้ด้วยปุ่มปิด แตะด้านนอก หรือปุ่มย้อนกลับ (Drawer ของ Flutter)
// หน้าหลักเป็นคนเปิดหน้าต่าง ๆ (onSelected)
// =======================================================

enum AccountMenuItem {
  profile,
  history,
  savedPosts,
  family,
  notifications,
  orders,
  savedProducts,
  addresses,
  shop,
  settings,
  help,
  logout,
}

class AccountDrawer extends StatefulWidget {
  // ผลจาก GET /api/profile (user, family, role, stats, shop) — ยังไม่โหลดก็ได้
  final Map<String, dynamic>? profile;

  // ชื่อที่รู้อยู่แล้ว ใช้ระหว่างรอโหลดโปรไฟล์
  final String fallbackName;

  // ตัวเลขเดียวกับกระดิ่งบนหน้าหลัก (หน้าหลักเป็นคนโหลด)
  final int unreadNotifications;

  // คำสั่งซื้อรอชำระเงิน (0 = ไม่แสดง)
  final int ordersToPay;

  final ValueChanged<AccountMenuItem> onSelected;

  const AccountDrawer({
    super.key,
    required this.profile,
    required this.fallbackName,
    required this.unreadNotifications,
    this.ordersToPay = 0,
    required this.onSelected,
  });

  @override
  State<AccountDrawer> createState() => _AccountDrawerState();
}

class _AccountDrawerState extends State<AccountDrawer> {
  // แถบเลื่อนของเมนู (ไม่ใช้ตัวเลื่อนหลักของหน้า)
  final ScrollController scrollController = ScrollController();

  Map<String, dynamic>? get profile => widget.profile;

  Map<String, dynamic> get user {
    final dynamic value = profile?['user'];

    return value is Map
        ? Map<String, dynamic>.from(value)
        : {'name': widget.fallbackName};
  }

  String get name {
    final String text = user['name']?.toString().trim() ?? '';

    return text.isEmpty ? widget.fallbackName : text;
  }

  bool get hasFamily => profile?['family'] is Map;

  // ยังโหลดโปรไฟล์ไม่เสร็จ → ไม่บอกว่า "ยังไม่มีกลุ่ม/ร้าน" ก่อน
  bool get loaded => profile != null;

  bool get hasShop => profile?['shop'] is Map;

  String? get familyLine {
    final dynamic family = profile?['family'];

    if (family is! Map) return loaded ? 'ยังไม่มีกลุ่ม' : null;

    final String role = profile?['role'] == 'owner' ? 'เจ้าของกลุ่ม' : 'สมาชิก';

    return '${family['name']} • $role';
  }

  // ปิดเมนูก่อน แล้วค่อยให้หน้าหลักเปิดหน้าที่เลือก
  void select(AccountMenuItem item) {
    Navigator.of(context).pop();

    widget.onSelected(item);
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildHeader() {
    final String? family = familyLine;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        8,
        MediaQuery.of(context).padding.top + 10,
        4,
        12,
      ),
      // ธีมมีภาพหัว → วางใต้ชื่อ (ภาพของธีมออกแบบให้ตัวหนังสืออ่านชัด)
      decoration: BoxDecoration(
        color: AppColors.softPrimary,
        image: switch (AppTheming.decor.header(AppColors.isDark)) {
          final String path => DecorationImage(
            image: FileImage(File(path)),
            fit: BoxFit.cover,
            alignment: Alignment.topRight,
            onError: (error, stackTrace) {},
          ),
          null => null,
        },
      ),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => select(AccountMenuItem.profile),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      UserAvatar(user: user, radius: 24, showBorder: true),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.navy,
                                fontSize: 17,
                                height: 1.25,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (family != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                family,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'ปิดเมนู',
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close_rounded, color: AppColors.navy),
          ),
        ],
      ),
    );
  }

  Widget buildItem({
    required AccountMenuItem item,
    required IconData icon,
    required String title,
    String? subtitle,
    Color? color,
    int badge = 0,
    bool danger = false,
  }) {
    final Color iconColor = danger ? AppColors.danger : AppColors.primary;

    return ListTile(
      onTap: () => select(item),
      minTileHeight: 52,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18),
      leading: Icon(icon, color: iconColor, size: 24),
      minLeadingWidth: 28,
      title: Text(
        title,
        style: TextStyle(
          color: danger ? AppColors.danger : AppColors.navy,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(color: AppColors.subtle, fontSize: 12.5),
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (badge > 0)
            Semantics(
              label: 'ยังไม่ได้อ่าน $badge รายการ',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  badge > 99 ? '99+' : '$badge',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          const SizedBox(width: 2),
          Icon(Icons.chevron_right_rounded, color: AppColors.muted),
        ],
      ),
    );
  }

  // หัวข้อหมวดเล็ก ๆ + เส้นคั่นบาง ๆ (ไม่ทำกรอบแยกทุกหมวด)
  List<Widget> buildSection(
    String label,
    List<Widget> items, {
    bool first = false,
  }) {
    return [
      if (!first)
        Divider(
          height: 17,
          thickness: 1,
          indent: 20,
          endIndent: 20,
          color: AppColors.border,
        ),
      Padding(
        padding: EdgeInsets.fromLTRB(20, first ? 12 : 4, 20, 2),
        child: Text(
          label,
          style: TextStyle(
            color: AppColors.subtle,
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      ...items,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final int toPay = widget.ordersToPay;

    return Drawer(
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          buildHeader(),
          Expanded(
            child: Scrollbar(
              controller: scrollController,
              child: ListView(
                controller: scrollController,
                // เว้นท้ายรายการไม่ให้ชนแถบนำทางของระบบ
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 16,
                ),
                children: [
                  ...buildSection('บัญชีและกิจกรรม', first: true, [
                    buildItem(
                      item: AccountMenuItem.profile,
                      icon: Icons.person_outline_rounded,
                      title: 'โปรไฟล์ของฉัน',
                    ),
                    buildItem(
                      item: AccountMenuItem.history,
                      icon: Icons.history_rounded,
                      title: 'ประวัติการใช้งาน',
                    ),
                    buildItem(
                      item: AccountMenuItem.savedPosts,
                      icon: Icons.bookmark_border_rounded,
                      title: 'โพสต์ที่บันทึก',
                    ),
                    buildItem(
                      item: AccountMenuItem.notifications,
                      icon: Icons.notifications_none_rounded,
                      title: 'การแจ้งเตือน',
                      badge: widget.unreadNotifications,
                    ),
                  ]),
                  ...buildSection('กลุ่ม', [
                    buildItem(
                      item: AccountMenuItem.family,
                      icon: Icons.groups_rounded,
                      title: 'กลุ่มของฉัน',
                      subtitle: loaded && !hasFamily
                          ? 'สร้างหรือเข้าร่วมกลุ่ม'
                          : null,
                      color: AppColors.sky,
                    ),
                  ]),
                  ...buildSection('การซื้อสินค้า', [
                    buildItem(
                      item: AccountMenuItem.orders,
                      icon: Icons.receipt_long_outlined,
                      title: 'คำสั่งซื้อของฉัน',
                      subtitle: toPay > 0 ? 'รอชำระเงิน $toPay รายการ' : null,
                      color: AppColors.market,
                    ),
                    buildItem(
                      item: AccountMenuItem.savedProducts,
                      icon: Icons.bookmark_border_rounded,
                      title: 'สินค้าที่บันทึก',
                      color: AppColors.market,
                    ),
                    buildItem(
                      item: AccountMenuItem.addresses,
                      icon: Icons.location_on_outlined,
                      title: 'ที่อยู่จัดส่ง',
                      color: AppColors.market,
                    ),
                  ]),
                  ...buildSection('การขายสินค้า', [
                    buildItem(
                      item: AccountMenuItem.shop,
                      icon: hasShop || !loaded
                          ? Icons.storefront_outlined
                          : Icons.add_business_outlined,
                      title: hasShop || !loaded
                          ? 'ร้านค้าของฉัน'
                          : 'เปิดร้านค้า',
                      subtitle: loaded && !hasShop ? 'ลงขายสินค้าในแอป' : null,
                      color: AppColors.market,
                    ),
                  ]),
                  ...buildSection('การตั้งค่า', [
                    buildItem(
                      item: AccountMenuItem.settings,
                      icon: Icons.settings_outlined,
                      title: 'ตั้งค่า',
                      color: AppColors.subtle,
                    ),
                    buildItem(
                      item: AccountMenuItem.help,
                      icon: Icons.support_agent_rounded,
                      title: 'ช่วยเหลือและแจ้งปัญหา',
                      color: AppColors.sky,
                    ),
                    buildItem(
                      item: AccountMenuItem.logout,
                      icon: Icons.logout_rounded,
                      title: 'ออกจากระบบ',
                      color: AppColors.danger,
                      danger: true,
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}
