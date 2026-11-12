import 'dart:convert';

import 'package:family_app/pages/chat_room_page.dart';
import 'package:family_app/widgets/chat_room_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// สื่อในแชท: ลิงก์ต้องยืนยันก่อนเปิด / ไฟล์-เสียงแสดงรายละเอียด / อีโมจิแทรกที่เคอร์เซอร์
// เมนูแนบ + แชร์ลิงก์ / ไมโครโฟนถูกปฏิเสธ → บอกทางไปตั้งค่า

Map<String, dynamic> msg(
  int id,
  String body, {
  Map<String, dynamic>? attachment,
}) {
  return {
    'id': id,
    'sender_id': 2,
    'is_mine': false,
    'body': body,
    'image_url': null,
    'attachment': attachment,
    'reactions': [],
    'reply_to': null,
    'created_at': DateTime.now().toUtc().toIso8601String(),
  };
}

MockClient server(List<Map<String, dynamic>> messages) {
  return MockClient((request) async {
    final Map<String, dynamic> body = request.url.path.endsWith('/messages')
        ? {
            'status': true,
            'conversation': {
              'id': 1,
              'can_send': true,
              'other_read_id': 0,
              'my_read_id': 999,
              'user': {'id': 2, 'name': 'ลูก'},
            },
            'messages': request.url.queryParameters['after_id'] == null
                ? messages
                : [],
            'has_more': false,
            'states': [],
          }
        : {'status': true, 'unread_count': 0};

    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

Future<void> open(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: ChatRoomPage(conversationId: 1)),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

TextEditingController input(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!;

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'token': 'test'});
    ChatDrafts.clear();
  });

  testWidgets(
    'web links open only after showing the domain; other schemes stay text',
    (tester) async {
      await http.runWithClient(
        () async {
          await open(tester);

          await tester.tap(
            find.text('https://example.com/a?b=1', findRichText: true),
          );
          await tester.pumpAndSettle();

          expect(find.text('example.com'), findsOneWidget);
          expect(find.text('เปิดลิงก์'), findsOneWidget);

          await tester.tap(find.text('ยกเลิก'));
          await tester.pumpAndSettle();
          expect(find.text('เปิดลิงก์'), findsNothing);

          // scheme อื่นไม่ถูกทำเป็นลิงก์
          await tester.tap(find.text('javascript:alert(1)'));
          await tester.pumpAndSettle();
          expect(find.text('เปิดลิงก์'), findsNothing);

          await tester.pumpWidget(const SizedBox());
        },
        () => server([
          msg(1, 'javascript:alert(1)'),
          msg(2, 'https://example.com/a?b=1'),
        ]),
      );
    },
  );

  testWidgets('file and voice messages show name, type, size and length', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await open(tester);

        expect(find.text('สรุปงาน.pdf'), findsOneWidget);
        expect(find.textContaining('PDF · 1.2 MB'), findsOneWidget);
        expect(find.byTooltip('เปิดไฟล์'), findsOneWidget);
        expect(find.byTooltip('เล่นข้อความเสียง'), findsOneWidget);
        expect(find.text('0:05'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
      () => server([
        msg(
          1,
          '',
          attachment: {
            'kind': 'file',
            'name': 'สรุปงาน.pdf',
            'mime': 'application/pdf',
            'size': 1258291,
            'url': 'https://files.test/1',
            'expires_in': 600,
          },
        ),
        msg(
          2,
          '',
          attachment: {
            'kind': 'voice',
            'name': 'ข้อความเสียง.m4a',
            'mime': 'audio/mp4',
            'size': 40000,
            'duration_ms': 5000,
            'url': 'https://files.test/2',
            'expires_in': 600,
          },
        ),
      ]),
    );
  });

  testWidgets(
    'emoji panel inserts at the cursor and keeps joined emoji whole',
    (tester) async {
      await http.runWithClient(() async {
        await open(tester);

        await tester.enterText(find.byType(TextField), 'ab');
        input(tester).selection = const TextSelection.collapsed(offset: 1);
        await tester.pump();

        await tester.tap(find.byTooltip('อีโมจิ'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('😀').last);
        await tester.pump();

        await tester.tap(find.text('❤️').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('❤️‍🔥'));
        await tester.pump();

        expect(input(tester).text, 'a😀❤️‍🔥b');
        expect(input(tester).text.characters.length, 4);
        expect(input(tester).selection.baseOffset, 'a😀❤️‍🔥'.length);

        // กลับไปใช้แป้นพิมพ์
        await tester.tap(find.byTooltip('แป้นพิมพ์'));
        await tester.pumpAndSettle();
        expect(find.text('❤️‍🔥'), findsNothing);

        await tester.pumpWidget(const SizedBox());
      }, () => server([]));
    },
  );

  testWidgets(
    'attach menu offers four choices and links are checked before use',
    (tester) async {
      await http.runWithClient(() async {
        await open(tester);

        await tester.enterText(find.byType(TextField), 'ดูนี่');
        await tester.pump();

        await tester.tap(find.byTooltip('แนบรูป ไฟล์ หรือลิงก์'));
        await tester.pumpAndSettle();

        for (final label in ['กล้อง', 'รูปภาพ', 'ไฟล์', 'ลิงก์']) {
          expect(find.text(label), findsOneWidget);
        }

        await tester.tap(find.text('ลิงก์'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byType(TextField).last,
          'ftp://files.example',
        );
        await tester.tap(find.text('ใส่ในข้อความ'));
        await tester.pump();
        expect(
          find.text('ลิงก์ต้องขึ้นต้นด้วย http:// หรือ https://'),
          findsOneWidget,
        );

        await tester.enterText(
          find.byType(TextField).last,
          'https://oravelle.app/x',
        );
        await tester.tap(find.text('ใส่ในข้อความ'));
        await tester.pumpAndSettle();

        // แทรกที่ตำแหน่งเคอร์เซอร์ (ท้ายข้อความที่พิมพ์ไว้) ข้อความร่างไม่หาย
        expect(input(tester).text, 'ดูนี่https://oravelle.app/x ');

        await tester.pumpWidget(const SizedBox());
      }, () => server([]));
    },
  );

  testWidgets('denied microphone explains how to allow it in settings', (
    tester,
  ) async {
    const channel = MethodChannel('flutter.baseflow.com/permissions/methods');

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'checkPermissionStatus') return 0;
      if (call.method == 'requestPermissions') return {7: 4};

      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await http.runWithClient(() async {
      await open(tester);

      // ช่องพิมพ์ว่าง → ปุ่มไมค์แทนปุ่มส่ง
      expect(find.byTooltip('อัดข้อความเสียง'), findsOneWidget);

      await tester.tap(find.byTooltip('อัดข้อความเสียง'));
      await tester.pumpAndSettle();

      expect(find.text('ยังไม่ได้อนุญาตให้ใช้ไมโครโฟน'), findsOneWidget);
      expect(find.text('เปิดการตั้งค่า'), findsOneWidget);

      await tester.tap(find.text('ไม่ใช่ตอนนี้'));
      await tester.pumpAndSettle();

      // ยังอยู่ที่ช่องพิมพ์ปกติ
      expect(find.byType(TextField), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, () => server([]));
  });
}
