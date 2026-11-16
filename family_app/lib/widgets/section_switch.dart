import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_theme.dart';

// =======================================================
// สวิตช์สลับหน้าย่อย
// เช่น หน้าหลัก: สำหรับคุณ | ล่าสุด | วิดีโอ (แบบเส้นใต้)
//      ครอบครัว: โพสต์ | สมาชิก (แบบปุ่มแบ่งช่อง)
// =======================================================

class SectionOption<T> {
  final T value;
  final IconData icon;
  final String label;

  const SectionOption({
    required this.value,
    required this.icon,
    required this.label,
  });
}

class SectionSwitch<T> extends StatelessWidget {
  final T value;
  final List<SectionOption<T>> options;
  final ValueChanged<T> onChanged;

  // true = แท็บเส้นใต้ (Clean underline): แท็บที่เลือกสีม่วง + เส้นใต้เลื่อนตาม บนเส้นบางเต็มแถว
  final bool underline;

  const SectionSwitch({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.underline = false,
  });

  // ช่องแคบกว่านี้ → ไม่แสดงไอคอน (เช่น 3 ช่องบนจอเล็ก)
  static const double compactSegmentWidth = 125;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bool compact =
            constraints.maxWidth / options.length < compactSegmentWidth;

        return underline
            ? buildUnderline(context, compact)
            : buildButton(context, compact);
      },
    );
  }

  Widget buildUnderline(BuildContext context, bool compact) {
    final int count = options.length;
    final int selected = options
        .indexWhere((option) => option.value == value)
        .clamp(0, count - 1);

    return Stack(
      children: [
        Row(
          children: [
            for (final option in options)
              Expanded(child: buildUnderlineTab(option, compact)),
          ],
        ),
        // เส้นบางเต็มแถว
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(height: 1, color: AppColors.border),
        ),
        // เส้นใต้แท็บที่เลือก (เลื่อนไปตามแท็บ / ลดการเคลื่อนไหว → ย้ายทันที)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 3,
          child: AnimatedAlign(
            alignment: Alignment(
              count == 1 ? 0 : -1 + 2 * selected / (count - 1),
              0,
            ),
            duration: AppMotion.of(context, AppMotion.panel),
            curve: AppMotion.move,
            child: FractionallySizedBox(
              widthFactor: 1 / count,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.72,
                  // สูงเต็ม 3 จุด (Center ปล่อยความสูงหลวม → ต้องกำหนดเอง)
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget buildUnderlineTab(SectionOption<T> option, bool compact) {
    final bool selected = option.value == value;
    final Color color = selected ? AppColors.primary : AppColors.muted;

    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: () => onChanged(option.value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 50),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 13),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ปุ่มแบ่งช่อง: พื้นหลังสีหลักเลื่อนไปช่องที่เลือก (เปลี่ยนเฉพาะตอนค่าที่เลือกเปลี่ยน ไม่เล่นซ้ำตอน rebuild)
  Widget buildButton(BuildContext context, bool compact) {
    final int count = options.length;
    final int selected = options
        .indexWhere((option) => option.value == value)
        .clamp(0, count - 1);

    final Duration duration = AppMotion.of(context, AppMotion.panel);

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppShapes.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              alignment: Alignment(
                count == 1 ? 0 : -1 + 2 * selected / (count - 1),
                0,
              ),
              duration: duration,
              curve: AppMotion.move,
              child: FractionallySizedBox(
                widthFactor: 1 / count,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: AppShapes.circular(13),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final option in options)
                Expanded(
                  child: buildSegment(context, option, compact, duration),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget buildSegment(
    BuildContext context,
    SectionOption<T> option,
    bool compact,
    Duration duration,
  ) {
    final bool selected = option.value == value;

    final Color color = selected ? AppColors.onPrimary : AppColors.muted;

    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: AppShapes.circular(13),
        onTap: selected ? null : () => onChanged(option.value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: color),
              duration: duration,
              builder: (context, animated, child) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!compact) ...[
                    Icon(option.icon, size: 18, color: animated),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: animated,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
