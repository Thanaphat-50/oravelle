import 'package:flutter/material.dart';

import '../services/market_service.dart';
import '../theme/app_theme.dart';
import '../widgets/market_widgets.dart';
import 'market_product_page.dart';

// =======================================================
// สินค้าที่บันทึกไว้ (ปุ่มบุ๊กมาร์กในหน้าสินค้า)
// สินค้าที่ถูกซ่อน / ร้านปิด จะไม่แสดง
// =======================================================

class SavedProductsPage extends StatefulWidget {
  const SavedProductsPage({super.key});

  @override
  State<SavedProductsPage> createState() => _SavedProductsPageState();
}

class _SavedProductsPageState extends State<SavedProductsPage> {
  final List<Map<String, dynamic>> products = [];

  bool isLoading = true;
  bool isLoadingMore = false;
  bool hasMore = false;
  int page = 1;
  String? loadError;

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
      final result = await MarketService.getSavedProducts(page: nextPage);

      if (!mounted) return;

      if (result['status'] != true) {
        setState(() {
          loadError = result['message']?.toString() ?? 'โหลดไม่สำเร็จ';
        });
        return;
      }

      setState(() {
        if (!more) products.clear();

        for (final item in (result['products'] as List?) ?? const []) {
          if (item is Map) products.add(Map<String, dynamic>.from(item));
        }

        page = nextPage;
        hasMore = result['has_more'] == true;
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

  // กลับจากหน้าสินค้า → โหลดใหม่ (อาจกดเอาออกจากที่บันทึกแล้ว)
  Future<void> openProduct(Map<String, dynamic> product) async {
    final int? id = (product['id'] as num?)?.toInt();

    if (id == null) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            MarketProductPage(productId: id, preview: product),
      ),
    );

    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('สินค้าที่บันทึก')),
      body: RefreshIndicator(
        onRefresh: load,
        child: isLoading && products.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : products.isEmpty
            ? ListView(
                padding: const EdgeInsets.all(32),
                children: [
                  const SizedBox(height: 60),
                  Icon(
                    Icons.bookmark_border_rounded,
                    size: 46,
                    color: AppColors.market,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    loadError ?? 'ยังไม่มีสินค้าที่บันทึก\nกดไอคอนบุ๊กมาร์กในหน้าสินค้าเพื่อเก็บไว้ดูภายหลัง',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontWeight: FontWeight.w700,
                      height: 1.5,
                    ),
                  ),
                ],
              )
            : NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.metrics.extentAfter < 400) {
                    load(more: true);
                  }

                  return false;
                },
                child: GridView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.64,
                  ),
                  itemCount: products.length,
                  itemBuilder: (context, index) {
                    final product = products[index];

                    return MarketProductCard(
                      product: product,
                      onTap: () => openProduct(product),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
