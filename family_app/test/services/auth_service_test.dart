import 'dart:async';
import 'dart:io';

import 'package:family_app/services/api_helper.dart';
import 'package:family_app/services/auth_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// AuthService: ตรวจเซสชันตอนเปิดแอป / เข้าสู่ระบบ / ออกจากระบบ
// ลบ token เฉพาะ 401 หรือผู้ใช้กดออกจากระบบ (เน็ตล่ม / 5xx เก็บไว้)

const String token = 'test-token';

http.Response json(
  int status,
  String body, {
  Map<String, String> headers = const {},
}) {
  return http.Response(
    body,
    status,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
  );
}

// เรียก AuthService โดยให้ http ทุกคำขอไปที่ handler นี้
Future<T> withServer<T>(
  Future<T> Function() body,
  Future<http.Response> Function(http.Request request) handler,
) {
  return http.runWithClient(body, () => MockClient(handler));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int unauthorizedCalls;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'token': token});
    unauthorizedCalls = 0;
    ApiHelper.onUnauthorized = () async => unauthorizedCalls++;
  });

  tearDown(() {
    ApiHelper.onUnauthorized = null;
    ApiHelper.timeout = const Duration(seconds: 15);
    AuthService.logoutTimeLimit = const Duration(seconds: 5);
  });

  group('checkSession (เปิดแอป)', () {
    test('no token → sign-in page without calling the server', () async {
      FlutterSecureStorage.setMockInitialValues({});

      var calls = 0;

      final result = await withServer(AuthService.checkSession, (_) async {
        calls++;
        return json(200, '{}');
      });

      expect(result.state, SessionState.signedOut);
      expect(calls, 0);
    });

    test('valid token → signed in', () async {
      final result = await withServer(AuthService.checkSession, (
        request,
      ) async {
        expect(request.headers['Authorization'], 'Bearer $token');
        return json(200, '{"id":1,"name":"แม่"}');
      });

      expect(result.state, SessionState.signedIn);
      expect(result.user?['name'], 'แม่');
    });

    test('401 → expired, token removed', () async {
      final result = await withServer(
        AuthService.checkSession,
        (_) async => json(401, '{"message":"Unauthenticated."}'),
      );

      expect(result.state, SessionState.expired);
      expect(result.message, ApiHelper.sessionExpiredMessage);
      expect(await AuthService.getToken(), isNull);
    });

    test('no internet → offline, token kept', () async {
      final result = await withServer(
        AuthService.checkSession,
        (_) async => throw const SocketException('Network is unreachable'),
      );

      expect(result.state, SessionState.offline);
      expect(result.message, ApiHelper.networkMessage);
      expect(await AuthService.getToken(), token);
    });

    test(
      'server too slow → offline (no endless loading), token kept',
      () async {
        ApiHelper.timeout = const Duration(milliseconds: 100);

        final result = await withServer(
          AuthService.checkSession,
          (_) => Completer<http.Response>().future,
        );

        expect(result.state, SessionState.offline);
        expect(result.message, ApiHelper.timeoutMessage);
        expect(await AuthService.getToken(), token);
      },
    );

    test('500 / HTML → server error, token kept', () async {
      for (final res in [
        json(500, '{"message":"Server Error"}'),
        http.Response('<html>maintenance</html>', 200),
      ]) {
        final result = await withServer(
          AuthService.checkSession,
          (_) async => res,
        );

        expect(result.state, SessionState.serverError);
        expect(await AuthService.getToken(), token);
      }

      expect(unauthorizedCalls, 0);
    });
  });

  group('login', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    Future<Map<String, dynamic>> login(http.Response res) {
      return withServer(
        () => AuthService.login(email: 'mom@example.com', password: 'secret'),
        (_) async => res,
      );
    }

    test('success saves the token', () async {
      final data = await login(
        json(200, '{"status":true,"token":"new-token","user":{"name":"แม่"}}'),
      );

      expect(data['status'], true);
      expect(await AuthService.getToken(), 'new-token');
    });

    test('wrong password (422 or 401) is a message, not a session expiry', () async {
      final wrong = await login(
        json(
          422,
          '{"message":"x","errors":{"email":["อีเมลหรือรหัสผ่านไม่ถูกต้อง"]}}',
        ),
      );

      expect(wrong['message'], 'อีเมลหรือรหัสผ่านไม่ถูกต้อง');

      final unauthorized = await login(
        json(401, '{"message":"Unauthenticated."}'),
      );

      expect(unauthorized['status'], false);

      await Future<void>.delayed(Duration.zero);

      expect(unauthorizedCalls, 0);
      expect(await AuthService.getToken(), isNull);
    });

    test('too many attempts (429) shows the wait in Thai', () async {
      final data = await login(
        json(
          429,
          '{"status":false,"message":"ลองหลายครั้งเกินไป กรุณารอ 60 วินาทีแล้วลองใหม่"}',
        ),
      );

      expect(data['message'], contains('60 วินาที'));
    });

    test('500 and non-JSON throw Thai errors (page stops loading)', () async {
      await expectLater(
        login(json(500, '{"message":"Server Error"}')),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            ApiHelper.serverMessage,
          ),
        ),
      );

      await expectLater(
        login(http.Response('<html>Wi-Fi login</html>', 200)),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.invalidResponse,
          ),
        ),
      );
    });
  });

  group('logout', () {
    test(
      'signs out on the device even when the server never answers',
      () async {
        AuthService.logoutTimeLimit = const Duration(milliseconds: 150);

        final stopwatch = Stopwatch()..start();

        await withServer(
          AuthService.logout,
          (_) => Completer<http.Response>().future,
        );

        expect(await AuthService.getToken(), isNull);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );

    test('tells the server to revoke the token', () async {
      String? sent;

      await withServer(AuthService.logout, (request) async {
        sent = request.headers['Authorization'];
        return json(200, '{"status":true}');
      });

      expect(sent, 'Bearer $token');
      expect(await AuthService.getToken(), isNull);
    });
  });
}
