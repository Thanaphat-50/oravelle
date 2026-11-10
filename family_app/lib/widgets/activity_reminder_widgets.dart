import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/app_theme.dart';

// =======================================================
// แจ้งเตือนกิจกรรมล่วงหน้า (ของแต่ละคน)
// - ตัวเลือก: ไม่เตือน / ตรงเวลา / ก่อน 15 นาที / ก่อน 30 นาที / ก่อน 1 วัน (ค่าเริ่มต้น ไม่เตือน)
// - แสดงเวลาที่จะเตือนจริงก่อนบันทึก / เวลาเตือนผ่านไปแล้ว → ให้เลือกใหม่
// - สิทธิ์แจ้งเตือนของเครื่องแยกจากการตั้งเตือน (ไม่ขอสิทธิ์ซ้ำทุกครั้ง)
// =======================================================

class ActivityReminders {
  static const List<int?> offsets = [null, 0, 15, 30, 1440];

  static String label(int? offset) {
    switch (offset) {
      case null:
        return 'ไม่เตือน';
      case 0:
        return 'ตรงเวลา';
      case 1440:
        return 'ก่อน 1 วัน';
      default:
        return 'ก่อน $offset นาที';
    }
  }

  // ก่อน 1 วัน = 24 ชั่วโมงจริง (ช่วงเปลี่ยนเวลาฤดูร้อน นาฬิกาอาจต่างจากเวลาเดิม 1 ชั่วโมง)
  static DateTime remindAt(DateTime start, int offset) =>
      start.subtract(Duration(minutes: offset));

  static bool isPast(DateTime start, int offset, {DateTime? now}) =>
      !remindAt(start, offset).isAfter(now ?? DateTime.now());

  // เวลาของกิจกรรมตามนาฬิกาเครื่องนี้
  // starts_at (UTC) → เวลาท้องถิ่นของเครื่อง (คนต่างเขตเวลาเห็นเวลาที่ตรงกัน)
  // กิจกรรมเดิม (ไม่มี starts_at) → activity_date ตามนาฬิกาที่ผู้สร้างเลือก
  static DateTime? startOf(Map<String, dynamic>? activity) {
    if (activity == null) return null;

    final dynamic value = activity['starts_at'] ?? activity['activity_date'];

    if (value == null) return null;

    try {
      return DateTime.parse(value.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? mine(Map<String, dynamic>? activity) {
    final dynamic value = activity?['my_reminder'];

    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  // pending / sent / expired / paused (null = ไม่ได้ตั้ง)
  static String? statusOf(Map<String, dynamic>? activity) =>
      mine(activity)?['status']?.toString();

  static int? offsetOf(Map<String, dynamic>? activity) {
    final dynamic value = mine(activity)?['offset_minutes'];

    return value is num ? value.toInt() : null;
  }

  // สถานะการเตือนของตัวเอง (ข้อความสั้น)
  static String? statusText(Map<String, dynamic>? activity) {
    final reminder = mine(activity);

    if (reminder == null) return null;

    switch (reminder['status']) {
      case 'sent':
        return 'ส่งการเตือนแล้ว';
      case 'expired':
        return 'เลยเวลาเตือนแล้ว (ไม่ได้ส่ง)';
      case 'paused':
        return 'พักการเตือนไว้ (กิจกรรมเสร็จแล้วหรือยังไม่มีวันเวลา)';
      default:
        return null;
    }
  }

  static String formatDateTime(DateTime date) {
    const months = [
      '',
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.',
    ];

    final String hour = date.hour.toString().padLeft(2, '0');
    final String minute = date.minute.toString().padLeft(2, '0');

    return '${date.day} ${months[date.month]} ${date.year} • $hour:$minute น.';
  }
}

// ตัวเลือกการเตือน + สรุปเวลาที่จะเตือนจริง
// blockedReason: ตั้งเตือนไม่ได้ (ยังไม่มีวันเวลา / ต้องยืนยันเวลา / เสร็จแล้ว) → แสดงเหตุผลแทน
class ReminderPicker extends StatelessWidget {
  final DateTime? start;
  final int? selected;
  final ValueChanged<int?> onChanged;
  final String? blockedReason;
  final bool enabled;
  final DateTime? now;

  // สถานะของค่าที่บันทึกไว้ (ส่งมาเฉพาะเมื่อยังเลือกค่าเดิม): sent / expired
  // → เวลาผ่านไปแล้วเป็นเรื่องปกติ แสดงสถานะแทนคำเตือนให้เลือกใหม่
  final String? savedStatus;

  const ReminderPicker({
    super.key,
    required this.start,
    required this.selected,
    required this.onChanged,
    this.blockedReason,
    this.enabled = true,
    this.now,
    this.savedStatus,
  });

  @override
  Widget build(BuildContext context) {
    final DateTime? startAt = start;
    final String? blocked =
        blockedReason ??
        (startAt == null
            ? 'ตั้งวันและเวลาของกิจกรรมก่อน จึงจะตั้งเตือนได้'
            : null);

    if (blocked != null || startAt == null) {
      return _ReminderNote(
        icon: Icons.notifications_off_outlined,
        color: AppColors.muted,
        text: blocked ?? '',
      );
    }

    final int? choice = selected;
    final bool choicePast =
        choice != null && ActivityReminders.isPast(startAt, choice, now: now);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final int? offset in ActivityReminders.offsets)
              _choice(context, startAt, offset),
          ],
        ),
        const SizedBox(height: 10),
        if (choicePast && savedStatus == 'sent')
          _ReminderNote(
            icon: Icons.check_circle_outline_rounded,
            color: AppColors.success,
            text:
                'ส่งการเตือนแล้ว: ${ActivityReminders.label(choice)} · '
                '${ActivityReminders.formatDateTime(ActivityReminders.remindAt(startAt, choice))}',
          )
        else if (choicePast && savedStatus == 'expired')
          _ReminderNote(
            icon: Icons.schedule_rounded,
            color: AppColors.warm,
            text: 'เลยเวลาเตือนแล้ว จึงไม่ได้ส่ง เลือกการเตือนใหม่ได้',
          )
        else if (choicePast)
          _ReminderNote(
            icon: Icons.error_outline_rounded,
            color: AppColors.danger,
            text: 'เวลาเตือนที่เลือกผ่านไปแล้ว กรุณาเลือกใหม่',
          )
        else
          _ReminderNote(
            icon: choice == null
                ? Icons.notifications_none_rounded
                : Icons.notifications_active_outlined,
            color: choice == null ? AppColors.muted : AppColors.primary,
            text: choice == null
                ? 'ไม่เตือนกิจกรรมนี้'
                : 'จะเตือน: ${ActivityReminders.label(choice)} · '
                      '${ActivityReminders.formatDateTime(ActivityReminders.remindAt(startAt, choice))}\n'
                      'อาจช้ากว่าเวลาที่ตั้งได้เล็กน้อย',
          ),
      ],
    );
  }

  Widget _choice(BuildContext context, DateTime startAt, int? offset) {
    final bool past =
        offset != null && ActivityReminders.isPast(startAt, offset, now: now);
    final bool isSelected = selected == offset;

    return ChoiceChip(
      label: Text(
        past && !isSelected
            ? '${ActivityReminders.label(offset)} (เลยแล้ว)'
            : ActivityReminders.label(offset),
      ),
      selected: isSelected,
      onSelected: enabled && (!past || isSelected)
          ? (_) => onChanged(offset)
          : null,
    );
  }
}

class _ReminderNote extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _ReminderNote({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// สิทธิ์แจ้งเตือนของเครื่อง (แยกจากการตั้งเตือน)
// ปิดอยู่ → การเตือนยังอยู่ในหน้าแจ้งเตือนของแอป แต่จะไม่เด้งบนเครื่อง → ปุ่มไปหน้าตั้งค่า
// ไม่ขอสิทธิ์ซ้ำ (ขอครั้งเดียวตอนเข้าแอป) / กลับจากหน้าตั้งค่า → ตรวจใหม่
class NotificationPermissionCard extends StatefulWidget {
  const NotificationPermissionCard({super.key});

  // ทดสอบ: กำหนดสถานะเอง
  static Future<bool?> Function()? statusOverride;
  static Future<void> Function()? openSettingsOverride;

  @override
  State<NotificationPermissionCard> createState() =>
      _NotificationPermissionCardState();
}

class _NotificationPermissionCardState extends State<NotificationPermissionCard>
    with WidgetsBindingObserver {
  // null = ตรวจไม่ได้ / ยังไม่รู้ → ไม่แสดง
  bool? granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) check();
  }

  Future<void> check() async {
    bool? value;

    try {
      final override = NotificationPermissionCard.statusOverride;

      value = override != null
          ? await override()
          : (await Permission.notification.status).isGranted;
    } catch (_) {
      value = null;
    }

    if (mounted) setState(() => granted = value);
  }

  Future<void> openSettings() async {
    try {
      final override = NotificationPermissionCard.openSettingsOverride;

      if (override != null) {
        await override();
      } else {
        await openAppSettings();
      }
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('เปิดหน้าตั้งค่าไม่สำเร็จ')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool? isGranted = granted;

    if (isGranted == null) return const SizedBox.shrink();

    if (isGranted) {
      return _ReminderNote(
        icon: Icons.check_circle_outline_rounded,
        color: AppColors.success,
        text: 'การแจ้งเตือนของเครื่องเปิดอยู่',
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warm.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.notifications_off_outlined,
                color: AppColors.warm,
                size: 19,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'การแจ้งเตือนของเครื่องปิดอยู่ การเตือนจะอยู่ในหน้าแจ้งเตือนของแอป '
                  'แต่จะไม่เด้งบนหน้าจอ',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: openSettings,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text('เปิดในการตั้งค่าเครื่อง'),
            ),
          ),
        ],
      ),
    );
  }
}
