import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

// =======================================================
// หัวใจถูกใจ (ใช้ร่วมกันทุกหน้า: ฟีด / หน้าวิดีโอ)
//
// - เล่นเฉพาะเมื่อ pulse เปลี่ยน = ผู้ใช้กดเอง
//   (โหลดข้อมูลใหม่ / polling / เลื่อนกลับมาเห็นโพสต์ → สถานะเปลี่ยนทันที ไม่เล่น)
// - กดถูกใจ: ขยายเล็กน้อยแล้วกลับขนาดเดิม พร้อมเปลี่ยนสี
// - ถอนถูกใจ: ย่อลงนิดเดียวแล้วกลับ (นุ่ม ๆ ไม่มีเอฟเฟกต์ฉลอง)
// - ลดการเคลื่อนไหว → เปลี่ยนไอคอน/สีทันที
// ต้องใส่ key ต่อโพสต์ (เช่น ValueKey('like-$id')) ไม่ให้สถานะข้ามโพสต์ตอนรายการเปลี่ยน
// =======================================================

class LikeHeart extends StatefulWidget {
  final bool liked;
  final int pulse;
  final double size;
  final Color likedColor;
  final Color color;
  final List<Shadow>? shadows;

  const LikeHeart({
    super.key,
    required this.liked,
    required this.pulse,
    required this.likedColor,
    required this.color,
    this.size = 22,
    this.shadows,
  });

  @override
  State<LikeHeart> createState() => _LikeHeartState();
}

class _LikeHeartState extends State<LikeHeart>
    with SingleTickerProviderStateMixin {
  static final Animatable<double> likeScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 1.28).chain(CurveTween(curve: Curves.easeOut)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 1.28, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 55,
    ),
  ]);

  static final Animatable<double> unlikeScale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(begin: 1.0, end: 0.86).chain(CurveTween(curve: Curves.easeOut)),
      weight: 40,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.86, end: 1.0).chain(CurveTween(curve: Curves.easeOut)),
      weight: 60,
    ),
  ]);

  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: AppMotion.button,
  );

  bool pulseIsLike = true;

  @override
  void didUpdateWidget(covariant LikeHeart oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.pulse == oldWidget.pulse) return;

    if (AppMotion.reduced(context)) {
      controller.value = 0;
      return;
    }

    pulseIsLike = widget.liked;
    controller.forward(from: 0);
  }

  @override
  void dispose() {
    controller.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget icon = Icon(
      widget.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      color: widget.liked ? widget.likedColor : widget.color,
      size: widget.size,
      shadows: widget.shadows,
    );

    return AnimatedBuilder(
      animation: controller,
      child: icon,
      builder: (context, child) {
        if (!controller.isAnimating) return child!;

        return Transform.scale(
          scale: (pulseIsLike ? likeScale : unlikeScale).evaluate(controller),
          child: child,
        );
      },
    );
  }
}
