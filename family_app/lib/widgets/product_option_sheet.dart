import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../theme/app_theme.dart';

// =======================================================
// แผ่นเลือกตัวเลือกสินค้าและจำนวน (กด "ซื้อเลย" / "เพิ่มลงตะกร้า")
// แสดงรูป ราคา จำนวนคงเหลือของตัวเลือกที่เลือก
// คืน null เมื่อปิดโดยไม่ยืนยัน
// =======================================================

typedef ProductChoice = ({int? variantId, int quantity});

Future<ProductChoice?> showProductOptionSheet(
  BuildContext context, {
  required Map<String, dynamic> product,
  required String confirmLabel,
}) {
  return showModalBottomSheet<ProductChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    builder: (context) =>
        _ProductOptionSheet(product: product, confirmLabel: confirmLabel),
  );
}

class _ProductOptionSheet extends StatefulWidget {
  final Map<String, dynamic> product;
  final String confirmLabel;

  const _ProductOptionSheet({
    required this.product,
    required this.confirmLabel,
  });

  @override
  State<_ProductOptionSheet> createState() => _ProductOptionSheetState();
}

class _ProductOptionSheetState extends State<_ProductOptionSheet> {
  late final List<Map<String, dynamic>> variants = [
    for (final item in (widget.product['variants'] as List?) ?? const [])
      if (item is Map) Map<String, dynamic>.from(item),
  ];

  // มีตัวเดียวที่ยังมีของ → เลือกให้เลย
  late Map<String, dynamic>? selected = () {
    final available = variants.where((v) => v['sold_out'] != true).toList();

    return available.length == 1 ? available.first : null;
  }();

  int quantity = 1;

  int get stock =>
      (selected != null ? selected!['stock'] : widget.product['stock'] as num?)
          ?.toInt() ??
      0;

  int get maxQuantity => stock.clamp(0, 99);

  dynamic get price =>
      selected != null ? selected!['price'] : widget.product['price'];

  bool get needsChoice => variants.isNotEmpty && selected == null;

  String? get imageUrl {
    final dynamic images = widget.product['images'];

    if (images is List && images.isNotEmpty && images.first is Map) {
      return (images.first as Map)['url']?.toString();
    }

    return widget.product['image_url']?.toString();
  }

  @override
  Widget build(BuildContext context) {
    final String optionName =
        widget.product['option_name']?.toString().trim().isNotEmpty == true
        ? widget.product['option_name'].toString()
        : 'ตัวเลือก';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: imageUrl == null
                        ? ColoredBox(color: AppColors.fill)
                        : Image.network(
                            imageUrl!,
                            fit: BoxFit.cover,
                            cacheWidth: 260,
                            errorBuilder: (context, error, stackTrace) =>
                                ColoredBox(color: AppColors.fill),
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatPrice(price),
                        style: TextStyle(
                          color: AppColors.market,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        needsChoice
                            ? 'เลือก$optionName'
                            : stock > 0
                            ? 'เหลือ $stock ชิ้น'
                            : 'สินค้าหมด',
                        style: TextStyle(
                          color: stock > 0 || needsChoice
                              ? AppColors.muted
                              : AppColors.danger,
                          fontSize: 13,
                        ),
                      ),
                      if (selected != null)
                        Text(
                          'เลือกแล้ว: ${selected!['name']}',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (variants.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                optionName,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.35,
                ),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final variant in variants)
                        ChoiceChip(
                          label: Text(
                            variant['sold_out'] == true
                                ? '${variant['name']} (หมด)'
                                : '${variant['name']}',
                          ),
                          selected: identical(selected, variant),
                          selectedColor: AppColors.market.withValues(alpha: 0.16),
                          onSelected: variant['sold_out'] == true
                              ? null
                              : (_) {
                                  setState(() {
                                    selected = variant;

                                    final int max =
                                        ((variant['stock'] as num?)?.toInt() ??
                                                1)
                                            .clamp(1, 99);

                                    if (quantity > max) quantity = max;
                                  });
                                },
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'จำนวน',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: quantity > 1
                      ? () => setState(() => quantity--)
                      : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '$quantity',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: !needsChoice && quantity < maxQuantity
                      ? () => setState(() => quantity++)
                      : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.market,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: needsChoice || stock <= 0
                  ? null
                  : () => Navigator.of(context).pop((
                      variantId: (selected?['id'] as num?)?.toInt(),
                      quantity: quantity,
                    )),
              child: Text(
                needsChoice ? 'กรุณาเลือก$optionName' : widget.confirmLabel,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
