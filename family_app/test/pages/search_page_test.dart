import 'dart:async';
import 'dart:convert';

import 'package:family_app/pages/search_page.dart';
import 'package:family_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// หน้าค้นหา: รอหยุดพิมพ์ / ช่องว่างไม่เรียก API / ผลเก่าไม่ทับผลใหม่ / แท็บ / แบ่งหน้า + ลองใหม่
// / ค้นหาในกลุ่ม / ไม่พบผลลัพธ์ / จอเล็ก ตัวอักษรใหญ่ โหมดมืด

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> post(int id, String content) => {
  'id': id,
  'user_id': 2,
  'user': {'id': 2, 'name': 'พ่อ'},
  'content': content,
  'visibility': 'community',
  'category': 'general',
  'comments': [],
  'images': [],
  'likes_count': 0,
  'shares_count': 0,
  'liked_by_me': false,
  'is_mine': false,
  'created_at': '2026-11-09T10:00:00Z',
};

Map<String, dynamic> user(int id, String name) => {
  'id': id,
  'name': name,
  'profile_image_url': null,
  'is_me': false,
  'is_family': id == 2,
};

Map<String, dynamic> postsPage(List<Map<String, dynamic>> posts) => {
  'status': true,
  'posts': posts,
  'current_user': {'id': 1, 'name': 'แม่', 'community_terms_accepted': true},
  'next_cursor': null,
  'has_more': false,
};

class FakeSearchServer {
  final List<Uri> requests = [];

  // คำค้นที่ให้ตอบช้า (ทดสอบผลเก่า)
  final Map<String, Completer<void>> slow = {};

  bool failUsersPage2 = true;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url);

    final String q = request.url.queryParameters['q'] ?? '';

    final Completer<void>? wait = slow[q];
    if (wait != null) await wait.future;

    if (request.url.path.endsWith('/search/users')) {
      final String? cursor = request.url.queryParameters['cursor'];

      if (cursor == 'page2') {
        if (failUsersPage2) return json({'message': 'Server Error'}, 500);

        return json({
          'status': true,
          // id 20 ซ้ำกับหน้าแรก → ไม่แสดงซ้ำ
          'users': [user(20, 'สมาชิก 20'), user(21, 'สมาชิก 21')],
          'next_cursor': null,
          'has_more': false,
        });
      }

      return json({
        'status': true,
        'users': [for (int i = 1; i <= 20; i++) user(i, 'สมาชิก $i')],
        'next_cursor': 'page2',
        'has_more': true,
      });
    }

    if (request.url.queryParameters['scope'] == 'family') {
      return json({
        'status': false,
        'code': 'no_family',
        'message': 'คุณยังไม่ได้อยู่ในกลุ่ม จึงค้นหาโพสต์ในกลุ่มไม่ได้',
      }, 403);
    }

    if (q == 'ไม่มี') return json(postsPage([]));

    return json(postsPage([post(q.length, 'ผลของ $q')]));
  }

  List<Uri> get searches =>
      requests.where((uri) => uri.path.contains('/search/')).toList();
}

Future<void> openSearch(
  WidgetTester tester, {
  SearchArea area = SearchArea.community,
}) async {
  await tester.pumpWidget(MaterialApp(home: SearchPage(area: area)));
  await tester.pump();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  tearDown(() => AppColors.palette = AppPalette.light);

  testWidgets('waits 400 ms, trims, skips empty, keyboard search is instant', (
    tester,
  ) async {
    final server = FakeSearchServer();

    await http.runWithClient(() async {
      await openSearch(tester);

      expect(
        find.text('พิมพ์คำเพื่อค้นหาโพสต์ในชุมชน หรือชื่อผู้ใช้'),
        findsOneWidget,
      );

      // ช่องว่างอย่างเดียว → ไม่เรียก API
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump(const Duration(seconds: 1));
      expect(server.searches, isEmpty);

      await tester.enterText(find.byType(TextField), '  ตลาดน้ำ ');
      await tester.pump(const Duration(milliseconds: 399));
      expect(server.searches, isEmpty);

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 50));

      expect(server.searches.single.queryParameters['q'], 'ตลาดน้ำ');
      expect(server.searches.single.queryParameters['scope'], 'community');
      expect(find.text('ผลของ ตลาดน้ำ'), findsOneWidget);

      // ปุ่มค้นหาบนคีย์บอร์ด → ค้นทันที
      await tester.enterText(find.byType(TextField), 'garden day');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(server.searches.last.queryParameters['q'], 'garden day');
      expect(find.text('ผลของ garden day'), findsOneWidget);

      // ล้างคำค้น → กลับไปหน้าคำแนะนำ
      await tester.tap(find.byTooltip('ล้างคำค้น'));
      await tester.pump();
      expect(
        find.text('พิมพ์คำเพื่อค้นหาโพสต์ในชุมชน หรือชื่อผู้ใช้'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('a slow answer for an old query never replaces the new one', (
    tester,
  ) async {
    final server = FakeSearchServer();
    final Completer<void> slowOld = Completer<void>();
    server.slow['แม่'] = slowOld;

    await http.runWithClient(() async {
      await openSearch(tester);

      await tester.enterText(find.byType(TextField), 'แม่');
      await tester.pump(const Duration(milliseconds: 450));

      await tester.enterText(find.byType(TextField), 'แมว');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('ผลของ แมว'), findsOneWidget);

      // คำตอบของ "แม่" มาถึงทีหลัง → ไม่แสดง
      slowOld.complete();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('ผลของ แมว'), findsOneWidget);
      expect(find.text('ผลของ แม่'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('tabs keep their own results; failed next page keeps the list', (
    tester,
  ) async {
    final server = FakeSearchServer();

    await http.runWithClient(() async {
      await openSearch(tester);

      await tester.enterText(find.byType(TextField), 'สมาชิก');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // แท็บผู้ใช้ยังไม่เปิด → ยังไม่ค้นผู้ใช้
      expect(
        server.searches.where((uri) => uri.path.endsWith('/users')),
        isEmpty,
      );

      await tester.tap(find.text('ผู้ใช้'));
      await tester.pumpAndSettle();

      expect(find.text('สมาชิก 1'), findsOneWidget);
      expect(find.text('สมาชิกในกลุ่มของคุณ'), findsOneWidget);
      expect(server.searches.last.queryParameters['q'], 'สมาชิก');

      // เลื่อนลง → หน้า 2 ล้มเหลว → รายการเดิมยังอยู่ + ปุ่มลองใหม่
      await tester.drag(find.byType(ListView).last, const Offset(0, -3000));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(server.searches.last.queryParameters['cursor'], 'page2');
      expect(find.text('โหลดเพิ่มไม่สำเร็จ'), findsOneWidget);

      // เลื่อนต่อไม่ยิงซ้ำเอง
      final int before = server.searches.length;
      await tester.drag(find.byType(ListView).last, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 50));
      expect(server.searches.length, before);

      server.failUsersPage2 = false;
      await tester.tap(find.text('ลองอีกครั้ง'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('สมาชิก 21'), findsOneWidget);
      expect(find.text('สมาชิก 20'), findsOneWidget);
      expect(find.text('ไม่มีผลค้นหาเพิ่มแล้ว'), findsOneWidget);

      // กลับแท็บโพสต์ → ผลเดิม ไม่ค้นใหม่
      final int count = server.searches.length;
      await tester.tap(find.text('โพสต์'));
      await tester.pumpAndSettle();

      expect(find.text('ผลของ สมาชิก'), findsOneWidget);
      expect(server.searches.length, count);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('no results message shows the query', (tester) async {
    final server = FakeSearchServer();

    await http.runWithClient(() async {
      await openSearch(tester);

      await tester.enterText(find.byType(TextField), 'ไม่มี');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('ไม่พบโพสต์สำหรับคำว่า “ไม่มี”'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('group search is labelled and explains when not in a group', (
    tester,
  ) async {
    final server = FakeSearchServer();

    await http.runWithClient(() async {
      await openSearch(tester, area: SearchArea.family);

      expect(
        find.text('ค้นหาในกลุ่ม · เฉพาะโพสต์ในกลุ่มของคุณ'),
        findsOneWidget,
      );
      expect(find.text('ผู้ใช้'), findsNothing);

      await tester.enterText(find.byType(TextField), 'วันเกิด');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(server.searches.single.queryParameters['scope'], 'family');
      expect(
        server.searches.single.queryParameters.containsKey('family_id'),
        isFalse,
      );
      expect(
        find.text('คุณยังไม่ได้อยู่ในกลุ่ม จึงค้นหาโพสต์ในกลุ่มไม่ได้'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('small screen, large text and dark mode do not overflow', (
    tester,
  ) async {
    final server = FakeSearchServer();
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
            child: SearchPage(),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.enterText(find.byType(TextField), 'สมาชิก');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('ผู้ใช้'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('สมาชิก 1'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });
}
