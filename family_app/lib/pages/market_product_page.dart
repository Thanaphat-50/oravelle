import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../config/app_info.dart';
import '../data/market_data.dart';
import '../services/cart_service.dart';
import '../services/chat_service.dart';
import '../services/market_service.dart';
import '../theme/app_theme.dart';
import '../widgets/market_sheets.dart';
import '../widgets/market_widgets.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/product_option_sheet.dart';
import '../widgets/shop_trust_widgets.dart'
    show ReviewTile, ShopReviewsPage, StarRow;
import 'cart_page.dart';
import 'chat_room_page.dart';
import 'checkout_page.dart';
import 'market_shop_page.dart';
import 'video_player_page.dart';

// =======================================================
// หน้าสินค้า
// รูป → ราคา/ชื่อ/สถานะ → การจัดส่ง → รายละเอียด → ร้าน → สินค้าอื่นในร้าน
// แถบล่างติดจอ: แชทกับร้าน + ซื้อเลย
// =======================================================

class MarketProductPage extends StatefulWidget {
  final int productId;

  // ข้อมูลย่อจากการ์ด ใช้แสดงระหว่างโหลด
  final Map<String, dynamic>? preview;

  const MarketProductPage({super.key, required this.productId, this.preview});

  @override
  State<MarketProductPage> createState() => _MarketProductPageState();
}

class _MarketProductPageState extends State<MarketProductPage> {
  Map<String, dynamic>? product;
  Map<String, dynamic>? shop;
  List<Map<String, dynamic>> otherProducts = [];

  // รีวิวสินค้าจากผู้ซื้อจริง (ล่าสุด 3 รายการ) + คะแนนเฉลี่ย
  List<Map<String, dynamic>> reviews = [];
  Map<String, dynamic> reviewSummary = {};

  bool isLoading = true;
  String? loadError;

  int imageIndex = 0;

  bool isSaved = false;
  bool isOpeningChat = false;
  bool isAddingToCart = false;

  @override
  void initState() {
    super.initState();
    loadProduct();
  }

  Future<void> loadProduct() async {
    setState(() {
      isLoading = true;
      loadError = null;
    });

    try {
      final result = await MarketService.getMarketProduct(widget.productId);

      if (!mounted) return;

      if (result['status'] == true) {
        final dynamic others = result['other_products'];
        final dynamic rawReviews = result['reviews'];
        final dynamic summary = result['review_summary'];

        setState(() {
          reviews = rawReviews is List
              ? rawReviews
                    .whereType<Map>()
                    .map((item) => Map<String, dynamic>.from(item))
                    .toList()
              : [];
          reviewSummary = summary is Map
              ? Map<String, dynamic>.from(summary)
              : {};
          product = Map<String, dynamic>.from(result['product'] as Map);
          shop = Map<String, dynamic>.from(result['shop'] as Map);
          otherProducts = others is List
              ? others
                    .whereType<Map>()
                    .map((item) => Map<String, dynamic>.from(item))
                    .toList()
              : [];
          isSaved = product?['is_saved'] == true;
        });

        // ตัวเลขบนไอคอนตะกร้า
        CartService.refreshCount();
      } else {
        setState(() {
          loadError = result['message']?.toString() ?? 'ไม่พบสินค้านี้';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loadError = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // =====================================================
  // ปุ่มด้านบน: แชร์ / บันทึก / รายงาน
  // =====================================================

  Future<void> shareProduct() async {
    final Map<String, dynamic>? data = product;

    if (data == null) return;

    await SharePlus.instance.share(
      ShareParams(
        text: [
          data['title']?.toString() ?? '',
          '${formatPrice(data['price'])} · ร้าน ${shop?['name'] ?? ''}',
          'ดูสินค้านี้ในแอป ${AppInfo.name}',
        ].join('\n'),
      ),
    );
  }

  // เปลี่ยนไอคอนทันที ไม่สำเร็จ → เปลี่ยนกลับ
  Future<void> toggleSave() async {
    final bool next = !isSaved;

    setState(() => isSaved = next);

    try {
      final result = await MarketService.setProductSaved(
        widget.productId,
        next,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        showMessage(result['message']?.toString() ?? '');
      } else {
        setState(() => isSaved = !next);
        showMessage(result['message']?.toString() ?? 'บันทึกไม่สำเร็จ');
      }
    } catch (e) {
      if (!mounted) return;

      setState(() => isSaved = !next);
      showMessage(e.toString());
    }
  }

  Future<void> reportProduct() async {
    final report = await showMarketReportSheet(
      context,
      title: 'รายงานสินค้านี้',
    );

    if (report == null || !mounted) return;

    try {
      final result = await MarketService.report(
        target: 'products',
        id: widget.productId,
        reason: report.reason,
        details: report.details,
      );

      if (!mounted) return;

      showMessage(result['message']?.toString() ?? 'ขอบคุณที่รายงาน');

      // รายงานแล้วจะไม่เห็นสินค้านี้ในตลาดอีก
      if (result['status'] == true) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    }
  }

  void showMessage(String message) {
    if (!mounted || message.isEmpty) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // แถบล่าง: แชทกับร้าน / ซื้อเลย
  // =====================================================

  Future<void> openShopChat() async {
    final int? shopId = (shop?['id'] as num?)?.toInt();

    if (shopId == null || isOpeningChat) return;

    setState(() => isOpeningChat = true);

    try {
      final result = await ChatService.openShopChat(shopId);

      if (!mounted) return;

      final dynamic conversation = result['conversation'];

      final int? conversationId = conversation is Map
          ? (conversation['id'] as num?)?.toInt()
          : null;

      if (result['status'] != true || conversationId == null) {
        showMessage(result['message']?.toString() ?? 'เปิดแชทไม่สำเร็จ');
        return;
      }

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ChatRoomPage(
            conversationId: conversationId,
            user: conversation['user'] is Map
                ? Map<String, dynamic>.from(conversation['user'])
                : null,
            draft: 'สอบถามสินค้า "${product?['title'] ?? ''}"',
          ),
        ),
      );
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isOpeningChat = false);
    }
  }

  // ซื้อแล้วกลับมา → โหลดใหม่ (สต็อกเปลี่ยน)
  List get variants => (product?['variants'] as List?) ?? const [];

  // ซื้อเลย: มีตัวเลือก → เลือกก่อน / ไม่มี → ไปหน้าสั่งซื้อทันที (แก้จำนวนในหน้าสั่งซื้อได้)
  Future<void> buyNow() async {
    final Map<String, dynamic>? data = product;

    if (data == null) return;

    ProductChoice choice = (variantId: null, quantity: 1);

    if (variants.isNotEmpty) {
      final ProductChoice? picked = await showProductOptionSheet(
        context,
        product: data,
        confirmLabel: 'ซื้อเลย',
      );

      if (picked == null || !mounted) return;

      choice = picked;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CheckoutPage(
          items: [
            {
              'product_id': widget.productId,
              'variant_id': choice.variantId,
              'quantity': choice.quantity,
            },
          ],
        ),
      ),
    );

    // สั่งแล้วกลับมา → โหลดใหม่ (สต็อกเปลี่ยน)
    if (mounted) await loadProduct();
  }

  Future<void> addToCart() async {
    final Map<String, dynamic>? data = product;

    if (data == null || isAddingToCart) return;

    ProductChoice choice = (variantId: null, quantity: 1);

    if (variants.isNotEmpty) {
      final ProductChoice? picked = await showProductOptionSheet(
        context,
        product: data,
        confirmLabel: 'เพิ่มลงตะกร้า',
      );

      if (picked == null || !mounted) return;

      choice = picked;
    }

    setState(() => isAddingToCart = true);

    try {
      final result = await CartService.addToCart(
        productId: widget.productId,
        variantId: choice.variantId,
        quantity: choice.quantity,
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(result['message']?.toString() ?? ''),
            // มีปุ่ม "ดูตะกร้า" แต่ให้หายเองเหมือนข้อความทั่วไป
            persist: false,
            action: result['status'] == true
                ? SnackBarAction(label: 'ดูตะกร้า', onPressed: openCart)
                : null,
          ),
        );
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isAddingToCart = false);
    }
  }

  Future<void> openCart() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (context) => const CartPage()));

    if (mounted) await loadProduct();
  }

  Widget? buildBottomBar(Map<String, dynamic> data) {
    if (data['is_mine'] == true) return null;

    final Map order = (data['order'] as Map?) ?? const {};

    final bool available = order['available'] == true;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 14, 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: [
            // แชทกับร้าน
            SizedBox(
              width: 64,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: isOpeningChat ? null : openShopChat,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      isOpeningChat
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.chat_bubble_outline_rounded,
                              color: AppColors.navy,
                            ),
                      const SizedBox(height: 3),
                      Text(
                        'แชท',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (available) ...[
              Expanded(
                child: OutlinedButton(
                  // ธีมของแอปให้ปุ่มกว้างเต็มจอ → ในแถวต้องกำหนดขนาดเอง
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.market,
                    side: BorderSide(color: AppColors.market, width: 1.4),
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: isAddingToCart ? null : addToCart,
                  child: isAddingToCart
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'เพิ่มลงตะกร้า',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              flex: available ? 1 : 2,
              child: available
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.market,
                        minimumSize: const Size(0, 52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: buyNow,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'ซื้อเลย',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            formatPrice(data['price']),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  : Container(
                      constraints: const BoxConstraints(minHeight: 52),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.fill,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        order['reason']?.toString() ?? 'สั่งซื้อในแอปไม่ได้',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // รูปสินค้า (ปัดดูได้ กดเพื่อดูเต็มจอและซูม)
  // =====================================================

  List<String> imageUrls() {
    final dynamic images = product?['images'];

    if (images is! List) return const [];

    return images
        .whereType<Map>()
        .map((image) => image['url']?.toString() ?? '')
        .where((url) => url.isNotEmpty)
        .toList();
  }

  Widget buildGallery() {
    final List<String> urls = imageUrls();

    if (urls.isEmpty) {
      final String? previewUrl = widget.preview?['image_url']?.toString();

      return AspectRatio(
        aspectRatio: 1,
        child: previewUrl == null
            ? ColoredBox(color: AppColors.fill)
            : Image.network(previewUrl, fit: BoxFit.cover),
      );
    }

    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        children: [
          PageView.builder(
            itemCount: urls.length,
            onPageChanged: (index) {
              setState(() {
                imageIndex = index;
              });
            },
            itemBuilder: (context, index) {
              return GestureDetector(
                onTap: () {
                  showPhotoViewer(context, urls: urls, initialIndex: index);
                },
                child: Image.network(
                  urls[index],
                  fit: BoxFit.cover,
                  width: double.infinity,
                  loadingBuilder: (context, child, progress) {
                    return progress == null
                        ? child
                        : ColoredBox(color: AppColors.fill);
                  },
                  errorBuilder: (context, error, stackTrace) {
                    return ColoredBox(
                      color: AppColors.fill,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: AppColors.muted,
                      ),
                    );
                  },
                ),
              );
            },
          ),
          if (urls.length > 1)
            Positioned(
              right: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${imageIndex + 1}/${urls.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // =====================================================
  // ส่วนต่าง ๆ ของหน้า
  // =====================================================

  Widget section({required Widget child, String? title}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: AppDecorations.cardBorder,
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }

  // ราคา ชื่อ สถานะพร้อมขาย
  Widget buildHeadline(Map<String, dynamic> data) {
    final int sold = (data['sold_count'] as num?)?.toInt() ?? 0;

    final int reviewCount = (reviewSummary['count'] as num?)?.toInt() ?? 0;

    // "★ 4.8 (12) · ขายแล้ว 30 ชิ้น"
    final String soldLine = [
      if (reviewCount > 0)
        '★ ${((reviewSummary['average'] as num?) ?? 0).toStringAsFixed(1)} ($reviewCount)',
      if (sold > 0) 'ขายแล้ว $sold ชิ้น',
    ].join(' · ');

    final bool soldOut = data['sold_out'] == true;

    final Color statusColor = soldOut ? AppColors.danger : AppColors.success;

    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data['is_featured'] == true) ...[
            const FeaturedProductBadge(),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  priceText(data),
                  style: TextStyle(
                    color: AppColors.market,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (soldLine.isNotEmpty)
                Text(
                  soldLine,
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            data['title']?.toString() ?? '',
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 19,
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  soldOut ? Icons.block_rounded : Icons.check_circle_rounded,
                  size: 15,
                  color: statusColor,
                ),
                const SizedBox(width: 5),
                Text(
                  soldOut
                      ? 'สินค้าหมด'
                      : 'พร้อมขาย · เหลือ ${data['stock'] ?? 0} ชิ้น',
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ราคาเดียว "฿200" / ตัวเลือกราคาต่างกัน "฿200 – ฿250"
  String priceText(Map<String, dynamic> data) {
    final Map? range = data['price_range'] as Map?;

    final num? min = range?['min'] as num?;
    final num? max = range?['max'] as num?;

    if (min != null && max != null && min != max) {
      return '${formatPrice(min)} – ${formatPrice(max)}';
    }

    return formatPrice(min ?? data['price']);
  }

  // ตัวเลือกสินค้า (แตะเพื่อเลือกแล้วซื้อ)
  Widget buildVariants(Map<String, dynamic> data) {
    final String optionName =
        data['option_name']?.toString().trim().isNotEmpty == true
        ? data['option_name'].toString()
        : 'ตัวเลือก';

    final bool canOrder = (data['order'] as Map?)?['available'] == true;

    return section(
      title: '$optionName (${variants.length} แบบ)',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: canOrder && data['is_mine'] != true ? buyNow : null,
        child: Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final variant in variants)
                    if (variant is Map)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.fill,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          variant['sold_out'] == true
                              ? '${variant['name']} (หมด)'
                              : '${variant['name']}',
                          style: TextStyle(
                            color: variant['sold_out'] == true
                                ? AppColors.muted
                                : AppColors.navy,
                            fontSize: 13,
                          ),
                        ),
                      ),
                ],
              ),
            ),
            if (canOrder && data['is_mine'] != true)
              Icon(Icons.chevron_right_rounded, color: AppColors.market),
          ],
        ),
      ),
    );
  }

  // วิธีรับสินค้า + ค่าส่ง + ระยะเวลาจัดส่ง (จากข้อมูลจริงของร้าน)
  Widget buildShipping(
    Map<String, dynamic> data,
    Map<String, dynamic> shopData,
  ) {
    final List options = (data['delivery_options'] as List?) ?? const [];

    final int? shipDays = (shopData['ship_within_days'] as num?)?.toInt();

    final Map stats = (shopData['stats'] as Map?) ?? const {};

    final double? avgHours = (stats['avg_ship_hours'] as num?)?.toDouble();

    final List payments = (shopData['payment_methods'] as List?) ?? const [];

    Widget line(IconData icon, String text, {String? trailing}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 19, color: AppColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: AppColors.navy, fontSize: 13.5),
              ),
            ),
            if (trailing != null)
              Text(
                trailing,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      );
    }

    return section(
      title: 'การจัดส่ง',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (options.isEmpty)
            Text(
              'ร้านยังไม่ได้ระบุวิธีรับสินค้า',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          for (final option in options)
            if (option is Map)
              line(
                findDeliveryMethod(option['key']?.toString() ?? '')?.icon ??
                    Icons.local_shipping_outlined,
                option['label']?.toString() ?? '',
                trailing: ((option['shipping_fee'] as num?) ?? 0) > 0
                    ? formatPrice(option['shipping_fee'])
                    : option['key'] == 'shipping' || option['key'] == 'delivery'
                    ? 'ส่งฟรี'
                    : 'ไม่มีค่าส่ง',
              ),
          if (shipDays != null || avgHours != null) const Divider(height: 18),
          if (shipDays != null)
            line(
              Icons.schedule_rounded,
              'ร้านจัดส่งภายใน $shipDays วันหลังชำระเงิน',
            ),
          if (avgHours != null)
            line(
              Icons.speed_rounded,
              'ส่งจริงเฉลี่ย ${formatShipTime(avgHours)} '
              '(${stats['shipped_orders'] ?? 0} ออเดอร์ล่าสุด)',
            ),
          if (payments.isNotEmpty) ...[
            const Divider(height: 18),
            line(
              Icons.payments_outlined,
              'ชำระได้: ${payments.map((key) => findPaymentMethod(key.toString())?.label ?? key).join(' · ')}',
            ),
          ],
        ],
      ),
    );
  }

  // 30 ชม. → "1 วัน 6 ชม." / 5.5 → "5.5 ชม."
  String formatShipTime(double hours) {
    if (hours < 24) {
      final bool whole = hours == hours.roundToDouble();

      return '${hours.toStringAsFixed(whole ? 0 : 1)} ชม.';
    }

    final int days = hours ~/ 24;
    final int rest = (hours - days * 24).round();

    return rest == 0 ? '$days วัน' : '$days วัน $rest ชม.';
  }

  Widget buildVideo(Map<String, dynamic> data) {
    final String videoUrl = data['video_url'].toString();

    final String? videoThumbnail = data['video_thumbnail_url']?.toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => VideoPlayerPage(url: videoUrl),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                videoThumbnail != null
                    ? Image.network(videoThumbnail, fit: BoxFit.cover)
                    : const ColoredBox(color: Colors.black),
                const ColoredBox(color: Color(0x33000000)),
                const Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    size: 56,
                    color: Colors.white,
                  ),
                ),
                const Positioned(
                  left: 12,
                  bottom: 10,
                  child: Text(
                    'วิดีโอแนะนำสินค้า',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildDescription(Map<String, dynamic> data) {
    final MarketCategory? category = findMarketCategory(data['category']);

    final String description = data['description']?.toString().trim() ?? '';

    return section(
      title: 'รายละเอียดสินค้า',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (category != null)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.market.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(category.icon, size: 14, color: AppColors.market),
                  const SizedBox(width: 5),
                  Text(
                    category.label,
                    style: TextStyle(
                      color: AppColors.market,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          Text(
            description.isEmpty
                ? 'ร้านไม่ได้ใส่รายละเอียดเพิ่มเติม'
                : description,
            style: TextStyle(
              color: description.isEmpty ? AppColors.muted : AppColors.subtle,
              fontSize: 14.5,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }

  // รีวิวสินค้า: คะแนนเฉลี่ย + รีวิวล่าสุด (รีวิวได้หลังได้รับสินค้าเท่านั้น)
  Widget buildReviews(Map<String, dynamic> data) {
    final int count = (reviewSummary['count'] as num?)?.toInt() ?? 0;

    final double average = (reviewSummary['average'] as num?)?.toDouble() ?? 0;

    void openAll() {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ShopReviewsPage.product(
            productId: widget.productId,
            productTitle: data['title']?.toString() ?? '',
          ),
        ),
      );
    }

    return section(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'รีวิวสินค้า',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (count > reviews.length)
                TextButton(
                  onPressed: openAll,
                  child: Text('ดูทั้งหมด ($count)'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (count > 0)
            Row(
              children: [
                Text(
                  average.toStringAsFixed(1),
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StarRow(rating: average, size: 18),
                    Text(
                      '$count รีวิวจากผู้ซื้อจริง',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ],
            )
          else
            Text(
              'ยังไม่มีรีวิว (รีวิวได้หลังได้รับสินค้าแล้ว)',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          for (final review in reviews) ...[
            const Divider(height: 22),
            ReviewTile(review: review),
          ],
        ],
      ),
    );
  }

  // ร้าน + ความน่าเชื่อถือ (คะแนนรีวิว ยอดขาย จำนวนสินค้า เปิดร้านมานาน)
  Widget buildShop(Map<String, dynamic> shopData) {
    final String? logoUrl = shopData['logo_url']?.toString();

    final int? shopId = (shopData['id'] as num?)?.toInt();

    final Map rating = (shopData['rating'] as Map?) ?? const {};
    final Map stats = (shopData['stats'] as Map?) ?? const {};

    final int reviewCount = (rating['count'] as num?)?.toInt() ?? 0;

    final String since = durationSince(shopData['member_since']);

    Widget stat(String value, String label) {
      return Expanded(
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
          ],
        ),
      );
    }

    void openShop() {
      if (shopId == null) return;

      Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => MarketShopPage(shopId: shopId)),
      );
    }

    return section(
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: openShop,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppColors.market.withValues(alpha: 0.10),
                  foregroundImage: logoUrl != null
                      ? NetworkImage(logoUrl)
                      : null,
                  child: Icon(
                    Icons.storefront_rounded,
                    color: AppColors.market,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        shopData['name']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          shopArea(shopData),
                          if (since.isNotEmpty) 'เปิดร้านมา $since',
                        ].where((part) => part.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  // ธีมของแอปให้ปุ่มกว้างเต็มจอ → ในแถวต้องกำหนดขนาดเอง
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.market,
                    side: BorderSide(color: AppColors.market),
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: openShop,
                  child: const Text('ดูร้าน'),
                ),
              ],
            ),
          ),
          const Divider(height: 22),
          Row(
            children: [
              stat(
                reviewCount > 0 ? '★ ${rating['average']}' : '-',
                reviewCount > 0 ? '$reviewCount รีวิว' : 'ยังไม่มีรีวิว',
              ),
              stat('${stats['sold_count'] ?? 0}', 'ขายแล้ว (ชิ้น)'),
              stat('${shopData['products_count'] ?? 0}', 'สินค้า'),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildOtherProducts() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
          child: Text(
            'สินค้าอื่นในร้านนี้',
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        SizedBox(
          height: 236,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: otherProducts.length,
            separatorBuilder: (context, index) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final Map<String, dynamic> item = otherProducts[index];

              final int? id = (item['id'] as num?)?.toInt();

              return SizedBox(
                width: 150,
                child: MarketProductCard(
                  product: item,
                  showShop: false,
                  onTap: () {
                    if (id == null) return;

                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            MarketProductPage(productId: id, preview: item),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget buildBody(Map<String, dynamic> data, Map<String, dynamic> shopData) {
    final bool mine = data['is_mine'] == true;

    final bool canOrder = (data['order'] as Map?)?['available'] == true;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        buildGallery(),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              buildHeadline(data),
              if (variants.isNotEmpty) buildVariants(data),
              if (mine)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.softPrimary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'นี่คือสินค้าของร้านคุณ (ผู้ซื้อจะเห็นหน้านี้แบบเดียวกัน)',
                    style: TextStyle(color: AppColors.navy, fontSize: 13),
                  ),
                ),
              buildShipping(data, shopData),
              if (data['video_url'] != null) buildVideo(data),
              buildDescription(data),
              buildReviews(data),
              buildShop(shopData),
              if (otherProducts.isNotEmpty) buildOtherProducts(),
              // ร้านยังไม่เปิดรับคำสั่งซื้อในแอป → ติดต่อร้านโดยตรงได้
              if (!mine && !canOrder) ...[
                ShopContactButtons(
                  phone: shopData['phone']?.toString(),
                  lineId: shopData['line_id']?.toString(),
                ),
                const SizedBox(height: 12),
              ],
              if (!mine) const MarketSafetyNote(),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? data = product;
    final Map<String, dynamic>? shopData = shop;

    return Scaffold(
      appBar: AppBar(
        title: const Text('รายละเอียดสินค้า'),
        actions: [
          if (data != null) ...[
            // ตะกร้า + จำนวนสินค้าในตะกร้า
            ValueListenableBuilder<int>(
              valueListenable: CartService.cartCount,
              builder: (context, count, child) => IconButton(
                tooltip: 'ตะกร้าสินค้า',
                onPressed: openCart,
                icon: Badge(
                  isLabelVisible: count > 0,
                  label: Text(count > 99 ? '99+' : '$count'),
                  backgroundColor: AppColors.market,
                  child: const Icon(Icons.shopping_cart_outlined),
                ),
              ),
            ),
            IconButton(
              tooltip: 'แชร์สินค้า',
              onPressed: shareProduct,
              icon: const Icon(Icons.share_outlined),
            ),
            IconButton(
              tooltip: isSaved ? 'เอาออกจากที่บันทึก' : 'บันทึกสินค้า',
              onPressed: toggleSave,
              icon: Icon(
                isSaved
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                color: isSaved ? AppColors.market : null,
              ),
            ),
          ],
          if (data != null && data['is_mine'] != true)
            PopupMenuButton<String>(
              tooltip: 'ตัวเลือก',
              onSelected: (value) {
                if (value == 'report') reportProduct();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined, color: AppColors.danger),
                      SizedBox(width: 10),
                      Text('รายงานสินค้า'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: isLoading && data == null
          ? const Center(child: CircularProgressIndicator())
          : loadError != null || data == null || shopData == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_off_rounded,
                      size: 44,
                      color: AppColors.muted,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      loadError ?? 'ไม่พบสินค้านี้',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.navy),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: loadProduct,
                      child: const Text('ลองอีกครั้ง'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: loadProduct,
              child: buildBody(data, shopData),
            ),
      bottomNavigationBar: data == null || loadError != null
          ? null
          : buildBottomBar(data),
    );
  }
}
