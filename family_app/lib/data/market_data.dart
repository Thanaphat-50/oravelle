import 'package:flutter/material.dart';

// =======================================================
// ข้อมูลตลาดที่ใช้ร่วมกันหลายหน้า
// ต้องตรงกับ config/market.php ใน Laravel
// =======================================================


class MarketCategory {
  final String key;
  final String label;
  final IconData icon;

  const MarketCategory({
    required this.key,
    required this.label,
    required this.icon,
  });
}

// หมวดของร้านและสินค้า
const List<MarketCategory> marketCategories = [
  MarketCategory(key: 'food', label: 'อาหาร', icon: Icons.restaurant_rounded),
  MarketCategory(key: 'produce', label: 'ผักผลไม้', icon: Icons.eco_rounded),
  MarketCategory(
    key: 'household',
    label: 'ของใช้ในบ้าน',
    icon: Icons.chair_outlined,
  ),
  MarketCategory(
    key: 'clothing',
    label: 'เสื้อผ้า',
    icon: Icons.checkroom_rounded,
  ),
  MarketCategory(
    key: 'service',
    label: 'บริการ',
    icon: Icons.handyman_outlined,
  ),
  MarketCategory(
    key: 'souvenir',
    label: 'ของฝาก',
    icon: Icons.card_giftcard_rounded,
  ),
  MarketCategory(key: 'other', label: 'อื่น ๆ', icon: Icons.category_outlined),
];

MarketCategory? findMarketCategory(dynamic key) {
  for (final category in marketCategories) {
    if (category.key == key) {
      return category;
    }
  }

  return null;
}

// จังหวัดทั้งหมด 77 จังหวัด
const List<String> thaiProvinces = [
  'กรุงเทพมหานคร',
  'กระบี่',
  'กาญจนบุรี',
  'กาฬสินธุ์',
  'กำแพงเพชร',
  'ขอนแก่น',
  'จันทบุรี',
  'ฉะเชิงเทรา',
  'ชลบุรี',
  'ชัยนาท',
  'ชัยภูมิ',
  'ชุมพร',
  'เชียงราย',
  'เชียงใหม่',
  'ตรัง',
  'ตราด',
  'ตาก',
  'นครนายก',
  'นครปฐม',
  'นครพนม',
  'นครราชสีมา',
  'นครศรีธรรมราช',
  'นครสวรรค์',
  'นนทบุรี',
  'นราธิวาส',
  'น่าน',
  'บึงกาฬ',
  'บุรีรัมย์',
  'ปทุมธานี',
  'ประจวบคีรีขันธ์',
  'ปราจีนบุรี',
  'ปัตตานี',
  'พระนครศรีอยุธยา',
  'พะเยา',
  'พังงา',
  'พัทลุง',
  'พิจิตร',
  'พิษณุโลก',
  'เพชรบุรี',
  'เพชรบูรณ์',
  'แพร่',
  'ภูเก็ต',
  'มหาสารคาม',
  'มุกดาหาร',
  'แม่ฮ่องสอน',
  'ยโสธร',
  'ยะลา',
  'ร้อยเอ็ด',
  'ระนอง',
  'ระยอง',
  'ราชบุรี',
  'ลพบุรี',
  'ลำปาง',
  'ลำพูน',
  'เลย',
  'ศรีสะเกษ',
  'สกลนคร',
  'สงขลา',
  'สตูล',
  'สมุทรปราการ',
  'สมุทรสงคราม',
  'สมุทรสาคร',
  'สระแก้ว',
  'สระบุรี',
  'สิงห์บุรี',
  'สุโขทัย',
  'สุพรรณบุรี',
  'สุราษฎร์ธานี',
  'สุรินทร์',
  'หนองคาย',
  'หนองบัวลำภู',
  'อ่างทอง',
  'อำนาจเจริญ',
  'อุดรธานี',
  'อุตรดิตถ์',
  'อุทัยธานี',
  'อุบลราชธานี',
];

// เหตุผลรายงานสินค้า/ร้าน (ตรงกับ market.report_reasons)
const Map<String, String> marketReportReasons = {
  'scam': 'หลอกลวง / โกง',
  'prohibited': 'สินค้าต้องห้าม / ผิดกฎหมาย',
  'fake': 'ของปลอม / ไม่ตรงปก',
  'inappropriate': 'ไม่เหมาะสม',
  'spam': 'สแปม',
  'other': 'อื่น ๆ',
};

// "บางนา, กรุงเทพมหานคร"
// วิธีรับสินค้า (ตรงกับ config('market.delivery_methods'))
class DeliveryMethod {
  final String key;
  final String label;
  final IconData icon;

  const DeliveryMethod({
    required this.key,
    required this.label,
    required this.icon,
  });
}

const List<DeliveryMethod> deliveryMethods = [
  DeliveryMethod(
    key: 'storefront',
    label: 'รับที่หน้าร้าน',
    icon: Icons.storefront_outlined,
  ),
  DeliveryMethod(
    key: 'meetup',
    label: 'นัดรับ',
    icon: Icons.handshake_outlined,
  ),
  DeliveryMethod(
    key: 'delivery',
    label: 'ส่งถึงบ้าน',
    icon: Icons.delivery_dining_outlined,
  ),
  DeliveryMethod(
    key: 'shipping',
    label: 'ส่งพัสดุ',
    icon: Icons.local_shipping_outlined,
  ),
];

DeliveryMethod? findDeliveryMethod(String key) {
  for (final method in deliveryMethods) {
    if (method.key == key) return method;
  }

  return null;
}

// วิธีรับเงินของร้าน (ตรงกับ config('market.payment_methods'))
// transfer = ผู้ซื้อโอนก่อนแล้วแนบสลิป
class PaymentMethod {
  final String key;
  final String label;
  final IconData icon;
  final bool transfer;
  final String hint;

  const PaymentMethod({
    required this.key,
    required this.label,
    required this.icon,
    required this.transfer,
    required this.hint,
  });
}

const List<PaymentMethod> paymentMethods = [
  PaymentMethod(
    key: 'promptpay',
    label: 'โอนพร้อมเพย์',
    icon: Icons.qr_code_2_rounded,
    transfer: true,
    hint: 'ผู้ซื้อสแกน QR ตามยอดรวม แล้วแนบสลิป',
  ),
  PaymentMethod(
    key: 'bank',
    label: 'โอนเข้าบัญชีธนาคาร',
    icon: Icons.account_balance_outlined,
    transfer: true,
    hint: 'ผู้ซื้อโอนเข้าเลขบัญชีของร้าน แล้วแนบสลิป',
  ),
  PaymentMethod(
    key: 'cod',
    label: 'เก็บเงินปลายทาง',
    icon: Icons.local_atm_rounded,
    transfer: false,
    hint: 'ใช้กับส่งพัสดุ / ส่งถึงบ้าน',
  ),
  PaymentMethod(
    key: 'cash',
    label: 'จ่ายเงินสดตอนรับของ',
    icon: Icons.payments_outlined,
    transfer: false,
    hint: 'ใช้กับรับที่หน้าร้าน / นัดรับ',
  ),
];

PaymentMethod? findPaymentMethod(String key) {
  for (final method in paymentMethods) {
    if (method.key == key) return method;
  }

  return null;
}

// ธนาคารที่ร้านเลือกได้ (ตรงกับ config('market.banks'))
const List<String> thaiBanks = [
  'ธนาคารกสิกรไทย',
  'ธนาคารไทยพาณิชย์',
  'ธนาคารกรุงเทพ',
  'ธนาคารกรุงไทย',
  'ธนาคารกรุงศรีอยุธยา',
  'ธนาคารทหารไทยธนชาต (ttb)',
  'ธนาคารออมสิน',
  'ธนาคารเพื่อการเกษตรและสหกรณ์การเกษตร (ธ.ก.ส.)',
  'ธนาคารอาคารสงเคราะห์',
  'ธนาคารยูโอบี',
  'ธนาคารซีไอเอ็มบี ไทย',
  'ธนาคารเกียรตินาคินภัทร',
  'ธนาคารแลนด์ แอนด์ เฮ้าส์',
  'ธนาคารทิสโก้',
  'ธนาคารอิสลามแห่งประเทศไทย',
];

// =======================================================
// สถานะคำสั่งซื้อ (ป้ายสี)
// =======================================================

ShopStatusStyle orderStatusStyle(dynamic status) {
  switch (status) {
    case 'awaiting_payment':
      return const ShopStatusStyle(
        label: 'รอชำระเงิน',
        color: Color(0xFFDC6803),
        icon: Icons.payments_outlined,
      );
    case 'payment_review':
      return const ShopStatusStyle(
        label: 'รอตรวจสอบการชำระเงิน',
        color: Color(0xFFDC6803),
        icon: Icons.receipt_long_rounded,
      );
    case 'preparing':
      return const ShopStatusStyle(
        label: 'รอร้านจัดส่ง',
        color: Color(0xFF2E90FA),
        icon: Icons.inventory_2_outlined,
      );
    case 'shipped':
      return const ShopStatusStyle(
        label: 'ส่งสินค้าแล้ว',
        color: Color(0xFF7A5AF8),
        icon: Icons.local_shipping_outlined,
      );
    case 'completed':
      return const ShopStatusStyle(
        label: 'สำเร็จ',
        color: Color(0xFF12B76A),
        icon: Icons.check_circle_rounded,
      );
    default:
      return const ShopStatusStyle(
        label: 'ยกเลิกแล้ว',
        color: Color(0xFF98A2B3),
        icon: Icons.cancel_outlined,
      );
  }
}

String shopArea(dynamic shop) {
  if (shop is! Map) return '';

  return [
    shop['district']?.toString() ?? '',
    shop['province']?.toString() ?? '',
  ].where((part) => part.trim().isNotEmpty).join(', ');
}

// =======================================================
// ราคา: "฿1,250" / "฿35.50" / ไม่มีราคา = "สอบถามราคา"
// =======================================================

// วันเวลาจาก Laravel (ISO 8601) → "18/11/2026 14:30 น." (null / ผิดรูปแบบ → '')
String formatDateTime(dynamic value, {bool withTime = true}) {
  final DateTime? time = DateTime.tryParse(value?.toString() ?? '')?.toLocal();

  if (time == null) return '';

  String two(int n) => n.toString().padLeft(2, '0');

  final String date = '${two(time.day)}/${two(time.month)}/${time.year}';

  return withTime ? '$date ${two(time.hour)}:${two(time.minute)} น.' : date;
}

// "เปิดร้านมาแล้ว 3 เดือน" / "สมาชิกมา 1 ปี"
String durationSince(dynamic value) {
  final DateTime? time = DateTime.tryParse(value?.toString() ?? '')?.toLocal();

  if (time == null) return '';

  final int days = DateTime.now().difference(time).inDays;

  if (days >= 365) return '${days ~/ 365} ปี';
  if (days >= 30) return '${days ~/ 30} เดือน';
  if (days >= 1) return '$days วัน';

  return 'วันนี้';
}

String formatPrice(dynamic price) {
  final double? value = price is num
      ? price.toDouble()
      : double.tryParse('${price ?? ''}');

  if (value == null) {
    return 'สอบถามราคา';
  }

  final bool whole = value == value.roundToDouble();

  final String fixed = value.toStringAsFixed(whole ? 0 : 2);

  final List<String> parts = fixed.split('.');

  final String digits = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (match) => ',',
  );

  return '฿$digits${parts.length > 1 ? '.${parts[1]}' : ''}';
}

// =======================================================
// สถานะร้าน
// =======================================================

class ShopStatusStyle {
  final String label;
  final Color color;
  final IconData icon;

  const ShopStatusStyle({
    required this.label,
    required this.color,
    required this.icon,
  });
}

ShopStatusStyle shopStatusStyle(dynamic status) {
  switch (status) {
    case 'active':
      return const ShopStatusStyle(
        label: 'เปิดขาย',
        color: Color(0xFF12B76A),
        icon: Icons.check_circle_rounded,
      );
    case 'rejected':
      return const ShopStatusStyle(
        label: 'ไม่ผ่าน',
        color: Color(0xFFE5484D),
        icon: Icons.error_rounded,
      );
    case 'suspended':
      return const ShopStatusStyle(
        label: 'ถูกระงับ',
        color: Color(0xFFE5484D),
        icon: Icons.block_rounded,
      );
    default:
      return const ShopStatusStyle(
        label: 'รออนุมัติ',
        color: Color(0xFFDC6803),
        icon: Icons.hourglass_top_rounded,
      );
  }
}
