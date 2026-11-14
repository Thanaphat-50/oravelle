import 'package:flutter/material.dart';

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
            : buildButton(compact);
      },
    );
  }

  Widget buildUnderline(BuildContext context, bool compact) {
    final int count = options.length;
    final int selected = options
        .indexWhere((option) => option.value == value)
        .clamp(0, count - 1);
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;

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
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
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

  Widget buildButton(bool compact) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [
          for (final option in options)
            ButtonSegment<T>(
              value: option.value,
              icon: compact ? null : Icon(option.icon, size: 18),
              label: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        selected: {value},
        onSelectionChanged: (selection) {
          onChanged(selection.first);
        },
        style: SegmentedButton.styleFrom(
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.muted,
          selectedBackgroundColor: AppColors.primary,
          selectedForegroundColor: AppColors.onPrimary,
          side: BorderSide(color: AppColors.border),
          minimumSize: const Size(0, 46),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}
