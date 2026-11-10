import 'dart:convert';
import 'dart:io';

import 'package:family_app/pages/activity_detail_page.dart';
import 'package:family_app/pages/activity_page.dart';
import 'package:family_app/services/activity_service.dart';
import 'package:family_app/theme/app_theme.dart';
import 'package:family_app/widgets/activity_reminder_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// แจ้งเตือนกิจกรรม: ตัวเลือก + เวลาที่จะเตือนจริง / เวลาเตือนผ่านแล้ว / ข้อมูลเก่า
// / หน้ารายละเอียด (สมาชิกตั้งเตือนเอง, ไม่พบ/ไม่มีสิทธิ์, เน็ตหลุด) / สิทธิ์แจ้งเตือนของเครื่อง

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

// เวลาเป็นนาทีเต็ม (ตรงกับที่ฟอร์มเลือกได้)
DateTime inMinutes(int minutes) {
  final DateTime now = DateTime.now().add(Duration(minutes: minutes));

  return DateTime(now.year, now.month, now.day, now.hour, now.minute);
}

Map<String, dynamic> activity({
  int id = 1,
  DateTime? start,
  bool legacy = false,
  bool mine = true,
  Map<String, dynamic>? reminder,
}) => {
  'id': id,
  'title': 'ประชุมผู้ปกครอง',
  'description': 'ห้อง 3',
  'activity_date': start?.toIso8601String().substring(0, 19),
  'starts_at': start == null || legacy ? null : start.toUtc().toIso8601String(),
  'timezone': start == null || legacy ? null : 'Asia/Bangkok',
  'visibility': mine ? 'private' : 'family',
  'is_completed': false,
  'is_mine': mine,
  'can_manage': mine,
  'can_remind': start != null && !legacy,
  'needs_time_confirmation': legacy && start != null,
  'my_reminder': reminder,
  'user': {'id': mine ? 1 : 2, 'name': mine ? 'แม่' : 'พ่อ'},
};

Map<String, dynamic> list(List<Map<String, dynamic>> items) => {
  'status': true,
  'activities': items,
  'page': 1,
  'has_more': false,
  'counts': {
    'all': items.length,
    'today': 0,
    'overdue': 0,
    'completed': 0,
    'mine': items.length,
    'family': 0,
  },
  'family': {'has_family': false, 'id': null},
};

Future<void> openEditSheet(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: ActivityPage()));
  await tester.pump(const Duration(milliseconds: 100));

  await tester.tap(find.byTooltip('จัดการ').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('แก้ไข'));
  await tester.pumpAndSettle();
}

ChoiceChip chip(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'token': 'test'});
    ActivityService.timezoneOverride = 'Asia/Bangkok';
    NotificationPermissionCard.statusOverride = () async => true;
    NotificationPermissionCard.openSettingsOverride = null;
  });

  tearDown(() {
    ActivityService.timezoneOverride = null;
    NotificationPermissionCard.statusOverride = null;
    NotificationPermissionCard.openSettingsOverride = null;
    AppColors.palette = AppPalette.light;
  });

  testWidgets(
    'edit form shows the real reminder time and sends UTC + timezone',
    (tester) async {
      final DateTime start = inMinutes(3 * 24 * 60);
      final List<Map<String, dynamic>> patches = [];

      Future<http.Response> server(http.Request request) async {
        if (request.method == 'PATCH') {
          patches.add(jsonDecode(request.body) as Map<String, dynamic>);

          return json({'status': true, 'activity': activity(start: start)});
        }

        return json(list([activity(start: start)]));
      }

      await http.runWithClient(() async {
        await openEditSheet(tester);

        // ค่าเริ่มต้น = ไม่เตือน
        expect(chip(tester, 'ไม่เตือน').selected, isTrue);
        expect(find.text('ไม่เตือนกิจกรรมนี้'), findsOneWidget);

        await tester.ensureVisible(find.text('ก่อน 30 นาที'));
        await tester.tap(find.text('ก่อน 30 นาที'));
        await tester.pump();

        final String expected = ActivityReminders.formatDateTime(
          start.subtract(const Duration(minutes: 30)),
        );
        expect(
          find.textContaining('จะเตือน: ก่อน 30 นาที · $expected'),
          findsOneWidget,
        );

        await tester.ensureVisible(find.text('บันทึกการแก้ไข'));
        await tester.tap(find.text('บันทึกการแก้ไข'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        final Map<String, dynamic> body = patches.single;
        expect(body['reminder_offset'], 30);
        expect(body['timezone'], 'Asia/Bangkok');
        expect(body['starts_at'], start.toUtc().toIso8601String());
        expect(body['starts_at'].toString().endsWith('Z'), isTrue);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
      }, () => MockClient(server));
    },
  );

  testWidgets('options already in the past cannot be chosen', (tester) async {
    final DateTime start = inMinutes(20);

    await http.runWithClient(() async {
      await openEditSheet(tester);

      expect(chip(tester, 'ก่อน 15 นาที').onSelected, isNotNull);
      expect(chip(tester, 'ก่อน 30 นาที (เลยแล้ว)').onSelected, isNull);
      expect(chip(tester, 'ก่อน 1 วัน (เลยแล้ว)').onSelected, isNull);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient((_) async => json(list([activity(start: start)]))));
  });

  testWidgets('past reminder kept after moving the time asks to choose again', (
    tester,
  ) async {
    // ตั้งไว้ ก่อน 1 วัน แต่กิจกรรมเหลือ 2 ชั่วโมง (เช่น เลื่อนเวลา) → บันทึกไม่ได้จนกว่าจะเลือกใหม่
    final DateTime start = inMinutes(120);
    final List<http.Request> patches = [];

    await http.runWithClient(
      () async {
        await openEditSheet(tester);

        // ค่าเดิมเลยเวลาแล้ว (ไม่ได้ส่ง) → แจ้งสถานะ ให้เลือกใหม่ได้
        expect(
          find.text('เลยเวลาเตือนแล้ว จึงไม่ได้ส่ง เลือกการเตือนใหม่ได้'),
          findsOneWidget,
        );
        expect(chip(tester, 'ก่อน 1 วัน').selected, isTrue);

        await tester.ensureVisible(find.text('ก่อน 15 นาที'));
        await tester.tap(find.text('ก่อน 15 นาที'));
        await tester.pump();

        expect(
          find.text('เลยเวลาเตือนแล้ว จึงไม่ได้ส่ง เลือกการเตือนใหม่ได้'),
          findsNothing,
        );
        expect(find.textContaining('จะเตือน: ก่อน 15 นาที'), findsOneWidget);

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient((request) async {
        if (request.method == 'PATCH') patches.add(request);

        return json(
          list([
            activity(
              start: start,
              reminder: {
                'offset_minutes': 1440,
                'label': 'ก่อน 1 วัน',
                'remind_at': null,
                'status': 'expired',
              },
            ),
          ]),
        );
      }),
    );

    expect(patches, isEmpty);
  });

  testWidgets('legacy activity asks the owner to confirm the time', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await openEditSheet(tester);

        expect(
          find.textContaining('กิจกรรมนี้สร้างก่อนมีระบบเตือน'),
          findsOneWidget,
        );

        await tester.pump(const Duration(seconds: 2));
        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient(
        (_) async =>
            json(list([activity(start: inMinutes(600), legacy: true)])),
      ),
    );
  });

  testWidgets('activity without a date explains why no reminder', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await openEditSheet(tester);

      expect(
        find.text('ตั้งวันและเวลาของกิจกรรมก่อน จึงจะตั้งเตือนได้'),
        findsOneWidget,
      );
      expect(find.byType(ChoiceChip), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient((_) async => json(list([activity()]))));
  });

  testWidgets('member sets own reminder on a shared activity from detail', (
    tester,
  ) async {
    final DateTime start = inMinutes(2 * 24 * 60);
    final List<Map<String, dynamic>> puts = [];
    bool settingsOpened = false;

    NotificationPermissionCard.statusOverride = () async => false;
    NotificationPermissionCard.openSettingsOverride = () async {
      settingsOpened = true;
    };

    Future<http.Response> server(http.Request request) async {
      if (request.method == 'PUT') {
        expect(request.url.path, '/api/activities/7/reminder');
        puts.add(jsonDecode(request.body) as Map<String, dynamic>);

        return json({
          'status': true,
          'message': 'ตั้งเตือนแล้ว: ก่อน 15 นาที',
          'reminder': {
            'offset_minutes': 15,
            'label': 'ก่อน 15 นาที',
            'remind_at': start
                .subtract(const Duration(minutes: 15))
                .toUtc()
                .toIso8601String(),
            'status': 'pending',
          },
        });
      }

      return json({
        'status': true,
        'activity': activity(id: 7, start: start, mine: false),
      });
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(home: ActivityDetailPage(activityId: 7)),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('ประชุมผู้ปกครอง'), findsOneWidget);
      expect(find.textContaining('สร้างโดย พ่อ'), findsOneWidget);

      // ตรวจสิทธิ์ของเครื่องเสร็จ → เฟรมถัดไป
      await tester.pump();

      // สิทธิ์แจ้งเตือนของเครื่องปิดอยู่ → ปุ่มไปหน้าตั้งค่า (ไม่ขอสิทธิ์เอง)
      expect(
        find.textContaining('การแจ้งเตือนของเครื่องปิดอยู่'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('เปิดในการตั้งค่าเครื่อง'));
      await tester.tap(find.text('เปิดในการตั้งค่าเครื่อง'));
      await tester.pump();
      expect(settingsOpened, isTrue);

      // ยังไม่เปลี่ยน → ปุ่มบันทึกกดไม่ได้
      final saveButton = find.widgetWithText(ElevatedButton, 'บันทึกการเตือน');
      expect(tester.widget<ElevatedButton>(saveButton).onPressed, isNull);

      await tester.ensureVisible(find.text('ก่อน 15 นาที'));
      await tester.tap(find.text('ก่อน 15 นาที'));
      await tester.pump();
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pump(const Duration(milliseconds: 100));

      expect(puts.single, {'offset': 15});
      expect(find.text('ตั้งเตือนแล้ว: ก่อน 15 นาที'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(saveButton).onPressed, isNull);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server));
  });

  testWidgets('deleted or no-permission activity shows a message only', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: ActivityDetailPage(activityId: 9)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          find.text('ไม่พบกิจกรรมนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว'),
          findsOneWidget,
        );
        expect(find.text('ประชุมผู้ปกครอง'), findsNothing);
        expect(find.byType(ChoiceChip), findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient(
        (_) async => json({
          'status': false,
          'message': 'ไม่พบกิจกรรมนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว',
        }, 404),
      ),
    );
  });

  testWidgets('network failure shows retry, then loads', (tester) async {
    bool down = true;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: ActivityDetailPage(activityId: 3)),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('ลองอีกครั้ง'), findsOneWidget);

        down = false;
        await tester.tap(find.text('ลองอีกครั้ง'));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('ประชุมผู้ปกครอง'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient((_) async {
        if (down) throw const SocketException('down');

        return json({
          'status': true,
          'activity': activity(id: 3, start: inMinutes(600)),
        });
      }),
    );
  });

  testWidgets('detail fits a small screen with large text in dark mode', (
    tester,
  ) async {
    AppColors.palette = AppPalette.dark;
    tester.view.physicalSize = const Size(320 * 3, 600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    NotificationPermissionCard.statusOverride = () async => false;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(),
            home: const MediaQuery(
              data: MediaQueryData(
                size: Size(320, 600),
                textScaler: TextScaler.linear(2),
              ),
              child: ActivityDetailPage(activityId: 4),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);

        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('เปิดในการตั้งค่าเครื่อง'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient(
        (_) async => json({
          'status': true,
          'activity': activity(
            id: 4,
            start: inMinutes(3000),
            mine: false,
            reminder: {
              'offset_minutes': 30,
              'label': 'ก่อน 30 นาที',
              'remind_at': null,
              'status': 'pending',
            },
          ),
        }),
      ),
    );
  });
}
