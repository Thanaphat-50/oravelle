import 'dart:convert';
import 'dart:io';

import 'package:family_app/pages/chat_room_page.dart';
import 'package:family_app/services/auth_service.dart';
import 'package:family_app/services/chat_background_store.dart';
import 'package:family_app/widgets/chat_room_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// พื้นหลังแชท: แยกบัญชี + ห้อง / อยู่ต่อหลังเปิดแอปใหม่ / รูปเก็บในพื้นที่ของแอป / ห้องแสดงพื้นหลัง

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('chat_bg_');
    ChatBackgroundStore.testDirectory = dir;
    ChatBackgroundStore.forgetCache();
  });

  tearDown(() {
    ChatBackgroundStore.testDirectory = null;
    ChatBackgroundStore.forgetCache();
    AuthService.currentUserId = null;

    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'settings are per account and room and survive an app restart',
    () async {
      const color = ChatBackground(
        kind: 'color',
        value: '4294309365',
        dim: 0.4,
      );

      await ChatBackgroundStore.save(1, 'chat:7', color);

      expect(await ChatBackgroundStore.load(1, 'chat:7'), color);
      // บัญชีอื่นในเครื่องเดียวกัน / ห้องอื่น → ไม่ปะปน
      expect(await ChatBackgroundStore.load(2, 'chat:7'), isNull);
      expect(await ChatBackgroundStore.load(1, 'group:7'), isNull);

      // เปิดแอปใหม่ → อ่านจากไฟล์
      ChatBackgroundStore.forgetCache();
      expect(await ChatBackgroundStore.load(1, 'chat:7'), color);

      await ChatBackgroundStore.reset(1, 'chat:7');
      ChatBackgroundStore.forgetCache();
      expect(await ChatBackgroundStore.load(1, 'chat:7'), isNull);
    },
  );

  test('photos are copied into app storage and replaced copies are removed', () async {
    final File picked = File(
      '${Directory.systemTemp.path}/picked_${DateTime.now().microsecondsSinceEpoch}.jpg',
    )..writeAsBytesSync([1, 2, 3]);

    final ChatBackground stored = await ChatBackgroundStore.save(
      1,
      'chat:7',
      ChatBackground(kind: 'image', value: picked.path),
    );

    expect(stored.value.startsWith(dir.path), isTrue);
    expect(File(stored.value).existsSync(), isTrue);

    // เปลี่ยนเป็นพื้นหลังสำเร็จรูป → สำเนารูปเดิมถูกลบ
    await ChatBackgroundStore.save(
      1,
      'chat:7',
      const ChatBackground(kind: 'preset', value: 'sky'),
    );
    expect(File(stored.value).existsSync(), isFalse);

    picked.deleteSync();
  });

  testWidgets('room shows the saved background and opens the settings page', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({'token': 'test'});
    ChatDrafts.clear();
    AuthService.currentUserId = 1;

    await tester.runAsync(
      () => ChatBackgroundStore.save(
        1,
        'chat:1',
        const ChatBackground(kind: 'preset', value: 'night', dim: 0.2),
      ),
    );

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: ChatRoomPage(conversationId: 1)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        final layer = tester.widget<ChatBackgroundLayer>(
          find.byType(ChatBackgroundLayer).first,
        );
        expect(layer.background?.value, 'night');

        await tester.tap(find.byTooltip('ตัวเลือกห้อง'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('พื้นหลังแชท'));
        await tester.pumpAndSettle();

        expect(find.text('พื้นหลังสำเร็จรูป'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.textContaining('ไม่ซิงก์ไปเครื่องอื่น'),
          200,
        );
        expect(find.textContaining('ไม่ซิงก์ไปเครื่องอื่น'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient(
        (request) async => http.Response(
          jsonEncode({
            'status': true,
            'conversation': {
              'id': 1,
              'can_send': true,
              'other_read_id': 0,
              'my_read_id': 0,
              'user': {'id': 2, 'name': 'ลูก'},
            },
            'messages': [
              {
                'id': 1,
                'is_mine': false,
                'body': 'สวัสดี',
                'created_at': DateTime.now().toUtc().toIso8601String(),
              },
            ],
            'has_more': false,
            'states': [],
            'unread_count': 0,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
  });
}
