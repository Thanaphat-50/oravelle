import 'package:flutter/material.dart';

import '../data/market_data.dart';
import '../pages/video_player_page.dart';
import '../services/market_service.dart';
import '../theme/app_theme.dart';
import 'photo_viewer.dart';
import 'user_avatar.dart';

// =======================================================
// หน้าร้าน: ความน่าเชื่อถือ / รายละเอียด / วิดีโอ / รีวิว
// =======================================================

const Color _starColor = Color(0xFFF59E0B);

BoxDecoration _cardDecoration() {
  return BoxDecoration(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(22),
    border: AppDecorations.cardBorder,
    boxShadow: AppDecorations.cardShadow,
  );
}

Widget _sectionTitle(String text, {Widget? trailing}) {
  return Row(
    children: [
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.navy,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      ?trailing,
    ],
  );
}

// ดาว 5 ดวง (ครึ่งดวงตามค่าเฉลี่ย)
class StarRow extends StatelessWidget {
  final double rating;
  final double size;

  const StarRow({super.key, required this.rating, this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 1; i <= 5; i++)
          Icon(
            rating >= i
                ? Icons.star_rounded
                : rating >= i - 0.5
                ? Icons.star_half_rounded
                : Icons.star_outline_rounded,
            size: size,
            color: _starColor,
          ),
      ],
    );
  }
}

// =======================================================
// ข้อมูลความน่าเชื่อถือ (ระบบคำนวณเอง)
// =======================================================

class ShopTrustCard extends StatelessWidget {
  final Map<String, dynamic> shop;

  const ShopTrustCard({super.key, required this.shop});

  static const Map<String, String> _loginNames = {
    'google': 'Google',
    'line': 'LINE',
    'facebook': 'Facebook',
  };

  @override
  Widget build(BuildContext context) {
    final Map trust = (shop['trust'] as Map?) ?? const {};

    final Map rating = (shop['rating'] as Map?) ?? const {};

    final List logins = (trust['login_methods'] as List?) ?? const [];

    final String opened = durationSince(trust['approved_at']);

    final String member = durationSince(trust['member_since']);

    final int ratingCount = (rating['count'] as num?)?.toInt() ?? 0;

    final List<(IconData, String, Color)> rows = [
      if (opened.isNotEmpty)
        (Icons.storefront_outlined, 'เปิดร้านมาแล้ว $opened', AppColors.navy),
      if (member.isNotEmpty)
        (Icons.person_outline_rounded, 'เป็นสมาชิกมา $member', AppColors.navy),
      if (logins.isNotEmpty)
        (
          Icons.lock_outline_rounded,
          'ยืนยันบัญชีด้วย ${logins.map((item) => _loginNames[item] ?? item).join(', ')}',
          AppColors.navy,
        ),
      (
        Icons.inventory_2_outlined,
        'สินค้า ${trust['products_count'] ?? 0} ชิ้น',
        AppColors.navy,
      ),
      if (ratingCount > 0)
        (
          Icons.star_rounded,
          'คะแนน ${rating['average']} จาก $ratingCount รีวิว',
          _starColor,
        ),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('ความน่าเชื่อถือของร้าน'),
          const SizedBox(height: 8),
          for (final (icon, text, color) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(icon, size: 19, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(color: AppColors.navy, fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// =======================================================
// เวลาเปิด-ปิด / วิธีรับสินค้า / รูปหน้าร้าน / วิดีโอ
// ไม่มีข้อมูลเลย → ไม่แสดง
// =======================================================

class ShopDetailsCard extends StatelessWidget {
  final Map<String, dynamic> shop;

  const ShopDetailsCard({super.key, required this.shop});

  static bool hasContent(Map<String, dynamic> shop) {
    return (shop['opening_hours']?.toString().isNotEmpty ?? false) ||
        ((shop['delivery_methods'] as List?)?.isNotEmpty ?? false) ||
        ((shop['images'] as List?)?.isNotEmpty ?? false) ||
        shop['video_url'] != null;
  }

  @override
  Widget build(BuildContext context) {
    final String hours = shop['opening_hours']?.toString() ?? '';

    final List methods = (shop['delivery_methods'] as List?) ?? const [];

    final List<String> photos = [
      for (final image in (shop['images'] as List?) ?? const [])
        if (image is Map && image['url'] != null) image['url'].toString(),
    ];

    final String? videoUrl = shop['video_url']?.toString();

    final String? videoThumbnail = shop['video_thumbnail_url']?.toString();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('รายละเอียดร้าน'),
          if (hours.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 19,
                  color: AppColors.market,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    hours,
                    style: TextStyle(color: AppColors.navy, fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ],
          if (methods.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final dynamic key in methods)
                  if (findDeliveryMethod(key.toString()) case final method?)
                    Chip(
                      avatar: Icon(method.icon, size: 17, color: AppColors.market),
                      label: Text(method.label),
                      visualDensity: VisualDensity.compact,
                    ),
              ],
            ),
          ],
          if (videoUrl != null || photos.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  if (videoUrl != null)
                    _MediaTile(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => VideoPlayerPage(url: videoUrl),
                        ),
                      ),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          videoThumbnail != null
                              ? Image.network(videoThumbnail, fit: BoxFit.cover)
                              : const ColoredBox(color: Colors.black),
                          const Center(
                            child: Icon(
                              Icons.play_circle_fill_rounded,
                              size: 38,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (int i = 0; i < photos.length; i++)
                    _MediaTile(
                      onTap: () => showPhotoViewer(
                        context,
                        urls: photos,
                        initialIndex: i,
                      ),
                      child: Image.network(
                        photos[i],
                        fit: BoxFit.cover,
                        cacheWidth: 330,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;

  const _MediaTile({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(width: 110, height: 110, child: child),
        ),
      ),
    );
  }
}

// =======================================================
// รีวิวร้าน: สรุปคะแนน + รีวิวล่าสุด + ปุ่มเขียนรีวิว
// onChanged: รีวิวของเราเปลี่ยน → หน้าร้านโหลดใหม่
// =======================================================

class ShopReviewsCard extends StatelessWidget {
  final int shopId;
  final String shopName;
  final Map<String, dynamic> shop;
  final List<Map<String, dynamic>> reviews;
  final Map<String, dynamic>? myReview;
  final VoidCallback onChanged;

  const ShopReviewsCard({
    super.key,
    required this.shopId,
    required this.shopName,
    required this.shop,
    required this.reviews,
    required this.myReview,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final Map rating = (shop['rating'] as Map?) ?? const {};

    final int count = (rating['count'] as num?)?.toInt() ?? 0;

    final double average = (rating['average'] as num?)?.toDouble() ?? 0;

    final bool isMine = shop['is_mine'] == true;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(
            'รีวิวร้าน',
            trailing: count > 0
                ? TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            ShopReviewsPage(shopId: shopId, shopName: shopName),
                      ),
                    ),
                    child: Text('ดูทั้งหมด ($count)'),
                  )
                : null,
          ),
          const SizedBox(height: 6),
          if (count > 0)
            Row(
              children: [
                Text(
                  average.toStringAsFixed(1),
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StarRow(rating: average, size: 18),
                    Text(
                      '$count รีวิว',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ],
            )
          else
            Text(
              isMine
                  ? 'ร้านของคุณยังไม่มีรีวิว'
                  : 'ยังไม่มีรีวิว เป็นคนแรกที่รีวิวร้านนี้',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          for (final review in reviews) ...[
            const Divider(height: 22),
            ReviewTile(review: review),
          ],
          if (!isMine) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final bool saved = await showShopReviewSheet(
                    context,
                    shopId: shopId,
                    existing: myReview,
                  );

                  if (saved) onChanged();
                },
                icon: const Icon(Icons.rate_review_outlined),
                label: Text(
                  myReview == null ? 'เขียนรีวิว' : 'แก้ไขรีวิวของฉัน',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class ReviewTile extends StatelessWidget {
  final Map<String, dynamic> review;

  const ReviewTile({super.key, required this.review});

  @override
  Widget build(BuildContext context) {
    final dynamic user = review['user'];

    final String comment = review['comment']?.toString() ?? '';

    // รีวิวสินค้า: ผู้ซื้อจริง + ตัวเลือกที่ซื้อ
    final String variant = review['variant_name']?.toString() ?? '';

    final bool verified = review['verified_purchase'] == true;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UserAvatar(user: user, radius: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      user is Map ? user['name']?.toString() ?? '' : '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.navy,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    formatDateTime(review['updated_at'], withTime: false),
                    style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              StarRow(
                rating: (review['rating'] as num?)?.toDouble() ?? 0,
                size: 15,
              ),
              if (verified || variant.isNotEmpty) ...[
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (verified)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.success.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.verified_rounded,
                              size: 12,
                              color: AppColors.success,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'ซื้อแล้ว',
                              style: TextStyle(
                                color: AppColors.success,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (variant.isNotEmpty)
                      Text(
                        'ตัวเลือก: $variant',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                  ],
                ),
              ],
              if (comment.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  comment,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// =======================================================
// เขียน / แก้ไข / ลบรีวิวร้าน (คืนค่า true เมื่อมีการเปลี่ยนแปลง)
// =======================================================

Future<bool> showShopReviewSheet(
  BuildContext context, {
  required int shopId,
  Map<String, dynamic>? existing,
}) {
  return showStarReviewSheet(
    context,
    title: existing == null ? 'รีวิวร้านนี้' : 'แก้ไขรีวิว',
    hint: 'เล่าประสบการณ์ซื้อจากร้านนี้ (ไม่บังคับ)',
    existing: existing,
    onSave: (rating, comment) =>
        MarketService.saveShopReview(shopId, rating: rating, comment: comment),
    onDelete: existing == null
        ? null
        : () => MarketService.deleteShopReview(shopId),
  );
}

// =======================================================
// แผ่นให้ดาว 1–5 + ความเห็น (ใช้กับรีวิวร้าน และรีวิวสินค้า)
// onSave คืนผลจากเซิร์ฟเวอร์ status = true → ปิดแผ่น
// onDelete = null → ไม่มีปุ่มลบ
// =======================================================

Future<bool> showStarReviewSheet(
  BuildContext context, {
  required String title,
  required String hint,
  required Future<Map<String, dynamic>> Function(int rating, String comment)
  onSave,
  Future<void> Function()? onDelete,
  Map<String, dynamic>? existing,
  String? subtitle,
}) async {
  FocusManager.instance.primaryFocus?.unfocus();

  final bool? changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _ReviewSheet(
      title: title,
      subtitle: subtitle,
      hint: hint,
      existing: existing,
      onSave: onSave,
      onDelete: onDelete,
    ),
  );

  return changed == true;
}

class _ReviewSheet extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String hint;
  final Map<String, dynamic>? existing;
  final Future<Map<String, dynamic>> Function(int rating, String comment)
  onSave;
  final Future<void> Function()? onDelete;

  const _ReviewSheet({
    required this.title,
    required this.hint,
    required this.onSave,
    this.subtitle,
    this.existing,
    this.onDelete,
  });

  @override
  State<_ReviewSheet> createState() => _ReviewSheetState();
}

class _ReviewSheetState extends State<_ReviewSheet> {
  late int rating = (widget.existing?['rating'] as num?)?.toInt() ?? 0;

  late final TextEditingController controller = TextEditingController(
    text: widget.existing?['comment']?.toString() ?? '',
  );

  bool isSaving = false;

  Future<void> save() async {
    if (rating == 0 || isSaving) return;

    setState(() => isSaving = true);

    try {
      final result = await widget.onSave(rating, controller.text.trim());

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message']?.toString() ?? 'บันทึกรีวิวแล้ว'),
        ),
      );

      if (result['status'] == true) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('บันทึกรีวิวไม่สำเร็จ: $e')));
      }
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  Future<void> delete() async {
    final Future<void> Function()? onDelete = widget.onDelete;

    if (onDelete == null) return;

    setState(() => isSaving = true);

    try {
      await onDelete();

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => isSaving = false);

        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('ลบรีวิวไม่สำเร็จ: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (widget.subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              widget.subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int i = 1; i <= 5; i++)
                  IconButton(
                    tooltip: '$i ดาว',
                    onPressed: isSaving
                        ? null
                        : () => setState(() => rating = i),
                    icon: Icon(
                      rating >= i
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      size: 38,
                      color: _starColor,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            decoration: InputDecoration(hintText: widget.hint),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (widget.onDelete != null)
                TextButton(
                  onPressed: isSaving ? null : delete,
                  child: Text(
                    'ลบรีวิว',
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
              const Spacer(),
              FilledButton(
                onPressed: rating == 0 || isSaving ? null : save,
                style: FilledButton.styleFrom(backgroundColor: AppColors.market),
                child: Text(isSaving ? 'กำลังบันทึก...' : 'ส่งรีวิว'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

// =======================================================
// รีวิวทั้งหมดของร้าน / ของสินค้า (โหลดทีละหน้า)
// productId != null → รีวิวสินค้า (จากผู้ซื้อจริง)
// =======================================================

class ShopReviewsPage extends StatefulWidget {
  final int shopId;
  final String shopName;
  final int? productId;

  const ShopReviewsPage({
    super.key,
    required this.shopId,
    required this.shopName,
  }) : productId = null;

  const ShopReviewsPage.product({
    super.key,
    required int this.productId,
    required String productTitle,
  }) : shopId = 0,
       shopName = productTitle;

  @override
  State<ShopReviewsPage> createState() => _ShopReviewsPageState();
}

class _ShopReviewsPageState extends State<ShopReviewsPage> {
  final List<Map<String, dynamic>> reviews = [];

  Map summary = const {};

  int page = 0;
  bool hasMore = true;
  bool isLoading = false;
  String? loadError;

  @override
  void initState() {
    super.initState();
    loadMore();
  }

  Future<void> loadMore() async {
    if (isLoading || !hasMore) return;

    setState(() {
      isLoading = true;
      loadError = null;
    });

    try {
      final int? productId = widget.productId;

      final result = productId != null
          ? await MarketService.getProductReviews(productId, page: page + 1)
          : await MarketService.getShopReviews(widget.shopId, page: page + 1);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          page++;
          hasMore = result['has_more'] == true;
          summary = (result['summary'] as Map?) ?? const {};
          reviews.addAll([
            for (final item in (result['reviews'] as List?) ?? const [])
              if (item is Map) Map<String, dynamic>.from(item),
          ]);
        });
      } else {
        setState(
          () =>
              loadError = result['message']?.toString() ?? 'โหลดรีวิวไม่สำเร็จ',
        );
      }
    } catch (e) {
      if (mounted) setState(() => loadError = 'โหลดรีวิวไม่สำเร็จ: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double average = (summary['average'] as num?)?.toDouble() ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.productId != null ? 'รีวิวสินค้า' : 'รีวิว ${widget.shopName}',
        ),
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.extentAfter < 300) loadMore();

          return false;
        },
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          itemCount: reviews.length + 2,
          separatorBuilder: (context, index) => index == 0
              ? const SizedBox(height: 12)
              : const Divider(height: 24),
          itemBuilder: (context, index) {
            if (index == 0) {
              return Row(
                children: [
                  Text(
                    average.toStringAsFixed(1),
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 10),
                  StarRow(rating: average, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '${summary['count'] ?? 0} รีวิว',
                    style: TextStyle(color: AppColors.muted),
                  ),
                ],
              );
            }

            if (index == reviews.length + 1) {
              if (isLoading) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              if (loadError != null) {
                return Center(
                  child: TextButton(
                    onPressed: loadMore,
                    child: Text(loadError!),
                  ),
                );
              }

              return const SizedBox.shrink();
            }

            return ReviewTile(review: reviews[index - 1]);
          },
        ),
      ),
    );
  }
}
