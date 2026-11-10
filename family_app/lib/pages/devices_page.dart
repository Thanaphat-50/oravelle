import 'package:flutter/material.dart';

import '../services/api_helper.dart';
import '../services/session_service.dart';
import '../theme/app_theme.dart';

// =======================================================
// อุปกรณ์ที่เข้าสู่ระบบ (ตั้งค่า → บัญชี)
// - รายการเซสชันของบัญชีนี้: รุ่นเครื่อง ระบบ เวอร์ชันแอป เวลาเข้าสู่ระบบ เวลาใช้งานล่าสุด
//   (เวลาตามเขตเวลาของเครื่องนี้ / ไม่มีข้อมูล → "อุปกรณ์ไม่ทราบชื่อ" / ไม่บอกว่า "ออนไลน์")
// - "เครื่องนี้" มาจากเซิร์ฟเวอร์ (token ของคำขอนี้) ไม่เดาจากชื่อรุ่น
// - ออกจากระบบเครื่องอื่นรายเครื่อง / ทั้งหมด (ยืนยันก่อน) — เครื่องนี้ใช้ปุ่มออกจากระบบเดิม
// - ไม่ลบรายการจากหน้าจอจนกว่าเซิร์ฟเวอร์ยืนยัน แล้วโหลดรายการล่าสุด
// =======================================================

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  List<Map<String, dynamic>> sessions = [];
  bool isLoading = true;
  String? loadError;

  // กำลังยกเลิกสิทธิ์ (id ของเซสชัน / -1 = ทั้งหมด) — กันกดซ้ำ
  int? busyId;

  static const int allOthers = -1;

  int get othersCount => sessions.where((s) => s['is_current'] != true).length;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await SessionService.list();

      if (!mounted) return;

      final dynamic raw = result['sessions'];

      if (result['status'] == true && raw is List) {
        setState(() {
          sessions = raw
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
          loadError = null;
        });
      } else {
        setState(
          () => loadError =
              result['message']?.toString() ?? 'โหลดรายการอุปกรณ์ไม่สำเร็จ',
        );
      }
    } catch (e) {
      if (!mounted) return;

      // มีรายการเดิมอยู่แล้ว → แจ้งอย่างเดียว ไม่ล้างรายการ
      if (sessions.isEmpty) {
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

  String nameOf(Map<String, dynamic> session) {
    final String name = session['device_name']?.toString().trim() ?? '';

    return name.isEmpty ? 'อุปกรณ์ไม่ทราบชื่อ' : name;
  }

  Future<bool> confirm({
    required String title,
    required String message,
    required String action,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );

    return ok == true;
  }

  Future<void> revoke(Map<String, dynamic> session) async {
    final dynamic id = session['id'];

    if (id is! num || busyId != null) return;

    final bool ok = await confirm(
      title: 'ออกจากระบบอุปกรณ์นี้?',
      message:
          'อุปกรณ์นี้จะต้องเข้าสู่ระบบใหม่เพื่อใช้บัญชีของคุณ\n\n'
          '${nameOf(session)}\n'
          'เข้าสู่ระบบเมื่อ ${formatTime(session['signed_in_at'])}',
      action: 'ออกจากระบบ',
    );

    if (!ok || !mounted) return;

    await run(id.toInt(), () => SessionService.revoke(id.toInt()));
  }

  Future<void> revokeOthers() async {
    if (busyId != null || othersCount == 0) return;

    final bool ok = await confirm(
      title: 'ออกจากระบบเครื่องอื่นทั้งหมด?',
      message:
          'คุณยังใช้งานบัญชีบนเครื่องนี้ต่อได้\n'
          'อุปกรณ์อื่น $othersCount เครื่องจะต้องเข้าสู่ระบบใหม่',
      action: 'ออกจากระบบทั้งหมด',
    );

    if (!ok || !mounted) return;

    await run(allOthers, SessionService.revokeOthers);
  }

  // ทำรายการ → สำเร็จจริงจากเซิร์ฟเวอร์เท่านั้นจึงโหลดรายการใหม่ / ไม่สำเร็จ → รายการเดิมอยู่ครบ
  Future<void> run(
    int id,
    Future<Map<String, dynamic>> Function() request,
  ) async {
    setState(() => busyId = id);

    try {
      final result = await request();

      if (!mounted) return;

      if (result['status'] == true) {
        showMessage(result['message']?.toString() ?? 'ยกเลิกสิทธิ์แล้ว');
        await load();
      } else {
        showMessage(result['message']?.toString() ?? 'ทำรายการไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => busyId = null);
    }
  }

  // เวลาตามเขตเวลาของเครื่องนี้
  static String formatTime(dynamic value) {
    if (value == null) return 'ไม่มีข้อมูล';

    final DateTime? time = DateTime.tryParse(value.toString())?.toLocal();

    if (time == null) return 'ไม่มีข้อมูล';

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

    final String hour = time.hour.toString().padLeft(2, '0');
    final String minute = time.minute.toString().padLeft(2, '0');

    return '${time.day} ${months[time.month]} ${time.year} • $hour:$minute น.';
  }

  @override
  Widget build(BuildContext context) {
    Widget body;

    if (isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (loadError != null && sessions.isEmpty) {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(28, 80, 28, 28),
        children: [
          Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.muted),
          const SizedBox(height: 10),
          Text(
            loadError!,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.navy, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 14),
          Center(
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  isLoading = true;
                  loadError = null;
                });
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text(
              'การเข้าสู่ระบบบัญชีของคุณจากแอป หากพบอุปกรณ์ที่ไม่รู้จัก '
              'ให้ออกจากระบบอุปกรณ์นั้น แล้วเปลี่ยนรหัสผ่าน',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Text(
                  'ไม่พบอุปกรณ์ที่เข้าสู่ระบบ',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted),
                ),
              ),
            ...sessions.map(buildSession),
            const SizedBox(height: 8),
            buildRevokeOthers(),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('อุปกรณ์ที่เข้าสู่ระบบ')),
      body: body,
    );
  }

  Widget buildSession(Map<String, dynamic> session) {
    final bool current = session['is_current'] == true;
    final dynamic id = session['id'];
    final bool busy = id is num && busyId == id.toInt();
    final String platform = session['device_platform']?.toString() ?? '';

    final List<String> system = [
      if ((session['os_version']?.toString() ?? '').isNotEmpty)
        session['os_version'].toString(),
      if ((session['app_version']?.toString() ?? '').isNotEmpty)
        'แอป ${session['app_version']}',
    ];

    return Container(
      key: ValueKey('session-$id'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: current
            ? Border.all(color: AppColors.primary.withValues(alpha: 0.5))
            : AppDecorations.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  platform == 'ios'
                      ? Icons.phone_iphone_rounded
                      : platform == 'android'
                      ? Icons.phone_android_rounded
                      : Icons.devices_other_rounded,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          nameOf(session),
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (current)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'เครื่องนี้',
                              style: TextStyle(
                                color: AppColors.primary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (system.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        system.join(' · '),
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      'เข้าสู่ระบบ: ${formatTime(session['signed_in_at'])}',
                      style: TextStyle(color: AppColors.navy, fontSize: 12),
                    ),
                    Text(
                      'ใช้งานล่าสุด: ${formatTime(session['last_used_at'])}',
                      style: TextStyle(color: AppColors.navy, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (!current) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: BorderSide(
                    color: AppColors.danger.withValues(alpha: 0.4),
                  ),
                ),
                onPressed: busyId == null ? () => revoke(session) : null,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.logout_rounded, size: 18),
                label: Text(busy ? 'กำลังออกจากระบบ...' : 'ออกจากระบบ'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget buildRevokeOthers() {
    final bool busy = busyId == allOthers;

    if (othersCount == 0) {
      // มีแค่เครื่องนี้ → ไม่มีอะไรต้องออกจากระบบ
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.fill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.verified_user_outlined, color: AppColors.success),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'ไม่มีอุปกรณ์อื่นที่เข้าสู่ระบบอยู่ ใช้บัญชีนี้บนเครื่องนี้เครื่องเดียว',
                style: TextStyle(color: AppColors.navy, fontSize: 12.5),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: busyId == null ? revokeOthers : null,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.phonelink_erase_rounded),
          label: Text(
            busy ? 'กำลังออกจากระบบ...' : 'ออกจากระบบเครื่องอื่นทั้งหมด',
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'อุปกรณ์ที่ถูกยกเลิกสิทธิ์จะออกจากระบบเมื่อเชื่อมต่ออินเทอร์เน็ตครั้งถัดไป '
          'และจะไม่ได้รับแจ้งเตือนของบัญชีนี้อีก',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
        ),
      ],
    );
  }
}
