import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../services/order_service.dart';
import '../theme/app_theme.dart';
import 'order_page.dart';
import 'shop_sales_page.dart';

// =======================================================
// รายการคำสั่งซื้อ
// seller = false → คำสั่งซื้อของฉัน (ที่ฉันซื้อ)
// seller = true  → ออเดอร์ของร้าน (ลูกค้าสั่งจากร้านฉัน)
// =======================================================

class OrdersPage extends StatefulWidget {
  final bool seller;

  // แท็บที่เปิดก่อน (เช่น completed = ประวัติการขาย)
  final String? initialFilter;

  const OrdersPage({super.key, this.seller = false, this.initialFilter});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  // แท็บ (key ส่งเป็น filter ไปเซิร์ฟเวอร์)
  late final List<(String, String)> tabs = widget.seller
      ? [
          ('todo', 'ต้องจัดการ'),
          ('shipping', 'กำลังจัดส่ง'),
          ('completed', 'สำเร็จ'),
          ('cancelled', 'ยกเลิก'),
        ]
      : [
          ('to_pay', 'รอชำระเงิน'),
          ('to_ship', 'รอจัดส่ง'),
          ('shipping', 'กำลังจัดส่ง'),
          ('completed', 'สำเร็จ'),
          ('cancelled', 'ยกเลิก'),
        ];

  // ผู้ซื้อ: จำนวนในแต่ละแท็บ (to_pay / to_ship / shipping)
  Map<String, int> counts = {};

  late String filter = tabs.any((tab) => tab.$1 == widget.initialFilter)
      ? widget.initialFilter!
      : tabs.first.$1;

  final List<Map<String, dynamic>> orders = [];
  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMore = false;
  int page = 1;
  String? loadError;

  // ร้าน: จำนวนออเดอร์ที่ต้องจัดการ
  int todoCount = 0;

  bool changed = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool more = false}) async {
    if (more && (isLoadingMore || !hasMore)) return;

    setState(() {
      if (more) {
        isLoadingMore = true;
      } else {
        isLoading = true;
        loadError = null;
      }
    });

    final int nextPage = more ? page + 1 : 1;

    try {
      final result = await OrderService.getOrders(
        seller: widget.seller,
        filter: filter,
        page: nextPage,
      );

      if (!mounted) return;

      if (result['status'] != true) {
        setState(() {
          loadError =
              result['message']?.toString() ?? 'โหลดคำสั่งซื้อไม่สำเร็จ';
        });
        return;
      }

      final dynamic raw = result['orders'];

      setState(() {
        if (!more) orders.clear();

        if (raw is List) {
          orders.addAll(
            raw.whereType<Map>().map((item) => Map<String, dynamic>.from(item)),
          );
        }

        page = nextPage;
        hasMore = result['has_more'] == true;
        todoCount = (result['todo'] as num?)?.toInt() ?? todoCount;

        final dynamic rawCounts = result['counts'];

        if (rawCounts is Map) {
          counts = {
            for (final entry in rawCounts.entries)
              entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
          };
        }
      });
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
          isLoadingMore = false;
        });
      }
    }
  }

  void selectTab(String key) {
    if (key == filter) return;

    setState(() => filter = key);

    load();
  }

  Future<void> openOrder(Map<String, dynamic> order) async {
    final int? id = (order['id'] as num?)?.toInt();

    if (id == null) return;

    final dynamic updated = await Navigator.of(context)
        .push(MaterialPageRoute(builder: (context) => OrderPage(orderId: id)));

    if (updated == true && mounted) {
      changed = true;

      await load();
    }
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildTabs() {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
        children: [
          for (final (key, label) in tabs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(() {
                  final int count = key == 'todo'
                      ? todoCount
                      : (counts[key] ?? 0);

                  return count > 0 ? '$label ($count)' : label;
                }()),
                selected: filter == key,
                selectedColor: AppColors.market.withValues(alpha: 0.16),
                onSelected: (_) => selectTab(key),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildTile(Map<String, dynamic> order) {
    final ShopStatusStyle style = orderStatusStyle(order['status']);

    final String? imageUrl = order['image_url']?.toString();

    final String who = widget.seller
        ? 'ลูกค้า: ${order['recipient_name'] ?? ''}'
        : (order['shop'] as Map?)?['name']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => openOrder(order),
          child: Ink(
            padding: const EdgeInsets.all(12),
            // สีพื้นต้องอยู่ใน Ink (ไม่งั้นเงาทะลุเป็นสีเทา)
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(22),
              border: AppDecorations.cardBorder,
              boxShadow: AppDecorations.cardShadow,
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: imageUrl == null
                        ? ColoredBox(
                            color: AppColors.fill,
                            child: Icon(
                              Icons.shopping_bag_outlined,
                              color: AppColors.market,
                            ),
                          )
                        : Image.network(
                            imageUrl,
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${order['product_title'] ?? ''} × ${order['quantity'] ?? 1}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$who · ${formatDateTime(order['created_at'])}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: style.color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                order['status_label']?.toString() ??
                                    style.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: style.color,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            formatPrice(order['total']),
                            style: TextStyle(
                              color: AppColors.market,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildList() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                loadError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.navy),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: load, child: const Text('ลองอีกครั้ง')),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: load,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 300) load(more: true);

          return false;
        },
        child: orders.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 90),
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 52,
                    color: AppColors.muted,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.seller
                        ? 'ยังไม่มีออเดอร์ในหมวดนี้'
                        : 'ยังไม่มีคำสั่งซื้อในหมวดนี้',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted),
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                itemCount: orders.length + (isLoadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= orders.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }

                  return buildTile(orders[index]);
                },
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        Navigator.of(context).pop(changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.seller ? 'ออเดอร์ของร้าน' : 'คำสั่งซื้อของฉัน'),
          actions: [
            if (widget.seller)
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const ShopSalesPage(),
                  ),
                ),
                icon: Icon(Icons.bar_chart_rounded, color: AppColors.market),
                label: Text(
                  'ยอดขาย',
                  style: TextStyle(color: AppColors.market),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            buildTabs(),
            Expanded(child: buildList()),
          ],
        ),
      ),
    );
  }
}
