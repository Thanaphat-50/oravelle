import 'dart:convert';

import 'package:family_app/pages/feed_page.dart';
import 'package:family_app/widgets/like_heart.dart';
import 'package:family_app/widgets/photo_viewer.dart';
import 'package:family_app/widgets/section_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// แอนิเมชัน 5 จุด: พฤติกรรมสำคัญเท่านั้น (ไม่ผูกกับทุกเฟรม)
// - ปุ่ม ＋ แบบขยาย: กดซ้ำเปิดครั้งเดียว / ย้อนกลับปิดเมนูก่อน / ร่างไม่หาย
// - หัวใจ: เล่นเฉพาะตอนผู้ใช้กด ไม่เล่นจากข้อมูลใหม่ / ลดการเคลื่อนไหวไม่เล่น
// - แท็บแบบปุ่มแบ่งช่อง: กดแท็บเดิมไม่เรียกซ้ำ
// - รูปเต็มจอ: รูปเดียวกันหลายที่ tag ไม่ชนกัน
// ข้อมูลจำลองทั้งหมด (MockClient) ไม่ส่งอะไรถึงใครจริง

http.Response jsonResponse(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

MockClient feedServer() => MockClient((request) async {
  if (request.url.path.endsWith('/posts')) {
    return jsonResponse({
      'status': true,
      'posts': [],
      'current_user': {
        'id': 1,
        'name': 'แม่',
        'community_terms_accepted': true,
      },
      'page': 1,
      'next_cursor': null,
      'has_more': false,
    });
  }

  return jsonResponse({'status': true, 'hashtags': [], 'users': []});
});

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  testWidgets('compose menu opens once, back closes it first, draft survives', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: FeedPage(scope: FeedScope.community)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final Finder fab = find.byTooltip('สร้างโพสต์ในชุมชน (เปิดเมนู)');

      // กดรัว 2 ครั้ง → เมนูเดียว
      await tester.tap(fab);
      await tester.tap(fab, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('เขียนโพสต์'), findsOneWidget);
      expect(find.text('รูปภาพ'), findsOneWidget);
      expect(find.text('วิดีโอ'), findsOneWidget);
      expect(find.text('โพสต์ในชุมชน • ทุกคนในชุมชนเห็น'), findsOneWidget);

      // ย้อนกลับ → ปิดเมนู หน้าเดิมยังอยู่
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('เขียนโพสต์'), findsNothing);
      expect(fab, findsOneWidget);

      // เขียนร่าง → ปิดหน้าต่าง → เปิดใหม่ → ร่างยังอยู่
      await tester.tap(fab);
      await tester.pumpAndSettle();
      await tester.tap(find.text('เขียนโพสต์'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'ร่างโพสต์ทดสอบ');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('ร่างโพสต์ทดสอบ'), findsNothing);

      await tester.tap(fab);
      await tester.pumpAndSettle();
      await tester.tap(find.text('เขียนโพสต์'));
      await tester.pumpAndSettle();

      expect(find.text('ร่างโพสต์ทดสอบ'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    }, feedServer);
  });

  Widget heart({required bool liked, required int pulse, bool reduce = false}) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Center(
          child: LikeHeart(
            liked: liked,
            pulse: pulse,
            likedColor: Colors.pink,
            color: Colors.black,
          ),
        ),
      ),
    );
  }

  Finder scaled() => find.descendant(
    of: find.byType(LikeHeart),
    matching: find.byType(Transform),
  );

  testWidgets('heart animates only on user taps, not on data refresh', (
    tester,
  ) async {
    await tester.pumpWidget(heart(liked: false, pulse: 0));

    // ข้อมูลใหม่จากเซิร์ฟเวอร์ (pulse เดิม) → เปลี่ยนไอคอนทันที ไม่เล่น
    await tester.pumpWidget(heart(liked: true, pulse: 0));
    await tester.pump(const Duration(milliseconds: 40));
    expect(scaled(), findsNothing);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

    // ผู้ใช้กด (pulse เพิ่ม) → เล่นสั้น ๆ แล้วจบ
    await tester.pumpWidget(heart(liked: false, pulse: 1));
    await tester.pump(const Duration(milliseconds: 40));
    expect(scaled(), findsOneWidget);
    await tester.pumpAndSettle();
    expect(scaled(), findsNothing);

    // ลดการเคลื่อนไหว → เปลี่ยนสถานะโดยไม่เล่น
    await tester.pumpWidget(heart(liked: true, pulse: 2, reduce: true));
    await tester.pump(const Duration(milliseconds: 40));
    expect(scaled(), findsNothing);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
  });

  testWidgets('segment switch ignores taps on the selected tab', (
    tester,
  ) async {
    final List<String> changes = [];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SectionSwitch<String>(
            value: 'posts',
            onChanged: changes.add,
            options: const [
              SectionOption(value: 'posts', icon: Icons.forum, label: 'โพสต์'),
              SectionOption(
                value: 'members',
                icon: Icons.groups,
                label: 'สมาชิก',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('โพสต์'));
    await tester.tap(find.text('สมาชิก'));
    await tester.pumpAndSettle();

    expect(changes, ['members']);
  });

  testWidgets('same photo in two places opens without hero tag clashes', (
    tester,
  ) async {
    final PhotoHeroTags tags = PhotoHeroTags();
    final Map<String, dynamic> first = {'id': 1};
    final Map<String, dynamic> second = {'id': 2};

    // เจ้าของเดิม = tag เดิม (ไม่เปลี่ยนตอน rebuild) / คนละเจ้าของ = คนละ tag
    expect(identical(tags.of(first, 1).first, tags.of(first, 1).first), isTrue);
    expect(tags.of(first, 1).first == tags.of(second, 1).first, isFalse);

    const String url = 'https://example.test/same.jpg';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                for (final owner in [first, second])
                  GestureDetector(
                    onTap: () => showPhotoViewer(
                      context,
                      urls: [url],
                      heroTags: tags.of(owner, 1),
                    ),
                    child: SizedBox(
                      key: ValueKey('thumb-${owner['id']}'),
                      width: 80,
                      height: 80,
                      child: PhotoHero(
                        tag: tags.of(owner, 1).first,
                        child: Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) =>
                              const ColoredBox(color: Colors.grey),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('thumb-2')));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoViewerPage), findsOneWidget);

    await tester.tap(find.byTooltip('ปิด'));
    await tester.pumpAndSettle();

    expect(find.byType(PhotoViewerPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
