import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/app_theme.dart';

// =======================================================
// พื้นหลังแชท: ตั้งค่าส่วนตัวต่อ "บัญชี + ห้อง" เก็บในเครื่องนี้เท่านั้น
// - ไม่ซิงก์ข้ามอุปกรณ์ / ไม่ส่งให้สมาชิกคนอื่น / รูปจากเครื่องไม่ถูกอัปโหลด
// - แยกตามรหัสบัญชี → เปลี่ยนบัญชีในเครื่องเดียวกันไม่ปะปน
// - อยู่ต่อหลังปิดเปิดแอป (ไฟล์ JSON + รูปที่คัดลอกไว้ในพื้นที่ของแอป)
// =======================================================

class ChatBackground {
  // color = สีพื้น (ARGB) / preset = พื้นหลังสำเร็จรูป / image = รูปจากเครื่อง (path ในพื้นที่ของแอป)
  final String kind;
  final String value;

  // ความจางที่ทับพื้นหลัง (0–0.7) ให้อ่านข้อความชัด
  final double dim;

  const ChatBackground({
    required this.kind,
    required this.value,
    this.dim = 0.3,
  });

  ChatBackground copyWith({double? dim}) =>
      ChatBackground(kind: kind, value: value, dim: dim ?? this.dim);

  Map<String, dynamic> toJson() => {'kind': kind, 'value': value, 'dim': dim};

  static ChatBackground? fromJson(dynamic raw) {
    if (raw is! Map) return null;

    final String? kind = raw['kind']?.toString();
    final String? value = raw['value']?.toString();

    if (kind == null || value == null) return null;

    return ChatBackground(
      kind: kind,
      value: value,
      dim: ((raw['dim'] as num?)?.toDouble() ?? 0.3).clamp(0.0, 0.7),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatBackground &&
      other.kind == kind &&
      other.value == value &&
      other.dim == dim;

  @override
  int get hashCode => Object.hash(kind, value, dim);
}

const List<Color> chatBackgroundColors = [
  Color(0xFFF1F5F9),
  Color(0xFFFEF3C7),
  Color(0xFFDCFCE7),
  Color(0xFFDBEAFE),
  Color(0xFFFCE7F3),
  Color(0xFFEDE9FE),
  Color(0xFF1F2937),
  Color(0xFF0F172A),
];

const Map<String, ({String name, List<Color> colors})> chatBackgroundPresets = {
  'sky': (name: 'ท้องฟ้า', colors: [Color(0xFFBFDBFE), Color(0xFFEDE9FE)]),
  'sunset': (
    name: 'พระอาทิตย์ตก',
    colors: [Color(0xFFFED7AA), Color(0xFFFBCFE8)],
  ),
  'forest': (name: 'ป่าเขียว', colors: [Color(0xFFBBF7D0), Color(0xFFD9F99D)]),
  'night': (name: 'กลางคืน', colors: [Color(0xFF1E293B), Color(0xFF4C1D95)]),
};

class ChatBackgroundStore {
  static Map<String, dynamic>? _cache;

  @visibleForTesting
  static Directory? testDirectory;

  @visibleForTesting
  static void forgetCache() => _cache = null;

  static Future<Directory> _dir() async =>
      testDirectory ?? await getApplicationSupportDirectory();

  static Future<File> _file() async =>
      File('${(await _dir()).path}/chat_backgrounds.json');

  static String keyOf(int userId, String room) => '$userId|$room';

  static Future<Map<String, dynamic>> _all() async {
    final Map<String, dynamic>? cached = _cache;

    if (cached != null) return cached;

    Map<String, dynamic> all = {};

    try {
      final File file = await _file();

      if (await file.exists()) {
        final dynamic decoded = jsonDecode(await file.readAsString());

        if (decoded is Map) all = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // ไฟล์เสีย → เริ่มใหม่ (พื้นหลังกลับเป็นค่าเริ่มต้น)
    }

    return _cache = all;
  }

  static Future<void> _write(Map<String, dynamic> all) async {
    final File file = await _file();

    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(all), flush: true);
  }

  // บัญชีนี้ตั้งพื้นหลังแชทเองไว้บ้างหรือไม่ (ถามก่อนใช้พื้นหลังของธีมแทน)
  static Future<bool> hasAnyFor(int userId) async {
    final Map<String, dynamic> all = await _all();

    return all.keys.any((key) => key.startsWith('$userId|'));
  }

  static Future<ChatBackground?> load(int userId, String room) async {
    final ChatBackground? background = ChatBackground.fromJson(
      (await _all())[keyOf(userId, room)],
    );

    // รูปถูกลบไปแล้ว → ใช้ค่าเริ่มต้น
    if (background?.kind == 'image' && !File(background!.value).existsSync()) {
      return null;
    }

    return background;
  }

  // รูปจากเครื่อง: คัดลอกเก็บในพื้นที่ของแอป (ไม่อัปโหลด) / รูปเดิมของห้องนี้ลบทิ้ง
  static Future<ChatBackground> save(
    int userId,
    String room,
    ChatBackground background,
  ) async {
    final Map<String, dynamic> all = await _all();
    final String key = keyOf(userId, room);
    final ChatBackground? old = ChatBackground.fromJson(all[key]);
    final String base = (await _dir()).path;
    ChatBackground stored = background;

    if (background.kind == 'image' && !background.value.startsWith(base)) {
      final Directory dir = Directory('$base/chat_backgrounds');

      await dir.create(recursive: true);

      final File copy = await File(background.value).copy(
        '${dir.path}/${userId}_${room.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );

      stored = ChatBackground(
        kind: 'image',
        value: copy.path,
        dim: background.dim,
      );
    }

    if (old != null && old.kind == 'image' && old.value != stored.value) {
      await _deleteQuietly(old.value);
    }

    all[key] = stored.toJson();
    await _write(all);

    return stored;
  }

  static Future<void> reset(int userId, String room) async {
    final Map<String, dynamic> all = await _all();
    final ChatBackground? old = ChatBackground.fromJson(
      all.remove(keyOf(userId, room)),
    );

    if (old?.kind == 'image') await _deleteQuietly(old!.value);

    await _write(all);
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final File file = File(path);

      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

// ชั้นพื้นหลังใต้รายการข้อความ (ความจางทับด้วยสีพื้นของแอป → อ่านง่ายทั้งโหมดสว่าง/มืด)
class ChatBackgroundLayer extends StatelessWidget {
  final ChatBackground? background;

  const ChatBackgroundLayer({super.key, required this.background});

  @override
  Widget build(BuildContext context) {
    final ChatBackground? value = background;

    if (value == null) return const SizedBox.shrink();

    final Widget base = switch (value.kind) {
      'color' => ColoredBox(
        color: Color(int.tryParse(value.value) ?? 0xFFF1F5F9),
      ),
      'preset' => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors:
                chatBackgroundPresets[value.value]?.colors ??
                const [Color(0xFFF1F5F9), Color(0xFFF1F5F9)],
          ),
        ),
      ),
      _ => Image.file(
        File(value.value),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      ),
    };

    return ExcludeSemantics(
      child: Stack(
        fit: StackFit.expand,
        children: [
          base,
          ColoredBox(color: AppColors.background.withValues(alpha: value.dim)),
        ],
      ),
    );
  }
}
