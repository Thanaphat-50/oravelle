import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart' show RemoteMessage;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../config/app_info.dart';
import '../services/auth_service.dart';
import '../services/background_location.dart';
import '../data/market_data.dart' show marketColor;
import '../services/cart_service.dart';
import '../services/chat_service.dart';
import '../services/family_service.dart';
import '../services/location_tracker.dart';
import '../services/notification_service.dart';
import '../services/profile_service.dart';
import '../services/push_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/account_drawer.dart';
import '../widgets/family_invitation_cards.dart';
import '../widgets/post_categories.dart';
import '../widgets/section_switch.dart';
import '../widgets/swipe_sections.dart';
import '../widgets/user_avatar.dart';

import 'activity_page.dart';
import 'addresses_page.dart';
import 'cart_page.dart';
import 'chat_list_page.dart';
import 'chat_room_page.dart';
import 'feed_page.dart';
import 'map_page.dart';
import 'history_page.dart';
import '../services/order_service.dart';
import 'my_shop_page.dart';
import 'notification_page.dart';
import 'order_page.dart';
import 'orders_page.dart';
import 'post_detail_page.dart';
import 'saved_products_page.dart';
import 'profile_page.dart';
import 'settings_page.dart';
import 'shop_page.dart';
import 'user_profile_page.dart';
import 'video_feed_page.dart';
import 'support_center_page.dart';
import 'support_ticket_page.dart';
import 'activity_detail_page.dart';
import 'search_page.dart';

// หน้าย่อยของแท็บ "หน้าหลัก"

// หน้าย่อยของแท็บ "ครอบครัว"
enum FamilySection { posts, members }

class HomePage extends StatefulWidget {
  final String userName;

  const HomePage({super.key, required this.userName});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final TextEditingController familyNameController = TextEditingController();

  final TextEditingController inviteCodeController = TextEditingController();

  // ลำดับแท็บบนแถบล่าง
  static const int tabHome = 0;
  static const int tabMarket = 1;
  static const int tabFamily = 2;
  static const int tabMap = 3;
  static const int tabActivity = 4;

  int selectedIndex = tabHome;
  int unreadNotificationCount = 0;

  // เมนูบัญชี: คำสั่งซื้อรอชำระเงิน
  int ordersToPay = 0;

  // เมนูบัญชีด้านซ้าย (เปิดจากรูปโปรไฟล์มุมซ้ายบน)
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

  // ข้อมูลจาก /api/profile ใช้กับรูปมุมซ้ายบนและหัวเมนูบัญชี
  Map<String, dynamic>? myProfile;

  // หน้าหลัก: สำหรับคุณ | ล่าสุด | วิดีโอ (ปัดซ้าย-ขวาสลับได้)
  CommunityFeedMode homeMode = CommunityFeedMode.forYou;

  // หมวดที่กรองฟีดหน้าหลัก (null = ทั้งหมด) ใช้ร่วมกันทั้ง สำหรับคุณ / ล่าสุด
  String? homeCategory;

  // ครอบครัว: โพสต์ | สมาชิก (ปัดซ้าย-ขวาสลับได้)
  FamilySection familySection = FamilySection.posts;

  // แถบเมนูล่าง: ในแท็บหน้าหลัก เลื่อนลงแล้วซ่อน เลื่อนขึ้นแล้วแสดง
  bool bottomBarVisible = true;

  // เพิ่มเมื่อร้านของเราเปลี่ยน → หน้าตลาดโหลดใหม่
  int marketRefreshToken = 0;

  bool isLoading = true;
  bool isWorking = false;

  Map<String, dynamic>? familyData;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    loadFamily();
    loadUnreadNotificationCount();
    loadMyProfile();

    setUpPush();

    FamilyService.changes.addListener(onFamilyChanged);
  }

  void onFamilyChanged() => loadFamily(showLoading: false);

  // =====================================================
  // APP LIFECYCLE
  // =====================================================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // loadFamily เริ่มส่งตำแหน่งต่อให้เอง
      loadFamily(showLoading: false);

      loadUnreadNotificationCount();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // ไม่ส่งตำแหน่งตอนแอปอยู่เบื้องหลัง
      LocationTracker.stop();
    }
  }

  // =====================================================
  // ส่งตำแหน่งให้ครอบครัว ขณะเปิดแอป (ทุกแท็บ)
  // =====================================================

  Future<void> startLocationSharing() async {
    if (!hasFamily) {
      LocationTracker.stop();
      BackgroundLocation.pause();
      return;
    }

    // โหลดค่า "แชร์ตำแหน่ง" ครั้งแรกก่อนเริ่ม
    if (SettingsService.locationSharing.value == null) {
      try {
        await SettingsService.getSettings();
      } catch (_) {
        // โหลดไม่ได้ → ใช้ค่าเริ่มต้น (แชร์)
      }
    }

    if (!mounted) return;

    await LocationTracker.start();

    // แชร์ตอนปิดแอปด้วย (ถ้าผู้ใช้เปิดไว้และยังอนุญาต "ตลอดเวลา")
    await BackgroundLocation.sync();
  }

  // =====================================================
  // FAMILY
  // =====================================================

  // คำเชิญ / คำขอเข้าครอบครัว (โหลดพร้อมข้อมูลครอบครัว)
  Map<String, dynamic>? invitations;

  final Set<int> invitationBusy = {};

  List<Map<String, dynamic>> invitationList(String key) {
    final dynamic raw = invitations?[key];

    return raw is List
        ? raw
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
        : [];
  }

  Future<void> loadInvitations() async {
    try {
      final result = await FamilyService.invitations();

      if (!mounted || result['status'] != true) return;

      setState(() => invitations = result);
    } catch (_) {
      // โหลดไม่ได้ → ไม่แสดงส่วนคำเชิญ
    }
  }

  // action: accept / decline
  Future<void> respondInvitation(
    Map<String, dynamic> invitation,
    String action,
  ) async {
    final dynamic id = invitation['id'];

    if (id is! num || invitationBusy.contains(id.toInt())) return;

    setState(() => invitationBusy.add(id.toInt()));

    try {
      final result = await FamilyService.respondInvitation(id.toInt(), action);

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ทำรายการไม่สำเร็จ');

      if (result['joined'] == true) {
        await loadFamily(showLoading: false);
      } else {
        await loadInvitations();
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => invitationBusy.remove(id.toInt()));
    }
  }

  Future<void> cancelInvitation(Map<String, dynamic> invitation) async {
    final dynamic id = invitation['id'];

    if (id is! num || invitationBusy.contains(id.toInt())) return;

    setState(() => invitationBusy.add(id.toInt()));

    try {
      final result = await FamilyService.cancelInvitation(id.toInt());

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ทำรายการไม่สำเร็จ');

      await loadInvitations();
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => invitationBusy.remove(id.toInt()));
    }
  }

  Future<void> inviteByEmail() async {
    final String? email = await askInviteEmail(context);

    if (email == null || !mounted) return;

    try {
      final result = await FamilyService.invite(email: email);

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ส่งคำเชิญไม่สำเร็จ');

      if (result['joined'] == true) {
        await loadFamily(showLoading: false);
      } else if (result['status'] == true) {
        await loadInvitations();
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    }
  }

  // ส่งรหัสเชิญผ่านแอปอื่น (LINE / Messenger ...)
  Future<void> shareInviteCode(String familyName, String code) async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          text:
              'มาอยู่กลุ่ม "$familyName" ด้วยกันในแอป ${AppInfo.name}\n'
              'เปิดแอป → แท็บกลุ่มสมาชิก → เข้าร่วมกลุ่ม แล้วใส่รหัส $code',
          subject: 'ชวนเข้ากลุ่ม $familyName',
        ),
      );
    } catch (_) {
      showMessage('เปิดหน้าแชร์ไม่ได้');
    }
  }

  // ยังไม่มีครอบครัว → ไปแท็บครอบครัว (สร้าง / เข้าร่วม / คำเชิญ)
  void goToFamilyTab() {
    setState(() {
      selectedIndex = tabFamily;
      bottomBarVisible = true;
    });
  }

  Future<void> loadFamily({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        isLoading = true;
      });
    }

    try {
      final result = await FamilyService.getCurrentFamily();

      if (!mounted) return;

      setState(() {
        familyData = result;
      });

      startLocationSharing();

      loadInvitations();
    } catch (e) {
      if (!mounted) return;

      showMessage('โหลดข้อมูลกลุ่มไม่สำเร็จ: $e');
    } finally {
      if (showLoading && mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // =====================================================
  // NOTIFICATION
  // =====================================================

  Future<void> loadUnreadNotificationCount() async {
    // ตัวเลขบนไอคอนแชทโหลดไปพร้อมกัน
    ChatService.refreshUnreadCount();

    try {
      final count = await NotificationService.getUnreadCount();

      if (!mounted) return;

      setState(() {
        unreadNotificationCount = count;
      });
    } catch (_) {
      // Notification ล้มเหลว
      // ไม่ให้กระทบหน้าหลัก
    }
  }

  // =====================================================
  // แจ้งเตือนเด้ง (Push)
  // =====================================================

  StreamSubscription<RemoteMessage>? pushOpenedSubscription;
  StreamSubscription<RemoteMessage>? pushForegroundSubscription;

  // แถบข้อความแจ้งเตือนที่แสดงอยู่ (ปิดตอนออกจากหน้านี้)
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? pushSnackBar;

  void setUpPush() {
    PushService.register();

    pushOpenedSubscription = PushService.onOpened.listen(
      (message) => openFromPush(message.data),
    );

    pushForegroundSubscription = PushService.onForeground.listen(
      showForegroundPush,
    );

    // เปิดแอปจากการกดแจ้งเตือน (ตอนแอปปิดอยู่)
    PushService.takeInitialMessage().then((data) {
      if (data != null && mounted) openFromPush(data);
    });
  }

  // แจ้งเตือนเข้าตอนเปิดแอปอยู่ → แถบข้อความ + ปุ่มดู
  void showForegroundPush(RemoteMessage message) {
    loadUnreadNotificationCount();

    // กำลังเปิดห้องแชทนั้นอยู่ → ข้อความขึ้นในห้องเองแล้ว
    if (message.data['type'] == 'new_message' &&
        message.data['conversation_id']?.toString() ==
            ChatService.activeConversationId?.toString()) {
      return;
    }

    final String text =
        message.notification?.body ?? message.notification?.title ?? '';

    if (text.isEmpty || !mounted) return;

    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();

    pushSnackBar = messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        action: SnackBarAction(
          label: 'ดู',
          onPressed: () => openFromPush(message.data),
        ),
      ),
    );
  }

  // กดแจ้งเตือน → ไปที่เรื่องนั้นเลย (เหมือนกดในหน้าแจ้งเตือน)
  Future<void> openFromPush(Map<String, dynamic> data) async {
    if (!mounted) return;

    final int? notificationId = int.tryParse('${data['notification_id'] ?? ''}');

    if (notificationId != null) {
      NotificationService.markAsRead(notificationId)
          .then((_) => loadUnreadNotificationCount())
          .catchError((_) {});
    }

    final String type = data['type']?.toString() ?? '';

    final int? postId = int.tryParse('${data['post_id'] ?? ''}');

    final NavigatorState navigator = Navigator.of(context);

    switch (type) {
      case 'new_message':
        final int? conversationId = int.tryParse(
          '${data['conversation_id'] ?? ''}',
        );

        if (conversationId != null) {
          await navigator.push(
            MaterialPageRoute(
              builder: (_) => ChatRoomPage(conversationId: conversationId),
            ),
          );
          return;
        }

      case 'new_post':
      case 'new_comment':
        if (postId != null) {
          await navigator.push(
            MaterialPageRoute(builder: (_) => PostDetailPage(postId: postId)),
          );
          return;
        }

      case 'shop_status':
      case 'promotion_status':
        await navigator.push(
          MaterialPageRoute(builder: (_) => const MyShopPage()),
        );
        return;

      // ทีมงานตอบ / เปลี่ยนสถานะคำร้อง → หน้าคำร้อง (เซิร์ฟเวอร์ตรวจว่าเป็นของเรา)
      case 'support_ticket':
        final int? ticketId = int.tryParse('${data['ticket_id'] ?? ''}');

        if (ticketId != null) {
          await navigator.push(
            MaterialPageRoute(
              builder: (_) => SupportTicketPage(ticketId: ticketId),
            ),
          );
          return;
        }

      case 'order_status':
        final int? orderId = int.tryParse('${data['order_id'] ?? ''}');
        if (orderId != null) {
          await navigator.push(
            MaterialPageRoute(builder: (_) => OrderPage(orderId: orderId)),
          );
          return;
        }

      // เตือนกิจกรรม → หน้ารายละเอียด (เซิร์ฟเวอร์ตรวจสิทธิ์ / ถูกลบ → ข้อความแจ้ง)
      case 'activity_reminder':
        final int? activityId = int.tryParse('${data['activity_id'] ?? ''}');

        if (activityId != null) {
          await navigator.push(
            MaterialPageRoute(
              builder: (_) => ActivityDetailPage(activityId: activityId),
            ),
          );
          return;
        }

      // เปลี่ยนแท็บ → ปิดหน้าที่เปิดซ้อนอยู่ก่อน ให้เห็นแท็บนั้น
      case 'new_activity':
        navigator.popUntil((route) => route.isFirst);

        setState(() {
          selectedIndex = tabActivity;
          bottomBarVisible = true;
        });
        return;

      case 'member_joined':
      case 'family_invite':
      case 'family_request':
      case 'family_request_accepted':
        navigator.popUntil((route) => route.isFirst);

        setState(() {
          selectedIndex = tabFamily;
          familySection = FamilySection.members;
          bottomBarVisible = true;
        });

        loadFamily(showLoading: false);
        return;
    }

    await openNotifications();
  }

  Future<void> openNotifications() async {
    final NotificationTarget? target = await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const NotificationPage()));

    if (!mounted) return;

    // กดการแจ้งเตือนกิจกรรม / สมาชิกใหม่ → เปิดแท็บนั้น
    switch (target) {
      case NotificationTarget.activities:
        setState(() {
          selectedIndex = tabActivity;
          bottomBarVisible = true;
        });
      case NotificationTarget.familyMembers:
        setState(() {
          selectedIndex = tabFamily;
          familySection = FamilySection.members;
          bottomBarVisible = true;
        });
        loadFamily(showLoading: false);
      case null:
        break;
    }

    await loadUnreadNotificationCount();
  }

  // =====================================================
  // MESSAGE
  // =====================================================

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // CREATE FAMILY
  // =====================================================

  Future<void> createFamily() async {
    final name = familyNameController.text.trim();

    if (name.isEmpty) {
      showMessage('กรุณาใส่ชื่อกลุ่ม');

      return;
    }

    setState(() {
      isWorking = true;
    });

    try {
      final result = await FamilyService.createFamily(name: name);

      if (!mounted) return;

      if (result['status'] == true) {
        familyNameController.clear();

        await loadFamily();

        if (!mounted) return;

        showMessage('สร้างกลุ่มสำเร็จ');
      } else {
        showMessage(result['message'] ?? 'สร้างกลุ่มไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) {
        setState(() {
          isWorking = false;
        });
      }
    }
  }

  // =====================================================
  // JOIN FAMILY
  // =====================================================

  Future<void> joinFamily() async {
    final code = inviteCodeController.text.trim();

    if (code.isEmpty) {
      showMessage('กรุณาใส่ Invite Code');

      return;
    }

    setState(() {
      isWorking = true;
    });

    try {
      final result = await FamilyService.joinFamily(inviteCode: code);

      if (!mounted) return;

      if (result['status'] == true) {
        inviteCodeController.clear();

        await loadFamily();

        if (!mounted) return;

        showMessage('เข้าร่วมกลุ่มสำเร็จ');
      } else {
        showMessage(result['message'] ?? 'เข้าร่วมกลุ่มไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    } finally {
      if (mounted) {
        setState(() {
          isWorking = false;
        });
      }
    }
  }

  // =====================================================
  // COPY INVITE CODE
  // =====================================================

  Future<void> copyInviteCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));

    if (!mounted) return;

    showMessage('คัดลอก Invite Code แล้ว');
  }

  // =====================================================
  // EDIT FAMILY NAME
  // =====================================================

  Future<void> editFamilyName() async {
    final family = familyData?['family'];

    if (family == null) return;

    String newName = family['name']?.toString() ?? '';

    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,

          surfaceTintColor: Colors.transparent,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),

          title: Text(
            'เปลี่ยนชื่อกลุ่ม',
            style: TextStyle(
              color: AppColors.navy,
              fontWeight: FontWeight.w800,
            ),
          ),

          content: TextFormField(
            initialValue: newName,

            autofocus: true,

            onChanged: (value) {
              newName = value;
            },

            decoration: const InputDecoration(
              labelText: 'ชื่อกลุ่ม',
              prefixIcon: Icon(Icons.groups_rounded),
            ),
          ),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
              child: const Text('ยกเลิก'),
            ),

            FilledButton(
              onPressed: () {
                final name = newName.trim();

                if (name.isEmpty) {
                  return;
                }

                Navigator.of(dialogContext).pop(name);
              },
              child: const Text('บันทึก'),
            ),
          ],
        );
      },
    );

    if (!mounted || result == null) {
      return;
    }

    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    try {
      final response = await FamilyService.updateFamilyName(
        familyId: (family['id'] as num).toInt(),
        name: result,
      );

      if (!mounted) return;

      if (response['status'] == true) {
        await loadFamily(showLoading: false);

        if (!mounted) return;

        showMessage('เปลี่ยนชื่อกลุ่มสำเร็จ');
      } else {
        showMessage(response['message'] ?? 'เปลี่ยนชื่อกลุ่มไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // REGENERATE INVITE CODE
  // =====================================================

  Future<void> regenerateInviteCode() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,

          surfaceTintColor: Colors.transparent,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),

          title: const Text(
            'สร้าง Invite Code ใหม่',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),

          content: const Text('รหัสเดิมจะไม่สามารถใช้เข้าร่วมกลุ่มได้อีก'),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('ยกเลิก'),
            ),

            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('สร้างรหัสใหม่'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) {
      return;
    }

    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    try {
      final response = await FamilyService.regenerateInviteCode();

      if (!mounted) return;

      if (response['status'] == true) {
        await loadFamily(showLoading: false);

        if (!mounted) return;

        showMessage('สร้าง Invite Code ใหม่แล้ว');
      } else {
        showMessage(response['message'] ?? 'สร้าง Invite Code ใหม่ไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // REMOVE MEMBER
  // =====================================================

  Future<void> removeFamilyMember(int userId, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,

          surfaceTintColor: Colors.transparent,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),

          title: const Text(
            'นำสมาชิกออก',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),

          content: Text('ต้องการนำ $name ออกจากกลุ่มหรือไม่?'),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('ยกเลิก'),
            ),

            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('นำออก'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) {
      return;
    }

    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    try {
      final response = await FamilyService.removeMember(userId: userId);

      if (!mounted) return;

      if (response['status'] == true) {
        await loadFamily(showLoading: false);

        if (!mounted) return;

        showMessage('นำสมาชิกออกจากกลุ่มแล้ว');
      } else {
        showMessage(response['message'] ?? 'นำสมาชิกออกไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // LEAVE FAMILY
  // =====================================================

  Future<void> leaveFamily() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,

          surfaceTintColor: Colors.transparent,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),

          title: const Text(
            'ออกจากกลุ่ม',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),

          content: const Text('คุณต้องการออกจากกลุ่มนี้หรือไม่?'),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('ยกเลิก'),
            ),

            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('ออกจากกลุ่ม'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) {
      return;
    }

    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    try {
      final response = await FamilyService.leaveFamily();

      if (!mounted) return;

      if (response['status'] == true) {
        await loadFamily();

        if (!mounted) return;

        setState(() {
          selectedIndex = tabHome;
        });

        showMessage('ออกจากกลุ่มแล้ว');
      } else {
        showMessage(response['message'] ?? 'ไม่สามารถออกจากกลุ่มได้');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // TRANSFER OWNER
  // =====================================================

  Future<void> transferFamilyOwner(int userId, String memberName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,

          surfaceTintColor: Colors.transparent,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),

          title: const Text(
            'โอนสิทธิ์ Owner',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),

          content: Text(
            'ต้องการโอนสิทธิ์ Owner ให้ $memberName หรือไม่?\n\n'
            'หลังจากโอนแล้ว คุณจะกลายเป็น Member',
          ),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('ยกเลิก'),
            ),

            FilledButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              icon: const Icon(Icons.workspace_premium_rounded),
              label: const Text('โอนสิทธิ์'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) {
      return;
    }

    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    try {
      final result = await FamilyService.transferOwner(userId: userId);

      if (!mounted) return;

      if (result['status'] == true) {
        await loadFamily(showLoading: false);

        if (!mounted) return;

        showMessage('โอนสิทธิ์ Owner ให้ $memberName สำเร็จ');
      } else {
        showMessage(result['message'] ?? 'โอนสิทธิ์ Owner ไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // DELETE FAMILY
  // =====================================================

  Future<void> deleteCurrentFamily() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.surface,

          surfaceTintColor: Colors.transparent,

          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),

          icon: Icon(
            Icons.warning_amber_rounded,
            color: AppColors.danger,
            size: 42,
          ),

          title: const Text(
            'ลบกลุ่ม?',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w800),
          ),

          content: const Text(
            'สมาชิกทั้งหมดจะออกจากกลุ่ม '
            'โพสต์และข้อมูลของกลุ่มจะถูกลบ\n\n'
            'การดำเนินการนี้ไม่สามารถย้อนกลับได้',
            textAlign: TextAlign.center,
          ),

          actionsAlignment: MainAxisAlignment.center,

          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('ยกเลิก'),
            ),

            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('ลบกลุ่ม'),
            ),
          ],
        );
      },
    );

    if (confirm != true || !mounted) {
      return;
    }

    await Future.delayed(const Duration(milliseconds: 250));

    if (!mounted) return;

    try {
      final result = await FamilyService.deleteFamily();

      if (!mounted) return;

      if (result['status'] == true) {
        await loadFamily();

        if (!mounted) return;

        setState(() {
          selectedIndex = tabHome;
        });

        showMessage('ลบกลุ่มสำเร็จ');
      } else {
        showMessage(result['message'] ?? 'ลบกลุ่มไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      showMessage('เกิดข้อผิดพลาด: $e');
    }
  }

  // =====================================================
  // LOGOUT
  // =====================================================

  Future<void> openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  // =====================================================
  // บัญชีของฉัน (รูปมุมซ้ายบน + เมนูด้านซ้าย)
  // =====================================================

  Future<void> loadMyProfile() async {
    try {
      final result = await ProfileService.getProfile();

      if (!mounted || result['status'] != true) return;

      setState(() {
        myProfile = Map<String, dynamic>.from(result);
      });
    } catch (_) {
      // โหลดไม่ได้ → ใช้ชื่อที่รู้อยู่แล้วไปก่อน
    }
  }

  Map<String, dynamic> get myUser {
    final dynamic value = myProfile?['user'];

    return value is Map
        ? Map<String, dynamic>.from(value)
        : {'name': widget.userName};
  }

  // หน้าโปรไฟล์ของคนอื่น (เช่น กดการ์ดสมาชิกครอบครัว)
  Future<void> openUserProfile(int userId, String name) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => UserProfilePage(userId: userId, name: name),
      ),
    );
  }

  void openAccountMenu() {
    // โหลดตัวเลข/รูปล่าสุดระหว่างเปิดเมนู
    loadMyProfile();
    loadUnreadNotificationCount();
    loadOrdersToPay();

    scaffoldKey.currentState?.openDrawer();
  }

  // คำสั่งซื้อรอชำระเงิน (ตัวเลขเดียวกับแท็บ "รอชำระเงิน" ในคำสั่งซื้อของฉัน)
  Future<void> loadOrdersToPay() async {
    try {
      final result = await OrderService.getOrders(
        seller: false,
        filter: 'to_pay',
      );

      final dynamic counts = result['counts'];

      if (!mounted || result['status'] != true || counts is! Map) return;

      setState(() {
        ordersToPay = (counts['to_pay'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {
      // โหลดไม่ได้ → ไม่แสดงข้อความรอชำระ
    }
  }

  Widget buildAccountButton() {
    return Center(
      child: Tooltip(
        message: 'บัญชีของฉัน',
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: openAccountMenu,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  width: 2,
                ),
              ),
              child: UserAvatar(user: myUser, radius: 18),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> handleAccountMenu(AccountMenuItem item) async {
    final NavigatorState navigator = Navigator.of(context);

    switch (item) {
      case AccountMenuItem.profile:
        // หน้าโปรไฟล์มีแถบด้านบน (ชื่อหน้า + ปุ่มตั้งค่า) ของตัวเอง
        await navigator.push(
          MaterialPageRoute(builder: (_) => const ProfilePage()),
        );

      // "โพสต์ของฉัน" และ "โปรไฟล์ในชุมชน" อยู่ในหน้าโปรไฟล์แล้ว
      // (ส่วนโพสต์ของฉัน + ตัวกรอง / ปุ่ม "ดูโปรไฟล์ที่คนอื่นเห็น")
      case AccountMenuItem.history:
        await navigator.push(
          MaterialPageRoute(builder: (_) => const HistoryPage()),
        );

      case AccountMenuItem.family:
        setState(() {
          selectedIndex = tabFamily;
          familySection = FamilySection.members;
          bottomBarVisible = true;
        });

        loadFamily(showLoading: false);
        return;

      case AccountMenuItem.notifications:
        await openNotifications();

      case AccountMenuItem.orders:
        await openMyOrders();

      case AccountMenuItem.addresses:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AddressesPage(picking: false),
          ),
        );

      case AccountMenuItem.savedProducts:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SavedProductsPage()));

      case AccountMenuItem.shop:
        await openSellerAccount();

      case AccountMenuItem.settings:
        await openSettings();

      case AccountMenuItem.help:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const SupportCenterPage()));
      case AccountMenuItem.logout:
        await confirmLogout();
        return;
    }

    // อาจเปลี่ยนรูป/ชื่อ หรือลบโพสต์ไปแล้ว → โหลดใหม่
    if (mounted) loadMyProfile();
  }

  Future<void> confirmLogout() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ออกจากระบบ?'),
        content: const Text('เครื่องนี้จะไม่ได้รับแจ้งเตือนของบัญชีนี้จนกว่าจะเข้าสู่ระบบอีกครั้ง'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('ออกจากระบบ'),
          ),
        ],
      ),
    );

    if (confirmed == true) await logout();
  }

  Future<void> logout() async {
    await AuthService.logout();

    if (!mounted) return;

    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  // =====================================================
  // HELPERS
  // =====================================================

  bool get hasFamily => familyData?['has_family'] == true;

  String getPageTitle() {
    switch (selectedIndex) {
      case tabHome:
        return 'ชุมชน';

      case tabMarket:
        return 'ร้านค้า';

      case tabFamily:
        return 'กลุ่มสมาชิก';

      case tabMap:
        return 'ตำแหน่งสมาชิก';

      case tabActivity:
        return 'กิจกรรม';

      default:
        return AppInfo.name;
    }
  }

  String getInitial(String name) {
    final text = name.trim();

    if (text.isEmpty) {
      return '?';
    }

    return text.characters.first.toUpperCase();
  }

  String? getMemberProfileImage(dynamic member) {
    if (member is! Map) return null;

    const possibleKeys = [
      'profile_image_url',
      'profile_image',
      'avatar_url',
      'avatar',
      'photo_url',
      'photo',
      'image_url',
      'image',
    ];

    for (final key in possibleKeys) {
      final value = member[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value.toLowerCase() != 'null') {
        return value;
      }
    }

    return null;
  }

  Widget buildMemberAvatar({
    required String name,
    required bool isOwner,
    String? imageUrl,
    double size = 48,
  }) {
    final hasImage = imageUrl != null && imageUrl.trim().isNotEmpty;

    Widget fallbackAvatar() {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isOwner
                ? [AppColors.warm, Color(0xFFFF8A5B)]
                : [AppColors.primary, Color(0xFF767BFF)],
          ),
          shape: BoxShape.circle,
        ),
        child: Text(
          getInitial(name),
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipOval(
          child: SizedBox(
            width: size,
            height: size,
            child: hasImage
                ? Image.network(
                    imageUrl.trim(),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => fallbackAvatar(),
                  )
                : fallbackAvatar(),
          ),
        ),

        if (isOwner)
          Positioned(
            right: -3,
            bottom: -2,
            child: Container(
              width: 21,
              height: 21,

              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,

                border: Border.all(color: AppColors.border),
              ),

              child: Icon(
                Icons.workspace_premium_rounded,
                size: 14,
                color: AppColors.warm,
              ),
            ),
          ),
      ],
    );
  }

  // =====================================================
  // PAGE SELECTOR
  // แถบล่างเปลี่ยนหน้าด้วยการกดเท่านั้น
  // ปัดซ้าย-ขวาได้เฉพาะหน้าย่อยในหน้าเดียวกัน
  // (หน้าหลัก: สำหรับคุณ / ล่าสุด / วิดีโอ, ครอบครัว: โพสต์ / สมาชิก)
  // =====================================================

  // แท็บที่ต้องใช้ข้อมูลครอบครัว (รอโหลดก่อนแสดง)
  // หน้าหลัก (ชุมชน) และตลาด ดูได้แม้ยังไม่มีครอบครัว
  bool get tabNeedsFamily =>
      selectedIndex == tabFamily || selectedIndex == tabMap;

  Widget getCurrentPage() {
    if (isLoading && tabNeedsFamily) {
      return const Center(child: CircularProgressIndicator());
    }

    switch (selectedIndex) {
      case tabHome:
        return buildHomeTab();

      case tabMarket:
        return ShopPage(refreshToken: marketRefreshToken);

      case tabFamily:
        return buildFamilyContent();

      case tabMap:
        if (!hasFamily) {
          return buildFamilyRequiredPage(
            message: 'เข้าร่วมกลุ่มก่อนเพื่อดูตำแหน่งของสมาชิก',
          );
        }

        return const MapPage();

      case tabActivity:
        return const ActivityPage();

      default:
        return buildNoFamily();
    }
  }

  // หน้าหลัก: สำหรับคุณ | ล่าสุด | วิดีโอ
  // แถบสลับอยู่กับที่ เลื่อนเฉพาะเนื้อหา (เหมือนแท็บครอบครัว)
  // ยังไม่มีครอบครัว: ดูชุมชนได้ โพสต์ต้องมีครอบครัวก่อน
  Widget buildHomeTab() {
    final bool guest = !hasFamily && !isLoading;

    return Column(
      children: [
        if (guest)
          buildCollapsible(visible: !immersive, child: buildJoinFamilyBanner()),
        buildCollapsible(
          visible: !immersive,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SectionSwitch<CommunityFeedMode>(
              value: homeMode,
              options: const [
                SectionOption(
                  value: CommunityFeedMode.forYou,
                  icon: Icons.auto_awesome_rounded,
                  label: 'สำหรับคุณ',
                ),
                SectionOption(
                  value: CommunityFeedMode.latest,
                  icon: Icons.schedule_rounded,
                  label: 'ล่าสุด',
                ),
                SectionOption(
                  value: CommunityFeedMode.videos,
                  icon: Icons.smart_display_rounded,
                  label: 'วิดีโอ',
                ),
              ],
              onChanged: showHomeMode,
            ),
          ),
        ),
        // แถวกรองหมวด: อยู่กับที่ ไม่เลื่อนตามตอนปัดซ้าย-ขวา
        buildCollapsible(
          visible: !immersive,
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: CategoryFilterStrip(
              selected: homeCategory,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              onChanged: (category) {
                setState(() => homeCategory = category);
              },
            ),
          ),
        ),
        Expanded(
          child: SwipeSections(
            index: homeMode.index,
            onChanged: (index) {
              showHomeMode(CommunityFeedMode.values[index]);
            },
            children: [
              for (final mode in CommunityFeedMode.values)
                buildHomeFeed(mode: mode, guest: guest),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildHomeFeed({required CommunityFeedMode mode, required bool guest}) {
    // วิดีโอ: เต็มจอ ปัดขึ้น-ลงทีละคลิป
    if (mode == CommunityFeedMode.videos) {
      return VideoFeedPage(
        onExit: () => showHomeMode(CommunityFeedMode.latest),
      );
    }

    // พื้นหลังของตัวเอง (ระหว่างปัดไปหน้าวิดีโอ พื้นหลังของจอเป็นสีดำ)
    return ColoredBox(
      color: AppColors.background,
      child: FeedPage(
        key: ValueKey('feed-community-${mode.name}${guest ? '-guest' : ''}'),
        scope: FeedScope.community,
        communityMode: mode,
        onJoinFamily: guest ? goToFamilyTab : null,
        category: homeCategory,
        onCategoryChanged: (category) {
          setState(() => homeCategory = category);
        },
      ),
    );
  }

  // =====================================================
  // NOTIFICATION BUTTON
  // =====================================================

  // ไอคอนแชท + จำนวนข้อความที่ยังไม่อ่าน
  Widget buildChatButton() {
    return ValueListenableBuilder<int>(
      valueListenable: ChatService.unreadCount,
      builder: (context, unread, child) {
        return IconButton(
          tooltip: 'แชท',
          onPressed: openChats,
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.chat_bubble_outline_rounded, size: 24),
              if (unread > 0)
                Positioned(
                  right: -6,
                  top: -5,
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.danger,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      unread > 99 ? '99+' : unread.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> openChats() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ChatListPage()),
    );

    ChatService.refreshUnreadCount();
  }

  Widget buildNotificationButton() {
    return IconButton(
      onPressed: openNotifications,

      tooltip: 'การแจ้งเตือน',

      icon: Stack(
        clipBehavior: Clip.none,

        children: [
          const Icon(Icons.notifications_none_rounded, size: 26),

          if (unreadNotificationCount > 0)
            Positioned(
              right: -6,
              top: -5,

              child: Container(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),

                padding: const EdgeInsets.symmetric(horizontal: 4),

                alignment: Alignment.center,

                decoration: BoxDecoration(
                  color: AppColors.danger,
                  shape: BoxShape.circle,
                ),

                child: Text(
                  unreadNotificationCount > 99
                      ? '99+'
                      : unreadNotificationCount.toString(),

                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // =====================================================
  // แท็บ ชุมชน | ตลาด บนแถบด้านบน
  // =====================================================

  // หน้าหลัก: ชื่อแอปตัวใหญ่ / แท็บอื่น: ชื่อแอป + ชื่อหน้า
  bool get showAppTitle => selectedIndex == tabHome && hasFamily && !isLoading;

  // แท็บที่เลื่อนลงแล้วซ่อนแถบล่าง
  bool get hidesBarOnScroll =>
      selectedIndex == tabHome || selectedIndex == tabMarket;

  // ปุ่ม 🏪 บัญชีผู้ขาย (แสดงเมื่ออยู่หน้าตลาด)
  Future<void> openSellerAccount() async {
    final dynamic changed = await Navigator.of(context)
        .push(MaterialPageRoute(builder: (context) => const MyShopPage()));

    if (changed == true && mounted) {
      setState(() {
        marketRefreshToken++;
      });
    }
  }

  // ปุ่ม 🛒 ตะกร้า (หน้าตลาด)
  Future<void> openCart() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const CartPage()));

    // สั่งซื้อจากตะกร้า → สต็อกสินค้าในตลาดเปลี่ยน
    if (mounted) {
      setState(() {
        marketRefreshToken++;
      });
    }
  }

  // คำสั่งซื้อของฉัน (เมนูบัญชี)
  Future<void> openMyOrders() async {
    final dynamic changed = await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const OrdersPage()),
    );

    // ยกเลิกคำสั่งซื้อ → สต็อกสินค้าในตลาดเปลี่ยน
    if (changed == true && mounted) {
      setState(() {
        marketRefreshToken++;
      });
    }
  }

  // เลื่อนลง → ซ่อนแถบล่าง / เลื่อนขึ้น → แสดง (หน้าหลัก / ตลาด)
  bool handleUserScroll(UserScrollNotification notification) {
    if (!hidesBarOnScroll || notification.metrics.axis != Axis.vertical) {
      return false;
    }

    // แจ้งครั้งเดียวตอนเริ่มลาก (ตอนนั้นยังอยู่บนสุด) จึงดูแค่ทิศทาง
    final ScrollDirection direction = notification.direction;

    final bool atTop =
        notification.metrics.pixels <= notification.metrics.minScrollExtent;

    final bool show =
        direction == ScrollDirection.forward ||
        (direction == ScrollDirection.idle && atTop);

    if (direction == ScrollDirection.reverse && bottomBarVisible) {
      setState(() => bottomBarVisible = false);
    } else if (show && !bottomBarVisible) {
      setState(() => bottomBarVisible = true);
    }

    return false;
  }

  // =====================================================
  // MAIN
  // =====================================================

  // หน้าวิดีโอเต็มจอ: แถบด้านบนเลื่อนหายขึ้นไป แถบล่างเลื่อนหายลงไป
  bool get immersive =>
      selectedIndex == tabHome && homeMode == CommunityFeedMode.videos;

  void showHomeMode(CommunityFeedMode mode) {
    setState(() {
      homeMode = mode;
      bottomBarVisible = true;
    });
  }

  // ย่อความสูงจนเหลือ 0 = เลื่อนหายขึ้นไปด้านบน
  Widget buildCollapsible({required bool visible, required Widget child}) {
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: visible ? 1 : 0),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        builder: (context, factor, child) {
          return Align(
            alignment: Alignment.bottomCenter,
            heightFactor: factor,
            child: child,
          );
        },
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool showBottomBar =
        (bottomBarVisible || !hidesBarOnScroll) && !immersive;

    // หน้าวิดีโอ: กดย้อนกลับ = กลับไปแท็บ "ล่าสุด"
    return PopScope(
      canPop: !immersive,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && immersive) showHomeMode(CommunityFeedMode.latest);
      },
      child: buildScaffold(showBottomBar),
    );
  }

  Widget buildScaffold(bool showBottomBar) {
    return Scaffold(
      key: scaffoldKey,

      // หน้าวิดีโอ: ขอบล่างใต้แถบนำทางของมือถือเป็นสีดำ
      backgroundColor: immersive ? Colors.black : null,

      // เปิดจากรูปโปรไฟล์เท่านั้น (ปัดขอบจอจะไปชนกับการเลื่อนแผนที่)
      drawerEnableOpenDragGesture: false,

      drawer: AccountDrawer(
        profile: myProfile,
        fallbackName: widget.userName,
        unreadNotifications: unreadNotificationCount,
        ordersToPay: ordersToPay,
        onSelected: handleAccountMenu,
      ),

      // แถบด้านบนอยู่ในเนื้อหา เพื่อเลื่อนหายได้ในหน้าวิดีโอ
      body: Column(
        children: [
          buildCollapsible(visible: !immersive, child: buildAppBar()),
          Expanded(
            // แถบด้านบนจัดระยะใต้แถบสถานะไว้แล้ว (เหมือน Scaffold.appBar)
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: NotificationListener<UserScrollNotification>(
                onNotification: handleUserScroll,
                child: getCurrentPage(),
              ),
            ),
          ),
        ],
      ),

      bottomNavigationBar: buildBottomBar(showBottomBar),
    );
  }

  AppBar buildAppBar() {
    return AppBar(
      toolbarHeight: 64,

      // มุมซ้ายบน: รูปโปรไฟล์ → เมนูบัญชี
      leadingWidth: 64,
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: buildAccountButton(),
      ),

      titleSpacing: 8,

      // หน้าหลัก: ชื่อแอป (แท็บอยู่ด้านล่าง) / หน้าอื่น: ชื่อแอป + ชื่อหน้า
      title: showAppTitle
          ? Text(
              AppInfo.name,
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppInfo.name,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),

                const SizedBox(height: 1),

                Text(
                  getPageTitle(),
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),


      actions: [
        if (selectedIndex == tabMarket) ...[
          // ตะกร้า (คำสั่งซื้อของฉัน อยู่ในหน้าตะกร้าและเมนูบัญชี)
          ValueListenableBuilder<int>(
            valueListenable: CartService.cartCount,
            builder: (context, count, child) => IconButton(
              tooltip: 'ตะกร้าสินค้า',
              onPressed: openCart,
              icon: Badge(
                isLabelVisible: count > 0,
                label: Text(count > 99 ? '99+' : '$count'),
                backgroundColor: marketColor,
                child: const Icon(Icons.shopping_cart_outlined, size: 25),
              ),
            ),
          ),
          IconButton(
            tooltip: 'บัญชีผู้ขาย',
            onPressed: openSellerAccount,
            icon: const Icon(Icons.storefront_outlined, size: 26),
          ),
        ],

        // ค้นหาโพสต์และผู้ใช้ในชุมชน (หน้าหลัก)
        if (selectedIndex == tabHome)
          IconButton(
            tooltip: 'ค้นหา',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
            icon: const Icon(Icons.search_rounded, size: 26),
          ),

        // แชทใช้ได้เมื่อมีครอบครัวแล้ว
        // แชทกับคนในกลุ่ม และกับร้านที่ทักไว้ (ไม่มีกลุ่มก็คุยกับร้านได้)
        buildChatButton(),

        buildNotificationButton(),

        const SizedBox(width: 8),
      ],
    );
  }

  // =====================================================
  // แถบล่างแบบลอย โค้งมน
  // =====================================================

  static const List<_NavItem> navItems = [
    _NavItem(Icons.home_outlined, Icons.home_rounded, 'หน้าหลัก'),
    _NavItem(
      Icons.shopping_basket_outlined,
      Icons.shopping_basket_rounded,
      'ร้านค้า',
    ),
    _NavItem(Icons.groups_outlined, Icons.groups_rounded, 'กลุ่มสมาชิก'),
    _NavItem(Icons.location_on_outlined, Icons.location_on_rounded, 'ตำแหน่ง'),
    _NavItem(Icons.event_note_outlined, Icons.event_note_rounded, 'กิจกรรม'),
  ];

  void selectTab(int index) {
    setState(() {
      selectedIndex = index;
      bottomBarVisible = true;
    });

    loadUnreadNotificationCount();

    // เปิดแท็บร้านค้า → ตัวเลขบนไอคอนตะกร้า
    if (index == tabMarket) CartService.refreshCount();

    if (index != tabActivity) {
      loadFamily(showLoading: false);
    }
  }

  // ซ่อนแถบด้วยการย่อความสูงลงจนเหลือ 0 (เนื้อหาด้านบนขยายลงมาแทน)
  Widget buildBottomBar(bool visible) {
    return SafeArea(
      top: false,
      child: ClipRect(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: visible ? 1 : 0),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, factor, child) {
            return Align(
              alignment: Alignment.topCenter,
              heightFactor: factor,
              child: child,
            );
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
            child: Container(
              height: 66,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.navy.withValues(alpha: 0.10),
                    blurRadius: 26,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: [
                  for (int i = 0; i < navItems.length; i++)
                    Expanded(child: buildNavItem(i)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildNavItem(int index) {
    final _NavItem item = navItems[index];

    final bool selected = selectedIndex == index;

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => selectTab(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.13)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Icon(
                selected ? item.selectedIcon : item.icon,
                size: 23,
                color: selected ? AppColors.primary : AppColors.muted,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              item.label,
              maxLines: 1,
              style: TextStyle(
                color: selected ? AppColors.navy : AppColors.muted,
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // FAMILY REQUIRED
  // =====================================================

  // แถบชวนสร้าง/เข้าร่วมครอบครัว (หน้าหลักตอนยังไม่มีครอบครัว)
  Widget buildJoinFamilyBanner() {
    final int invites = invitationList('received').length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Material(
        color: AppColors.softPrimary,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: goToFamilyTab,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(
              children: [
                Icon(
                  invites > 0
                      ? Icons.mark_email_unread_rounded
                      : Icons.groups_rounded,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    invites > 0
                        ? 'คุณได้รับคำเชิญเข้ากลุ่ม $invites รายการ'
                        : 'สร้างหรือเข้าร่วมกลุ่ม เพื่อโพสต์ แชท และแชร์ตำแหน่ง',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AppColors.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildFamilyRequiredPage({required String message}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),

        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,

          children: [
            Container(
              width: 100,
              height: 100,

              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.09),

                shape: BoxShape.circle,
              ),

              child: Icon(
                Icons.groups_rounded,
                size: 46,
                color: AppColors.primary,
              ),
            ),

            const SizedBox(height: 24),

            Text(
              'เข้าร่วมกลุ่มก่อน',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 23,
                fontWeight: FontWeight.w800,
              ),
            ),

            const SizedBox(height: 10),

            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 15,
                height: 1.5,
              ),
            ),

            const SizedBox(height: 25),

            SizedBox(
              width: 230,

              child: ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    selectedIndex = tabFamily;
                  });

                  loadFamily();
                },

                icon: const Icon(Icons.arrow_forward_rounded),

                label: const Text('ไปหน้ากลุ่มสมาชิก'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // FAMILY CONTENT
  // =====================================================

  Widget buildFamilyContent() {
    if (!hasFamily) {
      return buildNoFamily();
    }

    return buildFamilyTab();
  }

  // =====================================================
  // ครอบครัว: โพสต์ | สมาชิก (ปัดซ้าย-ขวาสลับได้)
  // =====================================================

  Widget buildFamilyTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SectionSwitch<FamilySection>(
            value: familySection,
            options: const [
              SectionOption(
                value: FamilySection.posts,
                icon: Icons.forum_rounded,
                label: 'โพสต์',
              ),
              SectionOption(
                value: FamilySection.members,
                icon: Icons.groups_rounded,
                label: 'สมาชิก',
              ),
            ],
            onChanged: (value) {
              setState(() {
                familySection = value;
              });
            },
          ),
        ),
        Expanded(
          child: SwipeSections(
            index: familySection == FamilySection.members ? 1 : 0,
            onChanged: (index) {
              setState(() {
                familySection = index == 1
                    ? FamilySection.members
                    : FamilySection.posts;
              });
            },
            children: [
              const FeedPage(
                key: ValueKey('feed-family'),
                scope: FeedScope.family,
              ),
              buildFamily(),
            ],
          ),
        ),
      ],
    );
  }

  // =====================================================
  // NO FAMILY
  // =====================================================

  Widget buildNoFamily() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 35),

      children: [
        // ===============================================
        // HERO
        // ===============================================

        Container(
          padding: const EdgeInsets.all(24),

          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF182458), Color(0xFF4F59E5)],
            ),

            borderRadius: BorderRadius.circular(28),

            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.20),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
            ],
          ),

          child: Stack(
            children: [
              Positioned(
                right: -30,
                top: -45,

                child: Container(
                  width: 145,
                  height: 145,

                  decoration: BoxDecoration(
                    shape: BoxShape.circle,

                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),

              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 54,
                    height: 54,

                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),

                      borderRadius: BorderRadius.circular(18),
                    ),

                    child: const Icon(
                      Icons.track_changes_rounded,
                      color: Colors.white,
                      size: 29,
                    ),
                  ),

                  const SizedBox(height: 22),

                  Text(
                    'สวัสดี ${widget.userName}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    'สร้างกลุ่มใหม่ หรือเข้าร่วมกลุ่มของคุณ',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.80),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 26),

        if (invitationList('received').isNotEmpty) ...[
          FamilyInvitationSection(
            title: 'คำเชิญถึงคุณ',
            children: [
              for (final invitation in invitationList('received'))
                InvitationCard(
                  invitation: invitation,
                  incoming: true,
                  busy: invitationBusy.contains(invitation['id']),
                  onAccept: () => respondInvitation(invitation, 'accept'),
                  onDecline: () => respondInvitation(invitation, 'decline'),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        if (invitationList('sent').isNotEmpty) ...[
          FamilyInvitationSection(
            title: 'คำขอเข้ากลุ่มของคุณ',
            children: [
              for (final invitation in invitationList('sent'))
                PendingInvitationTile(
                  invitation: invitation,
                  busy: invitationBusy.contains(invitation['id']),
                  onCancel: () => cancelInvitation(invitation),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        Text(
          'เริ่มต้นกลุ่มของคุณ',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),

        const SizedBox(height: 6),

        Text(
          'เลือกวิธีที่เหมาะกับคุณ',
          style: TextStyle(color: AppColors.muted),
        ),

        const SizedBox(height: 16),

        // ===============================================
        // CREATE
        // ===============================================
        Container(
          padding: const EdgeInsets.all(20),

          decoration: BoxDecoration(
            color: AppColors.surface,

            borderRadius: BorderRadius.circular(24),

            border: AppDecorations.cardBorder,
            boxShadow: AppDecorations.cardShadow,
          ),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,

                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.10),

                      borderRadius: BorderRadius.circular(15),
                    ),

                    child: Icon(
                      Icons.add_home_rounded,
                      color: AppColors.primary,
                    ),
                  ),

                  const SizedBox(width: 13),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'สร้างกลุ่ม',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),

                        SizedBox(height: 3),

                        Text(
                          'คุณจะเป็นเจ้าของกลุ่ม',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              TextField(
                controller: familyNameController,

                decoration: const InputDecoration(
                  labelText: 'ชื่อกลุ่ม',
                  hintText: 'เช่น บ้านของเรา',
                  prefixIcon: Icon(Icons.favorite_outline_rounded),
                ),
              ),

              const SizedBox(height: 14),

              ElevatedButton.icon(
                onPressed: isWorking ? null : createFamily,

                icon: const Icon(Icons.add_rounded),

                label: Text(isWorking ? 'กำลังสร้าง...' : 'สร้างกลุ่ม'),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // ===============================================
        // JOIN
        // ===============================================
        Container(
          padding: const EdgeInsets.all(20),

          decoration: BoxDecoration(
            color: AppColors.surface,

            borderRadius: BorderRadius.circular(24),

            border: AppDecorations.cardBorder,
            boxShadow: AppDecorations.cardShadow,
          ),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,

                    decoration: BoxDecoration(
                      color: AppColors.sky.withValues(alpha: 0.13),

                      borderRadius: BorderRadius.circular(15),
                    ),

                    child: Icon(
                      Icons.group_add_rounded,
                      color: AppColors.sky,
                    ),
                  ),

                  const SizedBox(width: 13),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'เข้าร่วมกลุ่ม',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),

                        SizedBox(height: 3),

                        Text(
                          'ใช้ Invite Code จาก Owner',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 18),

              TextField(
                controller: inviteCodeController,

                textCapitalization: TextCapitalization.characters,

                decoration: const InputDecoration(
                  labelText: 'Invite Code',
                  hintText: 'XXXXXXXX',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
              ),

              const SizedBox(height: 14),

              OutlinedButton.icon(
                onPressed: isWorking ? null : joinFamily,

                icon: const Icon(Icons.login_rounded),

                label: const Text('เข้าร่วมกลุ่ม'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =====================================================
  // FAMILY PAGE
  // =====================================================

  Widget buildFamily() {
    final family = familyData?['family'];

    if (family == null) {
      return const Center(child: Text('ไม่พบข้อมูลกลุ่ม'));
    }

    final List members = family['members'] as List? ?? [];

    final String myRole = familyData?['role']?.toString() ?? 'member';

    final bool isOwner = myRole == 'owner';

    final int ownerId = (family['owner_id'] as num).toInt();

    final String familyName = family['name']?.toString() ?? 'กลุ่ม';

    final String inviteCode = family['invite_code']?.toString() ?? '';

    return RefreshIndicator(
      color: AppColors.primary,

      onRefresh: () => loadFamily(showLoading: false),

      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),

        padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),

        children: [
          // ===============================================
          // FAMILY HERO CARD
          // ===============================================

          Container(
            padding: const EdgeInsets.all(23),

            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF172554),
                  Color(0xFF4650D8),
                  Color(0xFF656BFF),
                ],
              ),

              borderRadius: BorderRadius.circular(30),

              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.22),
                  blurRadius: 30,
                  offset: const Offset(0, 13),
                ),
              ],
            ),

            child: Stack(
              children: [
                Positioned(
                  right: -45,
                  top: -70,

                  child: Container(
                    width: 190,
                    height: 190,

                    decoration: BoxDecoration(
                      shape: BoxShape.circle,

                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),

                Positioned(
                  right: 20,
                  bottom: -55,

                  child: Container(
                    width: 120,
                    height: 120,

                    decoration: BoxDecoration(
                      shape: BoxShape.circle,

                      border: Border.all(
                        color: AppColors.sky.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                ),

                Positioned(
                  right: 42,
                  top: 29,

                  child: Container(
                    width: 10,
                    height: 10,

                    decoration: BoxDecoration(
                      color: AppColors.sky,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),

                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 6,
                          ),

                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.13),

                            borderRadius: BorderRadius.circular(999),
                          ),

                          child: const Text(
                            'กลุ่มของฉัน',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),

                        const Spacer(),

                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 6,
                          ),

                          decoration: BoxDecoration(
                            color: isOwner
                                ? AppColors.warm.withValues(alpha: 0.18)
                                : Colors.white.withValues(alpha: 0.12),

                            borderRadius: BorderRadius.circular(999),
                          ),

                          child: Row(
                            children: [
                              Icon(
                                isOwner
                                    ? Icons.workspace_premium_rounded
                                    : Icons.person_rounded,
                                color: isOwner ? AppColors.warm : Colors.white,
                                size: 14,
                              ),

                              const SizedBox(width: 5),

                              Text(
                                isOwner ? 'เจ้าของกลุ่ม' : 'สมาชิก',
                                style: TextStyle(
                                  color: isOwner
                                      ? AppColors.warm
                                      : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                familyName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 29,
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                ),
                              ),

                              const SizedBox(height: 8),

                              Text(
                                'สมาชิก ${members.length} คน',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.76),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),

                        if (isOwner)
                          IconButton.filledTonal(
                            onPressed: editFamilyName,

                            tooltip: 'แก้ไขชื่อ',

                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.13,
                              ),
                              foregroundColor: Colors.white,
                            ),

                            icon: const Icon(Icons.edit_rounded, size: 19),
                          ),
                      ],
                    ),

                    const SizedBox(height: 25),

                    Container(
                      padding: const EdgeInsets.all(14),

                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),

                        borderRadius: BorderRadius.circular(18),

                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                        ),
                      ),

                      child: Row(
                        children: [
                          Icon(
                            Icons.key_rounded,
                            color: AppColors.warm,
                            size: 20,
                          ),

                          const SizedBox(width: 10),

                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'รหัสเชิญ',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.64),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  ),
                                ),

                                const SizedBox(height: 2),

                                Text(
                                  inviteCode,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          IconButton(
                            onPressed: () {
                              copyInviteCode(inviteCode);
                            },

                            tooltip: 'คัดลอก',

                            icon: const Icon(
                              Icons.content_copy_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (isOwner) ...[
                      const SizedBox(height: 12),

                      InkWell(
                        borderRadius: BorderRadius.circular(14),

                        onTap: regenerateInviteCode,

                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),

                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.refresh_rounded,
                                color: Colors.white,
                                size: 17,
                              ),

                              SizedBox(width: 7),

                              Text(
                                'สร้างรหัสเชิญใหม่',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ===============================================
          // ชวนเข้าครอบครัว
          // ===============================================
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: inviteByEmail,
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 19),
                  label: const Text('ชวนด้วยอีเมล'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: inviteCode.isEmpty
                      ? null
                      : () => shareInviteCode(familyName, inviteCode),
                  icon: const Icon(Icons.ios_share_rounded, size: 19),
                  label: const Text('ส่งรหัสเชิญ'),
                ),
              ),
            ],
          ),

          if (isOwner && invitationList('requests').isNotEmpty) ...[
            const SizedBox(height: 22),
            FamilyInvitationSection(
              title: 'คำขอเข้าร่วม (${invitationList('requests').length})',
              subtitle: 'คนที่ขอเข้ากลุ่มจากหน้าโปรไฟล์ในชุมชน',
              children: [
                for (final invitation in invitationList('requests'))
                  InvitationCard(
                    invitation: invitation,
                    incoming: false,
                    busy: invitationBusy.contains(invitation['id']),
                    onAccept: () => respondInvitation(invitation, 'accept'),
                    onDecline: () => respondInvitation(invitation, 'decline'),
                  ),
              ],
            ),
          ],

          if (invitationList('invited').isNotEmpty) ...[
            const SizedBox(height: 22),
            FamilyInvitationSection(
              title: 'รอตอบรับคำเชิญ',
              children: [
                for (final invitation in invitationList('invited'))
                  PendingInvitationTile(
                    invitation: invitation,
                    busy: invitationBusy.contains(invitation['id']),
                    onCancel: () => cancelInvitation(invitation),
                  ),
              ],
            ),
          ],

          const SizedBox(height: 30),

          // ===============================================
          // MEMBER HEADER
          // ===============================================
          Row(
            children: [
              Text(
                'สมาชิกในกลุ่ม',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),

              const Spacer(),

              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),

                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.09),

                  borderRadius: BorderRadius.circular(999),
                ),

                child: Text(
                  '${members.length} คน',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 6),

          Text(
            'คนที่อยู่ในกลุ่มเดียวกับคุณ',
            style: TextStyle(color: AppColors.muted, fontSize: 13),
          ),

          const SizedBox(height: 14),

          // ===============================================
          // MEMBERS
          // ===============================================
          ...members.map((dynamic member) {
            final int memberId = (member['id'] as num).toInt();

            final bool memberIsOwner = memberId == ownerId;

            final String memberName = member['name']?.toString() ?? 'สมาชิก';

            // กดการ์ด → หน้าโปรไฟล์ของสมาชิก
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),

              child: Material(
                color: AppColors.surface,

                borderRadius: BorderRadius.circular(20),

                child: InkWell(
                  borderRadius: BorderRadius.circular(20),

                  onTap: () => openUserProfile(memberId, memberName),

                  child: Container(
              padding: const EdgeInsets.fromLTRB(15, 13, 10, 13),

              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),

                border: AppDecorations.cardBorder,
                boxShadow: AppDecorations.cardShadow,
              ),

              child: Row(
                children: [
                  buildMemberAvatar(
                    name: memberName,
                    isOwner: memberIsOwner,
                    imageUrl: getMemberProfileImage(member),
                  ),

                  const SizedBox(width: 13),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                memberName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppColors.navy,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),

                            if (memberIsOwner) ...[
                              const SizedBox(width: 7),

                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),

                                decoration: BoxDecoration(
                                  color: AppColors.warm.withValues(alpha: 0.14),

                                  borderRadius: BorderRadius.circular(999),
                                ),

                                child: const Text(
                                  'เจ้าของ',
                                  style: TextStyle(
                                    color: Color(0xFFCF762F),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),

                        const SizedBox(height: 3),

                        // ไม่แสดงอีเมลของสมาชิก (เซิร์ฟเวอร์ไม่ส่งมาแล้ว)
                        Text(
                          'แตะเพื่อดูโปรไฟล์',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (isOwner && !memberIsOwner)
                    PopupMenuButton<String>(
                      tooltip: 'จัดการสมาชิก',

                      onSelected: (value) {
                        if (value == 'owner') {
                          transferFamilyOwner(memberId, memberName);
                        }

                        if (value == 'remove') {
                          removeFamilyMember(memberId, memberName);
                        }
                      },

                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'owner',
                          child: Row(
                            children: [
                              Icon(
                                Icons.workspace_premium_rounded,
                                color: AppColors.warm,
                              ),

                              SizedBox(width: 10),

                              Text('ตั้งเป็น Owner'),
                            ],
                          ),
                        ),

                        PopupMenuItem(
                          value: 'remove',
                          child: Row(
                            children: [
                              Icon(
                                Icons.person_remove_rounded,
                                color: AppColors.danger,
                              ),

                              SizedBox(width: 10),

                              Text('นำออกจากกลุ่ม'),
                            ],
                          ),
                        ),
                      ],
                    )
                  else
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.muted,
                      ),
                    ),
                ],
              ),
                  ),
                ),
              ),
            );
          }),

          const SizedBox(height: 22),

          // ===============================================
          // MEMBER LEAVE
          // ===============================================
          if (!isOwner)
            Container(
              padding: const EdgeInsets.all(18),

              decoration: BoxDecoration(
                color: AppColors.surface,

                borderRadius: BorderRadius.circular(22),

                border: AppDecorations.cardBorder,
                boxShadow: AppDecorations.cardShadow,
              ),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'การเป็นสมาชิก',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                  const SizedBox(height: 5),

                  Text(
                    'คุณสามารถออกจากกลุ่มนี้ได้ทุกเมื่อ',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),

                  const SizedBox(height: 15),

                  OutlinedButton.icon(
                    onPressed: leaveFamily,

                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,

                      side: BorderSide(
                        color: AppColors.danger.withValues(alpha: 0.35),
                      ),
                    ),

                    icon: const Icon(Icons.logout_rounded),

                    label: const Text('ออกจากกลุ่ม'),
                  ),
                ],
              ),
            ),

          // ===============================================
          // OWNER DANGER ZONE
          // ===============================================
          if (isOwner) ...[
            Container(
              padding: const EdgeInsets.all(18),

              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.045),

                borderRadius: BorderRadius.circular(22),

                border: Border.all(
                  color: AppColors.danger.withValues(alpha: 0.18),
                ),
              ),

              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: AppColors.danger),

                      SizedBox(width: 9),

                      Text(
                        'Owner Zone',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 7),

                  Text(
                    'คุณเป็นผู้ดูแลกลุ่มนี้ '
                    'หากต้องการออก กรุณาโอน Owner ให้สมาชิกคนอื่นก่อน',
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),

                  const SizedBox(height: 16),

                  OutlinedButton.icon(
                    onPressed: deleteCurrentFamily,

                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,

                      side: BorderSide(
                        color: AppColors.danger.withValues(alpha: 0.35),
                      ),
                    ),

                    icon: const Icon(Icons.delete_outline_rounded),

                    label: const Text('ลบกลุ่ม'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  // =====================================================
  // DISPOSE
  // =====================================================

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    FamilyService.changes.removeListener(onFamilyChanged);

    // ออกจากระบบ / ลบบัญชี → หยุดส่งตำแหน่ง และล้างค่าตั้งค่าของบัญชีนี้
    // (บัญชีถัดไปบนเครื่องนี้ต้องเปิดแชร์ตอนปิดแอปเอง)
    LocationTracker.stop();
    BackgroundLocation.turnOff();
    SettingsService.locationSharing.value = null;

    pushOpenedSubscription?.cancel();
    pushForegroundSubscription?.cancel();
    pushSnackBar?.close();

    familyNameController.dispose();
    inviteCodeController.dispose();

    super.dispose();
  }
}

class _NavItem {
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  const _NavItem(this.icon, this.selectedIcon, this.label);
}
