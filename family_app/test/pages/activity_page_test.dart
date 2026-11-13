import 'dart:convert';

import 'package:family_app/pages/activity_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// หน้ากิจกรรม: ตัวกรอง/แบ่งหน้าบนเซิร์ฟเวอร์ และแก้ไขไม่สำเร็จแล้วฟอร์มไม่หาย

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> activity(int id, String title) => {
  'id': id,
  'title': title,
  'description': null,
  'activity_date': '2026-11-09T14:30:00',
  'visibility': 'private',
  'is_completed': false,
  'is_mine': true,
  'can_manage': true,
  'user': {'id': 1, 'name': 'แม่'},
};

class FakeActivityServer {
  final List<Uri> gets = [];
  final List<Map<String, dynamic>> patches = [];
  bool failPatch = true;

  Future<http.Response> handle(http.Request request) async {
    if (request.method == 'PATCH') {
      patches.add(jsonDecode(request.body) as Map<String, dynamic>);

      return failPatch
          ? json({'message': 'Server Error'}, 500)
          : json({'status': true, 'activity': activity(1, 'แก้แล้ว')});
    }

    gets.add(request.url);

    final String filter = request.url.queryParameters['filter'] ?? 'all';
    final int page = int.parse(request.url.queryParameters['page'] ?? '1');

    final List<Map<String, dynamic>> items = filter == 'today'
        ? [activity(500, 'งานวันนี้จากเซิร์ฟเวอร์')]
        : [
            for (int i = 1; i <= 20; i++)
              activity((page - 1) * 20 + i, 'งาน ${(page - 1) * 20 + i}'),
          ];

    return json({
      'status': true,
      'activities': items,
      'page': page,
      'has_more': filter == 'all' && page == 1,
      'counts': {
        'all': 40,
        'today': 1,
        'overdue': 3,
        'completed': 5,
        'mine': 40,
        'family': 0,
      },
      'family': {'has_family': false, 'id': null},
    });
  }
}

Future<void> openPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: ActivityPage()));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  testWidgets('filters ask the server and more pages load on scroll', (
    tester,
  ) async {
    final server = FakeActivityServer();

    await http.runWithClient(() async {
      await openPage(tester);

      final Uri first = server.gets.first;
      expect(first.queryParameters['page'], '1');
      expect(first.queryParameters['filter'], 'all');
      expect(first.queryParameters['now'], isNotNull);

      // จำนวนจากเซิร์ฟเวอร์ (ไม่ใช่แค่ 20 รายการที่โหลด)
      expect(find.text('40 รายการ'), findsOneWidget);
      expect(find.text('เลยกำหนด 3'), findsOneWidget);

      // เลื่อนลง → หน้า 2
      await tester.drag(find.byType(ListView).first, const Offset(0, -6000));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        server.gets.any((uri) => uri.queryParameters['page'] == '2'),
        isTrue,
      );

      // ตัวกรองวันนี้ → เซิร์ฟเวอร์กรองให้
      await tester.drag(find.byType(ListView).first, const Offset(0, 6000));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('วันนี้ 1'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(server.gets.last.queryParameters['filter'], 'today');
      expect(find.text('งานวันนี้จากเซิร์ฟเวอร์'), findsOneWidget);
      expect(find.text('งาน 1'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });

  testWidgets('failed edit reopens the form with what was typed', (
    tester,
  ) async {
    final server = FakeActivityServer();

    await http.runWithClient(() async {
      await openPage(tester);

      await tester.tap(find.byTooltip('จัดการ').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('แก้ไข'));
      await tester.pumpAndSettle();

      expect(find.text('แก้ไขกิจกรรม'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'งาน 1'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'งาน 1'),
        'ชื่อใหม่',
      );
      await tester.ensureVisible(find.text('บันทึกการแก้ไข'));
      await tester.tap(find.text('บันทึกการแก้ไข'));
      // ปิดฟอร์ม → รอ 250ms → ส่งคำขอ
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // บันทึกไม่สำเร็จ → ฟอร์มเปิดใหม่พร้อมชื่อที่พิมพ์ไว้
      expect(server.patches.single['title'], 'ชื่อใหม่');
      expect(server.patches.single['activity_date'], '2026-11-09T14:30:00.000');
      expect(find.text('แก้ไขกิจกรรม'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'ชื่อใหม่'), findsOneWidget);

      server.failPatch = false;

      await tester.ensureVisible(find.text('บันทึกการแก้ไข'));
      await tester.tap(find.text('บันทึกการแก้ไข'));
      // ปิดฟอร์ม → รอ 250ms → ส่งคำขอ
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(server.patches, hasLength(2));
      expect(find.text('แก้ไขกิจกรรม'), findsNothing);

      // ให้ตัวจับเวลาทิ้งช่องกรอกของฟอร์มทำงานให้ครบ
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient(server.handle));
  });
}
