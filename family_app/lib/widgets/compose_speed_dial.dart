import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_theme.dart';

// =======================================================
// ปุ่ม ＋ แบบขยาย (เมนูสร้างโพสต์)
//
// - เปิดเป็น route โปร่งใสทับทั้งจอ: พื้นหลังมืดลง + กดด้านหลังไม่ได้
// - ปิดได้ 3 ทาง: แตะด้านนอก / กด × / ปุ่มย้อนกลับ (ปิดเมนูก่อน ไม่ออกจากหน้า)
// - ＋ หมุนเป็น × ที่ตำแหน่งเดิมของปุ่ม รายการเลื่อนขึ้นทีละอันเหนือปุ่ม (ไม่ชนแถบล่าง)
// - คืนค่าเป็นตัวเลือกที่กด (null = ปิดเฉย ๆ) — หน้าที่เรียกเป็นคนเปิดขั้นตอนสร้างโพสต์เดิม
// - ลดการเคลื่อนไหว → แสดง/ปิดทันที, route ปิดแล้วไม่รับ focus/การกดอีก
// =======================================================

enum ComposeAction { text, photo, video }

class ComposeMenuItem {
  final ComposeAction action;
  final IconData icon;
  final String label;

  const ComposeMenuItem(this.action, this.icon, this.label);
}

Future<ComposeAction?> showComposeMenu(
  BuildContext context, {
  required Rect anchor,
  required List<ComposeMenuItem> items,
  required String audience,
  required Color color,
}) {
  return showGeneralDialog<ComposeAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'ปิดเมนูสร้างโพสต์',
    barrierColor: Colors.black.withValues(alpha: 0.36),
    transitionDuration: AppMotion.of(context, AppMotion.panel),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _ComposeMenu(
        anchor: anchor,
        items: items,
        audience: audience,
        color: color,
        animation: animation,
      );
    },
    // แต่ละส่วนขยับเองจาก animation (พื้นหลังมืดจางเข้าเองจาก barrier)
    transitionBuilder: (context, animation, secondaryAnimation, child) => child,
  );
}

class _ComposeMenu extends StatelessWidget {
  final Rect anchor;
  final List<ComposeMenuItem> items;
  final String audience;
  final Color color;
  final Animation<double> animation;

  const _ComposeMenu({
    required this.anchor,
    required this.items,
    required this.audience,
    required this.color,
    required this.animation,
  });

  // รายการที่ i (นับจากปุ่ม) เริ่มขยับหลังรายการก่อนหน้าเล็กน้อย
  Animation<double> itemAnimation(int fromButton) {
    final double total = AppMotion.panel.inMilliseconds.toDouble();
    final double start = math.min(
      0.5,
      fromButton * AppMotion.stagger.inMilliseconds / total,
    );

    return CurvedAnimation(
      parent: animation,
      curve: Interval(start, math.min(1, start + 0.6), curve: AppMotion.enter),
      reverseCurve: AppMotion.exit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);

    final double right = math.max(8, media.size.width - anchor.right);
    final double bottom = media.size.height - anchor.top + 14;
    final double maxHeight = math.max(140, anchor.top - media.padding.top - 24);

    final List<Widget> rows = [];

    for (int i = items.length - 1; i >= 0; i--) {
      final Animation<double> a = itemAnimation(i + 1);

      rows.add(
        FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.35),
              end: Offset.zero,
            ).animate(a),
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _MenuRow(item: items[i], color: color),
            ),
          ),
        ),
      );
    }

    final Animation<double> header = itemAnimation(items.length + 1);

    return Stack(
      children: [
        Positioned(
          right: right,
          bottom: bottom,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxHeight,
              maxWidth: media.size.width - right - 16,
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // ผู้ชมโพสต์ (ให้เห็นก่อนเลือก)
                  FadeTransition(
                    opacity: header,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        audience,
                        style: TextStyle(
                          color: AppColors.subtle,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  ...rows,
                ],
              ),
            ),
          ),
        ),
        // ＋ → × ที่ตำแหน่งเดิมของปุ่ม
        Positioned.fromRect(
          rect: anchor,
          child: Tooltip(
            message: 'ปิดเมนูสร้างโพสต์',
            child: Semantics(
              button: true,
              label: 'ปิดเมนูสร้างโพสต์',
              excludeSemantics: true,
              child: Material(
                color: color,
                shape: const CircleBorder(),
                elevation: 6,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Center(
                    child: RotationTransition(
                      turns: Tween<double>(begin: 0, end: 0.125).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: AppMotion.enter,
                          reverseCurve: AppMotion.exit,
                        ),
                      ),
                      child: Icon(
                        Icons.add_rounded,
                        size: 30,
                        color: AppColors.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  final ComposeMenuItem item;
  final Color color;

  const _MenuRow({required this.item, required this.color});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: () => Navigator.of(context).pop(item.action),
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Material(
                    color: AppColors.surface,
                    elevation: 3,
                    shadowColor: Colors.black26,
                    borderRadius: AppShapes.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Text(
                        item.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Material(
                  color: AppColors.surface,
                  shape: const CircleBorder(),
                  elevation: 3,
                  shadowColor: Colors.black26,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(item.icon, color: color, size: 24),
                  ),
                ),
                // จัดให้วงกลมอยู่แนวเดียวกับกลางปุ่ม ＋ (ปุ่มกว้าง 56)
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
