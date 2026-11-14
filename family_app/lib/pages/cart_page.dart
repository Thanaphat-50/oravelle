import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../services/cart_service.dart';
import '../theme/app_theme.dart';
import 'checkout_page.dart';
import 'market_product_page.dart';
import 'orders_page.dart';

// =======================================================
// ตะกร้าสินค้า (แยกตามร้าน)
// ติ๊กเลือกสินค้าที่จะซื้อ → "สั่งซื้อ" ไปหน้าทำการสั่งซื้อ
// ราคา/สต็อกเป็นค่าปัจจุบันจากเซิร์ฟเวอร์ สินค้าที่สั่งไม่ได้แล้วขึ้นเหตุผลไว้
// =======================================================

class CartPage extends StatefulWidget {
  const CartPage({super.key});

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  List<Map<String, dynamic>> items = [];

  // cart item id ที่ติ๊กไว้
  final Set<int> selected = {};

  bool isLoading = true;
  String? loadError;

  // กำลังแก้จำนวน / ลบ
  final Set<int> busy = {};

  @override
  void initState() {
    super.initState();
    load(selectAll: true);
  }

  Future<void> load({bool selectAll = false}) async {
    setState(() => loadError = null);

    try {
      final result = await CartService.getCart();

      if (!mounted) return;

      setState(() {
        if (result['status'] == true) {
          items = [
            for (final item in (result['items'] as List?) ?? const [])
              if (item is Map) Map<String, dynamic>.from(item),
          ];

          final Set<int> ids = items.map(idOf).toSet();

          selected.removeWhere((id) => !ids.contains(id));

          // เปิดหน้าครั้งแรก → เลือกทุกชิ้นที่สั่งได้
          if (selectAll) {
            selected.addAll(items.where(orderable).map(idOf));
          }

          // สั่งไม่ได้แล้ว → เอาออกจากที่เลือก
          selected.removeWhere(
            (id) => !items.any((item) => idOf(item) == id && orderable(item)),
          );
        } else {
          loadError = result['message']?.toString() ?? 'โหลดตะกร้าไม่สำเร็จ';
        }
      });
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  int idOf(Map<String, dynamic> item) => (item['id'] as num?)?.toInt() ?? 0;

  bool orderable(Map<String, dynamic> item) => item['problem'] == null;

  // แยกตามร้าน (เรียงตามลำดับในตะกร้า)
  Map<int, List<Map<String, dynamic>>> get byShop {
    final Map<int, List<Map<String, dynamic>>> groups = {};

    for (final item in items) {
      final int shopId = ((item['shop'] as Map?)?['id'] as num?)?.toInt() ?? 0;

      groups.putIfAbsent(shopId, () => []).add(item);
    }

    return groups;
  }

  List<Map<String, dynamic>> get chosen => [
    for (final item in items)
      if (selected.contains(idOf(item)) && orderable(item)) item,
  ];

  double get total => chosen.fold(
    0,
    (sum, item) => sum + (double.tryParse('${item['subtotal'] ?? 0}') ?? 0),
  );

  int get chosenCount => chosen.fold(
    0,
    (sum, item) => sum + ((item['quantity'] as num?)?.toInt() ?? 0),
  );

  Future<void> setQuantity(Map<String, dynamic> item, int quantity) async {
    final int id = idOf(item);

    setState(() => busy.add(id));

    try {
      final result = await CartService.setQuantity(id, quantity);

      if (!mounted) return;

      if (result['status'] != true) {
        showMessage(result['message']?.toString() ?? 'แก้จำนวนไม่สำเร็จ');
      }

      await load();
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  Future<void> remove(Map<String, dynamic> item) async {
    final int id = idOf(item);

    setState(() => busy.add(id));

    try {
      await CartService.remove(id);

      if (!mounted) return;

      selected.remove(id);

      await load();
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  Future<void> checkout() async {
    final List<Map<String, dynamic>> lines = [
      for (final item in chosen)
        {
          'product_id': item['product_id'],
          'variant_id': item['variant_id'],
          'quantity': item['quantity'],
        },
    ];

    if (lines.isEmpty) return;

    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => CheckoutPage(items: lines)));

    if (mounted) await load();
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildItem(Map<String, dynamic> item) {
    final int id = idOf(item);
    final bool canOrder = orderable(item);
    final bool working = busy.contains(id);
    final int quantity = (item['quantity'] as num?)?.toInt() ?? 1;
    final int max = (item['max_quantity'] as num?)?.toInt() ?? quantity;
    final String? imageUrl = item['image_url']?.toString();
    final int? productId = (item['product_id'] as num?)?.toInt();

    return Opacity(
      opacity: working ? 0.5 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: canOrder && selected.contains(id),
              activeColor: AppColors.market,
              onChanged: !canOrder || working
                  ? null
                  : (checked) => setState(() {
                      if (checked == true) {
                        selected.add(id);
                      } else {
                        selected.remove(id);
                      }
                    }),
            ),
            GestureDetector(
              onTap: productId == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            MarketProductPage(productId: productId),
                      ),
                    ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: imageUrl == null
                      ? ColoredBox(color: AppColors.fill)
                      : Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          cacheWidth: 220,
                          errorBuilder: (context, error, stackTrace) =>
                              ColoredBox(color: AppColors.fill),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['title']?.toString() ?? 'สินค้า',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (item['variant_name'] != null)
                    Text(
                      'ตัวเลือก: ${item['variant_name']}',
                      style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                  if (!canOrder)
                    Text(
                      item['problem'].toString(),
                      style: TextStyle(
                        color: AppColors.danger,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          formatPrice(item['unit_price']),
                          style: TextStyle(
                            color: AppColors.market,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: quantity > 1 ? 'ลดจำนวน' : 'เอาออก',
                        onPressed: working
                            ? null
                            : quantity > 1 && canOrder
                            ? () => setQuantity(item, quantity - 1)
                            : () => remove(item),
                        icon: Icon(
                          quantity > 1 && canOrder
                              ? Icons.remove_circle_outline_rounded
                              : Icons.delete_outline_rounded,
                          color: AppColors.muted,
                        ),
                      ),
                      Text(
                        '$quantity',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'เพิ่มจำนวน',
                        onPressed: working || !canOrder || quantity >= max
                            ? null
                            : () => setQuantity(item, quantity + 1),
                        icon: Icon(
                          Icons.add_circle_outline_rounded,
                          color: AppColors.market,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildShop(List<Map<String, dynamic>> shopItems) {
    final Map shop = (shopItems.first['shop'] as Map?) ?? const {};

    final List<int> ids = shopItems.where(orderable).map(idOf).toList();

    final bool allSelected = ids.isNotEmpty && ids.every(selected.contains);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(4, 6, 10, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: AppDecorations.cardBorder,
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Checkbox(
                value: allSelected,
                activeColor: AppColors.market,
                onChanged: ids.isEmpty
                    ? null
                    : (checked) => setState(() {
                        if (checked == true) {
                          selected.addAll(ids);
                        } else {
                          selected.removeAll(ids);
                        }
                      }),
              ),
              Icon(
                Icons.storefront_rounded,
                color: AppColors.market,
                size: 20,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  shop['name']?.toString() ?? 'ร้านค้า',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          for (final item in shopItems) buildItem(item),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          items.isEmpty ? 'ตะกร้าสินค้า' : 'ตะกร้าสินค้า (${items.length})',
        ),
        actions: [
          IconButton(
            tooltip: 'คำสั่งซื้อของฉัน',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (context) => const OrdersPage())),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: items.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(32),
                      children: [
                        const SizedBox(height: 60),
                        Icon(
                          Icons.shopping_cart_outlined,
                          size: 52,
                          color: AppColors.market,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          loadError ?? 'ตะกร้ายังว่างอยู่\nกด "เพิ่มลงตะกร้า" ในหน้าสินค้า',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.navy,
                            fontWeight: FontWeight.w700,
                            height: 1.5,
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                      children: [
                        for (final shopItems in byShop.values)
                          buildShop(shopItems),
                      ],
                    ),
            ),
      bottomNavigationBar: items.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'รวม (ไม่รวมค่าส่ง)',
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            formatPrice(total),
                            style: TextStyle(
                              color: AppColors.market,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.market,
                        minimumSize: const Size(150, 52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: chosen.isEmpty ? null : checkout,
                      child: Text(
                        'สั่งซื้อ ($chosenCount)',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
