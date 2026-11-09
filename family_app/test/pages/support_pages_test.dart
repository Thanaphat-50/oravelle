import 'dart:convert';
import 'dart:io';

import 'package:family_app/pages/support_ticket_form_page.dart';
import 'package:family_app/pages/support_ticket_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ศูนย์ช่วยเหลือ: เรื่องเดิมที่ยังไม่ปิด / ส่งไม่สำเร็จแล้วข้อมูลไม่หาย / ส่งใหม่ใช้รหัสเดิม / เรื่องที่ปิดแล้ว

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> ticket({
  int id = 7,
  String status = 'submitted',
  List<Map<String, dynamic>> messages = const [],
}) => {
  'id': id,
  'code': 'HT261109ABCDE',
  'category': 'refund',
  'category_label': 'คืนเงิน',
  'subject': 'ยังไม่ได้รับเงินคืน',
  'status': status,
  'status_label': status == 'closed' ? 'ปิดเรื่อง' : 'ส่งแล้ว',
  'order': {'id': 3, 'code': 'OR261109XYZ'},
  'previous_ticket': null,
  'can_reply': status != 'closed',
  'resolution': status == 'closed' ? 'ร้านโอนคืนแล้ว ตรวจสลิปแล้ว' : null,
  'closed_at': null,
  'created_at': '2026-11-09T10:00:00Z',
  'updated_at': '2026-11-09T10:00:00Z',
  'messages': messages,
};

// ค่าของช่องใน multipart
String? field(http.Request request, String name) {
  // ช่องที่เป็นภาษาไทยมีหัว content-type ต่อท้ายก่อนบรรทัดว่าง
  final match = RegExp(
    'name="$name"\\r\\n(?:[^\\r\\n]+\\r\\n)*\\r\\n([^\\r]*)\\r\\n',
  ).firstMatch(utf8.decode(request.bodyBytes, allowMalformed: true));

  return match?.group(1);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 'test'}));

  testWidgets('order form offers the open ticket, failed send keeps the form', (
    tester,
  ) async {
    final List<http.Request> posts = [];
    bool networkDown = true;

    Future<http.Response> server(http.Request request) async {
      if (request.method == 'GET') {
        // เข้าจากออเดอร์: ยังไม่มีเรื่องเดิม
        return json({'status': true, 'ticket': null});
      }

      posts.add(request);

      if (networkDown) {
        throw const SocketException('down');
      }

      if (field(request, 'confirm_new') == null) {
        return json({
          'status': false,
          'code': 'open_ticket_exists',
          'message': 'มีเรื่องที่ยังไม่ปิดของคำสั่งซื้อนี้อยู่แล้ว',
          'ticket': ticket(id: 5),
        }, 409);
      }

      return json({'status': true, 'ticket': ticket(id: 9)}, 201);
    }

    int? created;

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                created = await Navigator.of(context).push<int>(
                  MaterialPageRoute(
                    builder: (_) => const SupportTicketFormPage(
                      category: 'refund',
                      subject: 'ยังไม่ได้รับเงินคืน',
                      order: {'id': 3, 'code': 'OR261109XYZ'},
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('OR261109XYZ'), findsWidgets);
      expect(find.textContaining('ไม่เปลี่ยนสถานะคำสั่งซื้อ'), findsOneWidget);
      expect(find.textContaining('สูงสุด 4 รูป'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField).at(1),
        'ร้านบอกว่าโอนแล้วแต่เงินไม่เข้า',
      );

      final submit = find.text('ส่งเรื่องให้ทีมงานตรวจสอบ');

      // เน็ตขาด → ข้อมูลยังอยู่
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.textContaining('เชื่อมต่อไม่ได้'), findsOneWidget);
      expect(find.text('ร้านบอกว่าโอนแล้วแต่เงินไม่เข้า'), findsOneWidget);

      // ส่งใหม่ (รหัสเดิม) → มีเรื่องเดิม → เลือกเขียนเรื่องใหม่ → ส่งพร้อม confirm_new
      networkDown = false;
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      expect(find.text('มีเรื่องที่ยังไม่ปิดอยู่แล้ว'), findsOneWidget);

      await tester.tap(find.text('เขียนเรื่องใหม่'));
      await tester.pumpAndSettle();

      expect(created, 9);
      expect(posts, hasLength(3));
      expect(field(posts[0], 'client_id'), isNotNull);
      expect(field(posts[1], 'client_id'), field(posts[0], 'client_id'));
      expect(field(posts[2], 'client_id'), field(posts[0], 'client_id'));
      expect(field(posts[2], 'confirm_new'), '1');
      expect(field(posts[2], 'order_id'), '3');
    }, () => MockClient(server));
  });

  testWidgets(
    'reply draft survives a failed send and retries with the same id',
    (tester) async {
      final List<http.Request> posts = [];
      bool fail = true;

      Future<http.Response> server(http.Request request) async {
        if (request.method == 'GET') {
          return json({
            'status': true,
            'ticket': ticket(
              messages: [
                {
                  'id': 1,
                  'from': 'staff',
                  'author': 'ทีมงาน ORAVELLE',
                  'body': 'ขอสลิปการโอนคืนด้วยครับ',
                  'attachments': [],
                  'created_at': '2026-11-09T10:05:00Z',
                },
              ],
            ),
          });
        }

        posts.add(request);

        if (fail) return json({'message': 'Server Error'}, 500);

        return json({
          'status': true,
          'message': {
            'id': 2,
            'from': 'me',
            'author': 'คุณ',
            'body': field(request, 'body'),
            'attachments': [],
            'created_at': '2026-11-09T10:06:00Z',
          },
          'ticket': ticket(),
        }, 201);
      }

      await http.runWithClient(() async {
        await tester.pumpWidget(
          const MaterialApp(home: SupportTicketPage(ticketId: 7)),
        );
        await tester.pumpAndSettle();

        expect(find.text('ทีมงาน ORAVELLE', findRichText: true), findsNothing);
        expect(find.textContaining('ทีมงาน ORAVELLE'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'ยังไม่มีสลิปเลยครับ');
        await tester.tap(find.byTooltip('ส่ง'));
        await tester.pumpAndSettle();

        expect(find.textContaining('ข้อความยังอยู่'), findsOneWidget);
        expect(find.text('ยังไม่มีสลิปเลยครับ'), findsOneWidget);

        fail = false;
        await tester.tap(find.byTooltip('ส่ง'));
        await tester.pumpAndSettle();

        expect(field(posts[1], 'client_id'), field(posts[0], 'client_id'));
        expect(find.textContaining('ข้อความยังอยู่'), findsNothing);
        // ส่งแล้วขึ้นในรายการ (SelectableText) ช่องพิมพ์ว่าง
        expect(
          find.byWidgetPredicate(
            (w) => w is SelectableText && w.data == 'ยังไม่มีสลิปเลยครับ',
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '',
        );
      }, () => MockClient(server));
    },
  );

  testWidgets('closed ticket shows the summary and no reply box', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          const MaterialApp(home: SupportTicketPage(ticketId: 7)),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('สรุปผล: ร้านโอนคืนแล้ว'), findsOneWidget);
        expect(
          find.textContaining('สร้างเรื่องใหม่โดยอ้างอิงเรื่องนี้'),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsNothing);
      },
      () => MockClient(
        (_) async => json({'status': true, 'ticket': ticket(status: 'closed')}),
      ),
    );
  });
}
