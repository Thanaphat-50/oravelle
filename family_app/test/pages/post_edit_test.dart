import 'dart:convert';
import 'dart:io';

import 'package:family_app/pages/feed_page.dart';
import 'package:family_app/pages/post_edit_page.dart';
import 'package:family_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// แก้ไขโพสต์: ฟอร์ม / บันทึกไม่สำเร็จข้อความยังอยู่ / แก้ชนกัน / ถามก่อนทิ้ง / ข้อความล้วนห้ามว่าง
// / เมนูเฉพาะเจ้าของ / ข้อความใหม่แสดงทั้งในการ์ดและต้นฉบับของโพสต์แชร์

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> post({
  int id = 1,
  String content = 'ข้อความเดิม',
  bool mine = true,
  int version = 0,
  String? editedAt,
  Map<String, dynamic>? shared,
}) => {
  'id': id,
  'user_id': mine ? 1 : 2,
  'user': {'id': mine ? 1 : 2, 'name': mine ? 'แม่' : 'พ่อ'},
  'content': content,
  'visibility': 'community',
  'category': 'general',
  'comments': [],
  'images': [],
  'likes_count': 3,
  'shares_count': 0,
  'liked_by_me': false,
  'is_mine': mine,
  'edit_version': version,
  'edited_at': editedAt,
  'created_at': '2026-11-09T10:00:00Z',
  'shared_post_id': shared?['id'],
  'shared_post': shared,
};

// เปิดหน้าแก้ไขจากหน้าว่าง แล้วเก็บผลที่ pop กลับมา
Future<List<Object?>> openEditor(
  WidgetTester tester,
  Map<String, dynamic> data,
) async {
  final List<Object?> results = [];

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => PostEditPage(post: data)),
                  ),
                );
              },
              child: const Text('เปิด'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('เปิด'));
  await tester.pumpAndSettle();

  return results;
}

FilledButton saveButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'บันทึก'));

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  tearDown(() => AppColors.palette = AppPalette.light);

  testWidgets('saves only real changes; failed save keeps the draft', (
    tester,
  ) async {
    final List<Map<String, dynamic>> bodies = [];
    bool networkDown = true;

    await http.runWithClient(
      () async {
        final results = await openEditor(tester, post());

        expect(find.widgetWithText(TextField, 'ข้อความเดิม'), findsOneWidget);

        // ยังไม่เปลี่ยน → กดบันทึกไม่ได้
        expect(saveButton(tester).onPressed, isNull);

        await tester.enterText(find.byType(TextField), 'ข้อความใหม่');
        await tester.pump();
        await tester.tap(find.text('บันทึก'));
        await tester.pump(const Duration(milliseconds: 50));

        // เน็ตหลุด → ยังอยู่หน้าเดิม ข้อความร่างยังอยู่
        expect(find.text('แก้ไขโพสต์'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'ข้อความใหม่'), findsOneWidget);
        expect(results, isEmpty);

        networkDown = false;
        await tester.tap(find.text('บันทึก'));
        await tester.pumpAndSettle();

        expect(bodies.last, {'content': 'ข้อความใหม่', 'version': 0});
        expect((results.single as Map)['content'], 'ข้อความใหม่');
      },
      () => MockClient((request) async {
        if (networkDown) throw const SocketException('down');

        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);

        return json({
          'status': true,
          'changed': true,
          'post': post(
            content: 'ข้อความใหม่',
            version: 1,
            editedAt: '2026-11-10T10:00:00Z',
          ),
        });
      }),
    );
  });

  testWidgets('edit conflict shows the newest text and lets the user choose', (
    tester,
  ) async {
    final List<Map<String, dynamic>> bodies = [];

    await http.runWithClient(
      () async {
        final results = await openEditor(tester, post());

        await tester.enterText(find.byType(TextField), 'จากแท็บเล็ต');
        await tester.pump();
        await tester.tap(find.text('บันทึก'));
        await tester.pumpAndSettle();

        expect(find.text('มีการแก้ไขจากอีกเครื่อง'), findsOneWidget);
        expect(find.text('จากมือถือ'), findsOneWidget);

        await tester.tap(find.text('ใช้ข้อความล่าสุด'));
        await tester.pumpAndSettle();

        // ใช้ข้อความล่าสุด → ไม่มีอะไรต้องบันทึก
        expect(find.widgetWithText(TextField, 'จากมือถือ'), findsOneWidget);
        expect(saveButton(tester).onPressed, isNull);

        // แก้ต่อแล้วบันทึก → ส่ง version ล่าสุด
        await tester.enterText(find.byType(TextField), 'จากมือถือ (แก้ต่อ)');
        await tester.pump();
        await tester.tap(find.text('บันทึก'));
        await tester.pumpAndSettle();

        expect(bodies.last['version'], 1);
        expect(results, hasLength(1));
      },
      () => MockClient((request) async {
        final Map<String, dynamic> body =
            jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);

        if (body['version'] == 0) {
          return json({
            'status': false,
            'code': 'edit_conflict',
            'message': 'โพสต์นี้ถูกแก้ไขจากอีกเครื่องแล้ว',
            'post': post(content: 'จากมือถือ', version: 1),
          }, 409);
        }

        return json({
          'status': true,
          'post': post(content: body['content'] as String, version: 2),
        });
      }),
    );
  });

  testWidgets('asks before discarding and blocks empty text-only posts', (
    tester,
  ) async {
    int requests = 0;

    await http.runWithClient(
      () async {
        final results = await openEditor(tester, post());

        await tester.enterText(find.byType(TextField), '   ');
        await tester.pump();
        await tester.tap(find.text('บันทึก'));
        await tester.pump();

        expect(requests, 0);
        expect(find.textContaining('กรุณาพิมพ์ข้อความ'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'ยังไม่บันทึก');
        await tester.pump();
        await tester.tap(find.byTooltip('ยกเลิก'));
        await tester.pumpAndSettle();

        expect(find.text('ทิ้งการแก้ไข?'), findsOneWidget);
        await tester.tap(find.text('แก้ต่อ'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, 'ยังไม่บันทึก'), findsOneWidget);

        await tester.tap(find.byTooltip('ยกเลิก'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ทิ้ง'));
        await tester.pumpAndSettle();

        expect(find.text('แก้ไขโพสต์'), findsNothing);
        expect(results.single, isNull);
      },
      () => MockClient((_) async {
        requests++;
        return json({'status': true});
      }),
    );
  });

  testWidgets('deleted post while editing keeps the draft and explains', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await openEditor(tester, post());

      await tester.enterText(find.byType(TextField), 'แก้หลังถูกลบ');
      await tester.pump();
      await tester.tap(find.text('บันทึก'));
      await tester.pumpAndSettle();

      expect(find.text('ไม่พบโพสต์นี้ หรือโพสต์ถูกลบไปแล้ว'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'แก้หลังถูกลบ'), findsOneWidget);
      expect(saveButton(tester).onPressed, isNull);
    }, () => MockClient((_) async => json({'message': 'not found'}, 404)));
  });

  testWidgets('menu shows edit only on own posts; new text shows everywhere', (
    tester,
  ) async {
    final Map<String, dynamic> mine = post(content: 'ข่าวเดิม');

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: FeedPage(scope: FeedScope.community, hashtag: 'ข่าว'),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        // โพสต์ของคนอื่น (แชร์โพสต์ของเรา) → ไม่มีปุ่มแก้ไข
        await tester.tap(find.byTooltip('ตัวเลือกโพสต์').last);
        await tester.pumpAndSettle();
        expect(find.text('แก้ไขโพสต์'), findsNothing);
        expect(find.text('รายงานโพสต์'), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('ตัวเลือกโพสต์').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('แก้ไขโพสต์'));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField), 'ข่าวแก้แล้ว');
        await tester.pump();
        await tester.tap(find.text('บันทึก'));
        await tester.pumpAndSettle();

        // การ์ดของเรา + ต้นฉบับในโพสต์ที่แชร์ต่อ อัปเดตทั้งคู่ ยอดถูกใจเดิม
        expect(find.text('ข่าวแก้แล้ว'), findsNWidgets(2));
        expect(find.text('ข่าวเดิม'), findsNothing);
        expect(find.textContaining('แก้ไขแล้ว'), findsWidgets);
        expect(find.text('3'), findsWidgets);
      },
      () => MockClient((request) async {
        if (request.method == 'PATCH') {
          return json({
            'status': true,
            'post': post(
              content: 'ข่าวแก้แล้ว',
              version: 1,
              editedAt: '2026-11-10T10:00:00Z',
            ),
          });
        }

        return json({
          'status': true,
          'posts': [
            mine,
            post(id: 2, mine: false, content: 'แชร์ต่อ', shared: mine),
          ],
          'current_user': {
            'id': 1,
            'name': 'แม่',
            'community_terms_accepted': true,
          },
          'page': 1,
          'has_more': false,
        });
      }),
    );
  });

  testWidgets('edit form fits a small screen with large text in dark mode', (
    tester,
  ) async {
    AppColors.palette = AppPalette.dark;
    tester.view.physicalSize = const Size(320 * 3, 560 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 560),
            textScaler: TextScaler.linear(2),
          ),
          child: PostEditPage(post: post(content: 'ข้อความยาว ' * 40)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('แก้ไขโพสต์'), findsOneWidget);
  });
}
