import 'dart:io';

import 'package:flutter/material.dart';

import 'app_theme.dart';

// =======================================================
// รายละเอียดของธีม (สี / ความโค้ง / ชุดไอคอน / ภาพตกแต่ง)
//
// - ธีมเริ่มต้น Lavender Original อยู่ในแอป (ฟรี ใช้ได้เสมอ ไม่ต้องดาวน์โหลด)
// - ธีมอื่นมาจากชุดธีมที่ดาวน์โหลด: pack.json (ข้อมูลล้วน ไม่มีโค้ด) + ไฟล์ภาพ
// - ค่าใดในไฟล์ธีมขาด/ผิดรูปแบบ → ใช้ค่าของ Lavender แทน (ธีมเก่าใช้กับแอปใหม่ได้)
// =======================================================

enum ThemeIconStyle { rounded, outlined, sharp }

// ช่องไอคอนที่ธีมเปลี่ยนรูปได้ (ความหมายต้องเหมือนเดิม: บ้าน = หน้าหลัก ฯลฯ)
enum ThemeSlot {
  home('nav_home'),
  shop('nav_shop'),
  group('nav_group'),
  map('nav_map'),
  activity('nav_activity'),
  search('search'),
  chat('chat'),
  bell('bell');

  final String key;

  const ThemeSlot(this.key);
}

// ไฟล์ภาพตกแต่ง (path เต็มในเครื่อง หลังตรวจไฟล์แล้ว)
class ThemeDecor {
  final String? backgroundLight;
  final String? backgroundDark;

  final String? headerLight;
  final String? headerDark;

  // ภาพประกอบหน้าว่าง (ยังไม่มีข้อมูล)
  final String? emptyArt;

  final String? chatLight;
  final String? chatDark;

  // ไอคอนเฉพาะธีม: ภาพขาวพื้นใส ระบายสีตามสถานะในแอป
  final Map<ThemeSlot, String> icons;

  const ThemeDecor({
    this.backgroundLight,
    this.backgroundDark,
    this.headerLight,
    this.headerDark,
    this.emptyArt,
    this.chatLight,
    this.chatDark,
    this.icons = const {},
  });

  static const ThemeDecor none = ThemeDecor();

  String? background(bool dark) => dark ? backgroundDark : backgroundLight;

  String? header(bool dark) => dark ? headerDark : headerLight;

  String? chat(bool dark) => dark ? chatDark : chatLight;

  bool get hasChatBackground => chatLight != null || chatDark != null;
}

class AppThemeSpec {
  // รหัสธีมฟรีที่ติดมากับแอป
  static const String freeId = 'lavender-original';

  // รูปแบบไฟล์ธีมที่แอปรุ่นนี้อ่านได้
  static const int supportedFormat = 1;

  final String id;
  final int version;
  final String name;

  // null = ธีมนี้ไม่มีโหมดนั้น (เช่น ธีมอวกาศมีแต่โหมดมืด)
  final AppPalette? light;
  final AppPalette? dark;

  final double cornerScale;
  final ThemeIconStyle iconStyle;
  final ThemeDecor decor;

  const AppThemeSpec({
    required this.id,
    required this.version,
    required this.name,
    required this.light,
    required this.dark,
    this.cornerScale = 1,
    this.iconStyle = ThemeIconStyle.rounded,
    this.decor = ThemeDecor.none,
  }) : assert(light != null || dark != null);

  static const AppThemeSpec lavender = AppThemeSpec(
    id: freeId,
    version: 1,
    name: 'Lavender Original',
    light: AppPalette.light,
    dark: AppPalette.dark,
  );

  bool get isFree => id == freeId;

  bool get supportsLight => light != null;

  bool get supportsDark => dark != null;

  // โหมดที่ขอ ถ้าธีมไม่มี → ใช้โหมดที่ธีมมี
  Brightness resolve(Brightness requested) {
    if (requested == Brightness.dark && dark == null) return Brightness.light;
    if (requested == Brightness.light && light == null) return Brightness.dark;

    return requested;
  }

  AppPalette paletteFor(Brightness requested) =>
      resolve(requested) == Brightness.dark ? dark! : light!;

  // =====================================================
  // อ่าน pack.json ของชุดธีมที่ดาวน์โหลดและตรวจไฟล์แล้ว
  // dir = โฟลเดอร์ของชุดธีมนี้ในเครื่อง
  // ไฟล์ที่อ้างถึงต้องอยู่ในรายการ assets (ผ่านการตรวจขนาด/ชนิด/sha256 ตอนดาวน์โหลด)
  // =====================================================

  static AppThemeSpec fromManifest(Map<String, dynamic> manifest, String dir) {
    final int format = (manifest['format'] as num?)?.toInt() ?? 0;

    if (format < 1 || format > supportedFormat) {
      throw const FormatException('unsupported theme format');
    }

    final String id = manifest['slug']?.toString() ?? '';

    if (!safeSlug.hasMatch(id)) {
      throw const FormatException('bad theme slug');
    }

    final Set<String> files = {
      for (final dynamic asset in manifest['assets'] as List? ?? const [])
        if (asset is Map && isSafeAssetPath(asset['path'])) asset['path'],
    };

    String? file(dynamic name) {
      if (name is! String || !files.contains(name)) return null;

      return '$dir${Platform.pathSeparator}${name.replaceAll('/', Platform.pathSeparator)}';
    }

    final Map<String, dynamic> modes = asMap(manifest['modes']);

    final AppPalette? light = modes['light'] is Map
        ? AppPalette.fromTokens(
            asMap(modes['light']),
            fallback: AppPalette.light,
          )
        : null;

    final AppPalette? dark = modes['dark'] is Map
        ? AppPalette.fromTokens(asMap(modes['dark']), fallback: AppPalette.dark)
        : null;

    if (light == null && dark == null) {
      throw const FormatException('theme has no colors');
    }

    final Map<String, dynamic> shape = asMap(manifest['shape']);

    final double corner = ((shape['corner_scale'] as num?)?.toDouble() ?? 1)
        .clamp(0.4, 1.6);

    final Map<String, dynamic> icons = asMap(manifest['icons']);

    final ThemeIconStyle style = ThemeIconStyle.values.firstWhere(
      (value) => value.name == icons['style'],
      orElse: () => ThemeIconStyle.rounded,
    );

    final Map<String, dynamic> iconFiles = asMap(icons['files']);

    final Map<String, dynamic> decor = asMap(manifest['decor']);
    final Map<String, dynamic> background = asMap(decor['background']);
    final Map<String, dynamic> header = asMap(decor['header']);
    final Map<String, dynamic> chat = asMap(decor['chat_background']);

    return AppThemeSpec(
      id: id,
      version: (manifest['version'] as num?)?.toInt() ?? 1,
      name: manifest['name']?.toString() ?? id,
      light: light,
      dark: dark,
      cornerScale: corner,
      iconStyle: style,
      decor: ThemeDecor(
        backgroundLight: file(background['light']),
        backgroundDark: file(background['dark']),
        headerLight: file(header['light']),
        headerDark: file(header['dark']),
        emptyArt: file(decor['empty']),
        chatLight: file(chat['light']),
        chatDark: file(chat['dark']),
        icons: {
          for (final ThemeSlot slot in ThemeSlot.values)
            if (file(iconFiles[slot.key]) case final String path) slot: path,
        },
      ),
    );
  }

  static final RegExp safeSlug = RegExp(r'^[a-z0-9][a-z0-9\-]{1,48}$');

  // ชื่อไฟล์ในชุดธีม: ตัวเล็ก ตัวเลข - _ และโฟลเดอร์ย่อยได้ ห้าม .. / path เต็ม
  static bool isSafeAssetPath(dynamic value) {
    if (value is! String || value.length > 120) return false;

    return RegExp(r'^[a-z0-9_\-]+(/[a-z0-9_\-]+)*\.(png|webp|jpg)$')
        .hasMatch(value);
  }

  static Map<String, dynamic> asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};
}
