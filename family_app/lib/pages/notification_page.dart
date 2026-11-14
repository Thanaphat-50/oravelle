import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../theme/themed_widgets.dart';
import '../widgets/featured_shops_banner.dart' show featuredColor;
import 'market_product_page.dart';
import 'market_shop_page.dart';
import 'my_shop_page.dart';
import 'order_page.dart';
import 'post_detail_page.dart';
import 'support_ticket_page.dart';
import 'activity_detail_page.dart';

// แท็บในหน้าหลักที่ต้องเปิดหลังกดการแจ้งเตือน
// (หน้าแจ้งเตือนปิดตัวเองแล้วส่งค่านี้กลับไป)
enum NotificationTarget { activities, familyMembers }

// =======================================================
// การแจ้งเตือน
// - กดแล้วไปที่เรื่องนั้นเลย (โพสต์ กิจกรรม ร้าน สมาชิก)
// - ปัดซ้าย/ขวาเพื่อลบ · เมนู: อ่านทั้งหมด / ลบที่อ่านแล้ว
// - เลื่อนลงเพื่อโหลดเพิ่ม
// =======================================================

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  final ScrollController scrollController = ScrollController();

  List<Map<String, dynamic>> items = [];

  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMore = false;
  String? loadError;

  bool get hasUnread => items.any((item) => !isRead(item));

  bool get hasRead => items.any(isRead);

  @override
  void initState() {
    super.initState();
    scrollController.addListener(onScroll);
    loadNotifications();
  }

  // =====================================================
  // โหลดข้อมูล
  // =====================================================

  Future<void> loadNotifications({bool loadMore = false}) async {
    if (loadMore && (isLoading || isLoadingMore || !hasMore)) return;

    // โหลดเพิ่ม = รายการที่เก่ากว่ารายการเก่าสุดที่มีอยู่
    // (ไม่ใช้เลขหน้า เพราะการลบระหว่างเลื่อนจะทำให้ข้ามบางรายการ)
    final Iterable<int> loadedIds = items.map(idOf).whereType<int>();

    final int? beforeId = loadMore && loadedIds.isNotEmpty
        ? loadedIds.reduce((a, b) => a < b ? a : b)
        : null;

    setState(() {
      if (loadMore) {
        isLoadingMore = true;
      } else {
        loadError = null;
      }
    });

    try {
      final result = await NotificationService.getNotifications(
        beforeId: beforeId,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        final dynamic raw = result['notifications'];

        final List<Map<String, dynamic>> loaded = raw is List
            ? raw
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item))
                  .toList()
            : [];

        setState(() {
          if (loadMore) {
            final ids = items.map((item) => item['id']).toSet();

            items.addAll(loaded.where((item) => !ids.contains(item['id'])));
          } else {
            items = loaded;
          }

          hasMore = result['has_more'] == true;
        });
      } else {
        setLoadError(
          result['message']?.toString() ?? 'โหลดการแจ้งเตือนไม่สำเร็จ',
        );
      }
    } catch (e) {
      if (mounted) setLoadError(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
          isLoadingMore = false;
        });
      }
    }
  }

  void setLoadError(String message) {
    if (items.isEmpty) {
      setState(() => loadError = message);
    } else {
      showMessage(message);
    }
  }

  void onScroll() {
    if (!scrollController.hasClients) return;

    final position = scrollController.position;

    if (position.pixels >= position.maxScrollExtent - 300) {
      loadNotifications(loadMore: true);
    }
  }

  // =====================================================
  // อ่าน / ลบ
  // =====================================================

  // ทำเครื่องหมายว่าอ่านแล้วบนจอทันที แล้วค่อยส่งไป Server
  void markRead(Map<String, dynamic> item) {
    final int? id = idOf(item);

    if (id == null || isRead(item)) return;

    setState(() {
      item['is_read'] = true;
    });

    NotificationService.markAsRead(id).catchError((_) {
      return <String, dynamic>{};
    });
  }

  Future<void> markAllRead() async {
    try {
      final result = await NotificationService.markAllAsRead();

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          for (final item in items) {
            item['is_read'] = true;
          }
        });
      }

      showMessage(result['message']?.toString() ?? 'อ่านทั้งหมดแล้ว');
    } catch (e) {
      if (mounted) showMessage(e.toString());
    }
  }

  Future<void> clearRead() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('ลบการแจ้งเตือนที่อ่านแล้ว?'),
          content: const Text('การแจ้งเตือนที่ยังไม่ได้อ่านจะไม่ถูกลบ'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ยกเลิก'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('ลบ'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    try {
      final result = await NotificationService.clearRead();

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          items.removeWhere(isRead);
        });

        // ลบจนหมดหน้าแล้ว แต่ Server ยังมีอีก → โหลดใหม่
        if (items.isEmpty && hasMore) {
          setState(() => isLoading = true);
          await loadNotifications();
        }
      }

      showMessage(result['message']?.toString() ?? 'ลบแล้ว');
    } catch (e) {
      if (mounted) showMessage(e.toString());
    }
  }

  // ปัดเพื่อลบ: เอาออกจากจอทันที ถ้าลบไม่สำเร็จค่อยใส่คืน
  Future<void> deleteItem(Map<String, dynamic> item) async {
    final int? id = idOf(item);

    if (id == null) return;

    final int index = items.indexOf(item);

    setState(() {
      items.remove(item);
    });

    try {
      final result = await NotificationService.deleteNotification(id);

      if (!mounted) return;

      if (result['status'] != true) {
        throw Exception(result['message'] ?? 'ลบไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      setState(() {
        items.insert(index.clamp(0, items.length), item);
      });

      showMessage('ลบการแจ้งเตือนไม่สำเร็จ');
    }
  }

  // =====================================================
  // กดการแจ้งเตือน → ไปที่เรื่องนั้น
  // =====================================================

  Future<void> openItem(Map<String, dynamic> item) async {
    markRead(item);

    final String type = item['type']?.toString() ?? '';

    final dynamic data = item['data'];

    int? dataId(String key) {
      if (data is! Map) return null;

      final dynamic value = data[key];

      return value is num ? value.toInt() : int.tryParse('${value ?? ''}');
    }

    switch (type) {
      case 'new_post':
      case 'new_comment':
        final int? postId = dataId('post_id');

        if (postId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => PostDetailPage(postId: postId),
            ),
          );
          return;
        }

      // สถานะร้าน / ผลตรวจสลิปช่องแนะนำ → ร้านของฉัน
      case 'shop_status':
      case 'promotion_status':
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (context) => const MyShopPage()));
        return;

      // ผู้ดูแล: ระบบตรวจพบสินค้า/ร้านที่อาจผิดกฎหมาย → เปิดดูสินค้าหรือร้านนั้น
      case 'market_flag':
      case 'market_report':
        final int? productId = dataId('product_id');
        final int? flaggedShopId = dataId('shop_id');

        if (productId != null || flaggedShopId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => productId != null
                  ? MarketProductPage(productId: productId)
                  : MarketShopPage(shopId: flaggedShopId!),
            ),
          );
          return;
        }

      // ทีมงานตอบ / เปลี่ยนสถานะคำร้อง → หน้าคำร้อง (เซิร์ฟเวอร์ตรวจว่าเป็นของเรา)
      case 'support_ticket':
        final int? ticketId = dataId('ticket_id');

        if (ticketId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => SupportTicketPage(ticketId: ticketId),
            ),
          );
          return;
        }

      // คำสั่งซื้อเปลี่ยนสถานะ → หน้าคำสั่งซื้อ (ผู้ซื้อ / ร้าน)
      case 'order_status':
        final int? orderId = dataId('order_id');

        if (orderId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => OrderPage(orderId: orderId),
            ),
          );
          return;
        }

      // รีวิวร้านใหม่ → หน้าร้าน (เห็นรีวิว)
      case 'shop_review':
        final int? shopId = dataId('shop_id');

        if (shopId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => MarketShopPage(shopId: shopId),
            ),
          );
          return;
        }

      // เตือนกิจกรรม → หน้ารายละเอียด (ถูกลบ / ไม่มีสิทธิ์แล้ว → ข้อความแจ้ง)
      case 'activity_reminder':
        final int? activityId = dataId('activity_id');

        if (activityId != null) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ActivityDetailPage(activityId: activityId),
            ),
          );
          return;
        }

      case 'new_activity':
        Navigator.of(context).pop(NotificationTarget.activities);
        return;

      case 'member_joined':
      case 'family_invite':
      case 'family_request':
      case 'family_request_accepted':
        Navigator.of(context).pop(NotificationTarget.familyMembers);
        return;
    }

    if (!mounted) return;

    // ประเภทอื่น / ไม่มีข้อมูลปลายทาง → แสดงข้อความเต็ม
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(item['title']?.toString() ?? 'การแจ้งเตือน'),
          content: Text(item['message']?.toString() ?? ''),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('ปิด'),
            ),
          ],
        );
      },
    );
  }

  // =====================================================
  // HELPERS
  // =====================================================

  int? idOf(Map<String, dynamic> item) {
    final dynamic id = item['id'];

    return id is num ? id.toInt() : null;
  }

  bool isRead(Map<String, dynamic> item) {
    final dynamic value = item['is_read'];

    return value == true || value == 1;
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String formatTimeAgo(dynamic value) {
    final DateTime? date = DateTime.tryParse('${value ?? ''}')?.toLocal();

    if (date == null) return '';

    final Duration difference = DateTime.now().difference(date);

    if (difference.isNegative || difference.inMinutes < 1) {
      return 'เมื่อสักครู่';
    }

    if (difference.inMinutes < 60) {
      return '${difference.inMinutes} นาทีที่แล้ว';
    }

    if (difference.inHours < 24) {
      return '${difference.inHours} ชั่วโมงที่แล้ว';
    }

    if (difference.inDays == 1) return 'เมื่อวาน';

    if (difference.inDays < 7) return '${difference.inDays} วันที่แล้ว';

    return '${date.day}/${date.month}/${date.year}';
  }

  _NotificationStyle styleOf(String type) {
    switch (type) {
      case 'member_joined':
      case 'family_request_accepted':
        return _NotificationStyle(
          icon: Icons.person_add_alt_1_rounded,
          color: AppColors.sky,
        );
      case 'family_invite':
      case 'family_request':
        return _NotificationStyle(
          icon: Icons.mark_email_unread_rounded,
          color: AppColors.primary,
        );
      case 'new_post':
        return _NotificationStyle(
          icon: Icons.dynamic_feed_rounded,
          color: AppColors.primary,
        );
      case 'new_comment':
        return _NotificationStyle(
          icon: Icons.chat_bubble_rounded,
          color: AppColors.warm,
        );
      case 'new_activity':
        return _NotificationStyle(
          icon: Icons.event_available_rounded,
          color: AppColors.success,
        );
      case 'activity_reminder':
        return _NotificationStyle(
          icon: Icons.alarm_rounded,
          color: AppColors.warm,
        );
      case 'shop_status':
        return _NotificationStyle(
          icon: Icons.storefront_rounded,
          color: AppColors.market,
        );
      case 'market_flag':
        return _NotificationStyle(
          icon: Icons.gpp_maybe_rounded,
          color: AppColors.danger,
        );
      case 'market_report':
        return _NotificationStyle(
          icon: Icons.flag_rounded,
          color: AppColors.danger,
        );
      case 'order_status':
        return _NotificationStyle(
          icon: Icons.receipt_long_rounded,
          color: AppColors.market,
        );
      case 'support_ticket':
        return _NotificationStyle(
          icon: Icons.support_agent_rounded,
          color: AppColors.sky,
        );
      case 'promotion_status':
      case 'shop_review':
        return const _NotificationStyle(
          icon: Icons.star_rounded,
          color: featuredColor,
        );
      default:
        return _NotificationStyle(
          icon: Icons.notifications_rounded,
          color: AppColors.primary,
        );
    }
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildItem(Map<String, dynamic> item) {
    final bool read = isRead(item);

    final _NotificationStyle style = styleOf(item['type']?.toString() ?? '');

    final Widget deleteBackground = Container(
      color: AppColors.danger,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: Alignment.centerRight,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline_rounded, color: Colors.white),
          SizedBox(width: 6),
          Text(
            'ลบ',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );

    return Dismissible(
      key: ValueKey('notification-${item['id']}'),
      direction: DismissDirection.endToStart,
      background: deleteBackground,
      onDismissed: (_) => deleteItem(item),
      child: Material(
        color: read
            ? AppColors.surface
            : AppColors.primary.withValues(
                alpha: AppColors.isDark ? 0.12 : 0.05,
              ),
        child: InkWell(
          onTap: () => openItem(item),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: style.color.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(style.icon, color: style.color, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['title']?.toString() ?? 'การแจ้งเตือน',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 14.5,
                          fontWeight: read ? FontWeight.w600 : FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item['message']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.subtle,
                          fontSize: 13.5,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        formatTimeAgo(item['created_at']),
                        style: TextStyle(
                          color: read ? AppColors.muted : AppColors.primary,
                          fontSize: 12,
                          fontWeight: read ? FontWeight.w400 : FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!read)
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(top: 6, left: 8),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildState({
    required IconData icon,
    required String title,
    required String message,
    Widget? action,
    bool art = false,
  }) {
    final Widget symbol = Icon(icon, size: 52, color: AppColors.muted);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 120, 32, 32),
      children: [
        art ? ThemeEmptyArt(fallback: symbol) : symbol,
        const SizedBox(height: 14),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 13.5),
        ),
        if (action != null) ...[
          const SizedBox(height: 16),
          Center(child: action),
        ],
      ],
    );
  }

  Widget buildBody() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (loadError != null && items.isEmpty) {
      return buildState(
        icon: Icons.cloud_off_rounded,
        title: 'โหลดการแจ้งเตือนไม่สำเร็จ',
        message: loadError!,
        action: OutlinedButton(
          onPressed: () {
            setState(() => isLoading = true);
            loadNotifications();
          },
          child: const Text('ลองอีกครั้ง'),
        ),
      );
    }

    if (items.isEmpty) {
      return buildState(
        art: true,
        icon: Icons.notifications_none_rounded,
        title: 'ยังไม่มีการแจ้งเตือน',
        message: 'เมื่อมีโพสต์ ความคิดเห็น หรือกิจกรรมใหม่ จะแจ้งที่นี่',
      );
    }

    return ListView.separated(
      controller: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length + 1,
      separatorBuilder: (context, index) =>
          Divider(height: 1, color: AppColors.border),
      itemBuilder: (context, index) {
        if (index < items.length) return buildItem(items[index]);

        // ท้ายรายการ
        if (isLoadingMore) {
          return const Padding(
            padding: EdgeInsets.all(18),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            hasMore ? '' : 'ปัดซ้ายเพื่อลบการแจ้งเตือน',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('การแจ้งเตือน'),
        actions: [
          if (hasUnread)
            IconButton(
              tooltip: 'อ่านทั้งหมด',
              onPressed: markAllRead,
              icon: const Icon(Icons.done_all_rounded),
            ),
          PopupMenuButton<String>(
            tooltip: 'ตัวเลือก',
            enabled: hasRead,
            onSelected: (value) {
              if (value == 'clear') clearRead();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep_outlined, color: AppColors.danger),
                    SizedBox(width: 10),
                    Text('ลบที่อ่านแล้ว'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => loadNotifications(),
        child: buildBody(),
      ),
    );
  }

  @override
  void dispose() {
    scrollController.dispose();

    super.dispose();
  }
}

class _NotificationStyle {
  final IconData icon;
  final Color color;

  const _NotificationStyle({required this.icon, required this.color});
}
