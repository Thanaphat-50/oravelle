import 'dart:math';

import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../services/cart_service.dart';
import '../services/order_service.dart';
import '../theme/app_theme.dart';
import 'address_form_page.dart';
import 'addresses_page.dart';
import 'order_page.dart';
import 'orders_page.dart';

// =======================================================
// ทำการสั่งซื้อ (จาก "ซื้อเลย" หรือจากตะกร้า)
// ที่อยู่ → สินค้าแยกตามร้าน (วิธีรับ/วิธีจ่าย) → สรุปยอด → ยืนยัน
// - ราคาและค่าส่งมาจากเซิร์ฟเวอร์ทุกครั้ง
// - ราคา/สต็อกเปลี่ยนระหว่างนี้ → แจ้งให้ตรวจยอดใหม่ก่อนสั่ง
// - checkout_id เดียวต่อหน้า → กดซ้ำไม่เกิดคำสั่งซื้อซ้ำ
// =======================================================

class CheckoutPage extends StatefulWidget {
  // [{product_id, variant_id, quantity}]
  final List<Map<String, dynamic>> items;

  const CheckoutPage({super.key, required this.items});

  @override
  State<CheckoutPage> createState() => _CheckoutPageState();
}

class _CheckoutPageState extends State<CheckoutPage> {
  late final List<Map<String, dynamic>> items = [
    for (final item in widget.items) Map<String, dynamic>.from(item),
  ];

  final String checkoutId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();

  // shop_id → ข้อความฝากถึงร้าน
  final Map<int, TextEditingController> noteControllers = {};

  List<Map<String, dynamic>> groups = [];
  List<Map<String, dynamic>> unavailable = [];
  List<Map<String, dynamic>> addresses = [];

  // shop_id → วิธีรับสินค้า / วิธีจ่าย ที่เลือก
  final Map<int, String> delivery = {};
  final Map<int, String> payment = {};

  int? addressId;

  bool isLoading = true;
  bool isRefreshing = false;
  bool isSubmitting = false;
  String? loadError;

  @override
  void initState() {
    super.initState();
    load(first: true);
  }

  // =====================================================
  // โหลดหน้าสรุปจากเซิร์ฟเวอร์
  // =====================================================

  Future<void> load({bool first = false}) async {
    if (items.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }

    setState(() {
      if (first) {
        isLoading = true;
      } else {
        isRefreshing = true;
      }
      loadError = null;
    });

    try {
      final result = await OrderService.preview(items);

      if (!mounted) return;

      if (result['status'] == true) {
        applyPreview(result, first: first);
      } else {
        setState(() {
          loadError = result['message']?.toString() ?? 'โหลดไม่สำเร็จ';
        });
      }
    } catch (e) {
      if (mounted) setState(() => loadError = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
          isRefreshing = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> mapList(dynamic raw) {
    return raw is List
        ? raw.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
        : [];
  }

  void applyPreview(Map<String, dynamic> result, {bool first = false}) {
    setState(() {
      groups = mapList(result['groups']);
      unavailable = mapList(result['unavailable']);
      addresses = mapList(result['addresses']);

      // ที่อยู่ที่เลือกไว้ถูกลบ → ใช้ที่อยู่หลัก
      if (!addresses.any((a) => a['id'] == addressId)) {
        addressId = addresses.isEmpty
            ? null
            : (addresses.first['id'] as num?)?.toInt();
      }

      if (first) {
        final Map recipient = (result['recipient'] as Map?) ?? const {};

        nameController.text = recipient['name']?.toString() ?? '';
        phoneController.text = recipient['phone']?.toString() ?? '';
      }

      for (final group in groups) {
        final int shopId = shopIdOf(group);

        noteControllers.putIfAbsent(shopId, () => TextEditingController());

        final List methods = (group['delivery_methods'] as List?) ?? const [];

        // วิธีเดิมใช้ไม่ได้แล้ว → ล้าง / มีวิธีเดียว → เลือกให้
        if (!methods.any((m) => m is Map && m['key'] == delivery[shopId])) {
          delivery.remove(shopId);

          if (methods.length == 1) {
            delivery[shopId] = (methods.first as Map)['key'].toString();
          }
        }

        fixPayment(group);
      }
    });
  }

  int shopIdOf(Map<String, dynamic> group) =>
      ((group['shop'] as Map?)?['id'] as num?)?.toInt() ?? 0;

  Map<String, dynamic>? deliveryOption(Map<String, dynamic> group) {
    for (final option in mapList(group['delivery_methods'])) {
      if (option['key'] == delivery[shopIdOf(group)]) return option;
    }

    return null;
  }

  List<Map<String, dynamic>> paymentOptions(Map<String, dynamic> group) =>
      mapList(deliveryOption(group)?['payment_methods']);

  // วิธีจ่ายเดิมใช้กับวิธีรับใหม่ไม่ได้ → ล้าง / มีแบบเดียว → เลือกให้
  void fixPayment(Map<String, dynamic> group) {
    final int shopId = shopIdOf(group);
    final options = paymentOptions(group);

    if (!options.any((o) => o['key'] == payment[shopId])) {
      payment.remove(shopId);

      if (options.length == 1) {
        payment[shopId] = options.first['key'].toString();
      }
    }
  }

  // =====================================================
  // ยอดเงิน
  // =====================================================

  double groupItemsTotal(Map<String, dynamic> group) {
    double total = 0;

    for (final item in mapList(group['items'])) {
      if (item['problem'] != null) continue;

      total += double.tryParse('${item['subtotal'] ?? 0}') ?? 0;
    }

    return total;
  }

  double groupShipping(Map<String, dynamic> group) =>
      (deliveryOption(group)?['shipping_fee'] as num?)?.toDouble() ?? 0;

  double get itemsTotal =>
      groups.fold(0, (sum, group) => sum + groupItemsTotal(group));

  double get shippingTotal =>
      groups.fold(0, (sum, group) => sum + groupShipping(group));

  double get grandTotal => itemsTotal + shippingTotal;

  bool get needsAddress =>
      groups.any((group) => deliveryOption(group)?['needs_address'] == true);

  Map<String, dynamic>? get selectedAddress {
    for (final address in addresses) {
      if (address['id'] == addressId) return address;
    }

    return null;
  }

  List<Map<String, dynamic>> get problemItems => [
    ...unavailable,
    for (final group in groups)
      for (final item in mapList(group['items']))
        if (item['problem'] != null) item,
  ];

  // =====================================================
  // แก้จำนวน / เอาออก
  // =====================================================

  int indexOfItem(Map<String, dynamic> line) {
    return items.indexWhere(
      (item) =>
          item['product_id'] == line['product_id'] &&
          item['variant_id'] == line['variant_id'],
    );
  }

  Future<void> changeQuantity(Map<String, dynamic> line, int quantity) async {
    final int index = indexOfItem(line);

    if (index < 0) return;

    items[index]['quantity'] = quantity;

    await load();
  }

  Future<void> removeLine(Map<String, dynamic> line) async {
    final int index = indexOfItem(line);

    if (index >= 0) items.removeAt(index);

    // สินค้าที่ไม่มีขายแล้ว (ไม่รู้ product_id) → เอาตัวที่ไม่มีในหน้าสรุปออก
    if (index < 0 && line['product_id'] == null) {
      final Set known = {
        for (final group in groups)
          for (final item in mapList(group['items'])) item['product_id'],
      };

      items.removeWhere((item) => !known.contains(item['product_id']));
    }

    await load();
  }

  // =====================================================
  // ที่อยู่
  // =====================================================

  Future<void> chooseAddress() async {
    final dynamic picked = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AddressesPage(selectedId: addressId),
      ),
    );

    if (!mounted) return;

    if (picked is Map) addressId = (picked['id'] as num?)?.toInt();

    await load();
  }

  Future<void> addAddress() async {
    final dynamic saved = await Navigator.of(context)
        .push(MaterialPageRoute(builder: (context) => const AddressFormPage()));

    if (!mounted) return;

    if (saved is Map) addressId = (saved['id'] as num?)?.toInt();

    await load();
  }

  // =====================================================
  // สั่งซื้อ
  // =====================================================

  Future<void> submit() async {
    FocusManager.instance.primaryFocus?.unfocus();

    if (isSubmitting) return;

    if (problemItems.isNotEmpty) {
      showMessage('มีสินค้าที่สั่งไม่ได้ กรุณาเอาออกก่อน');
      return;
    }

    for (final group in groups) {
      final int shopId = shopIdOf(group);
      final String name = (group['shop'] as Map?)?['name']?.toString() ?? '';

      if (delivery[shopId] == null) {
        showMessage('กรุณาเลือกวิธีรับสินค้าของร้าน $name');
        return;
      }

      if (payment[shopId] == null) {
        showMessage('กรุณาเลือกวิธีชำระเงินของร้าน $name');
        return;
      }
    }

    if (needsAddress && selectedAddress == null) {
      showMessage('กรุณาเลือกที่อยู่จัดส่ง');
      return;
    }

    if (!needsAddress &&
        (nameController.text.trim().isEmpty ||
            phoneController.text.trim().isEmpty)) {
      showMessage('กรุณาใส่ชื่อและเบอร์โทรผู้รับ');
      return;
    }

    setState(() => isSubmitting = true);

    try {
      final result = await OrderService.placeOrder({
        'checkout_id': checkoutId,
        'items': items,
        'groups': [
          for (final group in groups)
            {
              'shop_id': shopIdOf(group),
              'delivery_method': delivery[shopIdOf(group)],
              'payment_method': payment[shopIdOf(group)],
              'note': noteControllers[shopIdOf(group)]?.text.trim(),
            },
        ],
        if (needsAddress) 'address_id': addressId,
        if (!needsAddress) 'recipient_name': nameController.text.trim(),
        if (!needsAddress) 'recipient_phone': phoneController.text.trim(),
        'expected_total': double.parse(grandTotal.toStringAsFixed(2)),
      });

      if (!mounted) return;

      final List<Map<String, dynamic>> orders = mapList(result['orders']);

      if (result['status'] == true && orders.isNotEmpty) {
        showMessage(result['message']?.toString() ?? 'สั่งซื้อแล้ว');

        CartService.refreshCount();

        final int? onlyId = orders.length == 1
            ? (orders.first['id'] as num?)?.toInt()
            : null;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => onlyId != null
                ? OrderPage(orderId: onlyId)
                : const OrdersPage(),
          ),
        );
        return;
      }

      // ราคา/สต็อกเปลี่ยน → แสดงยอดใหม่ให้ตรวจก่อน
      if (result['code'] == 'checkout_changed') {
        applyPreview(result);

        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('ข้อมูลสินค้าเปลี่ยน'),
            content: Text(
              '${result['message'] ?? ''}\nยอดชำระใหม่ ${formatPrice(grandTotal)}',
            ),
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.market),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('ตรวจสอบอีกครั้ง'),
              ),
            ],
          ),
        );
        return;
      }

      showMessage(result['message']?.toString() ?? 'สั่งซื้อไม่สำเร็จ');
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
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

  Widget card({required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: AppDecorations.cardBorder,
        boxShadow: AppDecorations.cardShadow,
      ),
      child: child,
    );
  }

  Widget label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.navy,
          fontSize: 14.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget buildAddress() {
    if (!needsAddress) {
      return card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            label('ผู้รับสินค้า'),
            TextField(
              controller: nameController,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: 'ชื่อผู้รับ',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'เบอร์โทร',
                helperText: 'ร้านใช้ติดต่อเรื่องคำสั่งซื้อนี้',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
          ],
        ),
      );
    }

    final Map<String, dynamic>? address = selectedAddress;

    return card(
      child: address == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label('ที่อยู่จัดส่ง'),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: AppColors.market),
                    onPressed: addAddress,
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('เพิ่มที่อยู่จัดส่ง'),
                  ),
                ),
              ],
            )
          : InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: chooseAddress,
              child: Row(
                children: [
                  Icon(Icons.location_on_rounded, color: AppColors.market),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${address['recipient_name']} · ${address['phone']}',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          address['full_address']?.toString() ?? '',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: AppColors.market),
                ],
              ),
            ),
    );
  }

  Widget buildLine(Map<String, dynamic> line) {
    final String? imageUrl = line['image_url']?.toString();
    final String? problem = line['problem']?.toString();
    final int quantity = (line['quantity'] as num?)?.toInt() ?? 1;
    final int max = (line['max_quantity'] as num?)?.toInt() ?? 1;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: 64,
              height: 64,
              child: imageUrl == null
                  ? ColoredBox(color: AppColors.fill)
                  : Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      cacheWidth: 200,
                      errorBuilder: (context, error, stackTrace) =>
                          ColoredBox(color: AppColors.fill),
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line['title']?.toString() ?? 'สินค้า',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (line['variant_name'] != null)
                  Text(
                    'ตัวเลือก: ${line['variant_name']}',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                const SizedBox(height: 4),
                if (problem != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          problem,
                          style: TextStyle(
                            color: AppColors.danger,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: isRefreshing ? null : () => removeLine(line),
                        child: const Text('เอาออก'),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          formatPrice(line['unit_price']),
                          style: TextStyle(
                            color: AppColors.market,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: isRefreshing
                            ? null
                            : quantity > 1
                            ? () => changeQuantity(line, quantity - 1)
                            : () => removeLine(line),
                        icon: Icon(
                          quantity > 1
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
                        onPressed: isRefreshing || quantity >= max
                            ? null
                            : () => changeQuantity(line, quantity + 1),
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
    );
  }

  Widget choice({
    required bool selected,
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? AppColors.market.withValues(alpha: 0.08)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: isSubmitting ? null : onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? AppColors.market : AppColors.border,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, color: selected ? AppColors.market : AppColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? AppColors.market : AppColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildGroup(Map<String, dynamic> group) {
    final int shopId = shopIdOf(group);
    final Map shop = (group['shop'] as Map?) ?? const {};

    final double shipping = groupShipping(group);

    return card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.storefront_rounded, color: AppColors.market),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  shop['name']?.toString() ?? '',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 18),
          for (final line in mapList(group['items'])) buildLine(line),
          const SizedBox(height: 8),
          label('วิธีรับสินค้า'),
          for (final option in mapList(group['delivery_methods']))
            choice(
              selected: delivery[shopId] == option['key'],
              icon:
                  findDeliveryMethod(option['key']?.toString() ?? '')?.icon ??
                  Icons.local_shipping_outlined,
              title: option['label']?.toString() ?? '',
              subtitle: option['needs_address'] == true
                  ? ((option['shipping_fee'] as num?) ?? 0) > 0
                        ? 'ค่าส่ง ${formatPrice(option['shipping_fee'])}'
                        : 'ส่งฟรี'
                  : 'ไม่มีค่าส่ง',
              onTap: () => setState(() {
                delivery[shopId] = option['key'].toString();
                fixPayment(group);
              }),
            ),
          if (delivery[shopId] != null) ...[
            const SizedBox(height: 6),
            label('วิธีชำระเงิน'),
            for (final option in paymentOptions(group))
              choice(
                selected: payment[shopId] == option['key'],
                icon:
                    findPaymentMethod(option['key']?.toString() ?? '')?.icon ??
                    Icons.payments_outlined,
                title: option['label']?.toString() ?? '',
                subtitle: option['transfer'] == true
                    ? 'สั่งแล้วโอนเข้าบัญชีร้าน แล้วแนบสลิปในคำสั่งซื้อ'
                    : 'จ่ายตอนได้รับสินค้า',
                onTap: () =>
                    setState(() => payment[shopId] = option['key'].toString()),
              ),
          ],
          TextField(
            controller: noteControllers[shopId],
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'ฝากถึงร้าน (ไม่บังคับ)',
              prefixIcon: Icon(Icons.sticky_note_2_outlined),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'สินค้า ${formatPrice(groupItemsTotal(group))}'
                  '${delivery[shopId] == null ? '' : ' · ค่าส่ง ${shipping > 0 ? formatPrice(shipping) : 'ไม่มี'}'}',
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ),
              Text(
                formatPrice(groupItemsTotal(group) + shipping),
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildUnavailable() {
    return card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'สินค้าที่ไม่มีขายแล้ว',
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          for (final line in unavailable) buildLine(line),
        ],
      ),
    );
  }

  Widget buildSummary() {
    Widget line(String text, String value, {bool bold = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: bold ? AppColors.navy : AppColors.muted,
                  fontSize: bold ? 15 : 13.5,
                  fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: bold ? AppColors.market : AppColors.navy,
                fontSize: bold ? 19 : 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    }

    return card(
      child: Column(
        children: [
          line('รวมค่าสินค้า', formatPrice(itemsTotal)),
          line(
            'ค่าจัดส่ง',
            shippingTotal > 0 ? formatPrice(shippingTotal) : 'ไม่มี',
          ),
          const Divider(height: 18),
          line('ยอดชำระทั้งหมด', formatPrice(grandTotal), bold: true),
          if (groups.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'สินค้าจาก ${groups.length} ร้าน จะแยกเป็น ${groups.length} คำสั่งซื้อ ชำระแยกแต่ละร้าน',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ทำการสั่งซื้อ')),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : loadError != null && groups.isEmpty
          ? Center(
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
                    OutlinedButton(
                      onPressed: () => load(first: true),
                      child: const Text('ลองอีกครั้ง'),
                    ),
                  ],
                ),
              ),
            )
          : Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                  children: [
                    buildAddress(),
                    if (unavailable.isNotEmpty) buildUnavailable(),
                    for (final group in groups) buildGroup(group),
                    buildSummary(),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.softWarm,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.shield_outlined,
                            color: AppColors.market,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'เงินโอนเข้าบัญชีร้านโดยตรง แอปไม่ได้รับเงินแทน '
                              'ระบบตรวจสลิปก่อนยืนยันว่าชำระแล้ว',
                              style: TextStyle(
                                color: AppColors.navy,
                                fontSize: 12.5,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (isRefreshing)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 3),
                  ),
              ],
            ),
      bottomNavigationBar: isLoading || groups.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.border)),
                ),
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.market,
                    minimumSize: const Size(double.infinity, 54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: isSubmitting || isRefreshing ? null : submit,
                  child: isSubmitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'ยืนยันคำสั่งซื้อ · ${formatPrice(grandTotal)}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
            ),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();

    for (final controller in noteControllers.values) {
      controller.dispose();
    }

    super.dispose();
  }
}
