import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/market_data.dart';
import '../services/market_service.dart';
import '../theme/app_theme.dart';
import '../widgets/featured_shops_banner.dart';
import '../widgets/promptpay_qr.dart';

// =======================================================
// ขึ้นช่องแนะนำสินค้า
// เลือกแพ็กเกจ → โอนพร้อมเพย์ตาม QR → แนบสลิป → ทีมงานตรวจ → ขึ้นช่องแนะนำ
// =======================================================

class PromotionPage extends StatefulWidget {
  // null = ช่องร้านแนะนำ (แบนเนอร์ใหญ่) / มีค่า = ช่องสินค้าแนะนำของสินค้านี้
  final int? productId;
  final String title;

  const PromotionPage({super.key, this.productId, required this.title});

  @override
  State<PromotionPage> createState() => _PromotionPageState();
}

class _PromotionPageState extends State<PromotionPage> {
  Map<String, dynamic>? info;
  Map<String, dynamic>? order;

  String? selectedPlan;

  bool isLoading = true;
  bool isWorking = false;
  String? loadError;

  // มีการเปลี่ยนแปลง → หน้าร้านของฉันโหลดสินค้าใหม่ตอนกลับ
  bool changed = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      isLoading = info == null;
      loadError = null;
    });

    try {
      final result = await MarketService.getPromotionInfo(widget.productId);

      if (!mounted) return;

      if (result['status'] == true) {
        final List plans = (result['plans'] as List?) ?? const [];

        setState(() {
          info = result;
          order = result['open_order'] is Map
              ? Map<String, dynamic>.from(result['open_order'])
              : null;
          selectedPlan ??= plans.isNotEmpty && plans.first is Map
              ? (plans.first as Map)['key']?.toString()
              : null;
        });
      } else {
        setState(() {
          loadError = result['message']?.toString() ?? 'โหลดข้อมูลไม่สำเร็จ';
        });
      }
    } catch (e) {
      if (mounted) setState(() => loadError = 'โหลดข้อมูลไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // สั่งซื้อ / แนบสลิป / ยกเลิก
  // =====================================================

  Future<void> createOrder() async {
    final String? plan = selectedPlan;

    if (plan == null || isWorking) return;

    setState(() => isWorking = true);

    try {
      final result = await MarketService.createPromotion(
        widget.productId,
        plan,
      );

      if (!mounted) return;

      // มีรายการค้างอยู่แล้ว → แสดงรายการนั้นแทน
      if (result['order'] is Map) {
        changed = true;

        setState(() => order = Map<String, dynamic>.from(result['order']));
      }

      if (result['status'] != true) {
        showMessage(result['message']?.toString() ?? 'สร้างรายการไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showMessage('สร้างรายการไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => isWorking = false);
    }
  }

  Future<void> attachSlip() async {
    final int? id = (order?['id'] as num?)?.toInt();

    if (id == null || isWorking) return;

    final XFile? file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1800,
    );

    if (file == null || !mounted) return;

    setState(() => isWorking = true);

    try {
      final result = await MarketService.uploadPromotionSlip(
        id,
        file.path,
        shop: widget.productId == null,
      );

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ส่งสลิปไม่สำเร็จ');

      if (result['status'] == true) {
        changed = true;

        setState(() => order = Map<String, dynamic>.from(result['order']));
      } else {
        // หมดเวลา → โหลดใหม่ให้เลือกแพ็กเกจได้อีกครั้ง
        await load();
      }
    } catch (e) {
      if (mounted) showMessage('ส่งสลิปไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => isWorking = false);
    }
  }

  Future<void> cancelOrder() async {
    final int? id = (order?['id'] as num?)?.toInt();

    if (id == null || isWorking) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ยกเลิกรายการนี้?'),
        content: const Text('ถ้าโอนเงินไปแล้ว ให้แนบสลิปแทนการยกเลิก'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ไม่ยกเลิก'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('ยกเลิกรายการ'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => isWorking = true);

    try {
      final result = await MarketService.cancelPromotion(
        id,
        shop: widget.productId == null,
      );

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ยกเลิกไม่สำเร็จ');

      changed = true;

      await load();
    } catch (e) {
      if (mounted) showMessage('ยกเลิกไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => isWorking = false);
    }
  }

  Future<void> shareQr(String payload, String amount) async {
    final String? error = await sharePromptPayQr(
      payload: payload,
      amount: amount,
      fileTag: 'promo_${order?['id'] ?? 'qr'}',
    );

    if (error != null && mounted) showMessage(error);
  }

  // =====================================================
  // UI
  // =====================================================

  Widget card({required Widget child, Color? color}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: AppDecorations.cardBorder,
        boxShadow: AppDecorations.cardShadow,
      ),
      child: child,
    );
  }

  Widget buildHeader() {
    final bool featured = info?['is_featured'] == true;

    return card(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: featuredColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.star_rounded, color: featuredColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  featured
                      ? 'แนะนำอยู่ถึง ${formatDateTime(info?['featured_until'])}'
                      : info?['placement_label']?.toString() ?? '',
                  style: TextStyle(
                    color: featured ? AppColors.success : AppColors.muted,
                    fontSize: 12.5,
                    fontWeight: featured ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildPlans() {
    final List plans = (info?['plans'] as List?) ?? const [];

    final Map slots = (info?['slots'] as Map?) ?? const {};

    final bool available = slots['available'] == true;

    final bool paymentEnabled = info?['payment_enabled'] == true;

    final bool featured = info?['is_featured'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          featured ? 'ต่ออายุช่องแนะนำ' : 'เลือกแพ็กเกจ',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${info?['slot_label'] ?? 'ช่องแนะนำ'} ใช้ไป ${slots['used'] ?? 0}/${slots['total'] ?? 0} ช่อง',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        const SizedBox(height: 12),
        for (final dynamic plan in plans)
          if (plan is Map) buildPlanTile(Map<String, dynamic>.from(plan)),
        const SizedBox(height: 6),
        if (!paymentEnabled)
          buildNotice(
            Icons.info_outline_rounded,
            'ยังไม่เปิดรับชำระเงินค่าช่องแนะนำ กรุณาลองใหม่ภายหลัง',
            AppColors.muted,
          )
        else if (!available)
          buildNotice(
            Icons.event_busy_rounded,
            'ช่องแนะนำหมวดนี้เต็มแล้ว ลองใหม่เมื่อมีช่องว่าง',
            AppColors.danger,
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed:
                paymentEnabled &&
                    available &&
                    selectedPlan != null &&
                    !isWorking
                ? createOrder
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.market,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            icon: isWorking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.qr_code_2_rounded),
            label: const Text('ไปชำระเงินด้วยพร้อมเพย์'),
          ),
        ),
        const SizedBox(height: 16),
        buildSteps(),
      ],
    );
  }

  Widget buildPlanTile(Map<String, dynamic> plan) {
    final String key = plan['key']?.toString() ?? '';
    final int days = (plan['days'] as num?)?.toInt() ?? 1;
    final int price = (plan['price'] as num?)?.toInt() ?? 0;

    final bool selected = selectedPlan == key;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? AppColors.market.withValues(alpha: 0.08)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() => selectedPlan = key),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? AppColors.market : AppColors.border,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? AppColors.market : AppColors.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan['label']?.toString() ?? key,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (days > 1)
                        Text(
                          'เฉลี่ยวันละ ${(price / days).toStringAsFixed(0)} บาท',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                Text(
                  formatPrice(price),
                  style: TextStyle(
                    color: AppColors.market,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildNotice(IconData icon, String text, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSteps() {
    const steps = [
      'เลือกแพ็กเกจ แล้วกด "ไปชำระเงิน"',
      'สแกน QR พร้อมเพย์ด้วยแอปธนาคาร (หรือบันทึกรูป QR แล้วสแกนจากรูป)',
      'กลับมาแนบสลิปการโอนในหน้านี้',
      'ทีมงานตรวจสลิป แล้วขึ้นช่องแนะนำทันที',
    ];

    return card(
      color: AppColors.fill,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ขั้นตอน',
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${i + 1}. ${steps[i]}',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildOrder(Map<String, dynamic> current) {
    final bool pending = current['status'] == 'pending_review';

    final Map payment = (current['payment'] as Map?) ?? const {};

    final String payload = payment['promptpay_payload']?.toString() ?? '';

    final String amount = formatPrice(current['amount']);

    if (pending) {
      return card(
        child: Column(
          children: [
            const Icon(
              Icons.hourglass_top_rounded,
              size: 46,
              color: featuredColor,
            ),
            const SizedBox(height: 10),
            Text(
              'ส่งสลิปแล้ว รอทีมงานตรวจสอบ',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${current['plan_label'] ?? ''} · $amount\nตรวจแล้วจะแจ้งเตือนให้ทราบ',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: isWorking ? null : attachSlip,
              icon: const Icon(Icons.image_outlined),
              label: const Text('เปลี่ยนสลิป'),
            ),
          ],
        ),
      );
    }

    return card(
      child: Column(
        children: [
          Text(
            'โอนพร้อมเพย์ ${current['plan_label'] ?? ''}',
            style: TextStyle(color: AppColors.muted, fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(
            amount,
            style: TextStyle(
              color: AppColors.market,
              fontSize: 30,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 12),
          if (payload.isNotEmpty) PromptPayQrImage(payload: payload),
          const SizedBox(height: 10),
          Text(
            [
              if (payment['promptpay_name'] != null)
                payment['promptpay_name'].toString(),
              'พร้อมเพย์ ${payment['promptpay_id'] ?? ''}',
            ].join('\n'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'แนบสลิปภายใน ${formatDateTime(current['payment_deadline'])}',
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          if (payload.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => shareQr(payload, amount),
                icon: const Icon(Icons.download_rounded),
                label: const Text('บันทึก / แชร์รูป QR'),
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isWorking ? null : attachSlip,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.market,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: isWorking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.receipt_long_rounded),
              label: const Text('แนบสลิปการโอน'),
            ),
          ),
          TextButton(
            onPressed: isWorking ? null : cancelOrder,
            child: Text(
              'ยกเลิกรายการ',
              style: TextStyle(color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildHistory() {
    final List history = (info?['history'] as List?) ?? const [];

    final List items = history
        .whereType<Map>()
        .where((item) => item['id'] != order?['id'])
        .toList();

    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 22),
        Text(
          'รายการก่อนหน้า',
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        for (final dynamic item in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${item['plan_label'] ?? ''} · ${formatPrice(item['amount'])}',
              style: TextStyle(
                color: AppColors.navy,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              [
                formatDateTime(item['created_at'], withTime: false),
                if (item['status'] == 'approved' && item['ends_at'] != null)
                  'ถึง ${formatDateTime(item['ends_at'])}',
                if (item['reject_reason'] != null)
                  item['reject_reason'].toString(),
              ].join(' · '),
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            trailing: Text(
              item['status_label']?.toString() ?? '',
              style: TextStyle(
                color: switch (item['status']) {
                  'approved' => AppColors.success,
                  'rejected' => AppColors.danger,
                  _ => AppColors.muted,
                },
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? current = order;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop(changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('ขึ้นช่องแนะนำ')),
        body: isLoading
            ? const Center(child: CircularProgressIndicator())
            : loadError != null && info == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(loadError!, textAlign: TextAlign.center),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: load,
                      child: const Text('ลองอีกครั้ง'),
                    ),
                  ],
                ),
              )
            : RefreshIndicator(
                onRefresh: load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    buildHeader(),
                    const SizedBox(height: 18),
                    if (current != null) buildOrder(current) else buildPlans(),
                    buildHistory(),
                  ],
                ),
              ),
      ),
    );
  }
}
