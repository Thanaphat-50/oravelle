import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/market_data.dart';
import '../services/market_service.dart';
import '../theme/app_theme.dart';
import 'autoplay_video_cover.dart';

// =======================================================
// การ์ดสินค้าในตาราง (หน้าตลาด / หน้าร้าน)
// =======================================================

class MarketProductCard extends StatelessWidget {
  final Map<String, dynamic> product;
  final VoidCallback onTap;

  // หน้าร้านไม่ต้องแสดงชื่อร้านซ้ำ
  final bool showShop;

  const MarketProductCard({
    super.key,
    required this.product,
    required this.onTap,
    this.showShop = true,
  });

  Widget buildImage(String? imageUrl) {
    if (imageUrl == null) {
      return ColoredBox(
        color: AppColors.fill,
        child: Icon(Icons.shopping_bag_outlined, color: marketColor),
      );
    }

    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      cacheWidth: 500,
      loadingBuilder: (context, child, progress) {
        return progress == null ? child : ColoredBox(color: AppColors.fill);
      },
      errorBuilder: (context, error, stackTrace) {
        return ColoredBox(
          color: AppColors.fill,
          child: Icon(Icons.broken_image_outlined, color: AppColors.muted),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? imageUrl = product['image_url']?.toString();

    // ผู้ขายเลือกให้การ์ดเล่นวิดีโอ
    final String? cardVideoUrl = product['card_video_url']?.toString();

    final bool soldOut = product['sold_out'] == true;

    final dynamic shop = product['shop'];

    final String shopLine = shop is Map
        ? [
            shop['name']?.toString() ?? '',
            shop['province']?.toString() ?? '',
          ].where((part) => part.isNotEmpty).join(' · ')
        : '';

    return DecoratedBox(
      // เงาอยู่นอกการ์ด (วาดใต้ InkWell จะทับพื้นขาวจนการ์ดเป็นสีเทา)
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppDecorations.cardShadow,
      ),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: AppDecorations.cardBorder,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // รูปใช้ความสูงที่เหลือจากข้อความ (ไม่ล้นเมื่อขยายตัวอักษร)
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: cardVideoUrl == null
                            ? buildImage(imageUrl)
                            : AutoplayVideoCover(
                                videoUrl: cardVideoUrl,
                                placeholder: buildImage(
                                  product['card_video_thumbnail_url']
                                          ?.toString() ??
                                      imageUrl,
                                ),
                              ),
                      ),
                      if (soldOut)
                        Positioned.fill(
                          child: ColoredBox(
                            color: Colors.black.withValues(alpha: 0.45),
                            child: const Center(
                              child: Text(
                                'สินค้าหมด',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // ช่องแนะนำแบบชำระเงิน
                      if (product['is_featured'] == true)
                        const Positioned(
                          left: 8,
                          top: 8,
                          child: FeaturedProductBadge(),
                        ),
                      // ♡ บันทึกสินค้า (มุมขวาบน) / ไอคอนวิดีโอย้ายไปมุมขวาล่าง
                      if (product['id'] is num)
                        Positioned(
                          right: 2,
                          top: 2,
                          child: ProductSaveHeart(product: product),
                        ),
                      if (product['has_video'] == true)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(11, 9, 11, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product['title']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 13.5,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        formatPrice(product['price']),
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (showShop && shopLine.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          shopLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =======================================================
// ช่องเลือกวิดีโอแนะนำ (ฟอร์มร้าน / ฟอร์มสินค้า)
// newThumbnailPath: รูปตัวอย่างของวิดีโอที่เพิ่งเลือก
// existingThumbnailUrl + showExisting: วิดีโอเดิมบนเซิร์ฟเวอร์
// =======================================================

class MarketVideoField extends StatelessWidget {
  final bool hasNewVideo;
  final String? newThumbnailPath;
  final bool showExisting;
  final String? existingThumbnailUrl;
  final bool busy;
  final bool disabled;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const MarketVideoField({
    super.key,
    required this.hasNewVideo,
    this.newThumbnailPath,
    required this.showExisting,
    this.existingThumbnailUrl,
    required this.busy,
    required this.disabled,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (!hasNewVideo && !showExisting) {
      return OutlinedButton.icon(
        onPressed: disabled || busy ? null : onPick,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.videocam_outlined),
        label: Text(
          busy ? 'กำลังเตรียมวิดีโอ...' : 'เพิ่มวิดีโอ (ไม่เกิน 30 วินาที)',
        ),
      );
    }

    final String? localThumbnail = newThumbnailPath;

    final Widget preview = hasNewVideo && localThumbnail != null
        ? Image.file(File(localThumbnail), fit: BoxFit.cover)
        : !hasNewVideo && existingThumbnailUrl != null
        ? Image.network(existingThumbnailUrl!, fit: BoxFit.cover)
        : const ColoredBox(color: Colors.black);

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 96,
            height: 96,
            child: Stack(
              fit: StackFit.expand,
              children: [
                preview,
                const Center(
                  child: Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            hasNewVideo ? 'วิดีโอใหม่ (บันทึกพร้อมข้อมูล)' : 'วิดีโอแนะนำ',
            style: TextStyle(
              color: AppColors.navy,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          tooltip: 'เปลี่ยนวิดีโอ',
          onPressed: disabled || busy ? null : onPick,
          icon: const Icon(Icons.swap_horiz_rounded),
        ),
        IconButton(
          tooltip: 'ลบวิดีโอ',
          onPressed: disabled ? null : onRemove,
          icon: Icon(Icons.delete_outline_rounded, color: AppColors.danger),
        ),
      ],
    );
  }
}

// ป้าย "แนะนำ" บนการ์ดสินค้าที่ซื้อช่องแนะนำ
class FeaturedProductBadge extends StatelessWidget {
  const FeaturedProductBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 13, color: Colors.white),
          SizedBox(width: 3),
          Text(
            'แนะนำ',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// =======================================================
// ปุ่มติดต่อร้าน: โทร / LINE
// เปิดแอปโทรศัพท์หรือ LINE ไม่ได้ → คัดลอกให้แทน
// =======================================================

class ShopContactButtons extends StatelessWidget {
  final String? phone;
  final String? lineId;

  const ShopContactButtons({super.key, this.phone, this.lineId});

  Future<void> open(
    BuildContext context, {
    required Uri uri,
    required String copyText,
    required String copiedMessage,
  }) async {
    bool opened = false;

    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }

    if (opened || !context.mounted) return;

    await Clipboard.setData(ClipboardData(text: copyText));

    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(copiedMessage)));
  }

  // LINE ID ส่วนตัว → line.me/R/ti/p/~id, บัญชีทางการ (@id) → line.me/R/ti/p/@id
  Uri lineUri(String id) {
    final String path = id.startsWith('@')
        ? Uri.encodeComponent(id)
        : '~${Uri.encodeComponent(id)}';

    return Uri.parse('https://line.me/R/ti/p/$path');
  }

  @override
  Widget build(BuildContext context) {
    final String? phoneNumber = phone?.trim().isNotEmpty == true
        ? phone!.trim()
        : null;

    final String? line = lineId?.trim().isNotEmpty == true
        ? lineId!.trim()
        : null;

    return Row(
      children: [
        if (phoneNumber != null)
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: marketColor,
                minimumSize: const Size(0, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () => open(
                context,
                uri: Uri(scheme: 'tel', path: phoneNumber),
                copyText: phoneNumber,
                copiedMessage: 'คัดลอกเบอร์ $phoneNumber แล้ว',
              ),
              icon: const Icon(Icons.call_rounded, size: 20),
              label: const Text('โทรหาร้าน'),
            ),
          ),
        if (phoneNumber != null && line != null) const SizedBox(width: 10),
        if (line != null)
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF06C755),
                side: const BorderSide(color: Color(0xFF06C755)),
                minimumSize: const Size(0, 50),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () => open(
                context,
                uri: lineUri(line),
                copyText: line,
                copiedMessage: 'คัดลอก LINE ID $line แล้ว',
              ),
              icon: const Icon(Icons.chat_rounded, size: 20),
              label: const Text('LINE'),
            ),
          ),
      ],
    );
  }
}

// =======================================================
// คำเตือนความปลอดภัยในการซื้อขาย
// =======================================================

class MarketSafetyNote extends StatelessWidget {
  const MarketSafetyNote({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.softWarm,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: marketColor, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'แอปไม่ได้รับชำระเงินแทน ควรนัดดูสินค้าหรือตรวจสอบร้าน'
              'ก่อนโอนเงิน หากพบการโกงกด "รายงาน" ได้ทันที',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ♡ บันทึกสินค้าบนการ์ด: เปลี่ยนทันที / ไม่สำเร็จ → คืนค่าเดิม + แจ้ง
class ProductSaveHeart extends StatefulWidget {
  final Map<String, dynamic> product;

  const ProductSaveHeart({super.key, required this.product});

  @override
  State<ProductSaveHeart> createState() => _ProductSaveHeartState();
}

class _ProductSaveHeartState extends State<ProductSaveHeart> {
  bool busy = false;

  bool get saved => widget.product['is_saved'] == true;

  Future<void> toggle() async {
    final dynamic id = widget.product['id'];

    if (busy || id is! num) return;

    final bool next = !saved;

    setState(() {
      busy = true;
      widget.product['is_saved'] = next;
    });

    try {
      final result = await MarketService.setProductSaved(id.toInt(), next);

      if (result['status'] != true) throw StateError('not saved');
    } catch (_) {
      if (mounted) {
        setState(() => widget.product['is_saved'] = !next);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('บันทึกสินค้าไม่สำเร็จ ลองใหม่อีกครั้ง'),
          ),
        );
      }
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // วงกลมขาวเล็ก 34 แต่พื้นที่แตะยังเป็น 48 ตามมาตรฐาน
    return IconButton(
      tooltip: saved ? 'เอาออกจากที่บันทึก' : 'บันทึกสินค้า',
      onPressed: toggle,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.92),
        fixedSize: const Size(34, 34),
        minimumSize: const Size(34, 34),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      icon: Icon(
        saved ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: saved ? const Color(0xFFE11D48) : const Color(0xFF374151),
        size: 19,
      ),
    );
  }
}
