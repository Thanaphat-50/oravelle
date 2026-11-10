import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/app_info.dart';
import '../services/auth_service.dart';
import '../services/background_location.dart';
import '../services/location_tracker.dart';
import '../services/profile_service.dart';
import '../services/settings_service.dart';
import '../services/social_auth_service.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/background_location_prompt.dart';
import '../widgets/community_sheets.dart';
import 'devices_page.dart';
import 'login_page.dart';
import 'support_center_page.dart';

// =======================================================
// ตั้งค่า
// - การแจ้งเตือน: เปิด/ปิดแต่ละประเภท
// - ตำแหน่ง: แชร์ตำแหน่งกับครอบครัว
// - ความเป็นส่วนตัว: ผู้ใช้ที่บล็อก
// - บัญชี: เปลี่ยนรหัสผ่าน / ออกจากระบบ / ขอลบบัญชี (ทีมงานลบให้)
// - เกี่ยวกับแอป: นโยบาย และเวอร์ชัน
// =======================================================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // ประเภทการแจ้งเตือนที่ปิดได้ (ตรงกับ AppNotification::OPTIONAL_TYPES)
  static const List<_NotificationOption> notificationOptions = [
    _NotificationOption(
      type: 'new_post',
      title: 'โพสต์ใหม่ในกลุ่ม',
      icon: Icons.dynamic_feed_rounded,
    ),
    _NotificationOption(
      type: 'new_comment',
      title: 'ความคิดเห็นในโพสต์ของฉัน',
      icon: Icons.chat_bubble_outline_rounded,
    ),
    _NotificationOption(
      type: 'new_activity',
      title: 'กิจกรรมใหม่ในกลุ่ม',
      icon: Icons.event_available_rounded,
    ),
    _NotificationOption(
      type: 'member_joined',
      title: 'มีสมาชิกใหม่เข้ากลุ่ม',
      icon: Icons.person_add_alt_1_rounded,
    ),
    _NotificationOption(
      type: 'new_message',
      title: 'ข้อความแชท',
      icon: Icons.forum_outlined,
    ),
  ];

  bool isLoading = true;
  String? loadError;

  bool locationSharing = true;
  Map<String, bool> notifications = {};

  // แชร์ตำแหน่งแม้ไม่ได้เปิดแอป (เปิดสวิตช์ไว้ + อนุญาต "ตลอดเวลา")
  bool backgroundLocation = false;
  bool backgroundBusy = false;

  // ค่าที่กำลังบันทึก (กันกดซ้ำ)
  final Set<String> savingKeys = {};

  String version = '';

  // บัญชี Google / LINE / Facebook ที่เชื่อมไว้ + มีรหัสผ่านหรือยัง
  List<Map<String, dynamic>> socialAccounts = [];

  bool hasPassword = true;

  // เจ้าที่กำลังเชื่อม / ยกเลิก
  String? socialBusy;

  // คำขอลบบัญชีที่รอทีมงานดำเนินการ (null = ไม่มี)
  Map<String, dynamic>? deletionRequest;

  bool deletionBusy = false;

  @override
  void initState() {
    super.initState();
    loadSettings();
    loadVersion();
    loadSocialAccounts();
    loadDeletionRequest();
    loadBackgroundLocation();
  }

  // =====================================================
  // แชร์ตำแหน่งแม้ไม่ได้เปิดแอป
  // =====================================================

  Future<void> loadBackgroundLocation() async {
    if (!BackgroundLocation.supported) return;

    final bool on =
        await BackgroundLocation.isEnabled() &&
        await BackgroundLocation.hasAlwaysPermission();

    if (mounted) setState(() => backgroundLocation = on);
  }

  Future<void> setBackgroundLocation(bool enabled) async {
    setState(() => backgroundBusy = true);

    try {
      if (enabled) {
        await enableBackgroundLocation(context);
      } else {
        await BackgroundLocation.turnOff();

        showMessage('ปิดแล้ว จะแชร์ตำแหน่งเฉพาะตอนเปิดแอป');
      }

      await loadBackgroundLocation();
    } finally {
      if (mounted) setState(() => backgroundBusy = false);
    }
  }

  // =====================================================
  // บัญชีที่เชื่อมต่อ (Google / LINE / Facebook)
  // =====================================================

  void applySocialAccounts(Map<String, dynamic> result) {
    final dynamic accounts = result['accounts'];

    if (result['status'] != true || accounts is! List) return;

    setState(() {
      hasPassword = result['has_password'] != false;

      socialAccounts = accounts
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    });
  }

  Future<void> loadSocialAccounts() async {
    try {
      final result = await SocialAuthService.linkedAccounts();

      if (mounted) applySocialAccounts(result);
    } catch (_) {
      // โหลดไม่ได้ → ไม่แสดงส่วนนี้
    }
  }

  Future<void> toggleSocial(Map<String, dynamic> account) async {
    final SocialProvider provider = SocialProvider.values.firstWhere(
      (value) => value.key == account['provider'],
    );

    final bool linked = account['linked'] == true;

    if (linked) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('ยกเลิกการเชื่อม ${provider.label}?'),
          content: Text(
            'จะเข้าสู่ระบบด้วย ${provider.label} ไม่ได้อีก จนกว่าจะเชื่อมใหม่',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ไม่ใช่ตอนนี้'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('ยกเลิกการเชื่อม'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;
    }

    setState(() => socialBusy = provider.key);

    try {
      final result = linked
          ? await SocialAuthService.unlink(provider)
          : await SocialAuthService.link(provider);

      if (!mounted) return;

      applySocialAccounts(result);

      showMessage(
        result['message']?.toString() ??
            (result['status'] == true ? 'บันทึกแล้ว' : 'ทำรายการไม่สำเร็จ'),
      );
    } on SocialLoginCanceled {
      // ผู้ใช้ปิดหน้าล็อกอินเอง
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => socialBusy = null);
    }
  }

  Widget buildSocialRow(Map<String, dynamic> account) {
    final bool linked = account['linked'] == true;

    final bool busy = socialBusy == account['provider'];

    final String? email = account['email']?.toString();

    final Color color = switch (account['provider']) {
      'line' => const Color(0xFF06C755),
      'facebook' => const Color(0xFF1877F2),
      _ => const Color(0xFF4285F4),
    };

    return ListTile(
      leading: buildIcon(
        linked ? Icons.link_rounded : Icons.link_off_rounded,
        color,
      ),
      contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
      title: Text(
        account['label']?.toString() ?? '',
        style: TextStyle(
          color: AppColors.navy,
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        linked
            ? (email == null || email.isEmpty
                  ? 'เชื่อมแล้ว'
                  : 'เชื่อมแล้ว · $email')
            : 'ยังไม่ได้เชื่อม',
        style: TextStyle(color: AppColors.muted, fontSize: 12),
      ),
      trailing: busy
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : TextButton(
              onPressed: socialBusy == null
                  ? () => toggleSocial(account)
                  : null,
              style: TextButton.styleFrom(
                foregroundColor: linked ? AppColors.danger : AppColors.primary,
              ),
              child: Text(linked ? 'ยกเลิก' : 'เชื่อม'),
            ),
    );
  }

  // แสดงเฉพาะเจ้าที่เปิดใช้ หรือที่เคยเชื่อมไว้
  List<Map<String, dynamic>> get visibleSocialAccounts => socialAccounts
      .where(
        (account) => account['enabled'] == true || account['linked'] == true,
      )
      .toList();

  // =====================================================
  // โหลด / บันทึกการตั้งค่า
  // =====================================================

  Future<void> loadSettings() async {
    setState(() {
      isLoading = true;
      loadError = null;
    });

    try {
      final result = await SettingsService.getSettings();

      if (!mounted) return;

      final dynamic settings = result['settings'];

      if (result['status'] == true && settings is Map) {
        final dynamic rawNotifications = settings['notifications'];

        setState(() {
          locationSharing = settings['location_sharing'] != false;

          notifications = {
            for (final option in notificationOptions)
              option.type: rawNotifications is Map
                  ? rawNotifications[option.type] != false
                  : true,
          };
        });
      } else {
        setState(() {
          loadError =
              result['message']?.toString() ?? 'โหลดการตั้งค่าไม่สำเร็จ';
        });
      }
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> loadVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();

      if (mounted) {
        setState(() {
          version = '${info.version} (${info.buildNumber})';
        });
      }
    } catch (_) {
      // อ่านเวอร์ชันไม่ได้ → ไม่แสดง
    }
  }

  // เปิด/ปิดการแจ้งเตือน: เปลี่ยนบนจอทันที ถ้าบันทึกไม่สำเร็จค่อยคืนค่าเดิม
  Future<void> setNotification(String type, bool enabled) async {
    if (savingKeys.contains(type)) return;

    final bool previous = notifications[type] ?? true;

    setState(() {
      notifications[type] = enabled;
      savingKeys.add(type);
    });

    try {
      final result = await SettingsService.updateSettings(
        notifications: {type: enabled},
      );

      if (!mounted) return;

      if (result['status'] != true) {
        setState(() => notifications[type] = previous);
        showMessage(result['message']?.toString() ?? 'บันทึกไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      setState(() => notifications[type] = previous);
      showMessage(e.toString());
    } finally {
      if (mounted) setState(() => savingKeys.remove(type));
    }
  }

  Future<void> setLocationSharing(bool enabled) async {
    const String key = 'location_sharing';

    if (savingKeys.contains(key)) return;

    // ปิดแชร์ → ยืนยันก่อน เพราะครอบครัวจะไม่เห็นตำแหน่งของเรา
    if (!enabled) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('ปิดการแชร์ตำแหน่ง?'),
            content: const Text(
              'สมาชิกในกลุ่มจะไม่เห็นตำแหน่งของคุณ และตำแหน่งล่าสุดที่บันทึกไว้จะถูกลบ '
              'เปิดกลับได้ทุกเมื่อ',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('ยกเลิก'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('ปิดการแชร์'),
              ),
            ],
          );
        },
      );

      if (confirmed != true || !mounted) return;
    }

    final bool previous = locationSharing;

    setState(() {
      locationSharing = enabled;
      savingKeys.add(key);
    });

    try {
      final result = await SettingsService.updateSettings(
        locationSharing: enabled,
      );

      if (!mounted) return;

      if (result['status'] != true) {
        setState(() => locationSharing = previous);
        showMessage(result['message']?.toString() ?? 'บันทึกไม่สำเร็จ');
        return;
      }

      if (enabled) {
        await startSharingWithPermission();
      } else {
        LocationTracker.stop();
        showMessage('ปิดการแชร์ตำแหน่งแล้ว');
      }

      // เริ่ม/หยุดการแชร์ตอนปิดแอปตามสวิตช์นี้ด้วย
      await BackgroundLocation.sync();
    } catch (e) {
      if (!mounted) return;

      setState(() => locationSharing = previous);
      showMessage(e.toString());
    } finally {
      if (mounted) setState(() => savingKeys.remove(key));
    }
  }

  // เปิดแชร์แล้ว → ขอสิทธิ์ตำแหน่ง (ถ้ายังไม่ได้ให้) แล้วเริ่มส่ง
  Future<void> startSharingWithPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (!mounted) return;

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      showMessage('เปิดแชร์แล้ว แต่ยังไม่ได้อนุญาตตำแหน่งในเครื่อง');
      return;
    }

    await LocationTracker.start();

    if (mounted) showMessage('เปิดการแชร์ตำแหน่งแล้ว');
  }

  Future<void> openBlockedUsers() async {
    await showBlockedUsersSheet(context, onChanged: () {});
  }

  Future<void> openPolicy(String url) async {
    final bool opened = await AppInfo.openUrl(url);

    if (!opened) showMessage('เปิดหน้าเว็บไม่สำเร็จ: $url');
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // PASSWORD
  // =====================================================

  Future<void> changePassword() async {
    String currentPassword = '';

    String newPassword = '';

    String confirmation = '';

    bool hideCurrent = true;
    bool hideNew = true;
    bool hideConfirm = true;

    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,

      isScrollControlled: true,

      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  15,
                  20,
                  MediaQuery.of(context).viewInsets.bottom + 25,
                ),

                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,

                  children: [
                    Text(
                      hasPassword ? 'เปลี่ยนรหัสผ่าน' : 'ตั้งรหัสผ่าน',

                      style: TextStyle(
                        color: AppColors.navy,

                        fontSize: 21,

                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    const SizedBox(height: 6),

                    Text(
                      hasPassword ? 'รหัสผ่านใหม่ต้องมีอย่างน้อย 8 ตัวอักษร' : 'ตั้งรหัสผ่านเพื่อเข้าสู่ระบบด้วยอีเมลได้ด้วย (อย่างน้อย 8 ตัวอักษร)',

                      style: TextStyle(color: AppColors.muted, fontSize: 11),
                    ),

                    const SizedBox(height: 22),

                    if (hasPassword) ...[
                      TextField(
                        obscureText: hideCurrent,

                        onChanged: (value) {
                          currentPassword = value;
                        },

                        decoration: InputDecoration(
                          labelText: 'รหัสผ่านปัจจุบัน',

                          prefixIcon: const Icon(Icons.lock_outline_rounded),

                          suffixIcon: IconButton(
                            onPressed: () {
                              setSheetState(() {
                                hideCurrent = !hideCurrent;
                              });
                            },

                            icon: Icon(
                              hideCurrent
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),
                    ],

                    TextField(
                      obscureText: hideNew,

                      onChanged: (value) {
                        newPassword = value;
                      },

                      decoration: InputDecoration(
                        labelText: 'รหัสผ่านใหม่',

                        prefixIcon: const Icon(Icons.key_rounded),

                        suffixIcon: IconButton(
                          onPressed: () {
                            setSheetState(() {
                              hideNew = !hideNew;
                            });
                          },

                          icon: Icon(
                            hideNew
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 14),

                    TextField(
                      obscureText: hideConfirm,

                      onChanged: (value) {
                        confirmation = value;
                      },

                      decoration: InputDecoration(
                        labelText: 'ยืนยันรหัสผ่านใหม่',

                        prefixIcon: const Icon(Icons.verified_user_outlined),

                        suffixIcon: IconButton(
                          onPressed: () {
                            setSheetState(() {
                              hideConfirm = !hideConfirm;
                            });
                          },

                          icon: Icon(
                            hideConfirm
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 22),

                    FilledButton(
                      onPressed: () {
                        if ((hasPassword && currentPassword.isEmpty) ||
                            newPassword.length < 8 ||
                            newPassword != confirmation) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('กรุณาตรวจสอบข้อมูลรหัสผ่าน'),
                            ),
                          );

                          return;
                        }

                        Navigator.of(sheetContext).pop({
                          'current': currentPassword,

                          'password': newPassword,

                          'confirmation': confirmation,
                        });
                      },

                      child: Text(
                        hasPassword ? 'เปลี่ยนรหัสผ่าน' : 'ตั้งรหัสผ่าน',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    await Future<void>.delayed(const Duration(milliseconds: 250));

    try {
      final response = await ProfileService.updatePassword(
        currentPassword: hasPassword ? result['current'] : null,

        password: result['password']!,

        passwordConfirmation: result['confirmation']!,
      );

      if (!mounted) return;

      showMessage(
        response['message'] ??
            (response['status'] == true
                ? 'เปลี่ยนรหัสผ่านแล้ว'
                : 'เปลี่ยนรหัสผ่านไม่สำเร็จ'),
      );

      if (response['status'] == true) loadSocialAccounts();
    } catch (e) {
      if (!mounted) return;

      showMessage('เปลี่ยนรหัสผ่านไม่สำเร็จ');
    }
  }

  // =====================================================
  // ACCOUNT DELETION REQUEST
  // ผู้ใช้ส่งคำขอ → ทีมงานลบบัญชีและข้อมูลทั้งหมดให้ภายใน 30 วัน
  // ระหว่างรอยังใช้แอปได้ และยกเลิกคำขอได้
  // =====================================================

  Future<void> loadDeletionRequest() async {
    try {
      final result = await ProfileService.getDeletionRequest();

      if (!mounted || result['status'] != true) return;

      final dynamic request = result['request'];

      setState(() {
        deletionRequest = request is Map
            ? Map<String, dynamic>.from(request)
            : null;
      });
    } catch (_) {
      // โหลดไม่ได้ → แสดงปุ่มขอลบบัญชีตามปกติ
    }
  }

  // 28 ต.ค. 2569
  static String formatThaiDate(DateTime date) {
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

    return '${date.day} ${months[date.month]} ${date.year + 543}';
  }

  // วันที่ส่ง และวันที่ทีมงานจะลบให้ไม่เกิน
  ({String sent, String due})? deletionDates() {
    final request = deletionRequest;

    if (request == null) return null;

    final DateTime? created = DateTime.tryParse(
      request['created_at']?.toString() ?? '',
    )?.toLocal();

    if (created == null) return null;

    final int days = request['process_within_days'] is int
        ? request['process_within_days'] as int
        : 30;

    return (
      sent: formatThaiDate(created),
      due: formatThaiDate(created.add(Duration(days: days))),
    );
  }

  void openDeletion() {
    if (deletionBusy) return;

    if (deletionRequest != null) {
      showDeletionRequest();
    } else {
      requestAccountDeletion();
    }
  }

  Future<void> requestAccountDeletion() async {
    String secret = '';
    String reason = '';

    bool hideSecret = true;
    bool confirmed = false;

    final ({String secret, String reason})?
    result = await showModalBottomSheet<({String secret, String reason})>(
      context: context,

      isScrollControlled: true,

      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  15,
                  20,
                  MediaQuery.of(context).viewInsets.bottom + 25,
                ),

                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,

                  children: [
                    Text(
                      'ขอลบบัญชี',

                      style: TextStyle(
                        color: AppColors.danger,

                        fontSize: 21,

                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    const SizedBox(height: 10),

                    Text(
                      'ทีมงานจะลบบัญชีและข้อมูลต่อไปนี้ให้ภายใน 30 วัน '
                      'และกู้คืนไม่ได้\n'
                      '• บัญชีและรูปโปรไฟล์\n'
                      '• การเป็นสมาชิกกลุ่มและตำแหน่ง\n'
                      '• โพสต์ ความคิดเห็น แชท และกิจกรรมทั้งหมด\n'
                      '• ร้านค้า สินค้า และรูปทั้งหมด',

                      style: TextStyle(
                        color: AppColors.muted,

                        fontSize: 13,

                        height: 1.6,
                      ),
                    ),

                    const SizedBox(height: 12),

                    Container(
                      padding: const EdgeInsets.all(12),

                      decoration: BoxDecoration(
                        color: AppColors.fill,

                        borderRadius: BorderRadius.circular(14),
                      ),

                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,

                        children: [
                          Icon(
                            Icons.info_outline_rounded,

                            size: 18,

                            color: AppColors.primary,
                          ),

                          const SizedBox(width: 8),

                          Expanded(
                            child: Text(
                              'ระหว่างรอยังใช้แอปได้ตามปกติ '
                              'และยกเลิกคำขอได้ที่หน้านี้',

                              style: TextStyle(
                                color: AppColors.navy,

                                fontSize: 12.5,

                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),

                    TextField(
                      minLines: 1,

                      maxLines: 3,

                      maxLength: 1000,

                      onChanged: (value) {
                        reason = value;
                      },

                      decoration: const InputDecoration(
                        labelText: 'เหตุผล (ไม่บังคับ)',

                        prefixIcon: Icon(Icons.edit_note_rounded),

                        counterText: '',
                      ),
                    ),

                    const SizedBox(height: 12),

                    TextField(
                      obscureText: hasPassword && hideSecret,

                      onChanged: (value) {
                        secret = value;
                      },

                      decoration: InputDecoration(
                        // ไม่มีรหัสผ่าน (สมัครด้วย Google / LINE / Facebook) → พิมพ์ "ลบบัญชี"
                        labelText: hasPassword
                            ? 'ยืนยันด้วยรหัสผ่าน'
                            : 'พิมพ์คำว่า "ลบบัญชี" เพื่อยืนยัน',

                        prefixIcon: const Icon(Icons.lock_outline_rounded),

                        suffixIcon: !hasPassword
                            ? null
                            : IconButton(
                                onPressed: () {
                                  setSheetState(() {
                                    hideSecret = !hideSecret;
                                  });
                                },

                                icon: Icon(
                                  hideSecret
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                      ),
                    ),

                    const SizedBox(height: 8),

                    CheckboxListTile(
                      value: confirmed,

                      contentPadding: EdgeInsets.zero,

                      controlAffinity: ListTileControlAffinity.leading,

                      activeColor: AppColors.danger,

                      title: Text(
                        'ฉันเข้าใจว่าเมื่อลบแล้ว ข้อมูลทั้งหมดจะกู้คืนไม่ได้',

                        style: TextStyle(
                          color: AppColors.navy,

                          fontSize: 13,

                          fontWeight: FontWeight.w600,
                        ),
                      ),

                      onChanged: (value) {
                        setSheetState(() {
                          confirmed = value ?? false;
                        });
                      },
                    ),

                    const SizedBox(height: 14),

                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.danger,

                        disabledBackgroundColor: AppColors.danger.withValues(
                          alpha: 0.35,
                        ),

                        disabledForegroundColor: Colors.white,

                        minimumSize: const Size(double.infinity, 52),
                      ),

                      onPressed: confirmed
                          ? () {
                              if (secret.trim().isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      hasPassword
                                          ? 'กรุณากรอกรหัสผ่าน'
                                          : 'กรุณาพิมพ์คำว่า "ลบบัญชี"',
                                    ),
                                  ),
                                );

                                return;
                              }

                              Navigator.of(sheetContext)
                                  .pop((secret: secret, reason: reason.trim()));
                            }
                          : null,

                      child: const Text('ส่งคำขอลบบัญชี'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (result == null || !mounted) {
      return;
    }

    setState(() => deletionBusy = true);

    try {
      final String? reasonText = result.reason.isEmpty ? null : result.reason;

      final response = hasPassword
          ? await ProfileService.requestAccountDeletion(
              password: result.secret,
              reason: reasonText,
            )
          : await ProfileService.requestAccountDeletion(
              confirmText: result.secret.trim(),
              reason: reasonText,
            );

      if (!mounted) return;

      if (response['status'] != true) {
        showMessage(response['message']?.toString() ?? 'ส่งคำขอไม่สำเร็จ');
        return;
      }

      final dynamic request = response['request'];

      setState(() {
        deletionRequest = request is Map
            ? Map<String, dynamic>.from(request)
            : null;
      });

      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: Icon(
            Icons.mark_email_read_outlined,
            color: AppColors.primary,
            size: 34,
          ),
          title: const Text('ส่งคำขอแล้ว'),
          content: Text(
            '${response['message'] ?? 'ส่งคำขอลบบัญชีแล้ว'}\n\n'
            'ระหว่างนี้ยังใช้แอปได้ตามปกติ ถ้าเปลี่ยนใจ '
            'ยกเลิกคำขอได้ที่ ตั้งค่า → คำขอลบบัญชี',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('เข้าใจแล้ว'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;

      showMessage(e.toString());
    } finally {
      if (mounted) setState(() => deletionBusy = false);
    }
  }

  // มีคำขอรออยู่ → ดูสถานะ / ยกเลิก
  Future<void> showDeletionRequest() async {
    final dates = deletionDates();

    final bool? cancel = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('คำขอลบบัญชี'),
        content: Text(
          dates == null
              ? 'ทีมงานกำลังดำเนินการลบบัญชีของคุณ\n\n'
                    'ระหว่างนี้ยังใช้แอปได้ตามปกติ'
              : 'ส่งคำขอเมื่อ ${dates.sent}\n'
                    'ทีมงานจะลบบัญชีและข้อมูลทั้งหมดให้ภายใน ${dates.due}\n\n'
                    'ระหว่างนี้ยังใช้แอปได้ตามปกติ',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              'ยกเลิกคำขอ',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ปิด'),
          ),
        ],
      ),
    );

    if (cancel != true || !mounted) return;

    setState(() => deletionBusy = true);

    try {
      final response = await ProfileService.cancelDeletionRequest();

      if (!mounted) return;

      if (response['status'] == true) {
        setState(() => deletionRequest = null);
      }

      showMessage(
        response['message']?.toString() ??
            (response['status'] == true
                ? 'ยกเลิกคำขอลบบัญชีแล้ว'
                : 'ยกเลิกไม่สำเร็จ'),
      );
    } catch (e) {
      if (!mounted) return;

      showMessage(e.toString());
    } finally {
      if (mounted) setState(() => deletionBusy = false);
    }
  }

  // =====================================================
  // LOGOUT
  // =====================================================

  Future<void> logout() async {
    try {
      await AuthService.logout();
    } catch (_) {}

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          color: AppColors.muted,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  // กล่องสีขาวที่รวมหลายแถว
  Widget buildGroup(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: AppDecorations.cardBorder,
        boxShadow: AppDecorations.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 60, color: AppColors.border),
            children[i],
          ],
        ],
      ),
    );
  }

  // โหมดสี: ตามเครื่อง / สว่าง / มืด (เปลี่ยนทันที)
  Widget buildThemeSelector() {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, child) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  buildIcon(Icons.contrast_rounded, AppColors.primary),
                  const SizedBox(width: 14),
                  Text(
                    'โหมดสี',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    backgroundColor: AppColors.fill,
                    selectedBackgroundColor: AppColors.primary,
                    selectedForegroundColor: Colors.white,
                    foregroundColor: AppColors.navy,
                    side: BorderSide(color: AppColors.border),
                  ),
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: Icon(Icons.brightness_auto_outlined, size: 18),
                      label: Text('ตามเครื่อง'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode_outlined, size: 18),
                      label: Text('สว่าง'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode_outlined, size: 18),
                      label: Text('มืด'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (selection) {
                    ThemeController.set(selection.first);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget buildIcon(IconData icon, Color color) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }

  Widget buildSwitchRow({
    required IconData icon,
    required Color color,
    required String title,
    String? subtitle,
    required bool value,
    required bool busy,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: busy ? null : onChanged,
      secondary: buildIcon(icon, color),
      contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
      title: Text(
        title,
        style: TextStyle(
          color: AppColors.navy,
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
    );
  }

  Widget buildActionRow({
    required IconData icon,
    required String title,
    String? subtitle,
    Color? color,
    bool danger = false,
    required VoidCallback onTap,
  }) {
    color ??= AppColors.primary;

    return ListTile(
      onTap: onTap,
      leading: buildIcon(icon, color),
      contentPadding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      title: Text(
        title,
        style: TextStyle(
          color: danger ? AppColors.danger : AppColors.navy,
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
      trailing: Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    );
  }

  List<Widget> buildPreferenceSections() {
    if (isLoading) {
      return const [
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (loadError != null) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
          child: Column(
            children: [
              Text(
                loadError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.navy),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: loadSettings,
                child: const Text('ลองอีกครั้ง'),
              ),
            ],
          ),
        ),
      ];
    }

    return [
      buildSectionTitle('ตำแหน่ง'),
      buildGroup([
        buildSwitchRow(
          icon: Icons.location_on_outlined,
          color: AppColors.success,
          title: 'แชร์ตำแหน่งกับกลุ่ม',
          subtitle: !locationSharing
              ? 'ปิดอยู่ สมาชิกในกลุ่มไม่เห็นตำแหน่งของคุณ'
              : backgroundLocation
              ? 'สมาชิกในกลุ่มเห็นตำแหน่งของคุณ แม้ปิดแอป'
              : 'สมาชิกในกลุ่มเห็นตำแหน่งล่าสุดของคุณขณะเปิดแอป',
          value: locationSharing,
          busy: savingKeys.contains('location_sharing'),
          onChanged: setLocationSharing,
        ),
        if (BackgroundLocation.supported)
          buildSwitchRow(
            icon: Icons.share_location_rounded,
            color: AppColors.primary,
            title: 'แชร์แม้ไม่ได้เปิดแอป',
            subtitle: backgroundLocation
                ? 'ส่งเมื่อคุณขยับ และอย่างน้อยทุก 5 นาที (มีแจ้งเตือนค้างไว้)'
                : 'สมาชิกในกลุ่มเห็นตำแหน่งปัจจุบันแม้คุณปิดแอป',
            value: locationSharing && backgroundLocation,
            busy: backgroundBusy || !locationSharing,
            onChanged: setBackgroundLocation,
          ),
      ]),
      buildSectionTitle('การแจ้งเตือน'),
      buildGroup([
        for (final option in notificationOptions)
          buildSwitchRow(
            icon: option.icon,
            color: AppColors.primary,
            title: option.title,
            value: notifications[option.type] ?? true,
            busy: savingKeys.contains(option.type),
            onChanged: (value) => setNotification(option.type, value),
          ),
      ]),
      Padding(
        padding: EdgeInsets.fromLTRB(6, 8, 6, 0),
        child: Text(
          'สถานะร้านค้าและผลตรวจสลิปจะแจ้งเสมอ',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ตั้งค่า')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          ...buildPreferenceSections(),
          buildSectionTitle('การแสดงผล'),
          buildGroup([buildThemeSelector()]),
          buildSectionTitle('ความเป็นส่วนตัว'),
          buildGroup([
            buildActionRow(
              icon: Icons.block_rounded,
              title: 'ผู้ใช้ที่บล็อก',
              subtitle: 'ดูและเลิกบล็อกผู้ใช้ในชุมชน',
              color: AppColors.muted,
              onTap: openBlockedUsers,
            ),
          ]),
          if (visibleSocialAccounts.isNotEmpty) ...[
            buildSectionTitle('บัญชีที่เชื่อมต่อ'),
            buildGroup([
              for (final account in visibleSocialAccounts)
                buildSocialRow(account),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Text(
                'เชื่อมแล้วเข้าสู่ระบบด้วยบัญชีนั้นได้ทันที โดยไม่ต้องใช้รหัสผ่าน',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          ],
          buildSectionTitle('บัญชี'),
          buildGroup([
            buildActionRow(
              icon: Icons.password_rounded,
              title: hasPassword ? 'เปลี่ยนรหัสผ่าน' : 'ตั้งรหัสผ่าน',
              color: AppColors.warm,
              onTap: changePassword,
            ),
            buildActionRow(
              icon: Icons.devices_rounded,
              title: 'อุปกรณ์ที่เข้าสู่ระบบ',
              subtitle: 'ดูเครื่องที่ใช้บัญชีนี้ และออกจากระบบเครื่องอื่น',
              color: AppColors.sky,
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const DevicesPage())),
            ),
            buildActionRow(
              icon: Icons.logout_rounded,
              title: 'ออกจากระบบ',
              color: AppColors.danger,
              danger: true,
              onTap: logout,
            ),
            if (deletionRequest != null)
              buildActionRow(
                icon: Icons.hourglass_top_rounded,
                title: 'คำขอลบบัญชี: รอดำเนินการ',
                subtitle: deletionDates() == null
                    ? 'แตะเพื่อดูรายละเอียดหรือยกเลิกคำขอ'
                    : 'ทีมงานจะลบให้ภายใน ${deletionDates()!.due} · แตะเพื่อยกเลิก',
                color: AppColors.warm,
                onTap: openDeletion,
              )
            else
              buildActionRow(
                icon: Icons.delete_forever_rounded,
                title: 'ขอลบบัญชี',
                subtitle: 'ส่งคำขอให้ทีมงานลบบัญชีและข้อมูลทั้งหมด',
                color: AppColors.danger,
                danger: true,
                onTap: openDeletion,
              ),
          ]),
          buildSectionTitle('ช่วยเหลือ'),
          buildGroup([
            buildActionRow(
              icon: Icons.support_agent_rounded,
              title: 'ช่วยเหลือและแจ้งปัญหา',
              color: AppColors.sky,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SupportCenterPage()),
              ),
            ),
          ]),
          buildSectionTitle('เกี่ยวกับแอป'),
          buildGroup([
            buildActionRow(
              icon: Icons.privacy_tip_outlined,
              title: 'นโยบายความเป็นส่วนตัว',
              color: AppColors.sky,
              onTap: () => openPolicy(AppInfo.privacyUrl),
            ),
            buildActionRow(
              icon: Icons.description_outlined,
              title: 'ข้อกำหนดการใช้งาน',
              color: AppColors.sky,
              onTap: () => openPolicy(AppInfo.termsUrl),
            ),
            buildActionRow(
              icon: Icons.child_care_rounded,
              title: 'มาตรฐานความปลอดภัยของเด็ก',
              color: AppColors.sky,
              onTap: () => openPolicy(AppInfo.childSafetyUrl),
            ),
          ]),
          if (version.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: Text(
                '${AppInfo.name} เวอร์ชัน $version',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotificationOption {
  final String type;
  final String title;
  final IconData icon;

  const _NotificationOption({
    required this.type,
    required this.title,
    required this.icon,
  });
}
