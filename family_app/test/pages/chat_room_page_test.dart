import 'dart:async';
import 'dart:convert';

import 'package:family_app/pages/chat_room_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ห้องแชท: ข้อความที่พิมพ์ระหว่างรอส่งไม่หาย / ส่งไม่สำเร็จ → ส่งอีกครั้งด้วยรหัสเดิม

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

class FakeChatServer {
  // POST ที่ยังไม่ตอบ (ทดสอบควบคุมว่าจะให้สำเร็จ/ล้มเมื่อไร)
  final List<Completer<http.Response>> pendingPosts = [];
  final List<Map<String, dynamic>> posted = [];

  int nextId = 100;

  Future<http.Response> handle(http.Request request) {
    final String path = request.url.path;

    if (request.method == 'POST' && path.endsWith('/messages')) {
      posted.add(jsonDecode(request.body) as Map<String, dynamic>);

      final completer = Completer<http.Response>();
      pendingPosts.add(completer);

      return completer.future;
    }

    if (path.endsWith('/unread-count')) {
      return Future.value(json({'status': true, 'unread_count': 0}));
    }

    // GET ข้อความ: ห้องว่าง
    return Future.value(
      json({
        'status': true,
        'messages': [],
        'has_more': false,
        'conversation': {
          'id': 1,
          'can_send': true,
          'other_read_id': 0,
          'user': {'id': 2, 'name': 'ลูก'},
        },
      }),
    );
  }

  // ตอบ POST ที่รออยู่ลำดับที่ index ว่าบันทึกสำเร็จ
  void succeed(int index) {
    final Map<String, dynamic> body = posted[index];

    pendingPosts[index].complete(
      json({
        'status': true,
        'message': {
          'id': nextId++,
          'sender_id': 1,
          'is_mine': true,
          'client_id': body['client_id'],
          'body': body['body'],
          'image_url': null,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      }, 201),
    );
  }

  void fail(int index) {
    pendingPosts[index].complete(json({'message': 'Server Error'}, 500));
  }
}

Future<void> openRoom(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: ChatRoomPage(conversationId: 1)),
  );

  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> closeRoom(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

TextField input(WidgetTester tester) {
  return tester.widget<TextField>(find.byType(TextField));
}

Future<void> typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byIcon(Icons.send_rounded));
  await tester.pump();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  testWidgets(
    'draft typed while sending is kept when the first send finishes',
    (tester) async {
      final server = FakeChatServer();

      await http.runWithClient(() async {
        await openRoom(tester);

        await typeAndSend(tester, 'ข้อความแรก');

        // ช่องพิมพ์ว่างทันที ข้อความแรกขึ้นเป็น "กำลังส่ง…"
        expect(input(tester).controller!.text, '');
        expect(find.text('ข้อความแรก'), findsOneWidget);
        expect(find.text('กำลังส่ง…'), findsOneWidget);

        // พิมพ์ข้อความที่สองระหว่างรอ
        await tester.enterText(find.byType(TextField), 'กำลังพิมพ์ข้อความสอง');
        await tester.pump();

        server.succeed(0);
        await tester.pump(const Duration(milliseconds: 50));

        // ข้อความแรกส่งแล้ว ร่างข้อความสองยังอยู่
        expect(input(tester).controller!.text, 'กำลังพิมพ์ข้อความสอง');
        expect(find.text('กำลังส่ง…'), findsNothing);
        expect(find.text('ข้อความแรก'), findsOneWidget);
        expect(server.posted.single['client_id'], isNotEmpty);

        await closeRoom(tester);
      }, () => MockClient(server.handle));
    },
  );

  testWidgets('failed message can be sent again with the same client id', (
    tester,
  ) async {
    final server = FakeChatServer();

    await http.runWithClient(() async {
      await openRoom(tester);

      await typeAndSend(tester, 'ส่งไม่ผ่าน');

      server.fail(0);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('ส่งไม่สำเร็จ · แตะเพื่อส่งอีกครั้ง'), findsOneWidget);

      await tester.tap(find.text('ส่งไม่ผ่าน'));
      await tester.pumpAndSettle();

      expect(
        find.text('ระบบขัดข้องชั่วคราว กรุณาลองใหม่อีกสักครู่'),
        findsOneWidget,
      );

      await tester.tap(find.text('ส่งอีกครั้ง'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('กำลังส่ง…'), findsOneWidget);
      expect(server.posted, hasLength(2));
      expect(server.posted[1]['client_id'], server.posted[0]['client_id']);

      server.succeed(1);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('ส่งไม่ผ่าน'), findsOneWidget);
      expect(find.textContaining('ส่งไม่สำเร็จ'), findsNothing);

      await closeRoom(tester);
    }, () => MockClient(server.handle));
  });

  testWidgets('failed message can be moved back to the input to edit', (
    tester,
  ) async {
    final server = FakeChatServer();

    await http.runWithClient(() async {
      await openRoom(tester);

      await typeAndSend(tester, 'แก้คำผิด');

      server.fail(0);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('แก้คำผิด'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('แก้ไขข้อความ'));
      await tester.pumpAndSettle();

      expect(input(tester).controller!.text, 'แก้คำผิด');
      expect(find.textContaining('ส่งไม่สำเร็จ'), findsNothing);

      await closeRoom(tester);
    }, () => MockClient(server.handle));
  });
}
