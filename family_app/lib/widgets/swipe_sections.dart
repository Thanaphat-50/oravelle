import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

// =======================================================
// หน้าย่อยที่ปัดซ้าย-ขวาสลับกันได้ (เฉพาะในหน้าเดียวกัน)
// - index: หน้าย่อยที่เลือกอยู่ (หน้าแม่เป็นคนเก็บ)
// - กดแท็บ/ปุ่มสลับในหน้าแม่ → index เปลี่ยน → เลื่อนไปให้
// - ปัดจนเปลี่ยนหน้า → onChanged
// สุดขอบแล้วปัดต่อไม่ได้ (ไม่ข้ามไปหน้าอื่นบนแถบล่าง)
// =======================================================

class SwipeSections extends StatefulWidget {
  final int index;

  final ValueChanged<int> onChanged;

  final List<Widget> children;

  // แท็บที่ต้องเก็บไว้แม้เลื่อนไปแท็บอื่น (ตำแหน่งเลื่อน/ข้อมูลไม่หาย ไม่โหลดซ้ำ)
  // null = เก็บทุกแท็บ / false ที่ตำแหน่งใด = ไม่เก็บ (เช่น หน้าวิดีโอ ต้องหยุดเล่นเมื่อออก)
  final List<bool>? keepAlive;

  const SwipeSections({
    super.key,
    required this.index,
    required this.onChanged,
    required this.children,
    this.keepAlive,
  });

  @override
  State<SwipeSections> createState() => _SwipeSectionsState();
}

class _SwipeSectionsState extends State<SwipeSections> {
  late final PageController controller = PageController(
    initialPage: widget.index,
  );

  @override
  void didUpdateWidget(SwipeSections oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!controller.hasClients) return;

    final double? page = controller.page;

    // ปัดเลยครึ่งทางแล้ว (หน้าแม่รู้แล้ว) → ไม่ต้องเลื่อนซ้ำ
    if (page == null || page.round() == widget.index) return;

    final Duration duration = AppMotion.of(context, AppMotion.page);

    // ลดการเคลื่อนไหว / ข้ามหลายแท็บ → กระโดดตรง ไม่วิ่งผ่านแท็บกลาง (ไม่สร้าง/โหลดแท็บที่ข้าม)
    if (duration == Duration.zero || (page - widget.index).abs() > 1.5) {
      controller.jumpToPage(widget.index);
      return;
    }

    controller.animateToPage(
      widget.index,
      duration: duration,
      curve: AppMotion.move,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: controller,
      onPageChanged: (index) {
        if (index != widget.index) widget.onChanged(index);
      },
      children: [
        for (int i = 0; i < widget.children.length; i++)
          widget.keepAlive == null || widget.keepAlive![i]
              ? _KeepAlive(child: widget.children[i])
              : widget.children[i],
      ],
    );
  }

  @override
  void dispose() {
    controller.dispose();

    super.dispose();
  }
}

class _KeepAlive extends StatefulWidget {
  final Widget child;

  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return widget.child;
  }
}
