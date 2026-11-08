import 'dart:async';
import 'dart:io';

import 'package:family_app/services/api_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// ApiHelper: เน็ตล่ม / หมดเวลา / 401 / 422 / 429 / 500 / ไม่ใช่ JSON
// ผู้ใช้ต้องเห็นข้อความภาษาไทยเสมอ และ 401 ทำให้ออกจากระบบเฉพาะคำขอที่ใช้ token

http.Response response(
  int status,
  String body, {
  Map<String, String> headers = const {},
}) {
  return http.Response(
    body,
    status,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
    request: http.Request(
      'GET',
      Uri.parse('https://example.test/api/orders?x=1'),
    ),
  );
}

void main() {
  late int unauthorizedCalls;

  setUp(() {
    unauthorizedCalls = 0;
    ApiHelper.onUnauthorized = () async => unauthorizedCalls++;
  });

  tearDown(() {
    ApiHelper.onUnauthorized = null;
    ApiHelper.timeout = const Duration(seconds: 15);
  });

  group('decode', () {
    test('2xx JSON is returned as is', () {
      expect(ApiHelper.decode(response(200, '{"status":true,"id":5}')), {
        'status': true,
        'id': 5,
      });
    });

    test('empty 204 counts as success', () {
      expect(ApiHelper.decode(response(204, '')), {'status': true});
    });

    test('HTML with 200 (e.g. Wi-Fi login page) is an invalid response', () {
      expect(
        () => ApiHelper.decode(response(200, '<html>Sign in to Wi-Fi</html>')),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.invalidResponse)
              .having(
                (e) => e.message,
                'message',
                ApiHelper.invalidResponseMessage,
              ),
        ),
      );
    });

    test('500 and 502 HTML are Thai server errors and do not sign out', () {
      for (final res in [
        response(500, '{"message":"Server Error"}'),
        response(502, '<html>Bad Gateway</html>'),
      ]) {
        expect(
          () => ApiHelper.decode(res),
          throwsA(
            isA<ApiException>()
                .having((e) => e.kind, 'kind', ApiErrorKind.server)
                .having((e) => e.isTemporary, 'temporary', true)
                .having((e) => e.message, 'message', ApiHelper.serverMessage),
          ),
        );
      }

      expect(unauthorizedCalls, 0);
    });

    test('401 on a signed-in request expires the session once', () async {
      expect(
        () => ApiHelper.decode(response(401, '{"message":"Unauthenticated."}')),
        throwsA(isA<SessionExpiredException>()),
      );

      await Future<void>.delayed(Duration.zero);

      expect(unauthorizedCalls, 1);
    });

    test('401 on the login page is just a message (no sign out)', () async {
      final data = ApiHelper.decode(
        response(401, '{"message":"Unauthenticated."}'),
        session: false,
      );

      await Future<void>.delayed(Duration.zero);

      expect(unauthorizedCalls, 0);
      expect(data['status'], false);
      expect(data['message'], contains('เข้าสู่ระบบไม่สำเร็จ'));
    });

    test('422 shows the first Thai field error without Laravel suffix', () {
      final data = ApiHelper.decode(
        response(
          422,
          '{"message":"อีเมลหรือรหัสผ่านไม่ถูกต้อง (and 1 more error)",'
          '"errors":{"email":["อีเมลหรือรหัสผ่านไม่ถูกต้อง"],"password":["กรุณาใส่รหัสผ่าน"]}}',
        ),
        session: false,
      );

      expect(data['message'], 'อีเมลหรือรหัสผ่านไม่ถูกต้อง');
      expect(data['status'], false);
      expect(data['errors'], isA<Map>());
    });

    test('422 with Laravel English default becomes Thai', () {
      final data = ApiHelper.decode(
        response(
          422,
          '{"message":"The email field is required.","errors":{"email":["The email field is required."]}}',
        ),
      );

      expect(data['message'], 'ข้อมูลไม่ถูกต้อง กรุณาตรวจสอบแล้วลองอีกครั้ง');
    });

    test('429 keeps Thai server text or explains the wait', () {
      expect(
        ApiHelper.decode(
          response(
            429,
            '{"message":"Too Many Attempts."}',
            headers: {'retry-after': '42'},
          ),
        )['message'],
        'ทำรายการบ่อยเกินไป กรุณารอ 42 วินาทีแล้วลองใหม่',
      );

      expect(
        ApiHelper.decode(
          response(
            429,
            '{"status":false,"message":"ลองหลายครั้งเกินไป กรุณารอ 60 วินาทีแล้วลองใหม่"}',
          ),
          session: false,
        )['message'],
        'ลองหลายครั้งเกินไป กรุณารอ 60 วินาทีแล้วลองใหม่',
      );
    });

    test('404 HTML is a Thai message, not raw HTML', () {
      expect(
        () => ApiHelper.decode(
          response(404, '<!DOCTYPE html><title>Not Found</title>'),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            'ไม่พบข้อมูลที่ต้องการ อาจถูกลบไปแล้ว',
          ),
        ),
      );
    });
  });

  group('request', () {
    test('no internet → network error', () {
      expect(
        () => ApiHelper.request(
          () => throw const SocketException('Failed host lookup'),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.network)
              .having((e) => e.message, 'message', ApiHelper.networkMessage),
        ),
      );
    });

    test('client exception → network error', () {
      expect(
        () => ApiHelper.request(
          () => throw http.ClientException('Connection reset'),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.network,
          ),
        ),
      );
    });

    test('no answer → stops waiting with a timeout error', () async {
      final stopwatch = Stopwatch()..start();

      await expectLater(
        ApiHelper.request(
          () => Completer<http.Response>().future,
          timeLimit: const Duration(milliseconds: 100),
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.timeout)
              .having((e) => e.message, 'message', ApiHelper.timeoutMessage),
        ),
      );

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('unexpected errors never show program details', () {
      expect(
        ApiHelper.messageOf(const FormatException('Unexpected <')),
        ApiHelper.unknownMessage,
      );
      expect(ApiHelper.messageOf(ApiException('ข้อความไทย')), 'ข้อความไทย');
    });
  });
}
