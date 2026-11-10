import 'dart:convert';
import 'dart:io';

import 'package:family_app/pages/group_chat_page.dart';
import 'package:family_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// แชทกลุ่ม: เปิดห้อง / ชื่อผู้ส่ง / ส่งไม่สำเร็จแล้วส่งใหม่ด้วยรหัสเดิม / ข้อความร่างใหม่ไม่หาย
// / ไม่แสดงซ้ำ / ปุ่ม "ข้อความใหม่" / อ่านแล้วเฉพาะตอนเห็น / หมดสิทธิ์ล้างข้อความ / ปิดเสียง

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> msg(
  int id,
  String body, {
  bool mine = false,
  String name = 'พ่อ',
  String? clientId,
}) => {
  'id': id,
  'sender': {'id': mine ? 1 : 2, 'name': mine ? 'แม่' : name},
  'is_mine': mine,
  'client_id': clientId,
  'body': body,
  'image_url': null,
  'created_at': '2026-11-10T03:00:00Z',
};

class FakeGroupServer {
  List<Map<String, dynamic>> messages = [];
  final List<String> calls = [];
  final List<Map<String, dynamic>> sends = [];
  final List<int> reads = [];
  bool failSend = false;
  bool lost = false;
  bool failOlder = false;
  bool muted = false;

  Map<String, dynamic> room() => {
    'id': 7,
    'family_id': 3,
    'name': 'บ้านทดสอบ',
    'members_count': 4,
    'muted': muted,
    'last_read_id': 0,
    'unread_count': 0,
  };

  Future<http.Response> handle(http.Request request) async {
    final String path = request.url.path;
    calls.add('${request.method} $path');

    if (lost) {
      return json({
        'status': false,
        'code': 'not_member',
        'message':
            'คุณไม่ได้อยู่ในกลุ่มนี้แล้ว จึงเปิดหรือส่งข้อความในแชทกลุ่มไม่ได้',
      }, 403);
    }

    if (path.endsWith('/group-chat/open')) {
      return json({'status': true, 'room': room()});
    }

    if (path.endsWith('/read')) {
      reads.add((jsonDecode(request.body) as Map)['message_id'] as int);
      return json({'status': true, 'unread_count': 0});
    }

    if (path.endsWith('/mute')) {
      muted = (jsonDecode(request.body) as Map)['muted'] == true;
      return json({
        'status': true,
        'muted': muted,
        'message': muted
            ? 'ปิดเสียงแจ้งเตือนห้องนี้แล้ว ยังรับข้อความตามปกติ'
            : 'เปิดเสียงแจ้งเตือนห้องนี้แล้ว',
      });
    }

    if (request.method == 'POST' && path.endsWith('/messages')) {
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      sends.add(body);

      if (failSend) throw const SocketException('down');

      final Map<String, dynamic> sent = msg(
        100 + sends.length,
        body['body'] as String,
        mine: true,
        clientId: body['client_id'] as String,
      );
      messages.add(sent);

      return json({'status': true, 'message': sent}, 201);
    }

    final String? before = request.url.queryParameters['before_id'];
    final String? after = request.url.queryParameters['after_id'];

    if (before != null) {
      if (failOlder) throw const SocketException('down');

      return json({
        'status': true,
        'room': room(),
        'messages': [msg(1, 'เก่ามาก')],
        'has_more': false,
      });
    }

    final List<Map<String, dynamic>> page = after == null
        ? messages
        : messages.where((m) => (m['id'] as int) > int.parse(after)).toList();

    return json({
      'status': true,
      'room': room(),
      'messages': page,
      'has_more': after == null && messages.length >= 30,
    });
  }
}

Future<void> openRoom(WidgetTester tester, {int? chatId}) async {
  await tester.pumpWidget(MaterialApp(home: GroupChatPage(chatId: chatId)));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  tearDown(() => AppColors.palette = AppPalette.light);

  testWidgets('opens the group room and shows who sent what', (tester) async {
    final server = FakeGroupServer()
      ..messages = [
        msg(10, 'สวัสดีทุกคน', name: 'พ่อ'),
        msg(11, 'วันนี้กินอะไร', name: 'พ่อ'),
        msg(12, 'ข้าวผัด', mine: true),
      ];

    await http.runWithClient(() async {
      await openRoom(tester);

      expect(server.calls.first, 'POST /api/group-chat/open');
      expect(find.text('บ้านทดสอบ'), findsOneWidget);
      expect(find.text('แชทกลุ่ม · สมาชิก 4 คน'), findsOneWidget);
      // ชื่อผู้ส่งแสดงครั้งเดียวต่อช่วงที่ส่งติดกัน
      expect(find.text('พ่อ'), findsOneWidget);
      expect(find.text('ข้าวผัด'), findsOneWidget);

      // อยู่ล่างสุด → อ่านถึงข้อความล่าสุด
      expect(server.reads, [12]);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('failed send keeps the next draft and retries with the same id', (
    tester,
  ) async {
    final server = FakeGroupServer()..failSend = true;

    await http.runWithClient(() async {
      await openRoom(tester, chatId: 7);

      await tester.enterText(find.byType(TextField), 'นัดเย็นนี้');
      await tester.pump();
      await tester.tap(find.byTooltip('ส่ง'));
      await tester.pump();

      // ช่องพิมพ์ว่างทันที → พิมพ์ข้อความถัดไประหว่างรอ
      await tester.enterText(find.byType(TextField), 'ข้อความถัดไป');
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('ส่งไม่สำเร็จ · แตะเพื่อส่งอีกครั้ง'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'ข้อความถัดไป'), findsOneWidget);

      server.failSend = false;
      await tester.tap(find.text('นัดเย็นนี้'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ส่งอีกครั้ง'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(server.sends, hasLength(2));
      expect(server.sends[0]['client_id'], server.sends[1]['client_id']);
      expect(find.text('นัดเย็นนี้'), findsOneWidget);
      expect(find.text('ส่งไม่สำเร็จ · แตะเพื่อส่งอีกครั้ง'), findsNothing);
      // ข้อความร่างถัดไปยังอยู่
      expect(find.widgetWithText(TextField, 'ข้อความถัดไป'), findsOneWidget);

      // รอบดึงข้อความใหม่ได้ข้อความเดียวกันมาอีก → ไม่แสดงซ้ำ
      await tester.pump(GroupChatPage.pollInterval);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('นัดเย็นนี้'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('reading older messages shows a new-messages button instead', (
    tester,
  ) async {
    final server = FakeGroupServer()
      ..messages = [for (int i = 1; i <= 30; i++) msg(100 + i, 'ข้อความ $i')];

    await http.runWithClient(() async {
      await openRoom(tester, chatId: 7);
      expect(server.reads, [130]);

      // เลื่อนขึ้นไปอ่านข้อความเก่า → โหลดเก่าไม่สำเร็จ ข้อความเดิมอยู่ครบ
      server.failOlder = true;
      await tester.drag(find.byType(ListView), const Offset(0, 3000));
      await tester.pumpAndSettle();
      // คำขอโหลดข้อความเก่า (อ่าน token จากที่เก็บในเครื่องก่อน) จบในเฟรมถัดไป
      await tester.pump(const Duration(milliseconds: 100));
      // ปุ่มลองใหม่อยู่บนสุดของรายการ → เลื่อนขึ้นอีกนิดให้เห็น
      await tester.drag(find.byType(ListView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.textContaining('โหลดข้อความเก่าไม่สำเร็จ'), findsOneWidget);
      expect(find.text('ข้อความ 1'), findsOneWidget);

      // มีข้อความใหม่ตอนอ่านข้างบน → ไม่เลื่อนลงเอง ไม่นับว่าอ่าน
      server.messages.add(msg(131, 'ข้อความใหม่จากพ่อ'));
      await tester.pump(GroupChatPage.pollInterval);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('ข้อความใหม่ 1'), findsOneWidget);
      expect(server.reads, [130]);

      await tester.tap(find.text('ข้อความใหม่ 1'));
      await tester.pumpAndSettle();

      expect(server.reads.last, 131);
      expect(find.text('ข้อความใหม่จากพ่อ'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('losing access clears the room and stops sending', (
    tester,
  ) async {
    final server = FakeGroupServer()..messages = [msg(10, 'เรื่องในบ้าน')];

    await http.runWithClient(() async {
      await openRoom(tester, chatId: 7);
      expect(find.text('เรื่องในบ้าน'), findsOneWidget);

      server.lost = true;
      await tester.pump(GroupChatPage.pollInterval);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('เรื่องในบ้าน'), findsNothing);
      expect(find.textContaining('ไม่ได้อยู่ในกลุ่มนี้แล้ว'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      final int calls = server.calls.length;
      await tester.pump(GroupChatPage.pollInterval * 3);
      expect(server.calls.length, calls);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('mute is a personal toggle with a clear message', (tester) async {
    final server = FakeGroupServer();

    await http.runWithClient(() async {
      await openRoom(tester, chatId: 7);

      expect(find.textContaining('ยังไม่มีข้อความในกลุ่ม'), findsOneWidget);

      await tester.tap(find.byTooltip('ปิดเสียงแจ้งเตือนห้องนี้'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(server.muted, isTrue);
      expect(
        find.text('ปิดเสียงแจ้งเตือนห้องนี้แล้ว ยังรับข้อความตามปกติ'),
        findsOneWidget,
      );
      expect(find.byTooltip('เปิดเสียงแจ้งเตือนห้องนี้'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('fits a small screen with large text in dark mode', (
    tester,
  ) async {
    AppColors.palette = AppPalette.dark;
    tester.view.physicalSize = const Size(320 * 3, 560 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final server = FakeGroupServer()
      ..messages = [
        msg(10, 'ข้อความยาว ' * 20, name: 'คุณยายผู้มีชื่อยาวมาก ๆ'),
        msg(11, 'ตอบสั้น ๆ', mine: true),
      ];

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(320, 560),
              textScaler: TextScaler.linear(2),
            ),
            child: GroupChatPage(chatId: 7),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('ตอบสั้น ๆ'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });
}
