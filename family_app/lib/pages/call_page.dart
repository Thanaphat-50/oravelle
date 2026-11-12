import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/call_coordinator.dart';
import '../services/call_media.dart';
import '../services/call_service.dart';
import '../widgets/chat_media.dart';
import '../widgets/user_avatar.dart';

// =======================================================
// หน้าสาย (โทรเสียง / วิดีโอคอล 1 ต่อ 1)
// - โทรออก: เข้าห้อง LiveKit ทันที รออีกฝ่าย (ถามสถานะทุก 2 วินาที)
// - สายเข้า: รับ / ปฏิเสธ (ถามสถานะทุก 2 วินาที: ผู้โทรยกเลิก / รับที่เครื่องอื่น / หมดเวลา → ปิดเอง)
// - เวลาสายเริ่มนับเมื่ออีกฝ่ายเชื่อมต่อจริงเท่านั้น
// - ระหว่างสาย heartbeat ทุก 15 วินาที (เซิร์ฟเวอร์ตรวจสิทธิ์/เซสชัน → หมดสิทธิ์ = สายถูกตัด)
// - ปุ่ม: ปิด/เปิดไมค์ ลำโพง (+ วิดีโอ: ปิด/เปิดกล้อง สลับกล้อง) วางสาย / ไม่บันทึกเสียงหรือวิดีโอ
// =======================================================

enum CallPhase { ringingOut, ringingIn, connecting, connected, ended }

class CallPage extends StatefulWidget {
  final Map<String, dynamic> call;

  // ผู้โทร: ได้ url/token ตอนเริ่มสาย / ผู้รับ: ได้ตอนกดรับ
  final Map<String, dynamic>? livekit;
  final bool incoming;
  final CallMedia Function()? mediaFactory;

  const CallPage({
    super.key,
    required this.call,
    this.livekit,
    this.incoming = false,
    this.mediaFactory,
  });

  static const Duration ringPoll = Duration(seconds: 2);
  static const Duration heartbeatEvery = Duration(seconds: 15);
  static const Duration closeDelay = Duration(milliseconds: 1500);

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late Map<String, dynamic> call = widget.call;
  late final CallMedia media = (widget.mediaFactory ?? LiveKitCallMedia.new)();
  late CallPhase phase = widget.incoming
      ? CallPhase.ringingIn
      : CallPhase.ringingOut;

  late bool speakerOn = video;
  late bool cameraOn = video;
  bool micOn = true;
  bool reconnecting = false;
  bool working = false;
  bool refreshing = false;
  String? endText;
  DateTime? connectedAt;

  // วินาทีที่คุยแล้ว (นับจากตอนอีกฝ่ายเชื่อมต่อจริง)
  int talkSeconds = 0;
  Timer? pollTimer;
  Timer? clock;
  StreamSubscription<Map<String, dynamic>>? events;

  int get callId => (call['id'] as num).toInt();

  bool get video => call['type'] == 'video';

  Map<String, dynamic> get other => call['other'] is Map
      ? Map<String, dynamic>.from(call['other'] as Map)
      : const {};

  @override
  void initState() {
    super.initState();

    media
      ..onRemoteJoined = onRemoteJoined
      ..onRemoteLeft = onRemoteLeft
      ..onDisconnected = onDisconnected
      ..onReconnecting = (value) {
        if (mounted) setState(() => reconnecting = value);
      }
      ..onTracksChanged = () {
        if (mounted) setState(() {});
      };

    // แจ้งเตือนสถานะสายมาถึง → ถามเซิร์ฟเวอร์ทันที (ไม่ต้องรอรอบถัดไป)
    events = CallCoordinator.events.stream
        .where((event) => event['call_id']?.toString() == '$callId')
        .listen((_) => refresh());

    startPolling(CallPage.ringPoll);

    if (!widget.incoming) connectOutgoing();
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    clock?.cancel();
    events?.cancel();

    if (phase != CallPhase.ended) {
      CallService.hangup(callId).catchError((_) => <String, dynamic>{});
      media.disconnect().catchError((_) {});
    }

    super.dispose();
  }

  // =====================================================
  // สถานะ
  // =====================================================

  void startPolling(Duration every) {
    pollTimer?.cancel();
    pollTimer = Timer.periodic(every, (_) => refresh());
  }

  Future<void> refresh() async {
    if (phase == CallPhase.ended || refreshing) return;

    refreshing = true;

    try {
      final Map<String, dynamic> result = phase == CallPhase.ringingIn
          ? await CallService.show(callId)
          : await CallService.heartbeat(callId);

      if (!mounted || phase == CallPhase.ended) return;

      final dynamic fresh = result['call'];

      if (fresh is Map) call = Map<String, dynamic>.from(fresh);

      if (result['status'] != true) {
        finish(result['message']?.toString() ?? 'สายถูกตัด', notify: false);
        return;
      }

      applyStatus(call['status']?.toString());
    } catch (_) {
      // เน็ตหลุดชั่วคราว → รอบหน้าลองใหม่ (เสียง/วิดีโอ LiveKit กู้การเชื่อมต่อเอง)
    } finally {
      refreshing = false;
    }
  }

  void applyStatus(String? status) {
    switch (status) {
      case 'accepted':
        if (phase == CallPhase.ringingIn) {
          finish('รับสายที่อุปกรณ์อื่นแล้ว', notify: false);
        } else if (phase == CallPhase.ringingOut) {
          setState(() => phase = CallPhase.connecting);
          startPolling(CallPage.heartbeatEvery);

          if (media.remotePresent) markConnected();
        }
      case 'declined':
        finish(
          phase == CallPhase.ringingIn ? 'ปฏิเสธสายแล้ว' : 'ปลายสายปฏิเสธสาย',
          notify: false,
        );
      case 'cancelled':
        finish('ผู้โทรยกเลิกสายแล้ว', notify: false);
      case 'missed':
        finish(
          phase == CallPhase.ringingIn ? 'ไม่ได้รับสาย' : 'ไม่มีผู้รับสาย',
          notify: false,
        );
      case 'busy':
        finish('ปลายสายไม่ว่าง', notify: false);
      case 'ended':
        finish('สายจบแล้ว', notify: false);
      case 'failed':
        finish(failedText(call['end_reason']?.toString()), notify: false);
    }
  }

  String failedText(String? reason) {
    return switch (reason) {
      'blocked' || 'not_allowed' => 'สายถูกตัด เพราะไม่มีสิทธิ์คุยกันแล้ว',
      'session_revoked' => 'สายถูกตัด เพราะมีการออกจากระบบของอุปกรณ์',
      'connection_lost' => 'สายหลุด',
      _ => 'สายจบแล้ว',
    };
  }

  void markConnected() {
    if (connectedAt != null || phase == CallPhase.ended) return;

    connectedAt = DateTime.now();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => talkSeconds += 1);
    });
    startPolling(CallPage.heartbeatEvery);

    if (mounted) setState(() => phase = CallPhase.connected);
  }

  void onRemoteJoined() {
    if (phase == CallPhase.ringingOut || phase == CallPhase.connecting) {
      markConnected();
    }
  }

  void onRemoteLeft() {
    if (phase == CallPhase.connected) finish('สายจบแล้ว', notify: true);
  }

  void onDisconnected() {
    if (phase != CallPhase.ended) finish('สายหลุด', notify: true);
  }

  // =====================================================
  // การกระทำ
  // =====================================================

  Future<void> connectOutgoing() async {
    final Map<String, dynamic>? livekit = widget.livekit;

    if (livekit == null) {
      finish('เชื่อมต่อไม่สำเร็จ', notify: true);
      return;
    }

    await connect(livekit);
  }

  Future<void> connect(Map<String, dynamic> livekit) async {
    try {
      await media.connect(
        livekit['url'].toString(),
        livekit['token'].toString(),
        video: video && cameraOn,
      );
      await media.setSpeaker(speakerOn);

      if (!mounted) return;

      if (media.remotePresent && phase != CallPhase.ringingOut) {
        markConnected();
      }
    } catch (_) {
      if (mounted) finish('เชื่อมต่อไม่สำเร็จ', notify: true);
    }
  }

  Future<void> accept() async {
    if (working || phase != CallPhase.ringingIn) return;

    if (!await ensureChatPermission(
      context,
      Permission.microphone,
      'ไมโครโฟน',
    )) {
      return;
    }

    // วิดีโอคอลแต่ไม่ให้ใช้กล้อง → รับแบบเสียงอย่างเดียว
    if (video && mounted) {
      cameraOn = await ensureChatPermission(
        context,
        Permission.camera,
        'กล้อง',
      );
    }

    if (!mounted || phase != CallPhase.ringingIn) return;

    setState(() {
      working = true;
      phase = CallPhase.connecting;
    });

    try {
      final Map<String, dynamic> result = await CallService.accept(callId);

      if (!mounted) return;

      final dynamic fresh = result['call'];
      final dynamic livekit = result['livekit'];

      if (fresh is Map) call = Map<String, dynamic>.from(fresh);

      if (result['status'] != true || livekit is! Map) {
        finish(
          result['message']?.toString() ?? 'รับสายไม่สำเร็จ',
          notify: false,
        );
        return;
      }

      startPolling(CallPage.heartbeatEvery);
      await connect(Map<String, dynamic>.from(livekit));
    } catch (_) {
      if (mounted) finish('เชื่อมต่อไม่สำเร็จ', notify: true);
    } finally {
      working = false;
    }
  }

  Future<void> decline() async {
    if (phase != CallPhase.ringingIn) return;

    setState(() => working = true);

    try {
      await CallService.decline(callId);
    } catch (_) {}

    finish('ปฏิเสธสายแล้ว', notify: false);
  }

  void hangup() {
    if (phase == CallPhase.ringingIn) {
      decline();
      return;
    }

    finish(
      phase == CallPhase.ringingOut ? 'ยกเลิกสายแล้ว' : 'วางสายแล้ว',
      notify: true,
    );
  }

  Future<void> finish(String text, {required bool notify}) async {
    if (phase == CallPhase.ended) return;

    pollTimer?.cancel();
    clock?.cancel();

    phase = CallPhase.ended;
    endText = text;

    if (mounted) setState(() {});

    if (notify) {
      CallService.hangup(callId).catchError((_) => <String, dynamic>{});
    }

    try {
      await media.disconnect();
    } catch (_) {}

    await Future<void>.delayed(CallPage.closeDelay);

    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> toggleMic() async {
    final bool next = !micOn;

    setState(() => micOn = next);

    try {
      await media.setMicrophone(next);
    } catch (_) {
      if (mounted) setState(() => micOn = !next);
    }
  }

  Future<void> toggleSpeaker() async {
    final bool next = !speakerOn;

    setState(() => speakerOn = next);

    try {
      await media.setSpeaker(next);
    } catch (_) {
      if (mounted) setState(() => speakerOn = !next);
    }
  }

  Future<void> toggleCamera() async {
    final bool next = !cameraOn;

    if (next &&
        !await ensureChatPermission(context, Permission.camera, 'กล้อง')) {
      return;
    }

    setState(() => cameraOn = next);

    try {
      await media.setCamera(next);
    } catch (_) {
      if (mounted) setState(() => cameraOn = !next);
    }
  }

  // =====================================================
  // UI
  // =====================================================

  String get statusText {
    switch (phase) {
      case CallPhase.ringingOut:
        return video ? 'กำลังวิดีโอคอล…' : 'กำลังโทร…';
      case CallPhase.ringingIn:
        return video ? 'วิดีโอคอลเข้า' : 'สายเรียกเข้า';
      case CallPhase.connecting:
        return 'กำลังเชื่อมต่อ…';
      case CallPhase.connected:
        if (reconnecting) return 'กำลังเชื่อมต่อใหม่…';

        return chatDuration(Duration(seconds: talkSeconds));
      case CallPhase.ended:
        return endText ?? 'สายจบแล้ว';
    }
  }

  Widget control({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
    Color? color,
  }) {
    final Color background =
        color ?? (active ? Colors.white : Colors.white.withValues(alpha: 0.18));
    final Color foreground = color != null || !active
        ? Colors.white
        : const Color(0xFF111827);

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      // แตะได้ทั้งปุ่มและป้ายชื่อ (พื้นที่กดใหญ่)
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: onTap == null
                      ? background.withValues(alpha: 0.5)
                      : background,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: foreground, size: 28),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> controls() {
    if (phase == CallPhase.ended) return const [];

    if (phase == CallPhase.ringingIn) {
      return [
        control(
          icon: Icons.call_end_rounded,
          label: 'ปฏิเสธ',
          color: const Color(0xFFDC2626),
          onTap: working ? null : decline,
        ),
        control(
          icon: video ? Icons.videocam_rounded : Icons.call_rounded,
          label: 'รับสาย',
          color: const Color(0xFF16A34A),
          onTap: working ? null : accept,
        ),
      ];
    }

    return [
      control(
        icon: micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
        label: micOn ? 'ปิดไมค์' : 'เปิดไมค์',
        active: !micOn,
        onTap: toggleMic,
      ),
      control(
        icon: speakerOn ? Icons.volume_up_rounded : Icons.hearing_rounded,
        label: speakerOn ? 'ลำโพงเปิด' : 'ลำโพงปิด',
        active: speakerOn,
        onTap: toggleSpeaker,
      ),
      if (video)
        control(
          icon: cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
          label: cameraOn ? 'ปิดกล้อง' : 'เปิดกล้อง',
          active: !cameraOn,
          onTap: toggleCamera,
        ),
      if (video && cameraOn)
        control(
          icon: Icons.cameraswitch_rounded,
          label: 'สลับกล้อง',
          onTap: () => media.switchCamera().catchError((_) {}),
        ),
      control(
        icon: Icons.call_end_rounded,
        label: phase == CallPhase.ringingOut ? 'ยกเลิก' : 'วางสาย',
        color: const Color(0xFFDC2626),
        onTap: hangup,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final Widget? remote = video && phase == CallPhase.connected
        ? media.remoteVideo()
        : null;
    final Widget? local = video && cameraOn && phase != CallPhase.ended
        ? media.localVideo()
        : null;
    final String name = other['name']?.toString() ?? 'ผู้ใช้';

    return PopScope(
      canPop: phase == CallPhase.ended,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) hangup();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF111827),
        body: Stack(
          children: [
            if (remote != null) Positioned.fill(child: remote),
            // เต็มจอ → ชื่อ/สถานะ/ปุ่มอยู่กลางจอ
            Positioned.fill(
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 32, 20, 24),
                  child: Column(
                    children: [
                      if (remote == null) ...[
                        UserAvatar(
                          user: {
                            'name': name,
                            'profile_photo_url': other['profile_image_url'],
                          },
                          radius: 52,
                        ),
                        const SizedBox(height: 18),
                      ],
                      Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          shadows: [Shadow(blurRadius: 6)],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          statusText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 16,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            shadows: const [Shadow(blurRadius: 6)],
                          ),
                        ),
                      ),
                      const Spacer(),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 18,
                        runSpacing: 16,
                        children: controls(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (local != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 16,
                right: 16,
                width: 108,
                height: 150,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: local,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
