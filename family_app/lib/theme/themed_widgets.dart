import 'dart:io';

import 'package:flutter/material.dart';

import '../services/chat_background_store.dart';
import 'app_theme.dart';
import 'app_theming.dart';
import 'theme_spec.dart';

// =======================================================
// ส่วนประกอบที่เปลี่ยนตามธีม (อ่านจาก AppTheming อย่างเดียว ไม่เช็กชื่อธีม)
// ภาพตกแต่งทั้งหมดซ่อนจากโปรแกรมอ่านหน้าจอ และไม่รับการแตะ
// =======================================================

// ไอคอนตามธีม: มีไฟล์ไอคอนของธีม → ใช้ภาพนั้น / ไม่มี → ไอคอนระบบตามสไตล์ของธีม
class ThemedIcon extends StatelessWidget {
  final ThemeSlot slot;
  final bool selected;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  const ThemedIcon(
    this.slot, {
    super.key,
    this.selected = false,
    this.size,
    this.color,
    this.semanticLabel,
  });

  static IconData material(
    ThemeSlot slot,
    ThemeIconStyle style,
    bool selected,
  ) {
    // [ไม่ได้เลือก, เลือก(rounded), เลือก(outlined), เลือก(sharp)]
    final List<IconData> set = switch (slot) {
      ThemeSlot.home => const [
        Icons.home_outlined,
        Icons.home_rounded,
        Icons.home,
        Icons.home_sharp,
      ],
      ThemeSlot.shop => const [
        Icons.shopping_basket_outlined,
        Icons.shopping_basket_rounded,
        Icons.shopping_basket,
        Icons.shopping_basket_sharp,
      ],
      ThemeSlot.group => const [
        Icons.groups_outlined,
        Icons.groups_rounded,
        Icons.groups,
        Icons.groups_sharp,
      ],
      ThemeSlot.map => const [
        Icons.location_on_outlined,
        Icons.location_on_rounded,
        Icons.location_on,
        Icons.location_on_sharp,
      ],
      ThemeSlot.activity => const [
        Icons.event_note_outlined,
        Icons.event_note_rounded,
        Icons.event_note,
        Icons.event_note_sharp,
      ],
      ThemeSlot.search => const [
        Icons.search_rounded,
        Icons.search_rounded,
        Icons.search,
        Icons.search_sharp,
      ],
      ThemeSlot.chat => const [
        Icons.chat_bubble_outline_rounded,
        Icons.chat_bubble_rounded,
        Icons.chat_bubble_outline,
        Icons.chat_bubble_outline_sharp,
      ],
      ThemeSlot.bell => const [
        Icons.notifications_none_rounded,
        Icons.notifications_rounded,
        Icons.notifications_none,
        Icons.notifications_none_sharp,
      ],
    };

    if (!selected) {
      // ไอคอนบนหัว (ค้นหา/แชท/กระดิ่ง) ใช้เส้นตามสไตล์ของธีม
      return switch (slot) {
        ThemeSlot.search ||
        ThemeSlot.chat ||
        ThemeSlot.bell => style == ThemeIconStyle.rounded ? set[0] : set[2],
        _ => set[0],
      };
    }

    return switch (style) {
      ThemeIconStyle.rounded => set[1],
      ThemeIconStyle.outlined => set[2],
      ThemeIconStyle.sharp => set[3],
    };
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeSpec spec = AppTheming.effective;

    final String? file = spec.decor.icons[slot];

    final double iconSize = size ?? IconTheme.of(context).size ?? 24;

    if (file != null) {
      return Semantics(
        label: semanticLabel,
        child: ImageIcon(FileImage(File(file)), size: iconSize, color: color),
      );
    }

    return Icon(
      material(slot, spec.iconStyle, selected),
      size: iconSize,
      color: color,
      semanticLabel: semanticLabel,
    );
  }
}

// ภาพจากชุดธีม (ไฟล์หาย/เสีย → ไม่แสดง แอปไม่พัง)
class _DecorImage extends StatelessWidget {
  final String path;
  final BoxFit fit;
  final Alignment alignment;
  final double? height;

  const _DecorImage(
    this.path, {
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);

    return Image.file(
      File(path),
      fit: fit,
      alignment: alignment,
      height: height,
      gaplessPlayback: true,
      // ถอดรหัสภาพเท่าความกว้างจอ (ประหยัดหน่วยความจำ)
      cacheWidth: (media.size.width * media.devicePixelRatio).round().clamp(
        320,
        1440,
      ),
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
    );
  }
}

// พื้นหลังหน้าหลักของธีม (อยู่ใต้การ์ด การ์ดยังทึบ → ตัวหนังสืออ่านชัด)
class ThemeBackdrop extends StatelessWidget {
  const ThemeBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final String? path = AppTheming.decor.background(AppColors.isDark);

    if (path == null) return const SizedBox.shrink();

    return IgnorePointer(child: ExcludeSemantics(child: _DecorImage(path)));
  }
}

// ภาพตกแต่งแถบหัว (หน้าหลัก / เมนูบัญชี) จางลงด้านล่างให้ตัวหนังสืออ่านง่าย
class ThemeHeaderArt extends StatelessWidget {
  const ThemeHeaderArt({super.key});

  @override
  Widget build(BuildContext context) {
    final String? path = AppTheming.decor.header(AppColors.isDark);

    if (path == null) return const SizedBox.shrink();

    return IgnorePointer(
      child: ExcludeSemantics(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.white, Colors.transparent],
            stops: [0, 0.55, 1],
          ).createShader(rect),
          child: _DecorImage(path, alignment: Alignment.topCenter),
        ),
      ),
    );
  }
}

// ภาพประกอบหน้าว่างของธีม / ไม่มี → ใช้แบบเดิมของหน้านั้น (fallback)
class ThemeEmptyArt extends StatelessWidget {
  final Widget fallback;
  final double height;

  const ThemeEmptyArt({super.key, required this.fallback, this.height = 120});

  @override
  Widget build(BuildContext context) {
    final String? path = AppTheming.decor.emptyArt;

    if (path == null) return fallback;

    return ExcludeSemantics(
      child: _DecorImage(path, fit: BoxFit.contain, height: height),
    );
  }
}

// พื้นหลังห้องแชท: พื้นหลังที่ผู้ใช้ตั้งเอง / ของธีม (ตามที่ผู้ใช้เลือกตอนเปิดใช้ธีม)
class ThemedChatBackground extends StatelessWidget {
  final ChatBackground? custom;

  const ThemedChatBackground({super.key, required this.custom});

  @override
  Widget build(BuildContext context) {
    final ChatBackground? mine = custom;

    final String? themed = AppTheming.decor.chat(AppColors.isDark);

    if (mine != null &&
        (themed == null || !AppTheming.preferThemeChatBackground)) {
      return ChatBackgroundLayer(background: mine);
    }

    if (themed == null) return const SizedBox.shrink();

    return IgnorePointer(child: ExcludeSemantics(child: _DecorImage(themed)));
  }
}
