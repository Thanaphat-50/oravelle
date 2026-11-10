import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:family_app/pages/devices_page.dart';
import 'package:family_app/services/auth_service.dart';
import 'package:family_app/services/device_info_service.dart';
import 'package:family_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// อุปกรณ์ที่เข้าสู่ระบบ: เครื่องนี้ / อุปกรณ์ไม่ทราบชื่อ / ยืนยันก่อน / ไม่ลบจากจอจนเซิร์ฟเวอร์ยืนยัน
// / ออกจากระบบเครื่องอื่นทั้งหมด / โหลดไม่สำเร็จ / จอเล็ก โหมดมืด / ส่งข้อมูลอุปกรณ์ตอนเข้าสู่ระบบ

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> session(int id, {String? name, bool current = false}) => {
  'id': id,
  'device_name': name,
  'device_platform': name == null ? null : 'android',
  'os_version': name == null ? null : 'Android 14',
  'app_version': name == null ? null : '1.4.0 (12)',
  'signed_in_at': '2026-11-09T03:00:00Z',
  'last_used_at': current ? '2026-11-10T03:00:00Z' : '2026-11-09T05:30:00Z',
  'is_current': current,
};

Map<String, dynamic> listOf(List<Map<String, dynamic>> sessions) => {
  'status': true,
  'sessions': sessions,
  'others_count': sessions.where((s) => s['is_current'] != true).length,
};

Future<void> openPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: DevicesPage()));
  await tester.pump(const Duration(milliseconds: 100));
}

Finder logoutButton(String label) => find.widgetWithText(OutlinedButton, label);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  tearDown(() {
    AppColors.palette = AppPalette.light;
    DeviceInfoService.override = null;
  });

  testWidgets('marks this device from the server and names unknown ones', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await openPage(tester);

        expect(find.text('เครื่องนี้'), findsOneWidget);
        // สองเครื่องรุ่นเดียวกัน แสดงแยกตามข้อมูลจริง
        expect(find.text('Google Pixel 7'), findsNWidgets(2));
        expect(find.text('อุปกรณ์ไม่ทราบชื่อ'), findsOneWidget);
        expect(find.text('Android 14 · แอป 1.4.0 (12)'), findsNWidgets(2));

        // เครื่องนี้ไม่มีปุ่มออกจากระบบรายเครื่อง
        expect(logoutButton('ออกจากระบบ'), findsNWidgets(2));
        expect(find.textContaining('ออนไลน์'), findsNothing);
        expect(find.textContaining('ใช้งานล่าสุด:'), findsNWidgets(3));
      },
      () => MockClient(
        (_) async => json(
          listOf([
            session(1, name: 'Google Pixel 7', current: true),
            session(2, name: 'Google Pixel 7'),
            session(3),
          ]),
        ),
      ),
    );
  });

  testWidgets(
    'revoking keeps the item until the server confirms, then reloads',
    (tester) async {
      final List<String> calls = [];
      Completer<void>? gate;
      bool networkDown = true;
      bool revoked = false;

      await http.runWithClient(
        () async {
          await openPage(tester);

          await tester.tap(logoutButton('ออกจากระบบ').first);
          await tester.pumpAndSettle();

          expect(find.text('ออกจากระบบอุปกรณ์นี้?'), findsOneWidget);
          expect(
            find.textContaining(
              'อุปกรณ์นี้จะต้องเข้าสู่ระบบใหม่เพื่อใช้บัญชีของคุณ',
            ),
            findsOneWidget,
          );

          // ยกเลิก → ไม่ส่งคำขอ
          await tester.tap(find.text('ยกเลิก'));
          await tester.pumpAndSettle();
          expect(calls.where((c) => c.startsWith('DELETE')), isEmpty);

          // เน็ตล่ม → รายการยังอยู่ แจ้งข้อผิดพลาด
          await tester.tap(logoutButton('ออกจากระบบ').first);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'ออกจากระบบ'));
          await tester.pumpAndSettle();

          expect(calls.last, 'DELETE /api/sessions/2');
          expect(find.text('Samsung A54'), findsOneWidget);
          expect(find.byType(SnackBar), findsOneWidget);

          // ระหว่างรอ: ปุ่มแสดงกำลังทำงาน กดซ้ำไม่ได้ รายการยังอยู่
          networkDown = false;
          gate = Completer<void>();
          await tester.tap(logoutButton('ออกจากระบบ').first);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'ออกจากระบบ'));
          await tester.pump(const Duration(milliseconds: 50));

          expect(find.text('กำลังออกจากระบบ...'), findsOneWidget);
          expect(find.text('Samsung A54'), findsOneWidget);
          expect(
            tester
                .widget<OutlinedButton>(logoutButton('ออกจากระบบ').first)
                .onPressed,
            isNull,
          );

          gate!.complete();
          await tester.pumpAndSettle();

          expect(find.text('ยกเลิกสิทธิ์ของอุปกรณ์นี้แล้ว'), findsOneWidget);
          expect(find.text('Samsung A54'), findsNothing);
          expect(
            calls.where((c) => c == 'GET /api/sessions').length,
            greaterThanOrEqualTo(2),
          );
        },
        () => MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');

          if (request.method == 'DELETE') {
            if (networkDown) throw const SocketException('down');

            await gate?.future;
            revoked = true;

            return json({
              'status': true,
              'revoked': 1,
              'message': 'ยกเลิกสิทธิ์ของอุปกรณ์นี้แล้ว',
            });
          }

          return json(
            listOf([
              session(1, name: 'Google Pixel 7', current: true),
              if (!revoked) session(2, name: 'Samsung A54'),
              session(3),
            ]),
          );
        }),
      );
    },
  );

  testWidgets('revoke all others asks first and keeps this device', (
    tester,
  ) async {
    bool revoked = false;

    await http.runWithClient(
      () async {
        await openPage(tester);

        // ปุ่มอยู่ท้ายรายการ (ListView สร้างเฉพาะส่วนที่เห็น) → เลื่อนลงก่อน
        await tester.scrollUntilVisible(
          find.text('ออกจากระบบเครื่องอื่นทั้งหมด'),
          200,
        );
        await tester.ensureVisible(find.text('ออกจากระบบเครื่องอื่นทั้งหมด'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ออกจากระบบเครื่องอื่นทั้งหมด'));
        await tester.pumpAndSettle();

        expect(find.text('ออกจากระบบเครื่องอื่นทั้งหมด?'), findsOneWidget);
        expect(
          find.textContaining('คุณยังใช้งานบัญชีบนเครื่องนี้ต่อได้'),
          findsOneWidget,
        );
        expect(find.textContaining('อุปกรณ์อื่น 2 เครื่อง'), findsOneWidget);

        await tester.tap(find.text('ออกจากระบบทั้งหมด'));
        await tester.pumpAndSettle();

        expect(find.text('เครื่องนี้'), findsOneWidget);
        expect(find.text('อุปกรณ์ไม่ทราบชื่อ'), findsNothing);
        // เหลือเครื่องนี้เครื่องเดียว → ไม่มีปุ่มทั้งหมด มีคำอธิบายแทน
        expect(find.text('ออกจากระบบเครื่องอื่นทั้งหมด'), findsNothing);
        expect(
          find.textContaining('ไม่มีอุปกรณ์อื่นที่เข้าสู่ระบบอยู่'),
          findsOneWidget,
        );
      },
      () => MockClient((request) async {
        if (request.method == 'POST') {
          revoked = true;
          return json({
            'status': true,
            'revoked': 2,
            'message': 'ยกเลิกสิทธิ์อุปกรณ์อื่นแล้ว 2 เครื่อง คุณยังใช้งานบนเครื่องนี้ต่อได้',
          });
        }

        return json(
          listOf([
            session(1, name: 'Google Pixel 7', current: true),
            if (!revoked) ...[session(2, name: 'Samsung A54'), session(3)],
          ]),
        );
      }),
    );
  });

  testWidgets('load failure shows retry', (tester) async {
    bool down = true;

    await http.runWithClient(
      () async {
        await openPage(tester);

        expect(find.text('ลองอีกครั้ง'), findsOneWidget);

        down = false;
        await tester.tap(find.text('ลองอีกครั้ง'));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('เครื่องนี้'), findsOneWidget);
      },
      () => MockClient((_) async {
        if (down) throw const SocketException('down');

        return json(listOf([session(1, name: 'Pixel', current: true)]));
      }),
    );
  });

  testWidgets('fits a small screen with large text in dark mode', (
    tester,
  ) async {
    AppColors.palette = AppPalette.dark;
    tester.view.physicalSize = const Size(320 * 3, 560 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: const MediaQuery(
              data: MediaQueryData(
                size: Size(320, 560),
                textScaler: TextScaler.linear(2),
              ),
              child: DevicesPage(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView), const Offset(0, -3000));
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      () => MockClient(
        (_) async => json(
          listOf([
            session(1, name: 'Samsung Galaxy Z Fold6 5G', current: true),
            session(2, name: 'Samsung Galaxy Z Fold6 5G'),
          ]),
        ),
      ),
    );
  });

  test('login sends device details for the sessions list', () async {
    DeviceInfoService.override = {
      'device_name': 'Google Pixel 7',
      'device_platform': 'android',
      'os_version': 'Android 14',
      'app_version': '1.4.0 (12)',
    };

    Map<String, dynamic>? body;

    await http.runWithClient(
      () => AuthService.login(email: 'mom@example.com', password: 'secret'),
      () => MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return json({'status': true, 'token': '1|abc'});
      }),
    );

    expect(body?['email'], 'mom@example.com');
    expect(body?['device_name'], 'Google Pixel 7');
    expect(body?['device_platform'], 'android');
    expect(body?['app_version'], '1.4.0 (12)');
  });

  test('model names are readable without duplicating the brand', () {
    expect(DeviceInfoService.modelName('Google', 'Pixel 7'), 'Google Pixel 7');
    expect(
      DeviceInfoService.modelName('samsung', 'SM-S918B'),
      'Samsung SM-S918B',
    );
    expect(DeviceInfoService.modelName('OnePlus', 'OnePlus 12'), 'OnePlus 12');
  });
}
