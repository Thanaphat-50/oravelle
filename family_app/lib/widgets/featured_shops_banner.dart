import 'dart:async';

import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../theme/app_theme.dart';
import 'market_widgets.dart';

// สีป้าย "แนะนำ"
const Color featuredColor = Color(0xFFF59E0B);

// =======================================================
// ป้าย ⭐ แนะนำ (ใช้บนแบนเนอร์และหน้าร้าน)
// =======================================================

class FeaturedBadge extends StatelessWidget {
  const FeaturedBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: featuredColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 14, color: featuredColor),
          SizedBox(width: 3),
          Text(
            'แนะนำ',
            style: TextStyle(
              color: Color(0xFFB45309),
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// =======================================================
// แบนเนอร์ร้านแนะนำ (ร้านที่เช่าพื้นที่) บนสุดของตลาด
// - เลื่อนไปร้านถัดไปเองทุก 4 วินาที
// - ผู้ใช้ปัดเองได้ (หยุดเลื่อนอัตโนมัติชั่วคราว)
// =======================================================

class FeaturedShopsBanner extends StatefulWidget {
  final List<Map<String, dynamic>> shops;
  final ValueChanged<int> onOpenShop;

  const FeaturedShopsBanner({
    super.key,
    required this.shops,
    required this.onOpenShop,
  });

  @override
  State<FeaturedShopsBanner> createState() => _FeaturedShopsBannerState();
}

class _FeaturedShopsBannerState extends State<FeaturedShopsBanner> {
  static const Duration slideInterval = Duration(seconds: 4);

  final PageController pageController = PageController();

  Timer? timer;

  int currentPage = 0;

  @override
  void initState() {
    super.initState();
    startAutoSlide();
  }

  @override
  void didUpdateWidget(covariant FeaturedShopsBanner oldWidget) {
    super.didUpdateWidget(oldWidget);

    // โหลดรายการร้านใหม่ → กลับไปร้านแรก แล้วเริ่มนับเวลาใหม่
    if (!identical(oldWidget.shops, widget.shops)) {
      currentPage = 0;

      if (pageController.hasClients) {
        pageController.jumpToPage(0);
      }

      startAutoSlide();
    }
  }

  void startAutoSlide() {
    timer?.cancel();

    if (widget.shops.length < 2) return;

    timer = Timer.periodic(slideInterval, (_) {
      // แบนเนอร์ยังไม่พร้อม (ยังไม่ได้วาด) → ข้ามรอบนี้ไปก่อน
      if (!mounted ||
          !pageController.hasClients ||
          !pageController.position.hasContentDimensions) {
        return;
      }

      final int count = widget.shops.length;

      if (count < 2) return;

      final int page = pageController.page?.round() ?? currentPage;

      final int next = (page + 1) % count;

      pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final int count = widget.shops.length;

    return Column(
      children: [
        SizedBox(
          height: 214,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // ผู้ใช้เริ่มปัดเอง → หยุดเลื่อนอัตโนมัติ / ปัดเสร็จ → เริ่มนับใหม่
              if (notification is ScrollStartNotification &&
                  notification.dragDetails != null) {
                timer?.cancel();
              } else if (notification is ScrollEndNotification) {
                startAutoSlide();
              }

              return false;
            },
            child: PageView.builder(
              controller: pageController,
              itemCount: count,
              onPageChanged: (page) {
                setState(() {
                  currentPage = page;
                });
              },
              itemBuilder: (context, index) {
                return _FeaturedShopCard(
                  shop: widget.shops[index],
                  onTap: () {
                    final int? id = (widget.shops[index]['id'] as num?)
                        ?.toInt();

                    if (id != null) widget.onOpenShop(id);
                  },
                );
              },
            ),
          ),
        ),
        if (count > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 0; i < count; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == currentPage ? 18 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: i == currentPage
                        ? AppColors.primary
                        : AppColors.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    pageController.dispose();

    super.dispose();
  }
}

class _FeaturedShopCard extends StatelessWidget {
  final Map<String, dynamic> shop;
  final VoidCallback onTap;

  const _FeaturedShopCard({required this.shop, required this.onTap});

  List<String> previewImages() {
    final dynamic images = shop['preview_images'];

    if (images is! List) return const [];

    return images
        .map((url) => url?.toString() ?? '')
        .where((url) => url.isNotEmpty)
        .take(3)
        .toList();
  }

  Widget buildImages() {
    final List<String> urls = previewImages();

    // ยังไม่มีสินค้า → พื้นหลังสีตลาดแทนรูป
    if (urls.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.softWarm, AppColors.softWarm],
          ),
        ),
        child: Center(
          child: Icon(Icons.storefront_rounded, color: AppColors.market, size: 46),
        ),
      );
    }

    return Row(
      children: [
        for (int i = 0; i < urls.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: Image.network(
              urls[i],
              fit: BoxFit.cover,
              height: double.infinity,
              cacheWidth: 500,
              loadingBuilder: (context, child, progress) {
                return progress == null
                    ? child
                    : ColoredBox(color: AppColors.fill);
              },
              errorBuilder: (context, error, stackTrace) {
                return ColoredBox(color: AppColors.fill);
              },
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? logoUrl = shop['logo_url']?.toString();

    final MarketCategory? category = findMarketCategory(shop['category']);

    final String subtitle = [
      if (category != null) category.label,
      shopArea(shop),
    ].where((part) => part.isNotEmpty).join(' • ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                // รูปสินค้าของร้าน + ป้าย ★ แนะนำ มุมซ้ายบน
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      buildImages(),
                      const Positioned(
                        left: 10,
                        top: 10,
                        child: FeaturedProductBadge(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: AppColors.softPrimary,
                        foregroundImage: logoUrl != null
                            ? NetworkImage(logoUrl)
                            : null,
                        child: Icon(
                          Icons.storefront_rounded,
                          color: AppColors.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shop['name']?.toString() ?? '',
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
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: onTap,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          minimumSize: const Size(0, 38),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          side: BorderSide(
                            color: AppColors.primary.withValues(alpha: 0.45),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('ดูร้าน'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
