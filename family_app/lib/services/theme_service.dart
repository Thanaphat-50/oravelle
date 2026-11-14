import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../config/api_config.dart';
import '../theme/app_theme.dart';
import '../theme/app_theming.dart';
import '../theme/theme_spec.dart';
import 'api_helper.dart';
import 'app_log.dart';
import 'auth_service.dart';

// =======================================================
// ธีมและการตกแต่ง (ฝั่งแอป)
//
// - แค็ตตาล็อก + สิทธิ์มาจากเซิร์ฟเวอร์เท่านั้น (แก้ค่าในเครื่องไม่ทำให้ได้สิทธิ์)
// - สิทธิ์ซิงก์ตามบัญชี / ธีมที่กำลังใช้เลือกแยกในแต่ละเครื่อง (เก็บต่อบัญชีในเครื่องนี้)
// - ชุดธีม = pack.json (ข้อมูลล้วน) + ภาพ: ดาวน์โหลดครบ ตรวจขนาด/ชนิด/sha256 ก่อน แล้วค่อยสลับธีม
//   ล้มเหลว → ใช้ธีมเดิมต่อ ไม่มีไฟล์ครึ่ง ๆ กลาง ๆ
// - ออฟไลน์: ธีมเสียเงินใช้ต่อได้ไม่เกิน offline_grace_days นับจากตรวจสิทธิ์สำเร็จครั้งล่าสุด
//   (เพิกถอนสิทธิ์จะมีผลเมื่อเครื่องออนไลน์และตรวจสิทธิ์ใหม่ ไม่ทันทีบนเครื่องที่ออฟไลน์)
// - ไฟล์ทั้งหมดอยู่ในพื้นที่ของแอป แยกโฟลเดอร์ต่อบัญชี: themes/u<id>/
// =======================================================

class ThemeException implements Exception {
  final String message;

  const ThemeException(this.message);

  @override
  String toString() => message;
}

class ThemePreview {
  final String name;
  final String url;

  const ThemePreview(this.name, this.url);

  String get label => switch (name) {
    'feed' => 'ฟีด',
    'chat' => 'แชท',
    'shop' => 'ร้านค้า',
    'profile' => 'โปรไฟล์',
    'activity' => 'กิจกรรม',
    'map' => 'ตำแหน่ง',
    _ => name,
  };
}

class ThemeListing {
  final String slug;
  final String name;
  final String description;
  final String category;
  final bool isFree;
  final bool supportsLight;
  final bool supportsDark;
  final List<String> changes;
  final List<ThemePreview> previews;
  final int? version;
  final int? minAppBuild;
  final int? packBytes;
  final String? productId;
  final String? testPrice;
  final bool owned;
  final String? revokeReason;

  // สีตัวอย่างบนการ์ดในร้าน [หลัก, พื้นหลัง, การ์ด, สีอ่อน]
  final List<Color> swatch;

  const ThemeListing({
    required this.slug,
    required this.name,
    required this.description,
    required this.category,
    required this.isFree,
    required this.supportsLight,
    required this.supportsDark,
    required this.changes,
    required this.previews,
    required this.version,
    required this.minAppBuild,
    required this.packBytes,
    required this.productId,
    required this.testPrice,
    required this.owned,
    required this.revokeReason,
    this.swatch = const [],
  });

  factory ThemeListing.fromJson(Map<String, dynamic> json) {
    final dynamic entitlement = json['entitlement'];

    return ThemeListing(
      slug: json['slug']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      category: json['category']?.toString() ?? 'simple',
      isFree: json['is_free'] == true,
      supportsLight: json['supports_light'] != false,
      supportsDark: json['supports_dark'] != false,
      changes: [
        for (final dynamic item in json['changes'] as List? ?? const [])
          item.toString(),
      ],
      previews: [
        for (final dynamic item in json['previews'] as List? ?? const [])
          if (item is Map && item['url'] is String)
            ThemePreview(item['name'].toString(), item['url'] as String),
      ],
      version: (json['version'] as num?)?.toInt(),
      minAppBuild: (json['min_app_build'] as num?)?.toInt(),
      packBytes: (json['pack_bytes'] as num?)?.toInt(),
      productId: json['product_id']?.toString(),
      testPrice: json['test_price'] is Map
          ? json['test_price']['formatted']?.toString()
          : null,
      owned: json['owned'] == true,
      revokeReason: entitlement is Map && entitlement['active'] != true
          ? entitlement['revoke_reason']?.toString()
          : null,
      swatch: [
        for (final dynamic hex in json['swatch'] as List? ?? const [])
          if (AppPalette.parseColor(hex) case final Color color) color,
      ],
    );
  }

  bool get builtIn => slug == AppThemeSpec.freeId;

  String get modesLabel => supportsLight && supportsDark
      ? 'สว่าง • มืด'
      : (supportsDark ? 'เฉพาะโหมดมืด' : 'เฉพาะโหมดสว่าง');

  static String categoryLabel(String category) => switch (category) {
    'simple' => 'เรียบง่าย',
    'nature' => 'ธรรมชาติ',
    'dark' => 'โหมดมืด',
    _ => category,
  };

  static String revokeReasonLabel(String? reason) => switch (reason) {
    'refunded' => 'มีการคืนเงิน',
    'chargeback' => 'มีการปฏิเสธการชำระเงิน',
    'cancelled' => 'การชำระเงินถูกยกเลิก',
    'revoked' => 'ผู้ให้บริการเพิกถอนสิทธิ์',
    _ => 'สิทธิ์ถูกยกเลิก',
  };
}

class ThemeCatalog {
  // google_play / test / null (ยังไม่เปิดขาย)
  final String? provider;
  final String accountRef;
  final int offlineGraceDays;
  final List<ThemeListing> themes;

  const ThemeCatalog({
    required this.provider,
    required this.accountRef,
    required this.offlineGraceDays,
    required this.themes,
  });

  bool get testMode => provider == 'test';

  ThemeListing? bySlug(String slug) {
    for (final ThemeListing theme in themes) {
      if (theme.slug == slug) return theme;
    }

    return null;
  }

  ThemeListing? byProduct(String productId) {
    for (final ThemeListing theme in themes) {
      if (theme.productId == productId) return theme;
    }

    return null;
  }
}

// สถานะดาวน์โหลดชุดธีม (progress 0..1, error = ข้อความล้มเหลว)
class ThemeDownload {
  final double progress;
  final String? error;

  const ThemeDownload({this.progress = 0, this.error});

  bool get failed => error != null;
}

// ผลการซื้อ/ตรวจการซื้อ
class ThemeBuyResult {
  // purchased / pending / cancelled / refunded / error
  final String status;
  final String message;
  final bool acknowledged;

  const ThemeBuyResult(this.status, this.message, {this.acknowledged = true});

  bool get purchased => status == 'purchased';
}

class ThemeService {
  static const String baseUrl = ApiConfig.baseUrl;

  // จำกัดชุดธีม (กันไฟล์ใหญ่ผิดปกติ)
  static const int maxFileBytes = 4 * 1024 * 1024;
  static const int maxPackBytes = 12 * 1024 * 1024;
  static const int maxFiles = 40;

  static final ValueNotifier<ThemeCatalog?> catalog = ValueNotifier(null);

  static final ValueNotifier<Map<String, ThemeDownload>> downloads =
      ValueNotifier(const {});

  // ข้อความแจ้งผู้ใช้เมื่อธีมถูกเปลี่ยนกลับเป็นธีมฟรีเอง (สิทธิ์ถูกยกเลิก / ออฟไลน์นานเกิน)
  static final ValueNotifier<String?> notice = ValueNotifier(null);

  static int? _userId;

  static Map<String, dynamic> _state = {};

  // ทดสอบ: แทนโฟลเดอร์เก็บไฟล์
  @visibleForTesting
  static Future<Directory> Function()? rootOverride;

  @visibleForTesting
  static int? appBuildOverride;

  // =====================================================
  // ไฟล์ของบัญชี
  // =====================================================

  static Future<Directory> _root() async {
    final Directory base =
        await (rootOverride?.call() ?? getApplicationSupportDirectory());

    return Directory('${base.path}${Platform.pathSeparator}themes');
  }

  static Future<Directory> _accountDir(int userId) async {
    final Directory root = await _root();

    return Directory('${root.path}${Platform.pathSeparator}u$userId');
  }

  static Future<File> _stateFile(int userId) async => File(
    '${(await _accountDir(userId)).path}${Platform.pathSeparator}state.json',
  );

  static Future<Directory> _packDir(
    int userId,
    String slug,
    int version,
  ) async {
    final Directory account = await _accountDir(userId);

    return Directory(
      [account.path, 'packs', slug, 'v$version'].join(Platform.pathSeparator),
    );
  }

  static Future<void> _loadState(int userId) async {
    try {
      final File file = await _stateFile(userId);

      _state = await file.exists()
          ? Map<String, dynamic>.from(
              jsonDecode(await file.readAsString()) as Map,
            )
          : {};
    } catch (_) {
      _state = {};
    }
  }

  static Future<void> _saveState() async {
    final int? userId = _userId;

    if (userId == null) return;

    try {
      final File file = await _stateFile(userId);

      await file.parent.create(recursive: true);

      final File temp = File('${file.path}.tmp');

      await temp.writeAsString(jsonEncode(_state), flush: true);
      await temp.rename(file.path);
    } catch (e) {
      AppLog.warn('Theme state save failed', e);
    }
  }

  static Future<Map<String, String>> _headers() async {
    final token = await AuthService.getToken();

    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  // =====================================================
  // เปิดแอป / เข้าสู่ระบบ: ใช้ธีมของบัญชีนี้ในเครื่องนี้ แล้วตรวจสิทธิ์ใหม่เบื้องหลัง
  // =====================================================

  static Future<void> restoreForCurrentUser() async {
    final int? userId = await AuthService.userId();

    if (userId == null) return;

    if (_userId != userId) {
      _userId = userId;
      catalog.value = null;
      downloads.value = const {};
      await _loadState(userId);
    }

    final String? active = _state['active'] as String?;

    if (active == null || active == AppThemeSpec.freeId) {
      AppTheming.setActive(
        AppThemeSpec.lavender,
        preferThemeChat: _state['prefer_theme_chat'] == true,
      );
    } else if (_withinOfflineGrace(active)) {
      final AppThemeSpec? spec = await _localSpec(
        userId,
        active,
        (_state['active_version'] as num?)?.toInt() ?? 0,
      );

      AppTheming.setActive(
        spec ?? AppThemeSpec.lavender,
        preferThemeChat: _state['prefer_theme_chat'] == true,
      );
    } else {
      // ไม่ได้ตรวจสิทธิ์นานเกินกำหนด → ธีมฟรีจนกว่าจะออนไลน์และตรวจใหม่
      AppTheming.setActive(AppThemeSpec.lavender);
    }

    try {
      await refreshCatalog();
    } catch (_) {
      // ออฟไลน์ → ใช้สถานะในเครื่องตามนโยบายด้านบน
    }
  }

  static bool _withinOfflineGrace(String slug) {
    final Map entitlements = _state['entitlements'] as Map? ?? const {};

    if (entitlements[slug] != true) return false;

    final DateTime? verified = DateTime.tryParse(
      _state['verified_at']?.toString() ?? '',
    );

    final int grace = (_state['grace_days'] as num?)?.toInt() ?? 14;

    return verified != null &&
        DateTime.now().difference(verified) < Duration(days: grace);
  }

  // ออกจากระบบ / เปลี่ยนบัญชี → ล้างค่าในหน่วยความจำ (ไฟล์ของบัญชีเดิมยังอยู่ในโฟลเดอร์ของบัญชีนั้น)
  static void signedOut() {
    _userId = null;
    _state = {};
    catalog.value = null;
    downloads.value = const {};
    notice.value = null;
    AppTheming.reset();
  }

  // =====================================================
  // แค็ตตาล็อก + สิทธิ์ (ตรวจกับเซิร์ฟเวอร์)
  // =====================================================

  static Future<ThemeCatalog> refreshCatalog() async {
    final response = await ApiHelper.request(
      () async =>
          http.get(Uri.parse('$baseUrl/themes'), headers: await _headers()),
    );

    final Map<String, dynamic> data = ApiHelper.decode(response);

    if (data['status'] != true) {
      throw ThemeException(
        data['message']?.toString() ?? 'โหลดร้านธีมไม่สำเร็จ',
      );
    }

    final ThemeCatalog result = ThemeCatalog(
      provider: data['billing'] is Map
          ? data['billing']['provider']?.toString()
          : null,
      accountRef: data['billing'] is Map
          ? data['billing']['account_ref']?.toString() ?? ''
          : '',
      offlineGraceDays: (data['offline_grace_days'] as num?)?.toInt() ?? 14,
      themes: [
        for (final dynamic item in data['themes'] as List? ?? const [])
          if (item is Map)
            ThemeListing.fromJson(Map<String, dynamic>.from(item)),
      ],
    );

    catalog.value = result;

    _state['entitlements'] = {
      for (final ThemeListing theme in result.themes)
        if (!theme.isFree) theme.slug: theme.owned,
    };
    _state['verified_at'] = DateTime.now().toIso8601String();
    _state['grace_days'] = result.offlineGraceDays;

    await _saveState();

    await _enforceEntitlement(result);

    return result;
  }

  // ธีมที่ใช้อยู่ไม่มีสิทธิ์แล้ว (คืนเงิน/เพิกถอน) → กลับธีมฟรี + บอกเหตุผล
  static Future<void> _enforceEntitlement(ThemeCatalog result) async {
    final String? active = _state['active'] as String?;

    if (active == null || active == AppThemeSpec.freeId) return;

    final ThemeListing? theme = result.bySlug(active);

    if (theme != null && (theme.owned || theme.isFree)) {
      await _upgradeActive(theme);

      return;
    }

    _state['active'] = AppThemeSpec.freeId;
    await _saveState();

    AppTheming.setActive(AppThemeSpec.lavender);

    notice.value = theme == null
        ? 'ธีมที่ใช้อยู่ไม่มีให้บริการแล้ว จึงกลับไปใช้ธีมเริ่มต้น'
        : 'สิทธิ์ใช้ธีม ${theme.name} ถูกยกเลิก (${ThemeListing.revokeReasonLabel(theme.revokeReason)}) จึงกลับไปใช้ธีมเริ่มต้น';
  }

  // ธีมที่ใช้อยู่มีเวอร์ชันใหม่ → ดาวน์โหลดครบแล้วค่อยสลับ (ไม่สำเร็จ = ใช้เวอร์ชันเดิมต่อ)
  static Future<void> _upgradeActive(ThemeListing theme) async {
    final int current = (_state['active_version'] as num?)?.toInt() ?? 0;

    if (theme.builtIn || (theme.version ?? 0) <= current) return;

    try {
      final AppThemeSpec spec = await ensurePack(theme);

      _state['active_version'] = spec.version;
      await _saveState();

      AppTheming.setActive(spec);
    } catch (e) {
      AppLog.warn('Theme upgrade failed', e);
    }
  }

  static String? get activeSlug =>
      (_state['active'] as String?) ?? AppThemeSpec.freeId;

  // =====================================================
  // ชุดธีม: ใช้ไฟล์ในเครื่องถ้าครบ / ไม่ครบ → ดาวน์โหลดใหม่ทั้งชุด
  // =====================================================

  static Future<AppThemeSpec?> _localSpec(
    int userId,
    String slug,
    int version,
  ) async {
    if (version < 1) return null;

    try {
      final Directory dir = await _packDir(userId, slug, version);

      final File manifest = File(
        '${dir.path}${Platform.pathSeparator}pack.json',
      );
      final File done = File('${dir.path}${Platform.pathSeparator}.complete');

      if (!await manifest.exists() || !await done.exists()) return null;

      final Map<String, dynamic> data = Map<String, dynamic>.from(
        jsonDecode(await manifest.readAsString()) as Map,
      );

      // ไฟล์ภาพหาย (เช่น ถูกล้างพื้นที่) → ถือว่าไม่ครบ
      for (final dynamic asset in data['assets'] as List? ?? const []) {
        if (asset is! Map || !AppThemeSpec.isSafeAssetPath(asset['path'])) {
          return null;
        }

        final File file = File(
          '${dir.path}${Platform.pathSeparator}${(asset['path'] as String).replaceAll('/', Platform.pathSeparator)}',
        );

        if (!await file.exists() || await file.length() != asset['size']) {
          return null;
        }
      }

      return AppThemeSpec.fromManifest(data, dir.path);
    } catch (e) {
      AppLog.warn('Theme pack unreadable', e);

      return null;
    }
  }

  static Future<int> _appBuild() async {
    if (appBuildOverride != null) return appBuildOverride!;

    try {
      return int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 1;
    } catch (_) {
      return 1;
    }
  }

  static void _setDownload(String slug, ThemeDownload? value) {
    final Map<String, ThemeDownload> next = Map.of(downloads.value);

    if (value == null) {
      next.remove(slug);
    } else {
      next[slug] = value;
    }

    downloads.value = next;
  }

  // trial: ลองธีม (ไม่ต้องมีสิทธิ์) / force: ดาวน์โหลดซ้ำแม้มีไฟล์ครบ
  static Future<AppThemeSpec> ensurePack(
    ThemeListing theme, {
    bool trial = false,
    bool force = false,
  }) async {
    if (theme.builtIn) return AppThemeSpec.lavender;

    final int? userId = _userId ?? await AuthService.userId();

    if (userId == null) throw const ThemeException('กรุณาเข้าสู่ระบบอีกครั้ง');

    final int version = theme.version ?? 0;

    if ((theme.minAppBuild ?? 1) > await _appBuild()) {
      throw const ThemeException(
        'ธีมนี้ต้องใช้แอปเวอร์ชันใหม่กว่า กรุณาอัปเดตแอป',
      );
    }

    if (!force) {
      final AppThemeSpec? local = await _localSpec(userId, theme.slug, version);

      if (local != null) return local;
    }

    _setDownload(theme.slug, const ThemeDownload());

    try {
      final AppThemeSpec spec = await _download(userId, theme, trial: trial);

      _setDownload(theme.slug, null);

      return spec;
    } on ThemeException catch (e) {
      _setDownload(theme.slug, ThemeDownload(error: e.message));
      rethrow;
    } on ApiException catch (e) {
      _setDownload(theme.slug, ThemeDownload(error: e.message));
      throw ThemeException(e.message);
    } catch (e) {
      AppLog.warn('Theme download failed', e);

      const String message =
          'ดาวน์โหลดธีมไม่สำเร็จ ตรวจอินเทอร์เน็ตแล้วลองใหม่';

      _setDownload(theme.slug, const ThemeDownload(error: message));

      throw const ThemeException(message);
    }
  }

  static Future<AppThemeSpec> _download(
    int userId,
    ThemeListing theme, {
    required bool trial,
  }) async {
    final response = await ApiHelper.request(
      () async => http.get(
        Uri.parse(
          '$baseUrl/themes/${theme.slug}/pack?purpose=${trial ? 'trial' : 'use'}',
        ),
        headers: await _headers(),
      ),
    );

    final Map<String, dynamic> data = ApiHelper.decode(response);

    if (data['status'] != true || data['pack'] is! Map) {
      throw ThemeException(
        data['message']?.toString() ?? 'ดาวน์โหลดธีมไม่สำเร็จ',
      );
    }

    final Map<String, dynamic> pack = Map<String, dynamic>.from(
      data['pack'] as Map,
    );

    final int version = (pack['version'] as num?)?.toInt() ?? 0;

    if (pack['slug'] != theme.slug || version < 1) {
      throw const ThemeException('ข้อมูลชุดธีมไม่ถูกต้อง');
    }

    if ((pack['format'] as num?)?.toInt() != AppThemeSpec.supportedFormat) {
      throw const ThemeException(
        'ธีมนี้ต้องใช้แอปเวอร์ชันใหม่กว่า กรุณาอัปเดตแอป',
      );
    }

    final List<Map<String, dynamic>> assets = [
      for (final dynamic item in pack['assets'] as List? ?? const [])
        if (item is Map) Map<String, dynamic>.from(item),
    ];

    final int total = assets.fold(
      0,
      (sum, a) => sum + ((a['size'] as num?)?.toInt() ?? 0),
    );

    if (assets.length > maxFiles || total > maxPackBytes) {
      throw const ThemeException('ชุดธีมมีขนาดใหญ่ผิดปกติ จึงไม่ดาวน์โหลด');
    }

    final Directory target = await _packDir(userId, theme.slug, version);
    final Directory temp = Directory(
      '${target.parent.path}${Platform.pathSeparator}.tmp-${Random().nextInt(1 << 30)}',
    );

    await temp.create(recursive: true);

    try {
      int received = 0;

      for (final Map<String, dynamic> asset in assets) {
        final String path = asset['path']?.toString() ?? '';
        final int size = (asset['size'] as num?)?.toInt() ?? -1;
        final String type = asset['type']?.toString() ?? '';
        final String sha = asset['sha256']?.toString() ?? '';
        final String url = asset['url']?.toString() ?? '';

        if (!AppThemeSpec.isSafeAssetPath(path) ||
            size < 1 ||
            size > maxFileBytes) {
          throw const ThemeException('ไฟล์ในชุดธีมไม่ถูกต้อง');
        }

        final File file = File(
          '${temp.path}${Platform.pathSeparator}${path.replaceAll('/', Platform.pathSeparator)}',
        );

        // กันเขียนไฟล์ออกนอกโฟลเดอร์ชั่วคราว
        if (!file.absolute.path.startsWith(temp.absolute.path)) {
          throw const ThemeException('ไฟล์ในชุดธีมไม่ถูกต้อง');
        }

        final http.Response fileResponse = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 30));

        final Uint8List bytes = fileResponse.bodyBytes;

        if (fileResponse.statusCode != 200 ||
            bytes.length != size ||
            sha256.convert(bytes).toString() != sha ||
            !_typeMatches(bytes, type)) {
          throw const ThemeException('ไฟล์ธีมเสียหรือไม่ครบ กรุณาลองใหม่');
        }

        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);

        received += size;
        _setDownload(
          theme.slug,
          ThemeDownload(progress: total == 0 ? 1 : received / total),
        );
      }

      final Map<String, dynamic> stored = Map.of(pack)
        ..['assets'] = [
          for (final Map<String, dynamic> a in assets)
            {
              'path': a['path'],
              'sha256': a['sha256'],
              'size': a['size'],
              'type': a['type'],
            },
        ];

      // ตรวจว่าอ่านเป็นธีมได้ก่อนย้ายเข้าที่จริง
      AppThemeSpec.fromManifest(stored, temp.path);

      await File('${temp.path}${Platform.pathSeparator}pack.json')
          .writeAsString(jsonEncode(stored), flush: true);
      await File('${temp.path}${Platform.pathSeparator}.complete')
          .writeAsString('1');

      if (await target.exists()) await target.delete(recursive: true);

      await temp.rename(target.path);

      return AppThemeSpec.fromManifest(stored, target.path);
    } on FormatException {
      throw const ThemeException('ธีมนี้ไม่รองรับแอปเวอร์ชันนี้');
    } finally {
      if (await temp.exists()) {
        await temp.delete(recursive: true).catchError((_) => temp);
      }
    }
  }

  static bool _typeMatches(Uint8List b, String type) {
    bool starts(List<int> sig, [int offset = 0]) {
      if (b.length < offset + sig.length) return false;

      for (int i = 0; i < sig.length; i++) {
        if (b[offset + i] != sig[i]) return false;
      }

      return true;
    }

    return switch (type) {
      'image/png' => starts(const [0x89, 0x50, 0x4E, 0x47]),
      'image/webp' => starts('RIFF'.codeUnits) && starts('WEBP'.codeUnits, 8),
      'image/jpeg' => starts(const [0xFF, 0xD8, 0xFF]),
      _ => false,
    };
  }

  // =====================================================
  // เปิดใช้ธีม (ต้องมีสิทธิ์ตามเซิร์ฟเวอร์) / กลับธีมเริ่มต้น
  // =====================================================

  static Future<void> use(ThemeListing theme, {bool? preferThemeChat}) async {
    if (!theme.isFree && !theme.owned) {
      throw const ThemeException('บัญชีนี้ยังไม่มีสิทธิ์ใช้ธีมนี้');
    }

    final AppThemeSpec spec = await ensurePack(theme);

    _state['active'] = theme.slug;
    _state['active_version'] = spec.version;

    if (preferThemeChat != null) _state['prefer_theme_chat'] = preferThemeChat;

    await _saveState();

    AppTheming.setActive(spec, preferThemeChat: preferThemeChat);
  }

  static Future<void> useDefault() async {
    _state['active'] = AppThemeSpec.freeId;

    await _saveState();

    AppTheming.setActive(AppThemeSpec.lavender);
  }

  // =====================================================
  // ซื้อ / ตรวจการซื้อ / กู้คืน
  // =====================================================

  // โหมดทดสอบ: เซิร์ฟเวอร์ออกหลักฐานจำลอง (ไม่เก็บเงินจริง) แล้วตรวจแบบเดียวกับของจริง
  static Future<ThemeBuyResult> buyTest(
    ThemeListing theme,
    String outcome,
  ) async {
    final response = await ApiHelper.request(
      () async => http.post(
        Uri.parse('$baseUrl/themes/${theme.slug}/test-purchase'),
        headers: await _headers(),
        body: jsonEncode({'outcome': outcome}),
      ),
    );

    final Map<String, dynamic> data = ApiHelper.decode(response);

    if (data['status'] != true) {
      return ThemeBuyResult(
        'error',
        data['message']?.toString() ?? 'ซื้อไม่สำเร็จ',
      );
    }

    return verify('test', theme.slug, data['purchase_token'].toString());
  }

  static Future<ThemeBuyResult> verify(
    String provider,
    String slug,
    String token,
  ) async {
    final response = await ApiHelper.request(
      () async => http.post(
        Uri.parse('$baseUrl/themes/$slug/purchases'),
        headers: await _headers(),
        body: jsonEncode({'provider': provider, 'purchase_token': token}),
      ),
    );

    final Map<String, dynamic> data = ApiHelper.decode(response);

    final String status = data['status'] == true
        ? data['purchase_status']?.toString() ?? 'error'
        : 'error';

    try {
      await refreshCatalog();
    } catch (_) {
      // สิทธิ์จะอัปเดตตอนโหลดครั้งถัดไป
    }

    return ThemeBuyResult(
      status,
      data['message']?.toString() ?? 'ตรวจการซื้อไม่สำเร็จ',
      acknowledged: data['acknowledged'] == true,
    );
  }

  // กู้คืนการซื้อ: ส่งหลักฐานจากผู้ให้บริการ (Google Play) ให้เซิร์ฟเวอร์ตรวจใหม่ แล้วโหลดสิทธิ์ล่าสุด
  static Future<int> restore(List<Map<String, String>> purchases) async {
    if (purchases.isNotEmpty) {
      final response = await ApiHelper.request(
        () async => http.post(
          Uri.parse('$baseUrl/themes/purchases/restore'),
          headers: await _headers(),
          body: jsonEncode({'purchases': purchases}),
        ),
      );

      ApiHelper.decode(response);
    }

    final ThemeCatalog result = await refreshCatalog();

    return result.themes.where((t) => !t.isFree && t.owned).length;
  }
}
