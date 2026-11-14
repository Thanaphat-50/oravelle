import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../services/market_service.dart';
import '../theme/app_theme.dart';
import '../widgets/featured_shops_banner.dart';
import '../widgets/market_sheets.dart';
import '../widgets/market_widgets.dart';
import '../widgets/shop_trust_widgets.dart';
import 'market_product_page.dart';

// =======================================================
// หน้าร้าน: ข้อมูลร้าน ปุ่มติดต่อ และสินค้าทั้งหมด
// =======================================================

class MarketShopPage extends StatefulWidget {
  final int shopId;

  const MarketShopPage({super.key, required this.shopId});

  @override
  State<MarketShopPage> createState() => _MarketShopPageState();
}

class _MarketShopPageState extends State<MarketShopPage> {
  Map<String, dynamic>? shop;
  List<Map<String, dynamic>> products = [];

  // รีวิวล่าสุด 3 รายการ + รีวิวของเรา
  List<Map<String, dynamic>> reviews = [];
  Map<String, dynamic>? myReview;

  bool isLoading = true;
  String? loadError;

  @override
  void initState() {
    super.initState();
    loadShop();
  }

  Future<void> loadShop() async {
    setState(() {
      isLoading = true;
      loadError = null;
    });

    try {
      final result = await MarketService.getMarketShop(widget.shopId);

      if (!mounted) return;

      if (result['status'] == true) {
        final dynamic raw = result['products'];

        setState(() {
          shop = Map<String, dynamic>.from(result['shop'] as Map);
          reviews = [
            for (final item in (result['reviews'] as List?) ?? const [])
              if (item is Map) Map<String, dynamic>.from(item),
          ];
          myReview = result['my_review'] is Map
              ? Map<String, dynamic>.from(result['my_review'])
              : null;
          products = raw is List
              ? raw
                    .whereType<Map>()
                    .map((item) => Map<String, dynamic>.from(item))
                    .toList()
              : [];
        });
      } else {
        setState(() {
          loadError = result['message']?.toString() ?? 'ไม่พบร้านนี้';
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

  Future<void> reportShop() async {
    final report = await showMarketReportSheet(context, title: 'รายงานร้านนี้');

    if (report == null || !mounted) return;

    try {
      final result = await MarketService.report(
        target: 'shops',
        id: widget.shopId,
        reason: report.reason,
        details: report.details,
      );

      if (mounted) {
        showMessage(result['message']?.toString() ?? 'ขอบคุณที่รายงาน');
      }
    } catch (e) {
      if (mounted) showMessage(e.toString());
    }
  }

  Future<void> openProduct(Map<String, dynamic> product) async {
    final int? id = (product['id'] as num?)?.toInt();

    if (id == null) return;

    final dynamic reported = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            MarketProductPage(productId: id, preview: product),
      ),
    );

    // รายงานสินค้าแล้ว → เอาออกจากหน้าร้าน
    if (reported == true && mounted) {
      setState(() {
        products.removeWhere((item) => item['id'] == product['id']);
      });
    }
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget buildHeader(Map<String, dynamic> data) {
    final String? logoUrl = data['logo_url']?.toString();

    final MarketCategory? category = findMarketCategory(data['category']);

    final String description = data['description']?.toString().trim() ?? '';

    final bool mine = data['is_mine'] == true;

    return Container(
      padding: const EdgeInsets.all(18),
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
              CircleAvatar(
                radius: 32,
                backgroundColor: AppColors.market.withValues(alpha: 0.10),
                foregroundImage: logoUrl != null ? NetworkImage(logoUrl) : null,
                child: Icon(
                  Icons.storefront_rounded,
                  color: AppColors.market,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data['name']?.toString() ?? '',
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (data['is_featured'] == true) ...[
                      const SizedBox(height: 4),
                      const FeaturedBadge(),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (category != null) category.label,
                        shopArea(data),
                      ].where((part) => part.isNotEmpty).join(' · '),
                      style: TextStyle(color: AppColors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              description,
              style: TextStyle(
                color: AppColors.subtle,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
          if (!mine) ...[
            const SizedBox(height: 16),
            ShopContactButtons(
              phone: data['phone']?.toString(),
              lineId: data['line_id']?.toString(),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? data = shop;

    return Scaffold(
      appBar: AppBar(
        title: Text(data?['name']?.toString() ?? 'ร้านค้า'),
        actions: [
          if (data != null && data['is_mine'] != true)
            PopupMenuButton<String>(
              tooltip: 'ตัวเลือก',
              onSelected: (value) {
                if (value == 'report') reportShop();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined, color: AppColors.danger),
                      SizedBox(width: 10),
                      Text('รายงานร้าน'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: isLoading && data == null
          ? const Center(child: CircularProgressIndicator())
          : loadError != null || data == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  loadError ?? 'ไม่พบร้านนี้',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.navy),
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: loadShop,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    sliver: SliverList.list(
                      children: [
                        buildHeader(data),
                        const SizedBox(height: 14),
                        ShopTrustCard(shop: data),
                        if (ShopDetailsCard.hasContent(data)) ...[
                          const SizedBox(height: 14),
                          ShopDetailsCard(shop: data),
                        ],
                        const SizedBox(height: 14),
                        ShopReviewsCard(
                          shopId: widget.shopId,
                          shopName: data['name']?.toString() ?? '',
                          shop: data,
                          reviews: reviews,
                          myReview: myReview,
                          onChanged: loadShop,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'สินค้าทั้งหมด (${products.length})',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (products.isEmpty)
                          Padding(
                            padding: EdgeInsets.symmetric(vertical: 30),
                            child: Center(
                              child: Text(
                                'ร้านนี้ยังไม่มีสินค้า',
                                style: TextStyle(color: AppColors.muted),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      data['is_mine'] == true ? 32 : 8,
                    ),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.68,
                          ),
                      itemCount: products.length,
                      itemBuilder: (context, index) {
                        final product = products[index];

                        return MarketProductCard(
                          product: product,
                          showShop: false,
                          onTap: () => openProduct(product),
                        );
                      },
                    ),
                  ),
                  if (data['is_mine'] != true)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      sliver: SliverToBoxAdapter(
                        child: Center(
                          child: TextButton.icon(
                            onPressed: reportShop,
                            icon: Icon(
                              Icons.flag_outlined,
                              color: AppColors.danger,
                            ),
                            label: Text(
                              'รายงานร้านนี้',
                              style: TextStyle(color: AppColors.danger),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
