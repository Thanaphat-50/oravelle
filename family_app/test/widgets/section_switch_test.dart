import 'package:family_app/theme/app_theme.dart';
import 'package:family_app/widgets/section_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// แท็บเส้นใต้ (หน้าหลัก): แท็บที่เลือกสีม่วง / แตะเปลี่ยนแท็บ / จอเล็ก + ตัวอักษรใหญ่ไม่ล้น

Widget tabs({
  required String value,
  required ValueChanged<String> onChanged,
  double width = 400,
  double textScale = 1,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 700),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: SizedBox(
          width: width,
          child: SectionSwitch<String>(
            underline: true,
            value: value,
            onChanged: onChanged,
            options: const [
              SectionOption(
                value: 'for_you',
                icon: Icons.auto_awesome_rounded,
                label: 'สำหรับคุณ',
              ),
              SectionOption(
                value: 'latest',
                icon: Icons.schedule_rounded,
                label: 'ล่าสุด',
              ),
              SectionOption(
                value: 'videos',
                icon: Icons.smart_display_rounded,
                label: 'วิดีโอ',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('selected tab is highlighted and tapping switches tabs', (
    tester,
  ) async {
    String? changed;

    await tester.pumpWidget(
      tabs(value: 'for_you', onChanged: (value) => changed = value),
    );

    final Text selected = tester.widget<Text>(find.text('สำหรับคุณ'));
    final Text other = tester.widget<Text>(find.text('ล่าสุด'));

    expect(selected.style?.fontWeight, FontWeight.w800);
    expect(other.style?.fontWeight, FontWeight.w600);
    expect(selected.style?.color, isNot(other.style?.color));
    expect(find.byType(SegmentedButton<String>), findsNothing);

    // เส้นใต้สีม่วงมองเห็นได้ (สูง 3) และอยู่ใต้แท็บที่เลือก
    final Finder indicator = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == AppColors.primary,
    );
    expect(tester.getSize(indicator).height, 3);
    expect(tester.getSize(indicator).width, greaterThan(40));
    expect(
      (tester.getCenter(indicator).dx -
              tester.getCenter(find.text('สำหรับคุณ')).dx)
          .abs(),
      lessThan(30),
    );

    await tester.tap(find.text('ล่าสุด'));
    expect(changed, 'latest');

    expect(
      tester.getSemantics(find.bySemanticsLabel('สำหรับคุณ')),
      isSemantics(isSelected: true, isButton: true),
    );
  });

  testWidgets('small screen with large text does not overflow', (tester) async {
    await tester.pumpWidget(
      tabs(value: 'videos', onChanged: (_) {}, width: 300, textScale: 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('วิดีโอ'), findsOneWidget);
  });
}
