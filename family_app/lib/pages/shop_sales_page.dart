import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../services/order_service.dart';
import '../theme/app_theme.dart';
import 'orders_page.dart';

// =======================================================
// ยอดขายของร้าน
// ยอดขาย = คำสั่งซื้อที่สำเร็จ (ลูกค้าได้รับสินค้าแล้ว) นับตามวันที่สำเร็จ
// วันนี้ / เดือนนี้ / ทั้งหมด → 7 วันล่าสุด → สินค้าขายดีเดือนนี้
// =======================================================

class ShopSalesPage extends StatefulWidget {
  const ShopSalesPage({super.key});

  @override
  State<ShopSalesPage> createState() => _ShopSalesPageState();
}

class _ShopSalesPageState extends State<ShopSalesPage> {
  Map<String, dynamic>? sales;
  String? loadError;
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loadError = null);

    try {
      final result = await OrderService.getSales();

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() => sales = result);
      } else {
        setState(() {
          loadError = result['message']?.toString() ?? 'โหลดยอดขายไม่สำเร็จ';
        });
      }
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void openOrders(String filter) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => OrdersPage(seller: true, initialFilter: filter),
      ),
    );
  }

  // =====================================================
  // UI
  // =====================================================

  Widget card({required Widget child, Color? color, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Ink(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            // สีพื้นต้องอยู่ใน Ink (ไม่งั้นเงาทะลุเป็นสีเทา)
            decoration: BoxDecoration(
              color: color ?? AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: AppDecorations.cardBorder,
              boxShadow: color == null ? AppDecorations.cardShadow : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget sectionTitle(String text, {String? caption}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (caption != null)
            Text(
              caption,
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Map summaryOf(String key) => (sales?[key] as Map?) ?? const {};

  String ordersText(Map summary) => '${summary['orders'] ?? 0} คำสั่งซื้อ';

  // ยอดวันนี้ใหญ่ + เดือนนี้ / ทั้งหมด
  Widget buildHeadline() {
    final Map today = summaryOf('today');

    Widget small(String label, Map summary) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 2),
            Text(
              formatPrice(summary['total'] ?? 0),
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              ordersText(summary),
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return card(
      onTap: () => openOrders('completed'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ยอดขายวันนี้',
            style: TextStyle(color: AppColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            formatPrice(today['total'] ?? 0),
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 32,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            ordersText(today),
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const Divider(height: 26),
          Row(
            children: [
              small('เดือนนี้', summaryOf('month')),
              small('ทั้งหมด', summaryOf('all')),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'นับเฉพาะคำสั่งซื้อที่ลูกค้าได้รับสินค้าแล้ว',
                  style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ),
              Text(
                'ดูประวัติการขาย',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.muted,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // รอจัดส่ง / กำลังส่ง (ยังไม่นับเป็นยอดขาย) + ต้องคืนเงิน
  Widget buildPipeline() {
    final Map progress = summaryOf('in_progress');
    final Map refund = summaryOf('refund_pending');

    final int refundCount = (refund['orders'] as num?)?.toInt() ?? 0;

    return Column(
      children: [
        card(
          onTap: () => openOrders('todo'),
          child: Row(
            children: [
              Icon(Icons.local_shipping_outlined, color: AppColors.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'กำลังดำเนินการ ${formatPrice(progress['total'] ?? 0)}',
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${ordersText(progress)} รอจัดส่ง / กำลังส่ง '
                      '(นับเป็นยอดขายเมื่อลูกค้าได้รับสินค้า)',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ],
          ),
        ),
        if (refundCount > 0)
          card(
            color: AppColors.danger.withValues(alpha: 0.08),
            onTap: () => openOrders('todo'),
            child: Row(
              children: [
                Icon(Icons.currency_exchange_rounded, color: AppColors.danger),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ต้องคืนเงินลูกค้า $refundCount รายการ',
                        style: TextStyle(
                          color: AppColors.danger,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'รวม ${formatPrice(refund['total'] ?? 0)} คืนเงินแล้วกด "คืนเงินให้ลูกค้าแล้ว" ในคำสั่งซื้อ',
                        style: TextStyle(color: AppColors.navy, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AppColors.muted),
              ],
            ),
          ),
      ],
    );
  }

  // ยอดขาย 7 วันล่าสุด (แท่งเดียวสี ร้าน = ยอดขาย แตะแท่งเพื่อดูตัวเลข)
  Widget buildDays() {
    final List<Map> days = [
      for (final item in (sales?['days'] as List?) ?? const [])
        if (item is Map) item,
    ];

    if (days.isEmpty) return const SizedBox.shrink();

    final double maxTotal = days.fold<double>(
      0,
      (max, day) => ((day['total'] as num?)?.toDouble() ?? 0) > max
          ? (day['total'] as num).toDouble()
          : max,
    );

    const double chartHeight = 120;

    String dayLabel(Map day, bool isToday) {
      if (isToday) return 'วันนี้';

      final DateTime? date = DateTime.tryParse(day['date']?.toString() ?? '');

      return date == null ? '' : '${date.day}/${date.month}';
    }

    return card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle(
            'ยอดขาย 7 วันล่าสุด',
            caption: 'แตะแท่งเพื่อดูยอดของวันนั้น',
          ),
          SizedBox(
            height: chartHeight + 44,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < days.length; i++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final Map day = days[i];
                        final bool isToday = i == days.length - 1;
                        final double total =
                            (day['total'] as num?)?.toDouble() ?? 0;

                        // แท่งที่ไม่มียอด = เส้นบาง ๆ ที่ฐาน
                        final double height = maxTotal <= 0 || total <= 0
                            ? 2
                            : (total / maxTotal * chartHeight).clamp(
                                4,
                                chartHeight,
                              );

                        // ใส่ตัวเลขเฉพาะวันนี้กับวันที่ขายมากสุด
                        final bool labelled =
                            total > 0 && (isToday || total == maxTotal);

                        return Tooltip(
                          triggerMode: TooltipTriggerMode.tap,
                          message:
                              '${dayLabel(day, isToday)}: ${formatPrice(total)} · ${day['orders'] ?? 0} คำสั่งซื้อ',
                          child: Semantics(
                            label:
                                '${dayLabel(day, isToday)} ยอดขาย ${formatPrice(total)}',
                            child: Padding(
                              // ช่องว่างระหว่างแท่ง
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (labelled)
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        formatPrice(total),
                                        style: TextStyle(
                                          color: AppColors.navy,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 4),
                                  Container(
                                    height: height,
                                    decoration: BoxDecoration(
                                      color: total > 0
                                          ? AppColors.market
                                          : AppColors.fill,
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(4),
                                      ),
                                    ),
                                  ),
                                  Container(height: 1, color: AppColors.fill),
                                  const SizedBox(height: 6),
                                  Text(
                                    dayLabel(day, isToday),
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: isToday
                                          ? AppColors.navy
                                          : AppColors.muted,
                                      fontSize: 11,
                                      fontWeight: isToday
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildTopProducts() {
    final List<Map> products = [
      for (final item in (sales?['top_products'] as List?) ?? const [])
        if (item is Map) item,
    ];

    final int cancelled = (sales?['cancelled_month'] as num?)?.toInt() ?? 0;

    return card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sectionTitle('สินค้าขายดีเดือนนี้'),
          if (products.isEmpty)
            Text(
              'เดือนนี้ยังไม่มีคำสั่งซื้อที่สำเร็จ',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          for (int i = 0; i < products.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      products[i]['title']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${products[i]['quantity'] ?? 0} ชิ้น · ${formatPrice(products[i]['total'] ?? 0)}',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          if (cancelled > 0) ...[
            const Divider(height: 18),
            InkWell(
              onTap: () => openOrders('cancelled'),
              child: Text(
                'เดือนนี้ยกเลิก $cancelled คำสั่งซื้อ',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ยอดขายของร้าน')),
      body: isLoading && sales == null
          ? const Center(child: CircularProgressIndicator())
          : sales == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      loadError ?? 'โหลดยอดขายไม่สำเร็จ',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.navy),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: load,
                      child: const Text('ลองอีกครั้ง'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  buildHeadline(),
                  buildPipeline(),
                  buildDays(),
                  buildTopProducts(),
                ],
              ),
            ),
    );
  }
}
