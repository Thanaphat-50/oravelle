import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/market_data.dart';
import '../services/market_service.dart';
import '../services/post_service.dart' show CommentMediaFile;
import '../theme/app_theme.dart';
import '../widgets/comment_media.dart' show pickShortVideo;
import '../widgets/market_sheets.dart';
import '../widgets/market_widgets.dart' show MarketVideoField;
import '../widgets/post_categories.dart';

// =======================================================
// สมัครเปิดร้าน / แก้ไขข้อมูลร้าน
// shop = null → สมัครใหม่
// สำเร็จแล้ว pop กลับพร้อมข้อมูลร้านล่าสุด
// =======================================================

class ShopFormPage extends StatefulWidget {
  final Map<String, dynamic>? shop;

  const ShopFormPage({super.key, this.shop});

  @override
  State<ShopFormPage> createState() => _ShopFormPageState();
}

class _ShopFormPageState extends State<ShopFormPage> {
  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  late final TextEditingController nameController = TextEditingController(
    text: initialText('name'),
  );
  late final TextEditingController descriptionController =
      TextEditingController(text: initialText('description'));
  late final TextEditingController phoneController = TextEditingController(
    text: initialText('phone'),
  );
  late final TextEditingController lineController = TextEditingController(
    text: initialText('line_id'),
  );
  late final TextEditingController districtController = TextEditingController(
    text: initialText('district'),
  );

  late final TextEditingController hoursController = TextEditingController(
    text: initialText('opening_hours'),
  );

  late final TextEditingController shipDaysController = TextEditingController(
    text: initialText('ship_within_days'),
  );

  // วิธีรับสินค้าที่เลือก (key ตาม deliveryMethods)
  late final Set<String> delivery = {
    for (final method
        in (widget.shop?['delivery_methods'] as List?) ?? const [])
      method.toString(),
  };

  // วิธีรับเงิน (key ตาม paymentMethods) + บัญชีรับเงินของร้าน
  late final Set<String> payments = {
    for (final method in (widget.shop?['payment_methods'] as List?) ?? const [])
      method.toString(),
  };

  late final TextEditingController promptPayController = TextEditingController(
    text: initialText('promptpay_id'),
  );
  late final TextEditingController accountNumberController =
      TextEditingController(text: initialText('bank_account_number'));
  late final TextEditingController accountNameController =
      TextEditingController(text: initialText('bank_account_name'));

  late String? bankName = thaiBanks.contains(widget.shop?['bank_name'])
      ? widget.shop!['bank_name'].toString()
      : null;

  bool get usesPromptPay => payments.contains('promptpay');
  bool get usesBank => payments.contains('bank');

  // รูปหน้าร้าน: รูปเดิม ({id, url}) / รูปเดิมที่เอาออก / รูปใหม่
  static const int maxPhotos = 5;

  late final List<Map<String, dynamic>> keptPhotos = [
    for (final image in (widget.shop?['images'] as List?) ?? const [])
      if (image is Map) Map<String, dynamic>.from(image),
  ];
  final List<int> removedPhotoIds = [];
  final List<XFile> newPhotos = [];

  // วิดีโอแนะนำร้าน
  CommentMediaFile? newVideo;
  bool removeVideo = false;
  bool isPickingVideo = false;

  late final String? existingVideoThumbnail = widget
      .shop?['video_thumbnail_url']
      ?.toString();
  late final bool hadVideo = widget.shop?['video_url'] != null;

  bool get mediaChanged =>
      newPhotos.isNotEmpty ||
      removedPhotoIds.isNotEmpty ||
      newVideo != null ||
      removeVideo;

  int get photoCount => keptPhotos.length + newPhotos.length;

  late String? category = widget.shop?['category']?.toString();
  late String? province = widget.shop?['province']?.toString();

  // โลโก้: รูปใหม่ที่เลือก / ลิงก์รูปเดิม / กดลบรูปเดิม
  XFile? pickedLogo;
  late String? currentLogoUrl = widget.shop?['logo_url']?.toString();
  bool removeLogo = false;

  bool acceptedRules = false;
  bool isSaving = false;

  // ข้อความ Error จาก Laravel แยกตามช่อง
  Map<String, String> serverErrors = {};

  bool get isNew => widget.shop == null;

  bool get isRejected => widget.shop?['status'] == 'rejected';

  String initialText(String key) {
    final dynamic value = widget.shop?[key];

    return value == null ? '' : value.toString();
  }

  // =====================================================
  // โลโก้
  // =====================================================

  // ปิดคีย์บอร์ดก่อนเปิดหน้าต่างอื่น
  // ใช้ primaryFocus.unfocus() เพื่อไม่ให้ Flutter คืนโฟกัส
  // กลับไปที่ช่องพิมพ์เดิมหลังปิดหน้าต่าง
  void dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> pickLogo() async {
    dismissKeyboard();

    try {
      final XFile? image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        imageQuality: 85,
      );

      if (image == null || !mounted) return;

      setState(() {
        pickedLogo = image;
        removeLogo = false;
      });
    } catch (_) {
      showMessage('เลือกรูปไม่สำเร็จ กรุณาลองอีกครั้ง');
    }
  }

  void clearLogo() {
    setState(() {
      pickedLogo = null;
      currentLogoUrl = null;
      removeLogo = true;
    });
  }

  // =====================================================
  // รูปหน้าร้าน + วิดีโอแนะนำร้าน
  // =====================================================

  Future<void> pickPhotos() async {
    dismissKeyboard();

    final int remaining = maxPhotos - photoCount;

    if (remaining <= 0) return;

    try {
      final List<XFile> images = await ImagePicker().pickMultiImage(
        maxWidth: 1600,
        imageQuality: 85,
        limit: remaining > 1 ? remaining : null,
      );

      if (images.isEmpty || !mounted) return;

      setState(() => newPhotos.addAll(images.take(remaining)));
    } catch (_) {
      showMessage('เลือกรูปไม่สำเร็จ กรุณาลองอีกครั้ง');
    }
  }

  Future<void> pickVideo() async {
    dismissKeyboard();

    final CommentMediaFile? picked = await pickShortVideo(
      context,
      onBusy: (busy) {
        if (mounted) setState(() => isPickingVideo = busy);
      },
    );

    if (picked == null || !mounted) return;

    setState(() {
      newVideo = picked;
      removeVideo = false;
    });
  }

  // บันทึกข้อมูลร้านแล้ว → ส่งรูป/วิดีโอ (คืนข้อมูลร้านล่าสุด / null ถ้าไม่สำเร็จ)
  Future<dynamic> saveMedia() async {
    try {
      final result = await MarketService.updateShopMedia(
        newImagePaths: newPhotos.map((photo) => photo.path).toList(),
        removeImageIds: removedPhotoIds,
        video: newVideo,
        removeVideo: removeVideo,
      );

      if (result['status'] == true) return result['shop'];

      showMessage(
        result['message']?.toString() ?? 'บันทึกรูปหรือวิดีโอไม่สำเร็จ',
      );
    } catch (e) {
      showMessage('บันทึกรูปหรือวิดีโอไม่สำเร็จ: $e');
    }

    return null;
  }

  // =====================================================
  // บันทึก
  // =====================================================

  Future<void> submit() async {
    dismissKeyboard();

    setState(() {
      serverErrors = {};
    });

    final bool valid = formKey.currentState?.validate() ?? false;

    if (!valid) return;

    if (category == null) {
      showMessage('กรุณาเลือกหมวดของร้าน');
      return;
    }

    if (isNew && !acceptedRules) {
      showMessage('กรุณายอมรับกฎผู้ขายก่อนเปิดร้าน');
      return;
    }

    setState(() {
      isSaving = true;
    });

    try {
      final result = await MarketService.saveShop(
        isNew: isNew,
        fields: {
          'name': nameController.text.trim(),
          'description': descriptionController.text.trim(),
          'category': category!,
          'phone': phoneController.text.trim(),
          'line_id': lineController.text.trim(),
          'province': province ?? '',
          'district': districtController.text.trim(),
          'opening_hours': hoursController.text.trim(),
          'ship_within_days': shipDaysController.text.trim(),
          'promptpay_id': promptPayController.text.trim(),
          'bank_name': bankName ?? '',
          'bank_account_number': accountNumberController.text.trim(),
          'bank_account_name': accountNameController.text.trim(),
        },
        deliveryMethods: [
          for (final method in deliveryMethods)
            if (delivery.contains(method.key)) method.key,
        ],
        paymentMethods: [
          for (final method in paymentMethods)
            if (payments.contains(method.key)) method.key,
        ],
        logoPath: pickedLogo?.path,
        removeLogo: removeLogo && pickedLogo == null,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        dynamic shop = result['shop'];

        // ข้อมูลร้านบันทึกแล้ว รูป/วิดีโอไม่สำเร็จก็ไม่ยกเลิก (แก้ทีหลังได้)
        if (mediaChanged) {
          shop = await saveMedia() ?? shop;
        }

        if (!mounted) return;

        showMessage(result['message']?.toString() ?? 'บันทึกแล้ว');

        Navigator.of(context).pop(shop);
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
      if (!mounted) return;

      showMessage(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          isSaving = false;
        });
      }
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

  // รูปหน้าร้าน: รูปเดิม + รูปใหม่ (กด × เพื่อเอาออก) + ช่องเพิ่มรูป
  Widget buildPhotos() {
    Widget tile({required Widget image, required VoidCallback onRemove}) {
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(width: 84, height: 84, child: image),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: GestureDetector(
              onTap: isSaving ? null : onRemove,
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final photo in keptPhotos)
          tile(
            image: Image.network(
              photo['url']?.toString() ?? '',
              fit: BoxFit.cover,
            ),
            onRemove: () {
              setState(() {
                keptPhotos.remove(photo);

                final dynamic id = photo['id'];

                if (id is num) removedPhotoIds.add(id.toInt());
              });
            },
          ),
        for (final photo in newPhotos)
          tile(
            image: Image.file(File(photo.path), fit: BoxFit.cover),
            onRemove: () => setState(() => newPhotos.remove(photo)),
          ),
        if (photoCount < maxPhotos)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: isSaving ? null : pickPhotos,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.fill,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(Icons.add_a_photo_outlined, color: AppColors.market),
            ),
          ),
      ],
    );
  }

  Widget buildLogoPicker() {
    final bool hasLogo = pickedLogo != null || currentLogoUrl != null;

    final ImageProvider? image = pickedLogo != null
        ? FileImage(File(pickedLogo!.path))
        : currentLogoUrl != null
        ? NetworkImage(currentLogoUrl!)
        : null;

    return Column(
      children: [
        GestureDetector(
          onTap: isSaving ? null : pickLogo,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColors.market.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                  image: image != null
                      ? DecorationImage(image: image, fit: BoxFit.cover)
                      : null,
                ),
                child: image == null
                    ? Icon(
                        Icons.storefront_rounded,
                        color: AppColors.market,
                        size: 40,
                      )
                    : null,
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.market,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: const Icon(
                    Icons.photo_camera_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (hasLogo)
          TextButton(
            onPressed: isSaving ? null : clearLogo,
            child: const Text('เอาโลโก้ออก'),
          )
        else
          Text(
            'โลโก้ร้าน (ไม่บังคับ)',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
        if (serverErrors['logo'] != null)
          Text(
            serverErrors['logo']!,
            style: TextStyle(color: AppColors.danger, fontSize: 12),
          ),
      ],
    );
  }

  Widget buildSectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.navy,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget buildCategoryChips() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in marketCategories)
              CategoryChoiceChip(
                label: item.label,
                icon: item.icon,
                color: AppColors.market,
                selected: category == item.key,
                onTap: () {
                  setState(() {
                    category = item.key;
                  });
                },
              ),
          ],
        ),
        if (serverErrors['category'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              serverErrors['category']!,
              style: TextStyle(color: AppColors.danger, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget buildProvinceField() {
    return FormField<String>(
      initialValue: province,
      validator: (_) => province == null ? 'กรุณาเลือกจังหวัด' : null,
      builder: (field) {
        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: isSaving
              ? null
              : () async {
                  dismissKeyboard();

                  final String? picked = await showProvincePicker(
                    context,
                    selected: province,
                  );

                  if (picked == null || !mounted) return;

                  setState(() {
                    province = picked;
                  });

                  field.didChange(picked);
                },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'จังหวัด',
              prefixIcon: const Icon(Icons.location_city_outlined),
              suffixIcon: const Icon(Icons.expand_more_rounded),
              errorText: field.errorText ?? serverErrors['province'],
            ),
            isEmpty: province == null,
            child: Text(
              province ?? '',
              style: TextStyle(color: AppColors.navy, fontSize: 15),
            ),
          ),
        );
      },
    );
  }

  // วิธีรับเงิน → เปิดให้ลูกค้าสั่งซื้อในแอป
  Widget buildPayments() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'เลือกอย่างน้อย 1 แบบ ลูกค้าจึงกดสั่งซื้อในแอปได้ (ต้องเลือกวิธีรับสินค้าด้วย)',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        const SizedBox(height: 10),
        for (final method in paymentMethods)
          CheckboxListTile(
            value: payments.contains(method.key),
            onChanged: isSaving
                ? null
                : (checked) {
                    setState(() {
                      if (checked == true) {
                        payments.add(method.key);
                      } else {
                        payments.remove(method.key);
                      }
                    });
                  },
            activeColor: AppColors.market,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            secondary: Icon(method.icon, color: AppColors.market),
            title: Text(
              method.label,
              style: TextStyle(
                color: AppColors.navy,
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              method.hint,
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
        if (serverErrors['payment_methods'] != null)
          Text(
            serverErrors['payment_methods']!,
            style: TextStyle(color: AppColors.danger, fontSize: 12),
          ),
        if (usesPromptPay) ...[
          const SizedBox(height: 8),
          TextFormField(
            controller: promptPayController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'พร้อมเพย์ของร้าน',
              helperText: 'เบอร์มือถือ 10 หลัก หรือเลขบัตรประชาชน 13 หลัก',
              prefixIcon: const Icon(Icons.qr_code_2_rounded),
              errorText: serverErrors['promptpay_id'],
            ),
            validator: (value) {
              if (!usesPromptPay) return null;

              final String digits = (value ?? '').replaceAll(RegExp(r'\D'), '');

              final bool valid =
                  (digits.length == 10 && digits.startsWith('0')) ||
                  digits.length == 13;

              return valid ? null : 'ใส่เบอร์ 10 หลัก หรือเลข 13 หลัก';
            },
          ),
        ],
        if (usesBank) ...[
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            initialValue: bankName,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'ธนาคาร',
              prefixIcon: const Icon(Icons.account_balance_outlined),
              errorText: serverErrors['bank_name'],
            ),
            items: [
              for (final bank in thaiBanks)
                DropdownMenuItem(
                  value: bank,
                  child: Text(bank, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: isSaving
                ? null
                : (value) => setState(() => bankName = value),
            validator: (value) =>
                usesBank && value == null ? 'กรุณาเลือกธนาคาร' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: accountNumberController,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'เลขบัญชี',
              prefixIcon: const Icon(Icons.numbers_rounded),
              errorText: serverErrors['bank_account_number'],
            ),
            validator: (value) {
              if (!usesBank) return null;

              final int digits = (value ?? '')
                  .replaceAll(RegExp(r'\D'), '')
                  .length;

              return digits >= 10 && digits <= 15 ? null : 'เลขบัญชีไม่ถูกต้อง';
            },
          ),
        ],
        if (usesPromptPay || usesBank) ...[
          const SizedBox(height: 14),
          TextFormField(
            controller: accountNameController,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: 'ชื่อบัญชีผู้รับเงิน',
              helperText: 'ให้ลูกค้าเช็กก่อนโอนว่าชื่อตรงกัน',
              prefixIcon: const Icon(Icons.person_outline_rounded),
              errorText: serverErrors['bank_account_name'],
            ),
            validator: (value) =>
                (usesPromptPay || usesBank) && (value ?? '').trim().isEmpty
                ? 'กรุณาใส่ชื่อบัญชี'
                : null,
          ),
          const SizedBox(height: 4),
          Text(
            'ลูกค้าเห็นเลขบัญชีเฉพาะตอนต้องโอนเงินตามคำสั่งซื้อเท่านั้น '
            'เงินโอนเข้าบัญชีร้านโดยตรง',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget buildRulesAgreement() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      decoration: BoxDecoration(
        color: AppColors.market.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Checkbox(
            value: acceptedRules,
            activeColor: AppColors.market,
            onChanged: isSaving
                ? null
                : (value) {
                    setState(() {
                      acceptedRules = value ?? false;
                    });
                  },
          ),
          Expanded(
            child: Text(
              'ฉันยอมรับกฎผู้ขาย',
              style: TextStyle(
                color: AppColors.navy,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.market),
            onPressed: () {
              dismissKeyboard();

              showSellerRulesDialog(context);
            },
            child: const Text('อ่านกฎ'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String submitLabel = isNew
        ? 'ส่งคำขอเปิดร้าน'
        : isRejected
        ? 'แก้ไขแล้วส่งตรวจอีกครั้ง'
        : 'บันทึกข้อมูลร้าน';

    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'เปิดร้านใหม่' : 'แก้ไขข้อมูลร้าน')),
      body: SafeArea(
        child: Form(
          key: formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              if (isNew)
                Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: AppColors.softWarm,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    'เปิดร้านฟรีช่วงเปิดตัว ลงสินค้าได้ 30 ชิ้น '
                    'ร้านเปิดขายได้ทันที ระบบจะตรวจหาสินค้าต้องห้ามอัตโนมัติ',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
              Center(child: buildLogoPicker()),
              const SizedBox(height: 20),
              buildSectionLabel('ข้อมูลร้าน'),
              TextFormField(
                controller: nameController,
                maxLength: 80,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'ชื่อร้าน',
                  prefixIcon: const Icon(Icons.storefront_outlined),
                  errorText: serverErrors['name'],
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'กรุณาใส่ชื่อร้าน' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: descriptionController,
                maxLength: 1000,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'ขายอะไร / จุดเด่นของร้าน (ไม่บังคับ)',
                  alignLabelWithHint: true,
                  errorText: serverErrors['description'],
                ),
              ),
              const SizedBox(height: 12),
              buildSectionLabel('หมวดของร้าน'),
              buildCategoryChips(),
              const SizedBox(height: 24),
              buildSectionLabel('ช่องทางติดต่อ'),
              TextFormField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'เบอร์โทร',
                  prefixIcon: const Icon(Icons.phone_outlined),
                  errorText: serverErrors['phone'],
                ),
                validator: (value) {
                  final String digits = (value ?? '').replaceAll(
                    RegExp(r'[\s\-]'),
                    '',
                  );

                  if (digits.isEmpty) return 'กรุณาใส่เบอร์โทร';

                  if (!RegExp(r'^\+?[0-9]{8,19}$').hasMatch(digits)) {
                    return 'เบอร์โทรไม่ถูกต้อง';
                  }

                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: lineController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'LINE ID (ไม่บังคับ)',
                  prefixIcon: const Icon(Icons.chat_outlined),
                  errorText: serverErrors['line_id'],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'ผู้ซื้อจะเห็นเบอร์โทรและ LINE เมื่อร้านเปิดขาย',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 24),
              buildSectionLabel('พื้นที่ขาย'),
              buildProvinceField(),
              const SizedBox(height: 14),
              TextFormField(
                controller: districtController,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: 'อำเภอ / เขต (ไม่บังคับ)',
                  prefixIcon: const Icon(Icons.map_outlined),
                  errorText: serverErrors['district'],
                ),
              ),
              const SizedBox(height: 16),
              buildSectionLabel('เวลาเปิด-ปิด และวิธีรับสินค้า'),
              TextFormField(
                controller: hoursController,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: 'เวลาเปิด-ปิด (ไม่บังคับ)',
                  hintText: 'เช่น ทุกวัน 08:00–18:00',
                  prefixIcon: const Icon(Icons.schedule_rounded),
                  errorText: serverErrors['opening_hours'],
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final method in deliveryMethods)
                    FilterChip(
                      avatar: Icon(method.icon, size: 18),
                      label: Text(method.label),
                      selected: delivery.contains(method.key),
                      onSelected: isSaving
                          ? null
                          : (selected) {
                              setState(() {
                                if (selected) {
                                  delivery.add(method.key);
                                } else {
                                  delivery.remove(method.key);
                                }
                              });
                            },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: shipDaysController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'จัดส่งภายในกี่วันหลังชำระเงิน (ไม่บังคับ)',
                  hintText: 'เช่น 2',
                  helperText: 'ลูกค้าเห็นในหน้าสินค้า',
                  prefixIcon: const Icon(Icons.local_shipping_outlined),
                  errorText: serverErrors['ship_within_days'],
                ),
                validator: (value) {
                  final String text = (value ?? '').trim();

                  if (text.isEmpty) return null;

                  final int? days = int.tryParse(text);

                  return days == null || days < 1 || days > 30
                      ? 'ใส่ 1 – 30 วัน'
                      : null;
                },
              ),
              const SizedBox(height: 24),
              buildSectionLabel('วิธีรับเงิน'),
              buildPayments(),
              const SizedBox(height: 24),
              buildSectionLabel('รูปหน้าร้าน (ไม่เกิน $maxPhotos รูป)'),
              buildPhotos(),
              const SizedBox(height: 24),
              buildSectionLabel('วิดีโอแนะนำร้าน (ไม่บังคับ)'),
              MarketVideoField(
                hasNewVideo: newVideo != null,
                newThumbnailPath: newVideo?.thumbnailPath,
                showExisting: hadVideo && !removeVideo,
                existingThumbnailUrl: existingVideoThumbnail,
                busy: isPickingVideo,
                disabled: isSaving,
                onPick: pickVideo,
                onRemove: () {
                  setState(() {
                    newVideo = null;
                    removeVideo = hadVideo;
                  });
                },
              ),
              if (isNew) ...[const SizedBox(height: 12), buildRulesAgreement()],
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.market,
                  minimumSize: const Size(double.infinity, 54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: isSaving ? null : submit,
                icon: isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(isSaving ? 'กำลังบันทึก' : submitLabel),
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
    descriptionController.dispose();
    phoneController.dispose();
    lineController.dispose();
    districtController.dispose();
    hoursController.dispose();
    shipDaysController.dispose();
    promptPayController.dispose();
    accountNumberController.dispose();
    accountNameController.dispose();

    super.dispose();
  }
}
