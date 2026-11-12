import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart' show navigatorKey;
import '../pages/call_page.dart';
import '../widgets/chat_media.dart';
import 'api_helper.dart';
import 'call_service.dart';

// =======================================================
// ตัวกลางการโทร: เริ่มสาย / แสดงสายเข้า
// - สายเข้า: แจ้งเตือนตอนเปิดแอป / กดแจ้งเตือน / กลับเข้าแอประหว่างที่ยังเรียกอยู่ (ถาม /calls/active)
// - ถามสถานะจริงจากเซิร์ฟเวอร์ก่อนแสดงเสมอ: แจ้งเตือนช้า / ซ้ำ / สายจบแล้ว → ไม่ดังขึ้นใหม่
// - แสดงทีละสาย และสายที่แสดงไปแล้วไม่แสดงซ้ำ
// ข้อจำกัด: สายเข้าตอนแอปอยู่เบื้องหลัง/ปิดอยู่ = แจ้งเตือนแบบเด้ง (แตะเพื่อรับ) ยังไม่ใช่หน้าจอสายเข้าเต็มจอ
// =======================================================

class CallCoordinator with WidgetsBindingObserver {
  CallCoordinator._();

  static final CallCoordinator instance = CallCoordinator._();

  // สถานะสายจากแจ้งเตือน → หน้าสายที่เปิดอยู่ถามเซิร์ฟเวอร์ทันที
  static final StreamController<Map<String, dynamic>> events =
      StreamController<Map<String, dynamic>>.broadcast();

  final Set<int> handled = {};
  int? showingCallId;
  bool started = false;

  void start() {
    if (started) return;

    started = true;
    WidgetsBinding.instance.addObserver(this);
    checkActive();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) checkActive();
  }

  // แจ้งเตือนเข้าตอนเปิดแอปอยู่
  void handlePush(Map<String, dynamic> data) {
    final int? id = int.tryParse('${data['call_id'] ?? ''}');

    if (id == null) return;

    events.add(data);

    if (data['status']?.toString() != 'ringing') return;

    // แจ้งเตือนมาช้าเกินเวลาเรียก → ไม่ดัง
    final DateTime? expires = DateTime.tryParse('${data['expires_at'] ?? ''}');

    if (expires != null && expires.isBefore(DateTime.now())) return;

    openIncoming(id);
  }

  Future<void> checkActive() async {
    if (showingCallId != null) return;

    try {
      final Map<String, dynamic> result = await CallService.active();
      final dynamic call = result['call'];

      if (call is Map) await showIncoming(Map<String, dynamic>.from(call));
    } catch (_) {
      // ยังไม่ได้เข้าสู่ระบบ / เน็ตหลุด → ครั้งหน้า
    }
  }

  Future<void> openIncoming(int callId) async {
    if (showingCallId != null || handled.contains(callId)) return;

    try {
      final Map<String, dynamic> result = await CallService.show(callId);
      final dynamic call = result['call'];

      if (result['status'] == true &&
          call is Map &&
          call['status'] == 'ringing' &&
          call['role'] == 'callee') {
        await showIncoming(Map<String, dynamic>.from(call));
      }
    } catch (_) {}
  }

  Future<void> showIncoming(Map<String, dynamic> call) async {
    final int? id = (call['id'] as num?)?.toInt();
    final NavigatorState? navigator = navigatorKey.currentState;

    if (id == null ||
        navigator == null ||
        showingCallId != null ||
        handled.contains(id)) {
      return;
    }

    showingCallId = id;
    handled.add(id);

    try {
      await navigator.push(
        MaterialPageRoute(builder: (_) => CallPage(call: call, incoming: true)),
      );
    } finally {
      showingCallId = null;
    }
  }

  // โทรออกจากห้องแชท (type: audio | video)
  Future<void> startCall(
    BuildContext context,
    int conversationId,
    String type,
  ) async {
    if (showingCallId != null) return;

    if (!await ensureChatPermission(
      context,
      Permission.microphone,
      'ไมโครโฟน',
    )) {
      return;
    }

    if (type == 'video' &&
        (!context.mounted ||
            !await ensureChatPermission(context, Permission.camera, 'กล้อง'))) {
      return;
    }

    if (!context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);

    void tell(String text) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    Map<String, dynamic> result;

    try {
      result = await CallService.start(conversationId, type);
    } catch (e) {
      tell(ApiHelper.messageOf(e));
      return;
    }

    final dynamic call = result['call'];

    if (result['status'] != true || call is! Map) {
      tell(result['message']?.toString() ?? 'โทรไม่สำเร็จ ลองใหม่อีกครั้ง');
      return;
    }

    if (call['status'] == 'busy') {
      tell('ปลายสายไม่ว่าง ลองใหม่ภายหลัง');
      return;
    }

    final int id = (call['id'] as num).toInt();
    final dynamic livekit = result['livekit'];

    showingCallId = id;
    handled.add(id);

    try {
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => CallPage(
            call: Map<String, dynamic>.from(call),
            livekit: livekit is Map ? Map<String, dynamic>.from(livekit) : null,
          ),
        ),
      );
    } finally {
      showingCallId = null;
    }
  }
}
