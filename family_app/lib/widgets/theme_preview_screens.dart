import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_spec.dart';
import '../theme/themed_widgets.dart';
import 'chat_widgets.dart';
import 'market_widgets.dart';
import 'section_switch.dart';

// =======================================================
// หน้าตัวอย่างสำหรับ "ลองธีม" (ข้อมูลจำลองทั้งหมด)
// - ใช้ส่วนประกอบจริงของแอป (ChatBubble, ChatComposer, MarketProductCard, SectionSwitch, ThemedIcon …)
// - ครอบด้วย AbsorbPointer → แตะอะไรก็ไม่ส่งข้อความ ไม่สั่งซื้อ ไม่แก้ข้อมูลจริง
// - วาดในกรอบโทรศัพท์ขนาดคงที่ แล้วย่อให้พอดีจอ
// =======================================================

enum ThemePreviewScreen {
  feed('ฟีด'),
  chat('แชท'),
  shop('ร้านค้า'),
  profile('โปรไฟล์'),
  activity('กิจกรรม');

  final String label;

  const ThemePreviewScreen(this.label);
}

class ThemePreviewFrame extends StatelessWidget {
  final ThemePreviewScreen screen;

  const ThemePreviewFrame({super.key, required this.screen});

  static const double width = 390;
  static const double height = 800;

  @override
  Widget build(BuildContext context) {
    final Widget content = switch (screen) {
      ThemePreviewScreen.feed => const _FeedPreview(),
      ThemePreviewScreen.chat => const _ChatPreview(),
      ThemePreviewScreen.shop => const _ShopPreview(),
      ThemePreviewScreen.profile => const _ProfilePreview(),
      ThemePreviewScreen.activity => const _ActivityPreview(),
    };

    return Semantics(
      label: 'ตัวอย่างหน้า${screen.label} ด้วยธีมที่กำลังลอง',
      child: FittedBox(
        fit: BoxFit.contain,
        child: Container(
          width: width,
          height: height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(34),
            border: Border.all(color: AppColors.border, width: 6),
          ),
          child: ExcludeSemantics(
            child: AbsorbPointer(
              child: MediaQuery.withNoTextScaling(child: content),
            ),
          ),
        ),
      ),
    );
  }
}

void _noop() {}

// =======================================================
// ส่วนร่วม: แถบหัว + แถบล่าง
// =======================================================

class _PreviewHeader extends StatelessWidget {
  final String? title;

  const _PreviewHeader({this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 22, 10, 6),
      child: Row(
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: AppColors.softPrimary,
            child: Text(
              'แ',
              style: TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: title == null
                ? Text(
                    'ORAVELLE',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ORAVELLE',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        title!,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
          ),
          if (title == null)
            ThemedIcon(ThemeSlot.search, color: AppColors.navy),
          const SizedBox(width: 14),
          ThemedIcon(ThemeSlot.chat, color: AppColors.navy),
          const SizedBox(width: 14),
          ThemedIcon(ThemeSlot.bell, color: AppColors.navy),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _PreviewNav extends StatelessWidget {
  final int selected;

  const _PreviewNav({required this.selected});

  static const List<(ThemeSlot, String)> items = [
    (ThemeSlot.home, 'หน้าหลัก'),
    (ThemeSlot.shop, 'ร้านค้า'),
    (ThemeSlot.group, 'กลุ่มสมาชิก'),
    (ThemeSlot.map, 'ตำแหน่ง'),
    (ThemeSlot.activity, 'กิจกรรม'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: AppDecorations.card(radius: 26),
      child: Row(
        children: [
          for (int i = 0; i < items.length; i++)
            Expanded(
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: i == selected
                          ? AppColors.primary.withValues(alpha: 0.13)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: ThemedIcon(
                      items[i].$1,
                      selected: i == selected,
                      size: 22,
                      color: i == selected
                          ? AppColors.primary
                          : AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    items[i].$2,
                    maxLines: 1,
                    style: TextStyle(
                      color: i == selected ? AppColors.navy : AppColors.muted,
                      fontSize: 10,
                      fontWeight: i == selected
                          ? FontWeight.w800
                          : FontWeight.w600,
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

class _Pill extends StatelessWidget {
  final String label;
  final bool selected;

  const _Pill(this.label, {this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? AppColors.primary : AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? AppColors.primary : AppColors.border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? AppColors.onPrimary : AppColors.navy,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MockPost extends StatelessWidget {
  final String name;
  final String meta;
  final String text;
  final bool image;

  const _MockPost({
    required this.name,
    required this.meta,
    required this.text,
    this.image = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: AppDecorations.card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.softPrimary,
                child: Text(
                  name.characters.first,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: AppColors.navy,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      meta,
                      style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Icon(Icons.more_horiz_rounded, color: AppColors.muted),
            ],
          ),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: AppColors.navy, fontSize: 14)),
          if (image) ...[
            const SizedBox(height: 10),
            Container(
              height: 140,
              decoration: BoxDecoration(
                borderRadius: AppShapes.circular(16),
                gradient: LinearGradient(
                  colors: [
                    AppColors.softPrimary,
                    AppColors.primary.withValues(alpha: 0.55),
                  ],
                ),
              ),
              child: Center(
                child: Icon(
                  Icons.image_outlined,
                  color: AppColors.onPrimary,
                  size: 36,
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _action(Icons.favorite_border_rounded, '24'),
              _action(Icons.chat_bubble_outline_rounded, '5'),
              _action(Icons.share_outlined, 'แชร์'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String label) => Row(
    children: [
      Icon(icon, size: 20, color: AppColors.navy),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: AppColors.navy, fontSize: 13)),
    ],
  );
}

// =======================================================
// ฟีด
// =======================================================

class _FeedPreview extends StatelessWidget {
  const _FeedPreview();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ThemeBackdrop()),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 170,
          child: ThemeHeaderArt(),
        ),
        Column(
          children: [
            const _PreviewHeader(),
            SectionSwitch<int>(
              value: 0,
              underline: true,
              onChanged: (_) {},
              options: const [
                SectionOption(
                  value: 0,
                  icon: Icons.auto_awesome,
                  label: 'สำหรับคุณ',
                ),
                SectionOption(value: 1, icon: Icons.schedule, label: 'ล่าสุด'),
                SectionOption(
                  value: 2,
                  icon: Icons.play_circle,
                  label: 'วิดีโอ',
                ),
              ],
            ),
            const SizedBox(height: 10),
            const SizedBox(
              height: 38,
              child: Padding(
                padding: EdgeInsets.only(left: 14),
                child: Row(
                  children: [
                    _Pill('ทั้งหมด', selected: true),
                    _Pill('ทั่วไป'),
                    _Pill('ถาม-ตอบ'),
                    _Pill('ข่าวสาร'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Column(
                  children: [
                    _MockPost(
                      name: 'ป้าแดง',
                      meta: 'ทั่วไป • วันนี้',
                      text: 'เช้านี้ไปตลาด ได้ผักสดมาเพียบเลย 🥬',
                      image: true,
                    ),
                    _MockPost(
                      name: 'ลุงสมชาย',
                      meta: 'ถาม-ตอบ • เมื่อวาน',
                      text: 'ใครรู้จักร้านซ่อมพัดลมแถวนี้บ้างครับ',
                    ),
                  ],
                ),
              ),
            ),
            const _PreviewNav(selected: 0),
          ],
        ),
        Positioned(
          right: 18,
          bottom: 92,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: AppShapes.circular(18),
            ),
            child: Icon(
              Icons.add_rounded,
              color: AppColors.onPrimary,
              size: 30,
            ),
          ),
        ),
      ],
    );
  }
}

// =======================================================
// แชท (ฟองข้อความ + ช่องพิมพ์ของจริง)
// =======================================================

class _ChatPreview extends StatefulWidget {
  const _ChatPreview();

  @override
  State<_ChatPreview> createState() => _ChatPreviewState();
}

class _ChatPreviewState extends State<_ChatPreview> {
  final TextEditingController controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.fromLTRB(10, 22, 10, 10),
          child: Row(
            children: [
              Icon(Icons.arrow_back_rounded, color: AppColors.navy),
              const SizedBox(width: 10),
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.softPrimary,
                child: Text(
                  'ล',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'ลุงสมชาย',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Icon(Icons.call_outlined, color: AppColors.primary),
              const SizedBox(width: 14),
              Icon(Icons.videocam_outlined, color: AppColors.primary),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              const Positioned.fill(child: ThemedChatBackground(custom: null)),
              ListView(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                children: const [
                  ChatBubble(
                    mine: false,
                    body: 'สวัสดีครับ วันนี้ว่างไหม',
                    semanticsLabel: '',
                    footer: '09:12',
                    endOfRun: true,
                  ),
                  SizedBox(height: 8),
                  ChatBubble(
                    mine: true,
                    body: 'ว่างค่ะ เย็นนี้ไปกินข้าวกันไหม',
                    semanticsLabel: '',
                    footer: '09:14',
                    footerIcon: Icons.done_all_rounded,
                    endOfRun: true,
                  ),
                  SizedBox(height: 8),
                  ChatBubble(
                    mine: false,
                    body: 'ได้เลย เดี๋ยวชวนน้องใหม่ด้วย 😊',
                    semanticsLabel: '',
                    footer: '09:15',
                    endOfRun: true,
                  ),
                  SizedBox(height: 8),
                  ChatBubble(
                    mine: true,
                    body: 'โอเคค่ะ เจอกันหกโมงนะ',
                    semanticsLabel: '',
                    footer: '09:16',
                    footerIcon: Icons.done_all_rounded,
                    endOfRun: true,
                  ),
                ],
              ),
            ],
          ),
        ),
        ChatComposer(
          controller: controller,
          image: null,
          canSend: false,
          onAttach: _noop,
          onRemoveImage: _noop,
          onSend: _noop,
        ),
      ],
    );
  }
}

// =======================================================
// ร้านค้า (การ์ดสินค้าของจริง ข้อมูลจำลอง ไม่มีปุ่มบันทึกที่ยิง API)
// =======================================================

class _ShopPreview extends StatelessWidget {
  const _ShopPreview();

  static final List<Map<String, dynamic>> products = [
    {
      'title': 'มะม่วงน้ำดอกไม้',
      'price': 60,
      'is_featured': true,
      'shop': {'name': 'สวนป้าแดง', 'province': 'เชียงใหม่'},
    },
    {
      'title': 'ผักสลัดออร์แกนิก',
      'price': 35,
      'shop': {'name': 'สวนป้าแดง', 'province': 'เชียงใหม่'},
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ThemeBackdrop()),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _PreviewHeader(title: 'ร้านค้า'),
            Container(
              margin: const EdgeInsets.fromLTRB(14, 6, 14, 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.fill,
                borderRadius: AppShapes.circular(18),
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, color: AppColors.muted),
                  const SizedBox(width: 8),
                  Text(
                    'ค้นหาสินค้าหรือร้านค้า',
                    style: TextStyle(color: AppColors.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(
              height: 38,
              child: Padding(
                padding: EdgeInsets.only(left: 14),
                child: Row(
                  children: [
                    _Pill('ทั้งหมด', selected: true),
                    _Pill('อาหาร'),
                    _Pill('ผักผลไม้'),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
              child: Text(
                'สินค้าสำหรับคุณ',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final Map<String, dynamic> product in products) ...[
                      Expanded(
                        child: SizedBox(
                          height: 290,
                          child: MarketProductCard(
                            product: product,
                            onTap: _noop,
                          ),
                        ),
                      ),
                      if (product != products.last) const SizedBox(width: 12),
                    ],
                  ],
                ),
              ),
            ),
            const _PreviewNav(selected: 1),
          ],
        ),
      ],
    );
  }
}

// =======================================================
// โปรไฟล์
// =======================================================

class _ProfilePreview extends StatelessWidget {
  const _ProfilePreview();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 22, 10, 4),
          child: Row(
            children: [
              Icon(Icons.arrow_back_rounded, color: AppColors.navy),
              const SizedBox(width: 12),
              Text(
                'โปรไฟล์',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          padding: const EdgeInsets.all(18),
          decoration: AppDecorations.card(),
          child: Column(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: AppColors.softPrimary,
                child: Text(
                  'แ',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'แม่ (ตัวอย่าง)',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                'ชอบทำอาหาร ปลูกผัก และเดินเล่นตอนเย็น',
                style: TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (final (String value, String label) in const [
                    ('12', 'โพสต์'),
                    ('48', 'ผู้ติดตาม'),
                    ('30', 'กำลังติดตาม'),
                  ])
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            value,
                            style: TextStyle(
                              color: AppColors.navy,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            label,
                            style: TextStyle(
                              color: AppColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _noop,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      child: const Text('แก้ไขโปรไฟล์'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _noop,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 44),
                      ),
                      child: const Text('แชร์โปรไฟล์'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: _MockPost(
            name: 'แม่ (ตัวอย่าง)',
            meta: 'กลุ่ม • 1 พ.ย.',
            text: 'ปลูกมะเขือเทศได้ผลแรกแล้ว 🍅',
            image: true,
          ),
        ),
      ],
    );
  }
}

// =======================================================
// กิจกรรม (การ์ดแผน + ชิป + หน้าว่างของธีม)
// =======================================================

class _ActivityPreview extends StatelessWidget {
  const _ActivityPreview();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ThemeBackdrop()),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _PreviewHeader(title: 'กิจกรรม'),
            Container(
              margin: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              padding: const EdgeInsets.all(16),
              decoration: AppDecorations.card(),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.softPrimary,
                          borderRadius: AppShapes.circular(14),
                        ),
                        child: Icon(
                          Icons.calendar_month_rounded,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'แผนของครอบครัว',
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      for (final (String value, String label, Color color) in [
                        ('3', 'ทั้งหมด', AppColors.navy),
                        ('1', 'สำเร็จ', AppColors.navy),
                        ('1', 'เลยกำหนด', AppColors.danger),
                      ])
                        Expanded(
                          child: Column(
                            children: [
                              Text(
                                value,
                                style: TextStyle(
                                  color: color,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                label,
                                style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(
              height: 38,
              child: Padding(
                padding: EdgeInsets.only(left: 14),
                child: Row(
                  children: [
                    _Pill('ทั้งหมด', selected: true),
                    _Pill('วันนี้'),
                    _Pill('เลยกำหนด'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Column(
                children: [
                  ThemeEmptyArt(
                    height: 130,
                    fallback: CircleAvatar(
                      radius: 52,
                      backgroundColor: AppColors.softPrimary,
                      child: Icon(
                        Icons.calendar_month_rounded,
                        color: AppColors.primary,
                        size: 50,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'ยังไม่มีกิจกรรม',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'บันทึกกิจกรรมส่วนตัว หรือแชร์ให้ครอบครัว',
                    style: TextStyle(color: AppColors.muted),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _noop,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('เพิ่มกิจกรรม'),
                  ),
                ],
              ),
            ),
            const _PreviewNav(selected: 4),
          ],
        ),
      ],
    );
  }
}
