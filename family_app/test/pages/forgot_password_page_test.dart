import 'dart:convert';

import 'package:family_app/pages/forgot_password_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// ลืมรหัสผ่าน: ขอรหัส → กรอกรหัสผิด (ข้อมูลที่กรอกยังอยู่) → กรอกถูก → กลับหน้าเข้าสู่ระบบพร้อมอีเมล

http.Response json(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  testWidgets('wrong code keeps the form, right code returns the email', (
    tester,
  ) async {
    final List<Map<String, dynamic>> resets = [];

    Future<http.Response> server(http.Request request) async {
      if (request.url.path.endsWith('/password/forgot')) {
        return json({
          'status': true,
          'message': 'ถ้าอีเมลนี้มีบัญชี ORAVELLE เราส่งรหัส 6 หลักไปให้แล้ว',
          'resend_seconds': 60,
        });
      }

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      resets.add(body);

      return body['code'] == '123456'
          ? json({'status': true, 'message': 'ตั้งรหัสผ่านใหม่แล้ว'})
          : json({
              'status': false,
              'message': 'x',
              'errors': {
                'code': [
                  'รหัสไม่ถูกต้องหรือหมดอายุ กรุณาตรวจรหัสในอีเมล หรือขอรหัสใหม่',
                ],
              },
            }, 422);
    }

    String? popped;

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const ForgotPasswordPage(email: 'mom@example.com'),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ส่งรหัสไปที่อีเมล'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('เราส่งรหัส 6 หลักไปให้แล้ว'), findsOneWidget);
      expect(find.text('ขอรหัสใหม่ได้ใน 60 วินาที'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '000000');
      await tester.enterText(fields.at(1), 'new-password-1');
      await tester.enterText(fields.at(2), 'new-password-1');

      await tester.tap(find.text('ตั้งรหัสผ่านใหม่'));
      await tester.pump(const Duration(milliseconds: 100));

      // ผิด: บอกเหตุผลภาษาไทย ข้อมูลที่กรอกยังอยู่
      expect(find.textContaining('รหัสไม่ถูกต้องหรือหมดอายุ'), findsOneWidget);
      expect(find.text('new-password-1'), findsNWidgets(2));
      expect(popped, isNull);

      await tester.enterText(fields.at(0), '123456');
      await tester.tap(find.text('ตั้งรหัสผ่านใหม่'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(popped, 'mom@example.com');
      expect(resets.last['email'], 'mom@example.com');
      expect(resets.last['password_confirmation'], 'new-password-1');
    }, () => MockClient(server));
  });
}
