import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

// =======================================================
// หมวดหมู่ของโพสต์ชุมชน
// key ต้องตรงกับ Post::CATEGORIES ใน Laravel
// =======================================================

class PostCategory {
  final String key;
  final String label;
  final IconData icon;
  final Color color;

  const PostCategory({
    required this.key,
    required this.label,
    required this.icon,
    required this.color,
  });
}

List<PostCategory> postCategories = [
  PostCategory(
    key: 'general',
    label: 'ทั่วไป',
    icon: Icons.forum_outlined,
    color: AppColors.muted,
  ),
  PostCategory(
    key: 'qa',
    label: 'ถาม-ตอบ',
    icon: Icons.help_outline_rounded,
    color: Color(0xFF7A5AF8),
  ),
  PostCategory(
    key: 'news',
    label: 'ข่าวสาร',
    icon: Icons.campaign_outlined,
    color: Color(0xFFDC6803),
  ),
  PostCategory(
    key: 'help',
    label: 'ช่วยเหลือ',
    icon: Icons.volunteer_activism_outlined,
    color: Color(0xFF0E9384),
  ),
  PostCategory(
    key: 'event',
    label: 'กิจกรรม',
    icon: Icons.event_outlined,
    color: Color(0xFF2E90FA),
  ),
];

// หาหมวดจาก key (ไม่รู้จัก / null → null)
PostCategory? findPostCategory(dynamic key) {
  for (final category in postCategories) {
    if (category.key == key) {
      return category;
    }
  }

  return null;
}

// สีฝั่งชุมชน = สีหลักของแอป (Lavender)
Color get communityAccentColor => AppColors.primary;

// =======================================================
// แถวกรองฟีดชุมชนตามหมวด ("ทั้งหมด" + หมวดต่าง ๆ) เลื่อนซ้าย-ขวาได้
// selected = null → ทั้งหมด
// =======================================================

class CategoryFilterStrip extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onChanged;
  final EdgeInsetsGeometry padding;

  const CategoryFilterStrip({
    super.key,
    required this.selected,
    required this.onChanged,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final List<Widget> chips = [
      CategoryChoiceChip(
        label: 'ทั้งหมด',
        icon: Icons.apps_rounded,
        color: communityAccentColor,
        selected: selected == null,
        onTap: () => onChanged(null),
      ),
      for (final category in postCategories)
        CategoryChoiceChip(
          label: category.label,
          icon: category.icon,
          color: category.color,
          selected: selected == category.key,
          onTap: () => onChanged(category.key),
        ),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (int i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );
  }
}

// =======================================================
// ชิปเลือกหมวด (ใช้ทั้งกล่องโพสต์และตัวกรองฟีด)
// =======================================================

class CategoryChoiceChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const CategoryChoiceChip({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected ? Colors.white : AppColors.navy;

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            constraints: const BoxConstraints(minHeight: 40),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: selected ? AppColors.primary : AppColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected ? AppColors.primary : AppColors.border,
              ),
            ),
            // ตัวหนังสืออย่างเดียว (Lavender) — สีหมวดยังใช้ที่ป้ายบนการ์ดโพสต์
            child: Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =======================================================
// ป้ายหมวดเล็ก ๆ บนการ์ดโพสต์
// =======================================================

class CategoryBadge extends StatelessWidget {
  final PostCategory category;

  const CategoryBadge({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: category.color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(category.icon, size: 12, color: category.color),
          const SizedBox(width: 4),
          Text(
            category.label,
            style: TextStyle(
              color: category.color,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
