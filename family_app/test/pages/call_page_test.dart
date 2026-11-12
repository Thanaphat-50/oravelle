import 'dart:convert';

import 'package:family_app/pages/call_page.dart';
import 'package:family_app/pages/chat_room_page.dart';
import 'package:family_app/services/call_media.dart';
import 'package:family_app/widgets/chat_room_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// หน้าสาย: รับ/ปฏิเสธ/วางสาย / เวลาเริ่มเมื่ออีกฝ่ายเชื่อมต่อจริง / รับที่เครื่องอื่น / ถูกตัดสาย
// สื่อจำลอง (ไม่ต่อ LiveKit จริง) + เซิร์ฟเวอร์จำลอง

class FakeMedia extends CallMedia {
  final List<String> log = [];
  bool remote = false;

  @override
  bool get remotePresent => remote;

  void joinRemote() {
    remote = true;
    onRemoteJoined?.call();
  }

  void leaveRemote() {
    remote = false;
    onRemoteLeft?.call();
  }

  @override
  Future<void> connect(String url, String token, {required bool video}) async =>
      log.add('connect $url $token video=$video');

  @override
  Future<void> setMicrophone(bool on) async => log.add('mic $on');

  @override
  Future<void> setCamera(bool on) async => log.add('camera $on');

  @override
  Future<void> switchCamera() async => log.add('switch');

  @override
  Future<void> setSpeaker(bool on) async => log.add('speaker $on');

  @override
  Widget? localVideo() => null;

  @override
  Widget? remoteVideo() => null;

  @override
  Future<void> disconnect() async => log.add('disconnect');
}

class FakeCalls {
  String status = 'ringing';
  int? deniedStatus;
  final List<String> posts = [];

  Map<String, dynamic> call(String role) => {
    'id': 5,
    'type': 'video',
    'status': status,
    'role': role,
    'other': {'id': 2, 'name': 'แม่'},
    'end_reason': null,
  };

  MockClient client(String role) => MockClient((request) async {
    final String path = request.url.path;
    Map<String, dynamic> body;
    int code = 200;

    if (request.method == 'POST') posts.add(path.split('/').last);

    if (path.endsWith('/accept')) {
      status = 'accepted';
      body = {
        'status': true,
        'call': call(role),
        'livekit': {'url': 'wss://lk.test', 'token': 'tok'},
      };
    } else if (path.endsWith('/decline')) {
      status = 'declined';
      body = {'status': true, 'call': call(role)};
    } else if (path.endsWith('/hangup')) {
      status = 'ended';
      body = {'status': true, 'call': call(role)};
    } else if (path.endsWith('/heartbeat') && deniedStatus != null) {
      code = deniedStatus!;
      status = 'failed';
      body = {
        'status': false,
        'code': 'session_revoked',
        'message': 'สายถูกตัด เพราะมีการออกจากระบบของอุปกรณ์ที่ใช้โทร',
        'call': call(role),
      };
    } else {
      body = {'status': true, 'call': call(role)};
    }

    return http.Response(
      jsonEncode(body),
      code,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

Future<void> openCall(
  WidgetTester tester,
  FakeCalls calls,
  FakeMedia media, {
  required bool incoming,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('ห้องแชท')),
    ),
  );

  navigator.currentState!.push(
    MaterialPageRoute(
      builder: (_) => CallPage(
        call: calls.call(incoming ? 'callee' : 'caller'),
        incoming: incoming,
        livekit: incoming ? null : {'url': 'wss://lk.test', 'token': 'caller'},
        mediaFactory: () => media,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'token': 'test'});
    ChatDrafts.clear();
  });

  // สิทธิ์ไมค์/กล้อง: อนุญาตแล้ว
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'),
          (call) async => call.method == 'checkPermissionStatus' ? 1 : null,
        );
  });

  testWidgets(
    'answer: timer starts only when the caller is connected, then hang up',
    (tester) async {
      final calls = FakeCalls();
      final media = FakeMedia();

      await http.runWithClient(() async {
        await openCall(tester, calls, media, incoming: true);

        expect(find.text('วิดีโอคอลเข้า'), findsOneWidget);
        expect(find.text('แม่'), findsOneWidget);

        await tester.tap(find.text('รับสาย'));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }

        expect(calls.posts, contains('accept'));
        expect(media.log, contains('connect wss://lk.test tok video=true'));
        expect(find.text('กำลังเชื่อมต่อ…'), findsOneWidget);

        // อีกฝ่ายเชื่อมต่อจริง → เริ่มนับเวลา
        media.joinRemote();
        await tester.pump();
        expect(find.text('0:00'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('0:02'), findsOneWidget);

        await tester.tap(find.text('ปิดไมค์'));
        await tester.pump();
        expect(media.log, contains('mic false'));
        expect(find.text('เปิดไมค์'), findsOneWidget);

        await tester.tap(find.text('สลับกล้อง'));
        await tester.pump();
        expect(media.log, contains('switch'));

        await tester.tap(find.text('วางสาย'));
        await tester.pump();
        expect(find.text('วางสายแล้ว'), findsOneWidget);
        expect(calls.posts, contains('hangup'));
        expect(media.log.last, 'disconnect');

        await tester.pump(CallPage.closeDelay);
        await tester.pumpAndSettle();
        expect(find.text('ห้องแชท'), findsOneWidget);
      }, () => calls.client('callee'));
    },
  );

  testWidgets('answered on another device: stops ringing without connecting', (
    tester,
  ) async {
    final calls = FakeCalls();
    final media = FakeMedia();

    await http.runWithClient(() async {
      await openCall(tester, calls, media, incoming: true);

      calls.status = 'accepted';
      await tester.pump(CallPage.ringPoll);
      await tester.pump();

      expect(find.text('รับสายที่อุปกรณ์อื่นแล้ว'), findsOneWidget);
      expect(media.log.where((l) => l.startsWith('connect')), isEmpty);

      await tester.pump(CallPage.closeDelay);
      await tester.pumpAndSettle();
      expect(find.text('ห้องแชท'), findsOneWidget);
    }, () => calls.client('callee'));
  });

  testWidgets(
    'outgoing: connects while ringing, then the other side declines',
    (tester) async {
      final calls = FakeCalls();
      final media = FakeMedia();

      await http.runWithClient(() async {
        await openCall(tester, calls, media, incoming: false);

        expect(find.text('กำลังวิดีโอคอล…'), findsOneWidget);
        expect(media.log.first, 'connect wss://lk.test caller video=true');
        expect(find.text('ยกเลิก'), findsOneWidget);

        calls.status = 'declined';
        await tester.pump(CallPage.ringPoll);
        await tester.pump();

        expect(find.text('ปลายสายปฏิเสธสาย'), findsOneWidget);

        await tester.pump(CallPage.closeDelay);
        await tester.pumpAndSettle();
      }, () => calls.client('caller'));
    },
  );

  testWidgets('revoked session during the call explains why it ended', (
    tester,
  ) async {
    final calls = FakeCalls();
    final media = FakeMedia();

    await http.runWithClient(() async {
      await openCall(tester, calls, media, incoming: false);

      calls.status = 'accepted';
      media.joinRemote();
      await tester.pump();
      expect(find.text('0:00'), findsOneWidget);

      calls.deniedStatus = 403;
      await tester.pump(CallPage.heartbeatEvery);
      await tester.pump();

      expect(
        find.text('สายถูกตัด เพราะมีการออกจากระบบของอุปกรณ์ที่ใช้โทร'),
        findsOneWidget,
      );
      expect(media.log.last, 'disconnect');

      await tester.pump(CallPage.closeDelay);
      await tester.pumpAndSettle();
    }, () => calls.client('caller'));
  });

  testWidgets('chat header shows call buttons only when calls are enabled', (
    tester,
  ) async {
    for (final enabled in [false, true]) {
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            const MaterialApp(home: ChatRoomPage(conversationId: 1)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump();

          expect(
            find.byTooltip('โทรเสียง'),
            enabled ? findsOneWidget : findsNothing,
          );
          expect(
            find.byTooltip('วิดีโอคอล'),
            enabled ? findsOneWidget : findsNothing,
          );

          await tester.pumpWidget(const SizedBox());
        },
        () => MockClient(
          (request) async => http.Response(
            jsonEncode({
              'status': true,
              'conversation': {
                'id': 1,
                'can_send': true,
                'calls_enabled': enabled,
                'other_read_id': 0,
                'my_read_id': 0,
                'user': {'id': 2, 'name': 'ลูก'},
              },
              'messages': [],
              'has_more': false,
              'states': [],
              'unread_count': 0,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
    }
  });
}
