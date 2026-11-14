import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:family_app/services/auth_service.dart';
import 'package:family_app/services/theme_service.dart';
import 'package:family_app/theme/app_theme.dart';
import 'package:family_app/theme/app_theming.dart';
import 'package:family_app/theme/theme_spec.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ระบบธีมฝั่งแอป: อ่านไฟล์ธีม / ดาวน์โหลดชุดธีมแบบตรวจไฟล์ / ลองธีมไม่บันทึก / สิทธิ์ถูกยกเลิก
// เซิร์ฟเวอร์ปลอม (MockClient) + โฟลเดอร์ชั่วคราว — ไม่ต่อเน็ตจริง

final List<int> png = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  1,
  2,
  3,
  4,
];

Map<String, dynamic> manifest({
  List<int>? servedBytes,
  String path = 'bg_light.png',
}) => {
  'format': 1,
  'slug': 'ocean-blue',
  'version': 1,
  'name': 'Ocean Blue',
  'min_app_build': 1,
  'modes': {
    'light': {'primary': '#1F7AE0', 'background': '#F3F8FD'},
  },
  'shape': {'corner_scale': 1.2},
  'icons': {'style': 'outlined', 'files': {}},
  'decor': {
    'background': {'light': 'bg_light.png'},
  },
  'assets': [
    {
      'path': path,
      'sha256': sha256.convert(png).toString(),
      'size': png.length,
      'type': 'image/png',
      'url': 'https://files.test/bg_light.png',
    },
  ],
};

Map<String, dynamic> catalogJson({required bool owned, String? reason}) => {
  'status': true,
  'billing': {'provider': 'test', 'account_ref': 'u7.ref'},
  'offline_grace_days': 14,
  'themes': [
    {
      'slug': 'lavender-original',
      'name': 'Lavender Original',
      'is_free': true,
      'owned': true,
    },
    {
      'slug': 'ocean-blue',
      'name': 'Ocean Blue',
      'is_free': false,
      'owned': owned,
      'version': 1,
      'min_app_build': 1,
      'entitlement': reason == null
          ? null
          : {'active': false, 'revoke_reason': reason},
    },
  ],
};

void main() {
  late Directory root;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'token': 'test'});
    root = await Directory.systemTemp.createTemp('themes_test');
    ThemeService.rootOverride = () async => root;
    ThemeService.appBuildOverride = 5;
    ThemeService.signedOut();
    AuthService.currentUserId = 7;
  });

  tearDown(() async {
    ThemeService.signedOut();
    AuthService.currentUserId = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('manifest falls back to Lavender values and ignores unsafe files', () {
    final AppThemeSpec spec = AppThemeSpec.fromManifest({
      ...manifest(),
      'modes': {
        'light': {'primary': 'not-a-color', 'surface': '#FFFFFF'},
      },
      'decor': {
        'background': {'light': '../../secret.png'},
        'empty': 'missing.png',
      },
    }, '/themes/ocean');

    expect(spec.light!.primary, AppPalette.light.primary);
    expect(spec.dark, isNull);
    expect(spec.resolve(Brightness.dark), Brightness.light);
    expect(spec.decor.backgroundLight, isNull);
    expect(spec.decor.emptyArt, isNull);
    expect(spec.cornerScale, 1.2);

    expect(
      () => AppThemeSpec.fromManifest({...manifest(), 'format': 99}, '/x'),
      throwsFormatException,
    );
  });

  test(
    'pack downloads into the account folder only after every file checks out',
    () async {
      final ThemeListing theme = ThemeListing.fromJson(
        catalogJson(owned: true)['themes'][1],
      );

      await http.runWithClient(
        () async {
          final AppThemeSpec spec = await ThemeService.ensurePack(theme);

          expect(spec.id, 'ocean-blue');
          expect(spec.decor.backgroundLight, contains('u7'));
          expect(File(spec.decor.backgroundLight!).existsSync(), isTrue);
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/pack')) {
            return http.Response(
              jsonEncode({'status': true, 'pack': manifest()}),
              200,
            );
          }

          return http.Response.bytes(png, 200);
        }),
      );

      // บัญชีอื่นในเครื่องเดียวกันไม่เห็นไฟล์/สถานะของบัญชีนี้
      expect(Directory('${root.path}/themes/u8').existsSync(), isFalse);
    },
  );

  test(
    'corrupted, oversized or escaping files keep the current theme',
    () async {
      final ThemeListing theme = ThemeListing.fromJson(
        catalogJson(owned: true)['themes'][1],
      );

      Future<void> attempt(Map<String, dynamic> pack, List<int> bytes) =>
          http.runWithClient(
            () => ThemeService.ensurePack(theme, force: true),
            () => MockClient((request) async {
              if (request.url.path.endsWith('/pack')) {
                return http.Response(
                  jsonEncode({'status': true, 'pack': pack}),
                  200,
                );
              }

              return http.Response.bytes(bytes, 200);
            }),
          );

      await expectLater(
        attempt(manifest(), [...png]..[9] = 9),
        throwsA(isA<ThemeException>()),
      );
      await expectLater(
        attempt(manifest(path: '../escape.png'), png),
        throwsA(isA<ThemeException>()),
      );
      await expectLater(
        attempt(manifest(), [1, 2, 3]),
        throwsA(isA<ThemeException>()),
      );

      expect(ThemeService.downloads.value['ocean-blue']?.failed, isTrue);
      expect(
        Directory('${root.path}/themes/u7/packs/ocean-blue/v1').existsSync(),
        isFalse,
      );
      expect(AppTheming.active.isFree, isTrue);
    },
  );

  test(
    'trial theme is memory only and ending it restores the active theme',
    () {
      final AppThemeSpec trial = AppThemeSpec.fromManifest(manifest(), '/x');

      AppTheming.startTrial(trial);
      expect(AppTheming.effective.id, 'ocean-blue');
      expect(AppTheming.active.isFree, isTrue);

      AppTheming.endTrial();
      expect(AppTheming.effective.isFree, isTrue);
    },
  );

  test(
    'revoked entitlement switches back to the free theme with a reason',
    () async {
      bool owned = true;

      await http.runWithClient(
        () async {
          final ThemeCatalog catalog = await ThemeService.refreshCatalog();

          await ThemeService.use(catalog.bySlug('ocean-blue')!);
          expect(AppTheming.active.id, 'ocean-blue');

          owned = false;
          await ThemeService.refreshCatalog();
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/themes')) {
            return http.Response(
              jsonEncode(
                catalogJson(owned: owned, reason: owned ? null : 'refunded'),
              ),
              200,
            );
          }

          if (request.url.path.endsWith('/pack')) {
            return http.Response(
              jsonEncode({'status': true, 'pack': manifest()}),
              200,
            );
          }

          return http.Response.bytes(png, 200);
        }),
      );

      expect(AppTheming.active.isFree, isTrue);
      expect(ThemeService.notice.value, contains('คืนเงิน'));
    },
  );

  test(
    'a theme that is not owned cannot be applied from the app side',
    () async {
      final ThemeListing theme = ThemeListing.fromJson(
        catalogJson(owned: false)['themes'][1],
      );

      await expectLater(
        ThemeService.use(theme),
        throwsA(isA<ThemeException>()),
      );
      expect(AppTheming.active.isFree, isTrue);
    },
  );
}
