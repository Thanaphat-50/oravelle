import 'package:flutter/material.dart';

import '../services/cart_service.dart';
import '../theme/app_theme.dart';
import '../widgets/market_sheets.dart';

// =======================================================
// เพิ่ม / แก้ไขที่อยู่จัดส่ง
// address = null → เพิ่มใหม่ (ที่อยู่แรกเป็นที่อยู่หลักเอง)
// บันทึกแล้ว pop กลับพร้อมที่อยู่ที่บันทึก
// =======================================================

class AddressFormPage extends StatefulWidget {
  final Map<String, dynamic>? address;

  const AddressFormPage({super.key, this.address});

  @override
  State<AddressFormPage> createState() => _AddressFormPageState();
}

class _AddressFormPageState extends State<AddressFormPage> {
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  late final TextEditingController nameController = text('recipient_name');
  late final TextEditingController phoneController = text('phone');
  late final TextEditingController lineController = text('address_line');
  late final TextEditingController subdistrictController = text('subdistrict');
  late final TextEditingController districtController = text('district');
  late final TextEditingController postcodeController = text('postcode');

  late String? province = widget.address?['province']?.toString();

  late bool isDefault = widget.address?['is_default'] == true;

  bool isSaving = false;

  Map<String, String> serverErrors = {};

  TextEditingController text(String key) =>
      TextEditingController(text: widget.address?[key]?.toString() ?? '');

  Future<void> save() async {
    FocusManager.instance.primaryFocus?.unfocus();

    setState(() => serverErrors = {});

    if (!(formKey.currentState?.validate() ?? false)) return;

    setState(() => isSaving = true);

    try {
      final result = await CartService.saveAddress(
        (widget.address?['id'] as num?)?.toInt(),
        {
          'recipient_name': nameController.text.trim(),
          'phone': phoneController.text.trim(),
          'address_line': lineController.text.trim(),
          'subdistrict': subdistrictController.text.trim(),
          'district': districtController.text.trim(),
          'province': province,
          'postcode': postcodeController.text.trim(),
          'is_default': isDefault,
        },
      );

      if (!mounted) return;

      if (result['status'] == true) {
        Navigator.of(context).pop(result['address']);
        return;
      }

      final dynamic errors = result['errors'];

      if (errors is Map) {
        setState(() {
          serverErrors = {
            for (final entry in errors.entries)
              entry.key.toString(): entry.value is List
                  ? (entry.value as List).first.toString()
                  : entry.value.toString(),
          };
        });
      }

      showMessage(result['message']?.toString() ?? 'บันทึกไม่สำเร็จ');
    } catch (e) {
      if (mounted) showMessage(e.toString());
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String? required(String? value, String message) =>
      (value ?? '').trim().isEmpty ? message : null;

  Widget field(
    TextEditingController controller,
    String label,
    String key,
    IconData icon, {
    TextInputType? keyboard,
    int? maxLength,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboard,
        maxLength: maxLength,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          errorText: serverErrors[key],
        ),
        validator: validator,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.address == null ? 'เพิ่มที่อยู่' : 'แก้ไขที่อยู่'),
      ),
      body: SafeArea(
        child: Form(
          key: formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              field(
                nameController,
                'ชื่อผู้รับ',
                'recipient_name',
                Icons.person_outline_rounded,
                maxLength: 100,
                validator: (v) => required(v, 'กรุณาใส่ชื่อผู้รับ'),
              ),
              field(
                phoneController,
                'เบอร์โทร',
                'phone',
                Icons.phone_outlined,
                keyboard: TextInputType.phone,
                validator: (value) {
                  final String digits = (value ?? '').replaceAll(
                    RegExp(r'[\s\-]'),
                    '',
                  );

                  if (digits.isEmpty) return 'กรุณาใส่เบอร์โทร';

                  return RegExp(r'^\+?[0-9]{8,19}$').hasMatch(digits)
                      ? null
                      : 'เบอร์โทรไม่ถูกต้อง';
                },
              ),
              field(
                lineController,
                'บ้านเลขที่ หมู่ ซอย ถนน',
                'address_line',
                Icons.home_outlined,
                maxLength: 255,
                validator: (v) => required(v, 'กรุณาใส่บ้านเลขที่ ซอย ถนน'),
              ),
              field(
                subdistrictController,
                'ตำบล / แขวง',
                'subdistrict',
                Icons.place_outlined,
                maxLength: 80,
                validator: (v) => required(v, 'กรุณาใส่ตำบล / แขวง'),
              ),
              field(
                districtController,
                'อำเภอ / เขต',
                'district',
                Icons.map_outlined,
                maxLength: 80,
                validator: (v) => required(v, 'กรุณาใส่อำเภอ / เขต'),
              ),
              FormField<String>(
                initialValue: province,
                validator: (_) => province == null ? 'กรุณาเลือกจังหวัด' : null,
                builder: (state) => InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () async {
                    FocusManager.instance.primaryFocus?.unfocus();

                    final String? picked = await showProvincePicker(
                      context,
                      selected: province,
                    );

                    if (picked == null || !mounted) return;

                    setState(() => province = picked);
                    state.didChange(picked);
                  },
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'จังหวัด',
                      prefixIcon: const Icon(Icons.location_city_outlined),
                      suffixIcon: const Icon(Icons.expand_more_rounded),
                      errorText: state.errorText ?? serverErrors['province'],
                    ),
                    isEmpty: province == null,
                    child: Text(
                      province ?? '',
                      style: TextStyle(color: AppColors.navy, fontSize: 15),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              field(
                postcodeController,
                'รหัสไปรษณีย์',
                'postcode',
                Icons.markunread_mailbox_outlined,
                keyboard: TextInputType.number,
                maxLength: 5,
                validator: (value) =>
                    RegExp(r'^[1-9][0-9]{4}$').hasMatch((value ?? '').trim())
                    ? null
                    : 'รหัสไปรษณีย์ต้องเป็นตัวเลข 5 หลัก',
              ),
              SwitchListTile(
                value: isDefault,
                onChanged: (value) => setState(() => isDefault = value),
                activeThumbColor: AppColors.market,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'ตั้งเป็นที่อยู่หลัก',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.market,
                  minimumSize: const Size(double.infinity, 54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: isSaving ? null : save,
                child: Text(isSaving ? 'กำลังบันทึก' : 'บันทึกที่อยู่'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    lineController.dispose();
    subdistrictController.dispose();
    districtController.dispose();
    postcodeController.dispose();

    super.dispose();
  }
}
