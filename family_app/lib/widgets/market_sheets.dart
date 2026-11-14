import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../theme/app_theme.dart';
import 'community_sheets.dart' show showReportReasonSheet;

// =======================================================
// กฎผู้ขาย
// แสดงก่อนสมัครเปิดร้าน (และเปิดอ่านซ้ำได้)
// =======================================================

Future<void> showSellerRulesDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.market.withValues(alpha: 0.10),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.storefront_rounded,
            color: AppColors.market,
            size: 28,
          ),
        ),
        title: const Text('กฎผู้ขาย'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SellerRule(
                icon: Icons.verified_outlined,
                text: 'ขายสินค้าและบริการที่ถูกกฎหมายเท่านั้น',
              ),
              _SellerRule(
                icon: Icons.block_rounded,
                text:
                    'ห้ามขาย เครื่องดื่มแอลกอฮอล์ บุหรี่และบุหรี่ไฟฟ้า '
                    'ยาหรืออาหารเสริมที่ไม่มี อย. อาวุธ ของปลอม '
                    'สัตว์ป่า การพนัน และสินค้าสำหรับผู้ใหญ่',
              ),
              _SellerRule(
                icon: Icons.fact_check_outlined,
                text: 'รูป รายละเอียด และราคาต้องตรงกับสินค้าจริง',
              ),
              _SellerRule(
                icon: Icons.payments_outlined,
                text:
                    'แอปไม่ได้รับชำระเงินแทน ผู้ซื้อและร้าน'
                    'ตกลงการชำระเงินและการส่งของกันเอง',
              ),
              _SellerRule(
                icon: Icons.phone_in_talk_outlined,
                text: 'เบอร์โทรและ LINE ที่ใส่ จะแสดงให้ผู้ซื้อเห็น',
              ),
              SizedBox(height: 10),
              Text(
                'ร้านหรือสินค้าที่ถูกรายงานจะถูกตรวจสอบ '
                'และอาจถูกซ่อนหรือระงับ',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.market,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
            },
            child: const Text('เข้าใจแล้ว'),
          ),
        ],
      );
    },
  );
}

class _SellerRule extends StatelessWidget {
  final IconData icon;
  final String text;

  const _SellerRule({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.market),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =======================================================
// เลือกจังหวัด (มีช่องค้นหา)
// คืนชื่อจังหวัด / null ถ้าปิดไปเฉย ๆ
// =======================================================

// =======================================================
// รายงานร้าน / สินค้า: เลือกเหตุผล → เล่ารายละเอียด (ไม่บังคับ)
// คืน (reason, details) / ยกเลิก → null
// =======================================================

Future<({String reason, String details})?> showMarketReportSheet(
  BuildContext context, {
  required String title,
}) async {
  final String? reason = await showReportReasonSheet(
    context,
    title: title,
    reasons: marketReportReasons,
    note: 'เจ้าของร้านจะไม่รู้ว่าใครเป็นคนรายงาน ทีมงานจะได้รับแจ้งทันที',
  );

  if (reason == null || !context.mounted) return null;

  final TextEditingController controller = TextEditingController();

  final bool? send = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(marketReportReasons[reason] ?? 'รายงาน'),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: 1000,
        decoration: const InputDecoration(
          hintText: 'เล่าสิ่งที่เกิดขึ้น เช่น โอนเงินแล้วไม่ได้ของ (ไม่บังคับ)',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('ยกเลิก'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('ส่งรายงาน'),
        ),
      ],
    ),
  );

  final String details = controller.text.trim();

  // รอหน้าต่างปิดเสร็จก่อนค่อยทิ้ง Controller
  Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);

  return send == true ? (reason: reason, details: details) : null;
}

Future<String?> showProvincePicker(BuildContext context, {String? selected}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      return _ProvincePicker(selected: selected);
    },
  );
}

class _ProvincePicker extends StatefulWidget {
  final String? selected;

  const _ProvincePicker({this.selected});

  @override
  State<_ProvincePicker> createState() => _ProvincePickerState();
}

class _ProvincePickerState extends State<_ProvincePicker> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final List<String> provinces = thaiProvinces
        .where((province) => province.contains(query.trim()))
        .toList();

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Text(
                'เลือกจังหวัด',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (value) {
                  setState(() {
                    query = value;
                  });
                },
                decoration: InputDecoration(
                  hintText: 'ค้นหาจังหวัด',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: AppColors.fill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: provinces.isEmpty
                  ? Center(
                      child: Text(
                        'ไม่พบจังหวัดนี้',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    )
                  : ListView.builder(
                      itemCount: provinces.length,
                      itemBuilder: (context, index) {
                        final String province = provinces[index];

                        final bool selected = province == widget.selected;

                        return ListTile(
                          title: Text(
                            province,
                            style: TextStyle(
                              color: selected ? AppColors.market : AppColors.navy,
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                            ),
                          ),
                          trailing: selected
                              ? Icon(
                                  Icons.check_rounded,
                                  color: AppColors.market,
                                )
                              : null,
                          onTap: () {
                            Navigator.of(context).pop(province);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
