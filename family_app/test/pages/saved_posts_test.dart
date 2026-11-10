import 'dart:convert';
import 'dart:io';

import 'package:family_app/pages/feed_page.dart';
import 'package:family_app/pages/saved_posts_page.dart';
import 'package:family_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// บันทึกโพสต์: เมนูบันทึก/ยกเลิก (คืนสถานะเมื่อไม่สำเร็จ) / โพสต์กลุ่มของคนอื่นมีแค่บันทึก
// / หน้าโพสต์ที่บันทึก: ยกเลิกแล้วหาย, หน้าถัดไปล้มแล้วรายการเดิมอยู่, ว่าง, จอเล็ก โหมดมืด

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> post(
  int id, {
  bool mine = false,
  bool saved = false,
  String visibility = 'community',
}) => {
  'id': id,
  'user_id': mine ? 1 : 2,
  'user': {'id': mine ? 1 : 2, 'name': mine ? 'แม่' : 'พ่อ'},
  'content': 'โพสต์ $id',
  'visibility': visibility,
  'category': visibility == 'community' ? 'general' : null,
  'comments': [],
  'images': [],
  'likes_count': 0,
  'shares_count': 0,
  'liked_by_me': false,
  'saved_by_me': saved,
  'is_mine': mine,
  'edit_version': 0,
  'created_at': '2026-11-09T10:00:00Z',
};

Map<String, dynamic> page(List<Map<String, dynamic>> posts, {String? next}) => {
  'status': true,
  'posts': posts,
  'current_user': {'id': 1, 'name': 'แม่', 'community_terms_accepted': true},
  'page': 1,
  'next_cursor': next,
  'has_more': next != null,
};

Future<void> openMenu(WidgetTester tester, {int index = 0}) async {
  await tester.tap(find.byTooltip('ตัวเลือกโพสต์').at(index));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  tearDown(() => AppColors.palette = AppPalette.light);

  testWidgets('save from the menu, failed request restores the old state', (
    tester,
  ) async {
    final List<String> calls = [];
    bool fail = false;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: FeedPage(scope: FeedScope.community, hashtag: 'x'),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        await openMenu(tester);
        await tester.tap(find.text('บันทึกโพสต์'));
        await tester.pumpAndSettle();

        expect(calls, ['PUT /api/posts/1/save']);
        expect(find.text('บันทึกโพสต์แล้ว'), findsOneWidget);

        await openMenu(tester);
        expect(find.text('ยกเลิกบันทึก'), findsOneWidget);

        // ไม่สำเร็จ → กลับเป็น "บันทึกแล้ว" + แจ้ง
        fail = true;
        await tester.tap(find.text('ยกเลิกบันทึก'));
        await tester.pumpAndSettle();

        expect(calls.last, 'DELETE /api/posts/1/save');
        // แจ้งข้อผิดพลาด (ข้อความจากระบบเครือข่าย)
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('ยกเลิกบันทึกแล้ว'), findsNothing);

        await openMenu(tester);
        expect(find.text('ยกเลิกบันทึก'), findsOneWidget);
      },
      () => MockClient((request) async {
        if (request.method == 'GET') {
          return json(page([post(1), post(2, visibility: 'family')]));
        }

        calls.add('${request.method} ${request.url.path}');

        if (fail) throw const SocketException('down');

        return json({'status': true, 'saved': request.method == 'PUT'});
      }),
    );
  });

  testWidgets("other people's group posts only offer saving", (tester) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: FeedPage(scope: FeedScope.community, hashtag: 'x'),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));

        await openMenu(tester);

        expect(find.text('บันทึกโพสต์'), findsOneWidget);
        expect(find.text('รายงานโพสต์'), findsNothing);
        expect(find.textContaining('บล็อก'), findsNothing);
        expect(find.text('แก้ไขโพสต์'), findsNothing);
      },
      () =>
          MockClient((_) async => json(page([post(5, visibility: 'family')]))),
    );
  });

  testWidgets('saved page: unsave removes, failed next page keeps the list', (
    tester,
  ) async {
    bool failPage2 = true;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(const MaterialApp(home: SavedPostsPage()));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('โพสต์ที่บันทึก'), findsOneWidget);
        expect(find.text('โพสต์ 1'), findsOneWidget);

        // ยกเลิกบันทึกโพสต์แรก → หายจากรายการ
        await openMenu(tester);
        await tester.tap(find.text('ยกเลิกบันทึก'));
        await tester.pumpAndSettle();
        expect(find.text('โพสต์ 1'), findsNothing);

        // เลื่อนลง → หน้า 2 ล้มเหลว → รายการเดิมยังอยู่ + ปุ่มลองใหม่
        await tester.drag(find.byType(ListView).first, const Offset(0, -20000));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('โหลดเพิ่มไม่สำเร็จ'), findsOneWidget);
        expect(find.text('โพสต์ 20'), findsOneWidget);

        failPage2 = false;
        await tester.tap(find.text('ลองอีกครั้ง'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.drag(find.byType(ListView).first, const Offset(0, -20000));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('โพสต์ 21'), findsOneWidget);
        expect(find.text('ไม่มีโพสต์เพิ่มแล้ว'), findsOneWidget);
      },
      () => MockClient((request) async {
        if (request.method == 'DELETE') {
          return json({'status': true, 'saved': false});
        }

        if (request.url.queryParameters['cursor'] == 'c20') {
          if (failPage2) return json({'message': 'Server Error'}, 500);

          return json(page([post(21, saved: true)]));
        }

        return json(
          page([
            for (int i = 1; i <= 20; i++) post(i, saved: true),
          ], next: 'c20'),
        );
      }),
    );
  });

  testWidgets('empty saved list and dark large text fit a small screen', (
    tester,
  ) async {
    AppColors.palette = AppPalette.dark;
    tester.view.physicalSize = const Size(320 * 3, 560 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(320, 560),
              textScaler: TextScaler.linear(2),
            ),
            child: SavedPostsPage(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('ยังไม่มีโพสต์ที่บันทึก'), findsOneWidget);
    }, () => MockClient((_) async => json(page([]))));
  });
}
