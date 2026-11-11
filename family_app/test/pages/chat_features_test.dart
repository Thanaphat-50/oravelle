import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:family_app/pages/chat_room_page.dart';
import 'package:family_app/pages/group_chat_page.dart';
import 'package:family_app/widgets/chat_room_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ห้องแชทแบบใหม่: เส้นยังไม่อ่าน / อ่านแล้ว / ตอบกลับ / Reaction / ร่างข้อความ / หน้าจอเล็ก

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
  Map<String, dynamic>? replyTo,
  List<Map<String, dynamic>> reactions = const [],
  int? readCount,
}) {
  return {
    'id': id,
    'sender_id': mine ? 1 : 2,
    'sender': {'id': mine ? 1 : 2, 'name': mine ? 'แม่' : 'ลูก'},
    'is_mine': mine,
    'client_id': null,
    'body': body,
    'image_url': null,
    'created_at': DateTime.now().toUtc().toIso8601String(),
    'reply_to': replyTo,
    'reactions': reactions,
    'read_count': mine ? (readCount ?? 0) : null,
  };
}

// เซิร์ฟเวอร์จำลอง ใช้ได้ทั้งแชทส่วนตัว (/chats/1) และแชทกลุ่ม (/group-chats/7)
class FakeServer {
  final List<Map<String, dynamic>> messages;
  final List<http.Request> requests = [];
  Map<String, dynamic> conversation = {
    'id': 1,
    'can_send': true,
    'other_read_id': 0,
    'my_read_id': 0,
    'user': {'id': 2, 'name': 'ลูก'},
  };
  Map<String, dynamic> room = {
    'id': 7,
    'name': 'บ้านทดสอบ',
    'members_count': 4,
    'muted': false,
    'last_read_id': 0,
    'unread_count': 0,
  };
  List<Map<String, dynamic>> states = [];
  Completer<http.Response>? holdReaction;
  int nextId = 500;

  FakeServer(this.messages);

  Iterable<http.Request> get gets => requests.where(
    (r) => r.method == 'GET' && r.url.path.endsWith('/messages'),
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);

    final String path = request.url.path;
    final Map<String, String> query = request.url.queryParameters;

    if (path.endsWith('/unread-count') || path.endsWith('/read')) {
      return json({'status': true, 'unread_count': 0});
    }

    if (path.endsWith('/reaction')) {
      final Completer<http.Response>? hold = holdReaction;

      if (hold != null) return hold.future;

      final List<String> parts = path.split('/');
      final String? emoji = request.method == 'PUT'
          ? jsonDecode(request.body)['emoji'] as String
          : null;

      return json({
        'status': true,
        'message_id': int.parse(parts[parts.length - 2]),
        'reactions': [
          if (emoji != null) {'emoji': emoji, 'count': 1, 'mine': true},
        ],
      });
    }

    if (request.method == 'POST' && path.endsWith('/messages')) {
      final Map<String, dynamic> body = jsonDecode(request.body);
      final dynamic replyId = body['reply_to_id'];
      Map<String, dynamic>? source;

      for (final m in messages) {
        if (m['id'] == replyId) source = m;
      }

      final Map<String, dynamic> sent = {
        ...msg(
          nextId++,
          body['body'] as String,
          mine: true,
          replyTo: source == null
              ? null
              : {
                  'available': true,
                  'id': source['id'],
                  'sender_name': 'ลูก',
                  'is_mine': source['is_mine'],
                  'body': source['body'],
                  'has_image': false,
                },
        ),
        'client_id': body['client_id'],
      };

      messages.add(sent);

      return json({'status': true, 'message': sent}, 201);
    }

    // GET ข้อความ: after_id = ใหม่กว่า / before_id = เก่ากว่า (หน้าละ 30)
    List<Map<String, dynamic>> page;
    bool hasMore = false;

    if (query['after_id'] != null) {
      final int after = int.parse(query['after_id']!);

      page = messages.where((m) => (m['id'] as int) > after).toList();
    } else {
      final int? before = int.tryParse(query['before_id'] ?? '');
      final List<Map<String, dynamic>> older = messages
          .where((m) => before == null || (m['id'] as int) < before)
          .toList();

      hasMore = older.length > 30;
      page = older.sublist(max(0, older.length - 30));
    }

    return json({
      'status': true,
      'conversation': conversation,
      'room': room,
      'messages': page,
      'has_more': hasMore,
      'states': query['states_from'] == null ? [] : states,
    });
  }
}

Future<void> openPrivate(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: ChatRoomPage(conversationId: 1)),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

Future<void> chooseFromMenu(
  WidgetTester tester,
  String message,
  String item,
) async {
  await tester.longPress(find.text(message).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'token': 'test'});
    ChatDrafts.clear();
  });

  testWidgets('unread line and read status follow the real read positions', (
    tester,
  ) async {
    final server = FakeServer([
      msg(1, 'สวัสดี', mine: true),
      msg(2, 'ตอบแล้วนะ'),
      msg(3, 'มาไหม'),
      msg(4, 'ไปจ้า', mine: true),
    ]);
    server.conversation = {
      ...server.conversation,
      'my_read_id': 1,
      'other_read_id': 1,
    };

    await http.runWithClient(() async {
      await openPrivate(tester);

      expect(find.text('ข้อความที่ยังไม่ได้อ่าน'), findsOneWidget);
      expect(find.textContaining('อ่านแล้ว'), findsOneWidget);
      expect(find.textContaining('ส่งแล้ว'), findsOneWidget);
      expect(find.textContaining('ออนไลน์'), findsNothing);

      // โหลดข้อความไม่นับว่าอ่าน / แสดงล่างสุดแล้วจึงบอกว่าอ่านถึงข้อความล่าสุด
      expect(
        server.gets.every((r) => r.url.queryParameters['mark_read'] == '0'),
        isTrue,
      );

      final reads = server.requests.where((r) => r.url.path.endsWith('/read'));

      expect(reads, hasLength(1));
      expect(jsonDecode(reads.single.body)['message_id'], 4);

      await close(tester);
    }, () => MockClient(server.handle));
  });

  testWidgets('reply from menu or swipe, cancel, and send with reply id', (
    tester,
  ) async {
    final server = FakeServer([msg(1, 'กินข้าวยัง'), msg(2, 'มาไหม')]);

    await http.runWithClient(() async {
      await openPrivate(tester);

      await chooseFromMenu(tester, 'มาไหม', 'ตอบกลับ');
      expect(find.text('ตอบกลับ ลูก'), findsOneWidget);

      await tester.tap(find.byTooltip('ยกเลิกการตอบกลับ'));
      await tester.pumpAndSettle();
      expect(find.text('ตอบกลับ ลูก'), findsNothing);

      // ปัดขวาเพื่อตอบกลับ
      await tester.drag(find.text('มาไหม'), const Offset(140, 0));
      await tester.pumpAndSettle();
      expect(find.text('ตอบกลับ ลูก'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ไปสิ');
      await tester.pump();
      await tester.tap(find.byTooltip('ส่ง'));
      await tester.pumpAndSettle();

      final post = server.requests.lastWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/messages'),
      );

      expect(jsonDecode(post.body)['reply_to_id'], 2);
      expect(find.text('ตอบกลับ ลูก'), findsNothing);
      // ข้อความต้นทาง + ข้อความอ้างอิงในฟองใหม่
      expect(find.text('มาไหม'), findsNWidgets(2));
      expect(find.text('ไปสิ'), findsOneWidget);

      await close(tester);
    }, () => MockClient(server.handle));
  });

  testWidgets('reaction shows at once and rolls back when saving fails', (
    tester,
  ) async {
    final server = FakeServer([msg(1, 'มาไหม')]);

    await http.runWithClient(() async {
      await openPrivate(tester);

      await chooseFromMenu(tester, 'มาไหม', '❤️');
      expect(find.text('❤️ 1'), findsOneWidget);
      // ป้ายกว้างตามเนื้อหา ไม่ขยายเต็มแถว
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text('❤️ 1'),
                    matching: find.byType(Container),
                  )
                  .first,
            )
            .width,
        lessThan(120),
      );

      // เปลี่ยนเป็น 😂: บนจอเปลี่ยนทันที → เซิร์ฟเวอร์ล้ม → กลับเป็น ❤️
      server.holdReaction = Completer<http.Response>();

      await chooseFromMenu(tester, 'มาไหม', '😂');
      expect(find.text('😂 1'), findsOneWidget);
      expect(find.text('❤️ 1'), findsNothing);

      server.holdReaction!.complete(json({'message': 'Server Error'}, 500));
      await tester.pumpAndSettle();

      expect(find.text('❤️ 1'), findsOneWidget);
      expect(find.text('😂 1'), findsNothing);
      expect(
        find.text('ระบบขัดข้องชั่วคราว กรุณาลองใหม่อีกสักครู่'),
        findsOneWidget,
      );

      // แตะอีโมจิของเราใต้ข้อความ = ถอน
      server.holdReaction = null;
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .hideCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('❤️ 1'));
      await tester.pumpAndSettle();
      expect(find.text('❤️ 1'), findsNothing);

      await close(tester);
    }, () => MockClient(server.handle));
  });

  testWidgets(
    'tapping a quote loads older pages to the source; unavailable quotes hide content',
    (tester) async {
      final server = FakeServer([
        for (int i = 1; i <= 38; i++) msg(i, 'ข้อความ $i'),
        msg(39, 'ตอบข้อความที่ลบแล้ว', replyTo: {'available': false}),
        msg(
          40,
          'ตอบข้อความเก่า',
          replyTo: {
            'available': true,
            'id': 2,
            'sender_name': 'ลูก',
            'is_mine': false,
            'body': 'ข้อความ 2',
            'has_image': false,
          },
        ),
      ]);

      await http.runWithClient(() async {
        await openPrivate(tester);

        expect(find.text('ข้อความนี้ไม่พร้อมใช้งาน'), findsOneWidget);
        expect(find.text('ข้อความ 2'), findsOneWidget);

        await tester.tap(find.text('ข้อความ 2'));
        await tester.pumpAndSettle();

        expect(
          server.gets.any((r) => r.url.queryParameters['before_id'] == '11'),
          isTrue,
        );
        // ต้นทางขึ้นบนจอแล้ว (ไม่ใช่แค่ข้อความอ้างอิง)
        expect(find.text('ข้อความ 1'), findsOneWidget);
        expect(find.text('ข้อความ 2').hitTestable(), findsWidgets);

        // ไปต้นทางไม่ได้นับว่าอ่าน (ยังบอกอ่านแค่ตอนเปิดห้อง)
        expect(
          server.requests.where((r) => r.url.path.endsWith('/read')),
          hasLength(1),
        );

        await close(tester);
      }, () => MockClient(server.handle));
    },
  );

  testWidgets(
    'group shows read counts and refreshes states of loaded messages',
    (tester) async {
      final server = FakeServer([
        msg(1, 'กินข้าวยัง'),
        msg(2, 'กินแล้ว', mine: true, readCount: 2),
      ]);

      await http.runWithClient(() async {
        await tester.pumpWidget(
          const MaterialApp(home: GroupChatPage(chatId: 7)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        expect(find.text('แชทกลุ่ม · สมาชิก 4 คน'), findsOneWidget);
        expect(find.textContaining('อ่านแล้ว 2 คน'), findsOneWidget);

        server.states = [
          {
            'id': 1,
            'reactions': [
              {'emoji': '👍', 'count': 2, 'mine': false},
            ],
          },
          {'id': 2, 'reactions': [], 'read_count': 3},
        ];

        await tester.pump(GroupChatPage.pollInterval);
        await tester.pump(const Duration(milliseconds: 100));

        expect(server.gets.last.url.queryParameters['states_from'], '1');
        expect(find.text('👍 2'), findsOneWidget);
        expect(find.textContaining('อ่านแล้ว 3 คน'), findsOneWidget);

        await close(tester);
      }, () => MockClient(server.handle));
    },
  );

  testWidgets('draft stays when leaving and coming back to the room', (
    tester,
  ) async {
    final server = FakeServer([msg(1, 'มาไหม')]);

    await http.runWithClient(() async {
      await openPrivate(tester);
      await tester.enterText(find.byType(TextField), 'ร่างไว้ก่อน');
      await tester.pump();
      await close(tester);

      await openPrivate(tester);

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'ร่างไว้ก่อน',
      );

      await close(tester);
    }, () => MockClient(server.handle));
  });

  testWidgets(
    'small screen, large text and dark mode with reply and reactions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final server = FakeServer([
        msg(
          1,
          'ข้อความยาวมากสำหรับทดสอบการตัดบรรทัดบนจอเล็กและตัวอักษรใหญ่',
          reactions: [
            {'emoji': '👍', 'count': 3, 'mine': true},
            {'emoji': '❤️', 'count': 12, 'mine': false},
            {'emoji': '😂', 'count': 1, 'mine': false},
          ],
        ),
        msg(
          2,
          'ข้อความตอบ',
          mine: true,
          replyTo: {
            'available': true,
            'id': 1,
            'sender_name': 'ลูก',
            'is_mine': false,
            'body': 'ข้อความยาวมากสำหรับทดสอบการตัดบรรทัด',
            'has_image': false,
          },
        ),
      ]);

      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: const ChatRoomPage(conversationId: 1),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        await chooseFromMenu(tester, 'ข้อความตอบ', 'ตอบกลับ');

        expect(tester.takeException(), isNull);
        expect(find.text('ตอบกลับ ข้อความของคุณ'), findsOneWidget);

        await close(tester);
      }, () => MockClient(server.handle));
    },
  );
}
