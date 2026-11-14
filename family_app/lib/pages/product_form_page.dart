import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/market_data.dart';
import '../services/market_service.dart';
import '../services/post_service.dart' show CommentMediaFile;
import '../theme/app_theme.dart';
import '../widgets/comment_media.dart' show pickShortVideo;
import '../widgets/market_widgets.dart' show MarketVideoField;
import '../widgets/post_categories.dart';
import 'promotion_page.dart';

// =======================================================
// เพิ่ม / แก้ไขสินค้า
// product = null → เพิ่มใหม่
// สำเร็จแล้ว pop กลับพร้อมข้อมูลสินค้าล่าสุด
// =======================================================

class ProductFormPage extends StatefulWidget {
  final Map<String, dynamic>? product;

  // หมวดเริ่มต้นของสินค้าใหม่ (ใช้หมวดของร้าน)
  final String? defaultCategory;

  // ร้านเปิดขายอยู่ → เลือกขึ้นช่องแนะนำต่อหลังบันทึกได้
  final bool canPromote;

  const ProductFormPage({
    super.key,
    this.product,
    this.defaultCategory,
    this.canPromote = false,
  });

  @override
  State<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<ProductFormPage> {
  // ตรงกับ Laravel: ชิ้นละไม่เกิน 5 รูป
  static const int maxImages = 5;

  final GlobalKey<FormState> formKey = GlobalKey<FormState>();

  late final TextEditingController titleController = TextEditingController(
    text: initialText('title'),
  );
  late final TextEditingController priceController = TextEditingController(
    text: initialPrice(),
  );
  late final TextEditingController descriptionController =
      TextEditingController(text: initialText('description'));

  // สินค้าใหม่เริ่มที่ 1 ชิ้น
  late final TextEditingController stockController = TextEditingController(
    text: widget.product?['stock']?.toString() ?? '1',
  );
  late final TextEditingController shippingController = TextEditingController(
    text: initialMoney('shipping_fee'),
  );

  // หน้าปกการ์ดในหน้าร้านค้า: image = รูปแรก / video = เล่นวิดีโอเอง
  // ตัวเลือกสินค้า (สี ขนาด รุ่น) แต่ละแบบมีราคา/สต็อกของตัวเอง
  late final TextEditingController optionNameController = TextEditingController(
    text: widget.product?['option_name']?.toString() ?? '',
  );

  late final List<_VariantRow> variantRows = [
    for (final item in (widget.product?['variants'] as List?) ?? const [])
      if (item is Map) _VariantRow.from(Map<String, dynamic>.from(item)),
  ];

  late String cardMedia = widget.product?['card_media'] == 'video'
      ? 'video'
      : 'image';

  late String? category =
      widget.product?['category']?.toString() ?? widget.defaultCategory;

  // รูปเดิมที่ยังเก็บไว้ ({id, url}) และรูปใหม่ที่เลือก
  late final List<Map<String, dynamic>> keptImages = [
    for (final image in (widget.product?['images'] as List?) ?? const [])
      if (image is Map) Map<String, dynamic>.from(image),
  ];
  final List<int> removedImageIds = [];
  final List<XFile> newImages = [];

  // วิดีโอแนะนำสินค้า (ใหม่ / ลบของเดิม)
  CommentMediaFile? newVideo;
  bool removeVideo = false;
  bool isPickingVideo = false;

  late final String? existingVideoThumbnail = widget
      .product?['video_thumbnail_url']
      ?.toString();
  late final bool hadVideo = widget.product?['video_url'] != null;

  // บันทึกแล้วไปหน้าชำระเงินช่องแนะนำต่อ
  bool promoteAfterSave = false;

  bool isSaving = false;

  Map<String, String> serverErrors = {};

  bool get isNew => widget.product == null;

  int get imageCount => keptImages.length + newImages.length;

  String initialText(String key) {
    final dynamic value = widget.product?[key];

    return value == null ? '' : value.toString();
  }

  String initialPrice() => initialMoney('price');

  // "35.00" → "35", "35.50" → "35.50"
  String initialMoney(String key) {
    final double? value = double.tryParse(initialText(key));

    if (value == null) return '';

    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }

  // มีวิดีโอ (ใหม่ หรือของเดิมที่ไม่ได้ลบ) → เลือกหน้าปกเป็นวิดีโอได้
  bool get hasVideo => newVideo != null || (hadVideo && !removeVideo);

  void dismissKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus();
  }

  // =====================================================
  // รูปสินค้า
  // =====================================================

  Future<void> pickImages() async {
    dismissKeyboard();

    final int remaining = maxImages - imageCount;

    if (remaining <= 0) {
      showMessage('สินค้าแต่ละชิ้นมีรูปได้สูงสุด $maxImages รูป');
      return;
    }

    try {
      final List<XFile> images = await ImagePicker().pickMultiImage(
        limit: remaining,
        maxWidth: 1600,
        imageQuality: 80,
      );

      if (!mounted || images.isEmpty) return;

      setState(() {
        newImages.addAll(images.take(remaining));
      });
    } catch (_) {
      showMessage('เลือกรูปไม่สำเร็จ กรุณาลองอีกครั้ง');
    }
  }

  void removeKeptImage(Map<String, dynamic> image) {
    final dynamic id = image['id'];

    setState(() {
      keptImages.remove(image);

      if (id is num) removedImageIds.add(id.toInt());
    });
  }

  // =====================================================
  // วิดีโอแนะนำสินค้า
  // =====================================================

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

  void clearVideo() {
    setState(() {
      newVideo = null;
      removeVideo = hadVideo;
    });
  }

  // บันทึกสินค้าสำเร็จแล้ว → อัปโหลด/ลบวิดีโอ (ไม่สำเร็จก็ไม่ยกเลิกสินค้า)
  Future<void> saveVideo(int productId) async {
    try {
      final CommentMediaFile? video = newVideo;

      final Map<String, dynamic>? result = video != null
          ? await MarketService.uploadProductVideo(productId, video)
          : removeVideo
          ? await MarketService.deleteProductVideo(productId)
          : null;

      if (result != null && result['status'] != true) {
        showMessage(result['message']?.toString() ?? 'บันทึกวิดีโอไม่สำเร็จ');
      }
    } catch (e) {
      showMessage('บันทึกวิดีโอไม่สำเร็จ: $e');
    }
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

    if (imageCount == 0) {
      showMessage('กรุณาเพิ่มรูปสินค้าอย่างน้อย 1 รูป');
      return;
    }

    if (category == null) {
      showMessage('กรุณาเลือกหมวดสินค้า');
      return;
    }

    setState(() {
      isSaving = true;
    });

    try {
      final dynamic id = widget.product?['id'];

      final result = await MarketService.saveProduct(
        productId: id is num ? id.toInt() : null,
        fields: {
          'title': titleController.text.trim(),
          'price': priceController.text.trim().replaceAll(',', ''),
          'description': descriptionController.text.trim(),
          'category': category!,
          'stock': stockController.text.trim(),
          'shipping_fee': shippingController.text.trim().replaceAll(',', ''),
          'card_media': hasVideo ? cardMedia : 'image',
          ...variantFields(),
        },
        newImagePaths: newImages.map((image) => image.path).toList(),
        removeImageIds: removedImageIds,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        final dynamic product = result['product'];

        final int? productId = product is Map
            ? (product['id'] as num?)?.toInt()
            : null;

        if (productId != null && (newVideo != null || removeVideo)) {
          await saveVideo(productId);
        }

        if (!mounted) return;

        showMessage(result['message']?.toString() ?? 'บันทึกสินค้าแล้ว');

        if (promoteAfterSave && productId != null) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (context) => PromotionPage(
                productId: productId,
                title: titleController.text.trim(),
              ),
            ),
          );
          return;
        }

        Navigator.of(context).pop(product);
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

      showMessage(result['message']?.toString() ?? 'บันทึกสินค้าไม่สำเร็จ');
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

  Widget buildImageTile({
    required Widget image,
    required VoidCallback onRemove,
  }) {
    const double size = 92;

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(width: size, height: size, child: image),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: isSaving ? null : onRemove,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildImages() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final image in keptImages)
              buildImageTile(
                image: Image.network(
                  image['url']?.toString() ?? '',
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                  errorBuilder: (context, error, stackTrace) {
                    return ColoredBox(
                      color: AppColors.fill,
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: AppColors.muted,
                      ),
                    );
                  },
                ),
                onRemove: () => removeKeptImage(image),
              ),
            for (final image in newImages)
              buildImageTile(
                image: Image.file(
                  File(image.path),
                  fit: BoxFit.cover,
                  cacheWidth: 300,
                ),
                onRemove: () {
                  setState(() {
                    newImages.remove(image);
                  });
                },
              ),
            if (imageCount < maxImages)
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: isSaving ? null : pickImages,
                child: Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    color: AppColors.market.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.market.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_photo_alternate_outlined,
                        color: AppColors.market,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$imageCount/$maxImages',
                        style: TextStyle(
                          color: AppColors.market,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (serverErrors.keys.any((key) => key.startsWith('images')))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              serverErrors.entries
                  .firstWhere((entry) => entry.key.startsWith('images'))
                  .value,
              style: TextStyle(color: AppColors.danger, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget buildVideo() {
    return MarketVideoField(
      hasNewVideo: newVideo != null,
      newThumbnailPath: newVideo?.thumbnailPath,
      showExisting: hadVideo && !removeVideo,
      existingThumbnailUrl: existingVideoThumbnail,
      busy: isPickingVideo,
      disabled: isSaving,
      onPick: pickVideo,
      onRemove: clearVideo,
    );
  }

  // ส่งตัวเลือกทั้งหมดทุกครั้ง (ไม่มีแถว = ลบตัวเลือกทั้งหมด)
  Map<String, String> variantFields() {
    return {
      'variants_present': '1',
      'option_name': optionNameController.text.trim(),
      for (int i = 0; i < variantRows.length; i++) ...{
        if (variantRows[i].id != null)
          'variants[$i][id]': '${variantRows[i].id}',
        'variants[$i][name]': variantRows[i].name.text.trim(),
        'variants[$i][price]': variantRows[i].price.text.trim().replaceAll(
          ',',
          '',
        ),
        'variants[$i][stock]': variantRows[i].stock.text.trim(),
      },
    };
  }

  Widget buildVariants() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'เช่น สี ขนาด รุ่น แต่ละแบบใส่ราคาและสต็อกแยกได้ '
          '(ไม่ใส่ราคา = ใช้ราคาสินค้า)',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
        if (variantRows.isNotEmpty) ...[
          const SizedBox(height: 10),
          TextFormField(
            controller: optionNameController,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'ชื่อหัวข้อ (เช่น สี / ขนาด)',
              prefixIcon: Icon(Icons.tune_rounded),
            ),
          ),
        ],
        for (int i = 0; i < variantRows.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: TextFormField(
                    controller: variantRows[i].name,
                    maxLength: 60,
                    decoration: InputDecoration(
                      labelText: 'แบบที่ ${i + 1}',
                      hintText: 'เช่น สีแดง M',
                      counterText: '',
                    ),
                    validator: (value) {
                      final String name = (value ?? '').trim();

                      if (name.isEmpty) return 'ใส่ชื่อ';

                      final int same = variantRows
                          .where((row) => row.name.text.trim() == name)
                          .length;

                      return same > 1 ? 'ชื่อซ้ำ' : null;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: variantRows[i].price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'ราคา'),
                    validator: (value) {
                      final String text = (value ?? '').trim().replaceAll(
                        ',',
                        '',
                      );

                      if (text.isEmpty) return null;

                      final double? price = double.tryParse(text);

                      return price == null || price < 0 ? 'ไม่ถูกต้อง' : null;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: variantRows[i].stock,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'สต็อก'),
                    validator: (value) {
                      final int? stock = int.tryParse((value ?? '').trim());

                      return stock == null || stock < 0 ? 'ใส่ 0+' : null;
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'ลบแบบนี้',
                  onPressed: isSaving
                      ? null
                      : () => setState(() {
                          variantRows.removeAt(i).dispose();
                        }),
                  icon: Icon(
                    Icons.remove_circle_outline_rounded,
                    color: AppColors.danger,
                  ),
                ),
              ],
            ),
          ),
        if (serverErrors.keys.any((key) => key.startsWith('variants')))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              serverErrors.entries
                  .firstWhere((entry) => entry.key.startsWith('variants'))
                  .value,
              style: TextStyle(color: AppColors.danger, fontSize: 12),
            ),
          ),
        if (variantRows.length < 20)
          TextButton.icon(
            onPressed: isSaving
                ? null
                : () => setState(() => variantRows.add(_VariantRow.empty())),
            icon: const Icon(Icons.add_rounded),
            label: const Text('เพิ่มตัวเลือก'),
          ),
      ],
    );
  }

  // เลือกให้การ์ดในหน้าร้านค้าแสดงรูป หรือเล่นวิดีโอ
  Widget buildCardMedia() {
    final bool canUseVideo = hasVideo;

    final String selected = canUseVideo ? cardMedia : 'image';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: [
              const ButtonSegment(
                value: 'image',
                icon: Icon(Icons.image_outlined),
                label: Text('รูปภาพ'),
              ),
              ButtonSegment(
                value: 'video',
                icon: const Icon(Icons.play_circle_outline_rounded),
                label: const Text('วิดีโอ'),
                enabled: canUseVideo,
              ),
            ],
            selected: {selected},
            onSelectionChanged: isSaving
                ? null
                : (value) => setState(() => cardMedia = value.first),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          !canUseVideo
              ? 'เพิ่มวิดีโอด้านบนก่อน จึงเลือกให้การ์ดเล่นวิดีโอได้'
              : selected == 'video'
              ? 'วิดีโอเล่นเอง (ไม่มีเสียง) เมื่อลูกค้าเลื่อนมาหยุด หรือแตะที่สินค้า'
              : 'การ์ดแสดงรูปแรกของสินค้า',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
      ],
    );
  }

  Widget buildPromoteSwitch() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
        ),
      ),
      child: SwitchListTile(
        value: promoteAfterSave,
        onChanged: isSaving
            ? null
            : (value) => setState(() => promoteAfterSave = value),
        activeThumbColor: const Color(0xFFF59E0B),
        secondary: const Icon(Icons.star_rounded, color: Color(0xFFF59E0B)),
        title: Text(
          'ขึ้นช่องแนะนำ (มีค่าใช้จ่าย)',
          style: TextStyle(color: AppColors.navy, fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          'บันทึกแล้วไปเลือกแพ็กเกจและชำระด้วยพร้อมเพย์ต่อ',
          style: TextStyle(color: AppColors.muted, fontSize: 12.5),
        ),
      ),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'เพิ่มสินค้า' : 'แก้ไขสินค้า')),
      body: SafeArea(
        child: Form(
          key: formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              buildSectionLabel('รูปสินค้า (1–5 รูป)'),
              buildImages(),
              const SizedBox(height: 24),
              buildSectionLabel('ข้อมูลสินค้า'),
              TextFormField(
                controller: titleController,
                maxLength: 120,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'ชื่อสินค้า',
                  prefixIcon: const Icon(Icons.sell_outlined),
                  errorText: serverErrors['title'],
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'กรุณาใส่ชื่อสินค้า' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'ราคา (บาท)',
                  helperText: 'เว้นว่างไว้ = สอบถามราคา',
                  prefixIcon: const Icon(Icons.payments_outlined),
                  errorText: serverErrors['price'],
                ),
                validator: (value) {
                  final String text = (value ?? '').trim().replaceAll(',', '');

                  if (text.isEmpty) return null;

                  final double? price = double.tryParse(text);

                  if (price == null || price < 0 || price > 9999999) {
                    return 'ราคาต้องเป็นตัวเลข 0 – 9,999,999 บาท';
                  }

                  return null;
                },
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: stockController,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      // มีตัวเลือก → สต็อกรวมจากตัวเลือก
                      enabled: variantRows.isEmpty,
                      decoration: InputDecoration(
                        labelText: 'จำนวนในสต็อก',
                        helperText: variantRows.isEmpty
                            ? 'ขายได้ระบบลดให้เอง'
                            : 'รวมจากตัวเลือกด้านล่าง',
                        prefixIcon: const Icon(Icons.inventory_2_outlined),
                        errorText: serverErrors['stock'],
                      ),
                      validator: (value) {
                        if (variantRows.isNotEmpty) return null;

                        final int? stock = int.tryParse((value ?? '').trim());

                        if (stock == null || stock < 0 || stock > 99999) {
                          return 'ใส่ 0 – 99,999';
                        }

                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: shippingController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'ค่าส่ง (บาท)',
                        helperText: 'เว้นว่าง = ส่งฟรี',
                        prefixIcon: const Icon(Icons.local_shipping_outlined),
                        errorText: serverErrors['shipping_fee'],
                      ),
                      validator: (value) {
                        final String text = (value ?? '').trim().replaceAll(
                          ',',
                          '',
                        );

                        if (text.isEmpty) return null;

                        final double? fee = double.tryParse(text);

                        return fee == null || fee < 0 || fee > 99999
                            ? 'ใส่ 0 – 99,999'
                            : null;
                      },
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(
                  'ค่าส่งคิดครั้งเดียวต่อคำสั่งซื้อ เฉพาะส่งพัสดุ / ส่งถึงบ้าน',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ),
              const SizedBox(height: 20),
              buildSectionLabel('ตัวเลือกสินค้า (ไม่บังคับ)'),
              buildVariants(),
              const SizedBox(height: 16),
              buildSectionLabel('หมวดสินค้า'),
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
              const SizedBox(height: 20),
              TextFormField(
                controller: descriptionController,
                maxLength: 2000,
                minLines: 4,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: 'รายละเอียด (ไม่บังคับ)',
                  hintText: 'ขนาด สี วิธีรับของ หรือรายละเอียดอื่น ๆ',
                  alignLabelWithHint: true,
                  errorText: serverErrors['description'],
                ),
              ),
              const SizedBox(height: 8),
              buildSectionLabel('วิดีโอแนะนำสินค้า (ไม่บังคับ)'),
              buildVideo(),
              const SizedBox(height: 20),
              buildSectionLabel('หน้าปกการ์ดสินค้า'),
              buildCardMedia(),
              if (widget.canPromote) ...[
                const SizedBox(height: 12),
                buildPromoteSwitch(),
              ],
              const SizedBox(height: 20),
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
                label: Text(
                  isSaving
                      ? 'กำลังบันทึก'
                      : isNew
                      ? 'เพิ่มสินค้า'
                      : 'บันทึกสินค้า',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    titleController.dispose();
    priceController.dispose();
    descriptionController.dispose();
    stockController.dispose();
    optionNameController.dispose();

    for (final row in variantRows) {
      row.dispose();
    }
    shippingController.dispose();

    super.dispose();
  }
}

// ตัวเลือกสินค้า 1 แบบในฟอร์ม (id = null → แบบใหม่)
class _VariantRow {
  final int? id;
  final TextEditingController name;
  final TextEditingController price;
  final TextEditingController stock;

  _VariantRow(this.id, String name, String price, String stock)
    : name = TextEditingController(text: name),
      price = TextEditingController(text: price),
      stock = TextEditingController(text: stock);

  factory _VariantRow.empty() => _VariantRow(null, '', '', '1');

  factory _VariantRow.from(Map<String, dynamic> data) {
    final double? price = double.tryParse('${data['price'] ?? ''}');

    return _VariantRow(
      (data['id'] as num?)?.toInt(),
      data['name']?.toString() ?? '',
      price == null
          ? ''
          : price == price.roundToDouble()
          ? price.toStringAsFixed(0)
          : price.toStringAsFixed(2),
      '${data['stock'] ?? 0}',
    );
  }

  void dispose() {
    name.dispose();
    price.dispose();
    stock.dispose();
  }
}
