import 'package:flutter/material.dart';

import '../services/activity_service.dart';
import '../services/api_helper.dart';
import '../theme/app_theme.dart';
import '../widgets/activity_reminder_widgets.dart';

// =======================================================
// รายละเอียดกิจกรรม (กดจากรายการ / กดแจ้งเตือน "เตือนกิจกรรม")
// - เซิร์ฟเวอร์ตรวจสิทธิ์: ถูกลบ / ไม่มีสิทธิ์ดูแล้ว → ข้อความแจ้ง ไม่แสดงข้อมูลเก่า
// - ตั้งเตือนของตัวเองได้ (สมาชิกกลุ่มไม่ต้องมีสิทธิ์แก้ไขกิจกรรม)
// - เวลาแสดงตามนาฬิกาเครื่องนี้ (starts_at เป็น UTC)
// - pop(true) = มีการเปลี่ยนแปลง (หน้ารายการโหลดใหม่)
// =======================================================

class ActivityDetailPage extends StatefulWidget {
  final int activityId;

  const ActivityDetailPage({super.key, required this.activityId});

  @override
  State<ActivityDetailPage> createState() => _ActivityDetailPageState();
}

class _ActivityDetailPageState extends State<ActivityDetailPage> {
  Map<String, dynamic>? activity;
  bool isLoading = true;
  String? loadError;

  // ตัวเลือกที่กำลังเลือก (ยังไม่บันทึก)
  int? choice;
  bool isSaving = false;
  String? saveError;
  bool changed = false;

  String? deviceTimezone;

  @override
  void initState() {
    super.initState();
    load();
    ActivityService.deviceTimezone().then((value) {
      if (mounted) setState(() => deviceTimezone = value);
    });
  }

  Future<void> load() async {
    try {
      final result = await ActivityService.getActivity(widget.activityId);

      if (!mounted) return;

      final dynamic data = result['activity'];

      if (result['status'] == true && data is Map) {
        setState(() {
          activity = Map<String, dynamic>.from(data);
          choice = ActivityReminders.offsetOf(activity);
          loadError = null;
        });
      } else {
        // ถูกลบ / ไม่มีสิทธิ์แล้ว → ไม่แสดงข้อมูลเดิม
        setState(() {
          activity = null;
          loadError =
              result['message']?.toString() ??
              'ไม่พบกิจกรรมนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว';
        });
      }
    } catch (e) {
      if (!mounted) return;

      if (activity == null) {
        setState(() => loadError = ApiHelper.messageOf(e));
      } else {
        showMessage(ApiHelper.messageOf(e));
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  int? get savedChoice => ActivityReminders.offsetOf(activity);

  // ตั้งเตือนไม่ได้เพราะอะไร (null = ตั้งได้)
  String? blockedReason(Map<String, dynamic> data) {
    if (data['is_completed'] == true) {
      return 'กิจกรรมนี้ทำเสร็จแล้ว จึงไม่มีการเตือน';
    }

    if (data['needs_time_confirmation'] == true) {
      return data['is_mine'] == true
          ? 'กิจกรรมนี้สร้างก่อนมีระบบเตือน กรุณายืนยันวันเวลา '
                '(แก้ไขกิจกรรมในหน้ากิจกรรม ตรวจวันเวลาแล้วกดบันทึก) ก่อนตั้งเตือน'
          : 'กิจกรรมนี้สร้างก่อนมีระบบเตือน ต้องให้ผู้สร้างยืนยันวันเวลาก่อน จึงจะตั้งเตือนได้';
    }

    if (data['can_remind'] != true) {
      return 'กิจกรรมนี้ยังไม่ได้กำหนดวันเวลา จึงตั้งเตือนไม่ได้';
    }

    return null;
  }

  Future<void> saveReminder() async {
    final DateTime? start = ActivityReminders.startOf(activity);
    final int? offset = choice;

    if (start != null &&
        offset != null &&
        ActivityReminders.isPast(start, offset)) {
      setState(() => saveError = 'เวลาเตือนที่เลือกผ่านไปแล้ว กรุณาเลือกใหม่');
      return;
    }

    setState(() {
      isSaving = true;
      saveError = null;
    });

    try {
      final result = await ActivityService.setReminder(
        activityId: widget.activityId,
        offset: offset,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        final dynamic reminder = result['reminder'];

        setState(() {
          activity = {
            ...?activity,
            'my_reminder': reminder is Map
                ? Map<String, dynamic>.from(reminder)
                : null,
          };
          choice = ActivityReminders.offsetOf(activity);
          changed = true;
        });

        showMessage(result['message']?.toString() ?? 'บันทึกแล้ว');
      } else {
        setState(
          () => saveError = result['message']?.toString() ?? 'บันทึกไม่สำเร็จ',
        );

        // ถูกลบ / หมดสิทธิ์ระหว่างเปิดหน้า → โหลดใหม่ (ได้ข้อความ "ไม่พบกิจกรรมนี้")
        if (result['errors'] == null) await load();
      }
    } catch (e) {
      if (mounted) setState(() => saveError = ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? data = activity;

    Widget body;

    if (isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (data == null) {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(28, 80, 28, 28),
        children: [
          Icon(Icons.event_busy_rounded, size: 44, color: AppColors.muted),
          const SizedBox(height: 10),
          Text(
            loadError ?? 'เปิดกิจกรรมไม่สำเร็จ',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.navy, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 14),
          Center(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(160, 44)),
              onPressed: () {
                setState(() => isLoading = true);
                load();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('ลองอีกครั้ง'),
            ),
          ),
        ],
      );
    } else {
      body = RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
          children: [
            buildInfo(data),
            const SizedBox(height: 14),
            buildReminder(data),
          ],
        ),
      );
    }

    // ย้อนกลับ (ปุ่มบนแถบ / ปุ่มเครื่อง) → ส่งผลว่ามีการเปลี่ยนแปลงไหม / กำลังบันทึกอยู่ → รอก่อน
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || isSaving) return;

        Navigator.of(context).pop(changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('รายละเอียดกิจกรรม')),
        body: body,
      ),
    );
  }

  Widget card({required List<Widget> children}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: AppDecorations.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget infoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildInfo(Map<String, dynamic> data) {
    final String title = data['title']?.toString() ?? 'กิจกรรม';
    final String description = data['description']?.toString() ?? '';
    final bool completed = data['is_completed'] == true;
    final bool shared = data['visibility'] == 'family';
    final dynamic user = data['user'];
    final String owner = data['is_mine'] == true
        ? 'สร้างโดยคุณ'
        : 'สร้างโดย ${user is Map ? user['name'] ?? 'สมาชิก' : 'สมาชิก'}';

    final DateTime? start = ActivityReminders.startOf(data);
    final String? timezone = data['timezone']?.toString();
    final bool otherZone =
        data['starts_at'] != null &&
        timezone != null &&
        deviceTimezone != null &&
        timezone != deviceTimezone;

    DateTime? creatorClock;
    if (otherZone) {
      try {
        creatorClock = DateTime.parse(data['activity_date'].toString());
      } catch (_) {}
    }

    return card(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  decoration: completed ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (completed)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: AppColors.success,
                  ),
                  label: const Text('เสร็จแล้ว'),
                ),
              ),
          ],
        ),
        infoRow(
          shared ? Icons.groups_rounded : Icons.lock_outline_rounded,
          shared ? 'แชร์ในกลุ่ม · $owner' : 'ส่วนตัว · $owner',
        ),
        infoRow(
          Icons.schedule_rounded,
          start == null
              ? 'ไม่กำหนดเวลา'
              : '${ActivityReminders.formatDateTime(start)}'
                    '${otherZone ? ' (เวลาตามเครื่องคุณ)' : ''}',
        ),
        if (otherZone && creatorClock != null)
          infoRow(
            Icons.public_rounded,
            'ผู้สร้างตั้งไว้ ${ActivityReminders.formatDateTime(creatorClock)} ($timezone)',
          ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            description,
            style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
          ),
        ],
      ],
    );
  }

  Widget buildReminder(Map<String, dynamic> data) {
    final String? blocked = blockedReason(data);
    final String? status = ActivityReminders.statusText(data);
    final bool dirty = choice != savedChoice;

    return card(
      children: [
        Text(
          'แจ้งเตือนล่วงหน้า (ของคุณ)',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'สมาชิกแต่ละคนตั้งเตือนของตัวเอง คนอื่นไม่เห็นค่านี้',
          style: TextStyle(color: AppColors.muted, fontSize: 11),
        ),
        const SizedBox(height: 12),
        ReminderPicker(
          start: ActivityReminders.startOf(data),
          selected: choice,
          savedStatus: dirty ? null : ActivityReminders.statusOf(data),
          blockedReason: blocked,
          enabled: !isSaving,
          onChanged: (value) => setState(() {
            choice = value;
            saveError = null;
          }),
        ),
        // พักไว้ (เสร็จแล้ว / ไม่มีวันเวลา) → ตัวเลือกถูกปิดอยู่แล้ว แสดงสถานะเพิ่ม
        if (status != null && blocked != null && !dirty) ...[
          const SizedBox(height: 8),
          Text(status, style: TextStyle(color: AppColors.muted, fontSize: 11)),
        ],
        if (saveError != null) ...[
          const SizedBox(height: 8),
          Text(
            saveError!,
            style: TextStyle(color: AppColors.danger, fontSize: 12),
          ),
        ],
        if (blocked == null) ...[
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: dirty && !isSaving ? saveReminder : null,
            icon: isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(isSaving ? 'กำลังบันทึก...' : 'บันทึกการเตือน'),
          ),
        ],
        const SizedBox(height: 12),
        const NotificationPermissionCard(),
      ],
    );
  }
}
