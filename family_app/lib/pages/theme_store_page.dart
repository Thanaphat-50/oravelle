import 'dart:async';

import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/chat_background_store.dart';
import '../services/theme_billing.dart';
import '../services/theme_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_theming.dart';
import '../theme/theme_spec.dart';
import '../widgets/section_switch.dart';
import '../widgets/theme_preview_screens.dart';

// =======================================================
// ตั้งค่า → ธีมและการตกแต่ง
// - ร้านธีม: ตัวกรองหมวด / การ์ดธีม / หน้ารายละเอียด (ภาพตัวอย่างหลายหน้า ลองธีม ซื้อ)
// - ธีมของฉัน: ธีมฟรี + ธีมที่บัญชีนี้มีสิทธิ์ / เปลี่ยนธีม / กลับธีมเริ่มต้น / ดาวน์โหลดซ้ำ / กู้คืนการซื้อ
// การซื้อเพิ่มแค่การตกแต่ง ทุกฟังก์ชันใช้ได้ครบกับธีมฟรี
// =======================================================

class ThemeStorePage extends StatefulWidget {
  const ThemeStorePage({super.key});

  @override
  State<ThemeStorePage> createState() => _ThemeStorePageState();
}

class _ThemeStorePageState extends State<ThemeStorePage> {
  int tab = 0;

  String category = 'all';

  bool loading = true;

  String? error;

  bool restoring = false;

  @override
  void initState() {
    super.initState();

    ThemePlayBilling.message.addListener(showBillingMessage);

    load();
  }

  @override
  void dispose() {
    ThemePlayBilling.message.removeListener(showBillingMessage);

    super.dispose();
  }

  void showBillingMessage() {
    final String? message = ThemePlayBilling.message.value;

    if (message == null || !mounted) return;

    ThemePlayBilling.message.value = null;

    showSnack(context, message);
  }

  Future<void> load() async {
    setState(() {
      loading = ThemeService.catalog.value == null;
      error = null;
    });

    try {
      final ThemeCatalog catalog = await ThemeService.refreshCatalog();

      if (catalog.provider == 'google_play') {
        ThemePlayBilling.start();

        await ThemePlayBilling.loadProducts([
          for (final ThemeListing theme in catalog.themes)
            if (theme.productId != null && !theme.isFree) theme.productId!,
        ]);
      }
    } on ThemeException catch (e) {
      error = e.message;
    } catch (e) {
      error = ThemeService.catalog.value == null
          ? 'โหลดร้านธีมไม่สำเร็จ ตรวจอินเทอร์เน็ตแล้วลองใหม่'
          : null;
    }

    if (mounted) setState(() => loading = false);
  }

  Future<void> restorePurchases() async {
    setState(() => restoring = true);

    try {
      if (ThemeService.catalog.value?.provider == 'google_play') {
        await ThemePlayBilling.restore();
      }

      final int count = await ThemeService.restore(const []);

      if (mounted) {
        showSnack(
          context,
          count == 0
              ? 'บัญชีนี้ยังไม่มีธีมที่ซื้อไว้'
              : 'กู้คืนแล้ว บัญชีนี้มีธีมที่ซื้อ $count ธีม',
        );
      }
    } catch (e) {
      if (mounted) showSnack(context, 'กู้คืนการซื้อไม่สำเร็จ ลองใหม่อีกครั้ง');
    } finally {
      if (mounted) setState(() => restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ธีมและการตกแต่ง')),
      body: Column(
        children: [
          SectionSwitch<int>(
            value: tab,
            underline: true,
            onChanged: (value) => setState(() => tab = value),
            options: const [
              SectionOption(
                value: 0,
                icon: Icons.storefront_outlined,
                label: 'ร้านธีม',
              ),
              SectionOption(
                value: 1,
                icon: Icons.palette_outlined,
                label: 'ธีมของฉัน',
              ),
            ],
          ),
          Expanded(
            child: ValueListenableBuilder<ThemeCatalog?>(
              valueListenable: ThemeService.catalog,
              builder: (context, catalog, child) {
                if (catalog == null) {
                  return loading
                      ? const Center(child: CircularProgressIndicator())
                      : _ErrorState(
                          message: error ?? 'โหลดร้านธีมไม่สำเร็จ',
                          onRetry: load,
                        );
                }

                return RefreshIndicator(
                  onRefresh: load,
                  child: tab == 0 ? buildStore(catalog) : buildMine(catalog),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // =====================================================
  // ร้านธีม
  // =====================================================

  Widget buildStore(ThemeCatalog catalog) {
    final List<ThemeListing> themes = [
      for (final ThemeListing theme in catalog.themes)
        if (category == 'all' || theme.category == category) theme,
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (String key, String label) in const [
                ('all', 'ทั้งหมด'),
                ('simple', 'เรียบง่าย'),
                ('nature', 'ธรรมชาติ'),
                ('dark', 'โหมดมืด'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _FilterPill(
                    label: label,
                    selected: category == key,
                    onTap: () => setState(() => category = key),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _SaleNotice(provider: catalog.provider),
        const SizedBox(height: 14),
        if (themes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text(
              'ยังไม่มีธีมในหมวดนี้',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          ),
        for (final ThemeListing theme in themes) ...[
          _ThemeCard(
            theme: theme,
            catalog: catalog,
            onOpen: () => openDetail(theme),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Future<void> openDetail(ThemeListing theme) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ThemeDetailPage(slug: theme.slug)),
    );

    if (mounted) setState(() {});
  }

  // =====================================================
  // ธีมของฉัน
  // =====================================================

  Widget buildMine(ThemeCatalog catalog) {
    final List<ThemeListing> mine = [
      for (final ThemeListing theme in catalog.themes)
        if (theme.isFree || theme.owned) theme,
    ];

    final List<ThemeListing> revoked = [
      for (final ThemeListing theme in catalog.themes)
        if (!theme.isFree && !theme.owned && theme.revokeReason != null) theme,
    ];

    return ValueListenableBuilder<Map<String, ThemeDownload>>(
      valueListenable: ThemeService.downloads,
      builder: (context, downloads, child) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.softPrimary,
              borderRadius: AppShapes.circular(18),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'ธีมที่ซื้อผูกกับบัญชี ใช้ได้ทุกเครื่องที่เข้าสู่ระบบบัญชีนี้ '
                    '(กด "กู้คืนการซื้อ" ในเครื่องใหม่) ส่วนธีมที่กำลังใช้ตั้งแยกในแต่ละเครื่อง',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (final ThemeListing theme in mine) ...[
            _MineRow(
              theme: theme,
              download: downloads[theme.slug],
              onUse: () => applyThemeFlow(context, theme),
              onRedownload: theme.builtIn ? null : () => redownload(theme),
            ),
            const SizedBox(height: 10),
          ],
          for (final ThemeListing theme in revoked) ...[
            _RevokedRow(theme: theme),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: AppTheming.active.isFree
                ? null
                : () => resetToDefault(context),
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('กลับธีมเริ่มต้น (Lavender)'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: restoring ? null : restorePurchases,
            icon: restoring
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.restore_rounded),
            label: Text(restoring ? 'กำลังกู้คืน...' : 'กู้คืนการซื้อ'),
          ),
        ],
      ),
    );
  }

  Future<void> redownload(ThemeListing theme) async {
    try {
      await ThemeService.ensurePack(theme, force: true);

      if (AppTheming.active.id == theme.slug) {
        await ThemeService.use(theme);
      }

      if (mounted) showSnack(context, 'ดาวน์โหลดธีม ${theme.name} ใหม่แล้ว');
    } on ThemeException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }
}

// =======================================================
// หน้ารายละเอียดธีม
// =======================================================

class ThemeDetailPage extends StatefulWidget {
  final String slug;

  const ThemeDetailPage({super.key, required this.slug});

  @override
  State<ThemeDetailPage> createState() => _ThemeDetailPageState();
}

class _ThemeDetailPageState extends State<ThemeDetailPage> {
  int page = 0;

  bool busy = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeCatalog?>(
      valueListenable: ThemeService.catalog,
      builder: (context, catalog, child) {
        final ThemeListing? theme = catalog?.bySlug(widget.slug);

        if (catalog == null || theme == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const _ErrorState(message: 'ไม่พบธีมนี้'),
          );
        }

        return Scaffold(
          appBar: AppBar(title: Text(theme.name)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              buildPreviews(theme),
              const SizedBox(height: 16),
              Text(
                theme.name,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Badge(ThemeListing.categoryLabel(theme.category)),
                  _Badge(
                    theme.modesLabel,
                    icon: theme.supportsLight
                        ? Icons.contrast_rounded
                        : Icons.dark_mode_outlined,
                  ),
                  if (theme.packBytes != null)
                    _Badge(
                      'ขนาด ${(theme.packBytes! / 1024).ceil()} KB',
                      icon: Icons.download_outlined,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                theme.description,
                style: TextStyle(
                  color: AppColors.subtle,
                  fontSize: 14.5,
                  height: 1.5,
                ),
              ),
              if (!theme.supportsLight || !theme.supportsDark) ...[
                const SizedBox(height: 10),
                Text(
                  theme.supportsDark
                      ? 'ธีมนี้ใช้โหมดมืดเสมอ แม้ตั้งค่าโหมดสีเป็นสว่าง'
                      : 'ธีมนี้ใช้โหมดสว่างเสมอ แม้ตั้งค่าโหมดสีเป็นมืด',
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                'สิ่งที่จะเปลี่ยน',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              for (final String change in theme.changes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 19,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          change,
                          style: TextStyle(color: AppColors.navy, fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                'ธีมเปลี่ยนเฉพาะหน้าตา เมนูและการใช้งานอยู่ที่เดิมทุกอย่าง '
                'ส่วนที่เป็นของระบบเครื่อง (คีย์บอร์ด กล้อง หน้าชำระเงิน หน้าขอสิทธิ์) และตัวแผนที่บางส่วนไม่เปลี่ยนตามธีม',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 12.5,
                  height: 1.45,
                ),
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: ValueListenableBuilder<Map<String, ThemeDownload>>(
                valueListenable: ThemeService.downloads,
                builder: (context, downloads, child) {
                  final ThemeDownload? download = downloads[theme.slug];

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (download != null && !download.failed) ...[
                        LinearProgressIndicator(
                          value: download.progress == 0
                              ? null
                              : download.progress,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'กำลังดาวน์โหลดธีม ${(download.progress * 100).round()}%',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Row(
                        children: [
                          // ลองได้ทุกธีมที่ไม่ได้ใช้อยู่ (รวม Lavender ตอนใช้ธีมอื่น)
                          if (AppTheming.active.id != theme.slug) ...[
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 50),
                                ),
                                onPressed: busy ? null : () => tryTheme(theme),
                                icon: const Icon(Icons.visibility_outlined),
                                label: const Text('ลองธีม'),
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(child: buildMainButton(catalog, theme)),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget buildPreviews(ThemeListing theme) {
    final int count = theme.previews.isEmpty ? 1 : theme.previews.length;

    return Column(
      children: [
        SizedBox(
          height: 380,
          child: PageView.builder(
            itemCount: count,
            onPageChanged: (value) => setState(() => page = value),
            itemBuilder: (context, index) {
              if (theme.previews.isEmpty) {
                return _SwatchPhone(theme: theme);
              }

              final ThemePreview preview = theme.previews[index];

              return Semantics(
                image: true,
                label: 'ภาพตัวอย่างหน้า${preview.label}',
                child: ClipRRect(
                  borderRadius: AppShapes.circular(22),
                  child: Image.network(
                    preview.url,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        _SwatchPhone(theme: theme),
                    loadingBuilder: (context, child, progress) =>
                        progress == null
                        ? child
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        if (theme.previews.length > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 0; i < theme.previews.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    theme.previews[i].label,
                    style: TextStyle(
                      color: i == page ? AppColors.primary : AppColors.muted,
                      fontSize: 12.5,
                      fontWeight: i == page ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
                ),
            ],
          )
        else
          Text(
            'กด "ลองธีม" เพื่อดูหน้าฟีด แชท ร้านค้า โปรไฟล์ และกิจกรรม',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
      ],
    );
  }

  Widget buildMainButton(ThemeCatalog catalog, ThemeListing theme) {
    final bool active = AppTheming.active.id == theme.slug;

    if (active) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
        onPressed: null,
        icon: const Icon(Icons.check_rounded),
        label: const Text('กำลังใช้งาน'),
      );
    }

    if (theme.isFree || theme.owned) {
      return FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
        onPressed: busy
            ? null
            : () => run(() => applyThemeFlow(context, theme)),
        child: const Text('ใช้งาน'),
      );
    }

    final String? price = priceLabel(catalog, theme);

    return FilledButton(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
      onPressed: busy || price == null
          ? null
          : () => run(() => buy(catalog, theme)),
      child: Text(price == null ? 'ยังไม่เปิดขาย' : 'ซื้อ $price'),
    );
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);

    try {
      await action();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> tryTheme(ThemeListing theme) async {
    final String? result = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ThemeTrialPage(theme: theme)),
    );

    if (!mounted || result == null) return;

    final ThemeCatalog? catalog = ThemeService.catalog.value;

    if (result == 'use') {
      await run(() => applyThemeFlow(context, theme));
    } else if (result == 'buy' && catalog != null) {
      await run(() => buy(catalog, theme));
    }
  }

  Future<void> buy(ThemeCatalog catalog, ThemeListing theme) async {
    if (catalog.provider == 'test') {
      final String? outcome = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => _TestPaySheet(theme: theme),
      );

      if (outcome == null || !mounted) return;

      try {
        final ThemeBuyResult result = await ThemeService.buyTest(
          theme,
          outcome,
        );

        if (!mounted) return;

        showSnack(context, result.message);

        if (result.purchased) {
          final ThemeListing? updated = ThemeService.catalog.value?.bySlug(
            theme.slug,
          );

          if (updated != null) await applyThemeFlow(context, updated);
        }
      } catch (e) {
        if (mounted) showSnack(context, 'ซื้อไม่สำเร็จ ลองใหม่อีกครั้ง');
      }

      return;
    }

    if (catalog.provider == 'google_play' && theme.productId != null) {
      try {
        if (!await ThemePlayBilling.available()) {
          throw const ThemeException(
            'Google Play ยังไม่พร้อมในเครื่องนี้ (ต้องติดตั้งแอปจาก Google Play และเข้าสู่ระบบ Play Store)',
          );
        }

        await ThemePlayBilling.buy(theme.productId!, catalog.accountRef);
      } on ThemeException catch (e) {
        if (mounted) showSnack(context, e.message);
      }
    }
  }
}

// ราคาที่แสดง = ราคาจากแหล่งที่เรียกเก็บจริง (Google Play / โหมดทดสอบ) — ไม่มี = ยังไม่เปิดขาย
String? priceLabel(ThemeCatalog catalog, ThemeListing theme) {
  if (theme.isFree) return null;

  return switch (catalog.provider) {
    'test' => theme.testPrice,
    'google_play' => ThemePlayBilling.product(theme.productId)?.price,
    _ => null,
  };
}

// =======================================================
// เปิดใช้ธีม: ดาวน์โหลด (ถ้ายังไม่มี) → ถามเรื่องพื้นหลังแชท (ถ้าตั้งเองไว้) → สลับธีม
// ล้มเหลว → ธีมเดิมยังใช้อยู่
// =======================================================

Future<void> applyThemeFlow(BuildContext context, ThemeListing theme) async {
  try {
    final AppThemeSpec spec = await ThemeService.ensurePack(theme);

    bool? preferThemeChat;

    final int? userId = await AuthService.userId();

    if (spec.decor.hasChatBackground &&
        userId != null &&
        await ChatBackgroundStore.hasAnyFor(userId)) {
      if (!context.mounted) return;

      preferThemeChat = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('พื้นหลังแชท'),
          content: const Text(
            'คุณตั้งพื้นหลังแชทเองไว้ในบางห้อง ต้องการใช้พื้นหลังของธีมนี้แทน หรือเก็บพื้นหลังที่ตั้งไว้?\n'
            '(พื้นหลังที่ตั้งเองไม่ถูกลบ เปลี่ยนใจภายหลังได้)',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('เก็บที่ตั้งเอง'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('ใช้ของธีม'),
            ),
          ],
        ),
      );

      if (preferThemeChat == null) return;
    }

    await ThemeService.use(theme, preferThemeChat: preferThemeChat ?? false);

    if (context.mounted) {
      showSnack(context, 'เปลี่ยนเป็นธีม ${theme.name} แล้ว');
    }
  } on ThemeException catch (e) {
    if (context.mounted) showSnack(context, e.message);
  }
}

Future<void> resetToDefault(BuildContext context) async {
  await ThemeService.useDefault();

  if (context.mounted) {
    showSnack(
      context,
      'กลับไปใช้ธีมเริ่มต้นแล้ว ธีมที่ซื้อไว้ยังอยู่ในธีมของฉัน',
    );
  }
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

// =======================================================
// ลองธีม (ไม่บันทึก ไม่ใช่สิทธิ์ ออกจากหน้านี้ = กลับธีมเดิม)
// =======================================================

class ThemeTrialPage extends StatefulWidget {
  final ThemeListing theme;

  const ThemeTrialPage({super.key, required this.theme});

  @override
  State<ThemeTrialPage> createState() => _ThemeTrialPageState();
}

class _ThemeTrialPageState extends State<ThemeTrialPage> {
  ThemePreviewScreen screen = ThemePreviewScreen.feed;

  String? error;

  bool ready = false;

  @override
  void initState() {
    super.initState();

    start();
  }

  Future<void> start() async {
    setState(() => error = null);

    try {
      final AppThemeSpec spec = await ThemeService.ensurePack(
        widget.theme,
        trial: true,
      );

      if (!mounted) return;

      AppTheming.startTrial(spec);

      setState(() => ready = true);
    } on ThemeException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  @override
  void dispose() {
    // ออกด้วยปุ่มย้อนกลับ / ปิดหน้า / ปิดแอป → ไม่บันทึกอะไร
    // dispose อยู่กลางรอบวาด (ต้นไม้ล็อกอยู่) → กลับธีมเดิมหลังรอบนี้จบ ให้ทุกหน้าวาดใหม่ได้
    scheduleMicrotask(AppTheming.endTrial);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeListing theme = widget.theme;

    final bool canUse = theme.isFree || theme.owned;

    final ThemeCatalog? catalog = ThemeService.catalog.value;

    final String? price = catalog == null ? null : priceLabel(catalog, theme);

    return Scaffold(
      appBar: AppBar(
        title: Text('ลองธีม ${theme.name}'),
        leading: IconButton(
          tooltip: 'ออกจากการลองธีม',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.softPrimary,
                borderRadius: AppShapes.circular(14),
              ),
              child: Text(
                canUse ? 'กำลังลองธีม ออกจากหน้านี้แล้วจะกลับธีมเดิม' : 'กำลังลองธีม (ยังไม่ได้ซื้อ) ออกจากหน้านี้แล้วจะกลับธีมเดิม',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final ThemePreviewScreen value
                      in ThemePreviewScreen.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _FilterPill(
                        label: value.label,
                        selected: screen == value,
                        onTap: () => setState(() => screen = value),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: error != null
                    ? _ErrorState(message: error!, onRetry: start)
                    : !ready
                    ? ValueListenableBuilder<Map<String, ThemeDownload>>(
                        valueListenable: ThemeService.downloads,
                        builder: (context, downloads, child) {
                          final double progress =
                              downloads[theme.slug]?.progress ?? 0;

                          return Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(
                                  value: progress == 0 ? null : progress,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'กำลังเตรียมธีม ${(progress * 100).round()}%',
                                  style: TextStyle(color: AppColors.muted),
                                ),
                              ],
                            ),
                          );
                        },
                      )
                    : Center(child: ThemePreviewFrame(screen: screen)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 50),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('ออกจากการลอง'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 50),
                      ),
                      onPressed: !ready
                          ? null
                          : canUse
                          ? () => Navigator.of(context).pop('use')
                          : price == null
                          ? null
                          : () => Navigator.of(context).pop('buy'),
                      child: Text(
                        canUse
                            ? 'ใช้งานธีมนี้'
                            : (price == null ? 'ยังไม่เปิดขาย' : 'ซื้อ $price'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =======================================================
// ส่วนประกอบย่อย
// =======================================================

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 18),
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
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final IconData? icon;

  const _Badge(this.label, {this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: AppColors.muted),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: AppColors.subtle,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SaleNotice extends StatelessWidget {
  final String? provider;

  const _SaleNotice({required this.provider});

  @override
  Widget build(BuildContext context) {
    final String? text = switch (provider) {
      'test' => 'โหมดทดสอบ: การซื้อเป็นการจำลอง ไม่มีการเก็บเงินจริง',
      null =>
        'ยังไม่เปิดขายธีม ดูรายละเอียดและกด "ลองธีม" ได้ก่อน ธีมฟรีใช้ได้ทันที',
      _ => null,
    };

    if (text == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.softWarm,
        borderRadius: AppShapes.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            provider == 'test'
                ? Icons.science_outlined
                : Icons.schedule_rounded,
            color: AppColors.warm,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: AppColors.navy, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// โทรศัพท์จำลองจากสีของธีม (ใช้เมื่อยังไม่มีภาพตัวอย่าง)
class _SwatchPhone extends StatelessWidget {
  final ThemeListing theme;
  final double scale;

  const _SwatchPhone({required this.theme, this.scale = 1});

  @override
  Widget build(BuildContext context) {
    final List<Color> c = theme.swatch.length >= 4
        ? theme.swatch
        : [
            AppColors.primary,
            AppColors.background,
            AppColors.surface,
            AppColors.softPrimary,
          ];

    final bool darkBg = c[1].computeLuminance() < 0.3;
    final Color line = darkBg ? Colors.white24 : Colors.black12;

    Widget bar(double width, {Color? color}) => Container(
      width: width * scale,
      height: 8 * scale,
      decoration: BoxDecoration(
        color: color ?? line,
        borderRadius: BorderRadius.circular(99),
      ),
    );

    return ExcludeSemantics(
      child: Center(
        child: AspectRatio(
          aspectRatio: 0.52,
          child: Container(
            padding: EdgeInsets.all(12 * scale),
            decoration: BoxDecoration(
              color: c[1],
              borderRadius: BorderRadius.circular(26 * scale),
              border: Border.all(color: AppColors.border, width: 4 * scale),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(radius: 9 * scale, backgroundColor: c[3]),
                    SizedBox(width: 6 * scale),
                    bar(60, color: c[0]),
                  ],
                ),
                SizedBox(height: 12 * scale),
                for (int i = 0; i < 2; i++) ...[
                  Container(
                    height: 70 * scale,
                    width: double.infinity,
                    padding: EdgeInsets.all(8 * scale),
                    decoration: BoxDecoration(
                      color: c[2],
                      borderRadius: BorderRadius.circular(14 * scale),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        bar(50),
                        SizedBox(height: 6 * scale),
                        bar(90),
                        const Spacer(),
                        bar(30, color: c[0]),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * scale),
                ],
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    for (int i = 0; i < 5; i++)
                      CircleAvatar(
                        radius: 6 * scale,
                        backgroundColor: i == 0 ? c[0] : line,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  final ThemeListing theme;
  final ThemeCatalog catalog;
  final VoidCallback onOpen;

  const _ThemeCard({
    required this.theme,
    required this.catalog,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final bool active = AppTheming.active.id == theme.slug;

    final String status = active
        ? 'กำลังใช้งาน'
        : theme.isFree
        ? 'ฟรี'
        : theme.owned
        ? 'ซื้อแล้ว'
        : (priceLabel(catalog, theme) ?? 'ยังไม่เปิดขาย');

    return Semantics(
      button: true,
      label: '${theme.name} ${theme.modesLabel} $status',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppShapes.circular(22),
          boxShadow: AppDecorations.cardShadow,
        ),
        child: Material(
          color: AppColors.surface,
          borderRadius: AppShapes.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onOpen,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: AppShapes.circular(22),
                border: active
                    ? Border.all(color: AppColors.primary, width: 2)
                    : AppDecorations.cardBorder,
              ),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  SizedBox(
                    width: 86,
                    height: 150,
                    child: theme.previews.isEmpty
                        ? _SwatchPhone(theme: theme, scale: 0.42)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.network(
                              theme.previews.first.url,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  _SwatchPhone(theme: theme, scale: 0.42),
                            ),
                          ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          theme.name,
                          style: TextStyle(
                            color: AppColors.navy,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          theme.description,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _Badge(theme.modesLabel),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: active || theme.owned || theme.isFree
                                    ? AppColors.softPrimary
                                    : AppColors.primary,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (active) ...[
                                    Icon(
                                      Icons.check_rounded,
                                      size: 15,
                                      color: AppColors.primary,
                                    ),
                                    const SizedBox(width: 3),
                                  ],
                                  Text(
                                    status,
                                    style: TextStyle(
                                      color:
                                          active || theme.owned || theme.isFree
                                          ? AppColors.primary
                                          : AppColors.onPrimary,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MineRow extends StatelessWidget {
  final ThemeListing theme;
  final ThemeDownload? download;
  final VoidCallback onUse;
  final VoidCallback? onRedownload;

  const _MineRow({
    required this.theme,
    required this.download,
    required this.onUse,
    required this.onRedownload,
  });

  @override
  Widget build(BuildContext context) {
    final bool active = AppTheming.active.id == theme.slug;
    final ThemeDownload? d = download;

    final String status = d != null && !d.failed
        ? 'กำลังดาวน์โหลด ${(d.progress * 100).round()}%'
        : d != null && d.failed
        ? d.error!
        : active
        ? 'กำลังใช้งาน'
        : theme.isFree
        ? 'ธีมฟรี ติดมากับแอป'
        : 'ซื้อแล้ว';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: AppDecorations.card(radius: 18),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: theme.swatch.length >= 2
                    ? [theme.swatch[0], theme.swatch[1]]
                    : [AppColors.primary, AppColors.softPrimary],
              ),
              border: Border.all(color: AppColors.border),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  theme.name,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: TextStyle(
                    color: d?.failed == true
                        ? AppColors.danger
                        : AppColors.muted,
                    fontSize: 12.5,
                  ),
                ),
                if (d != null && !d.failed) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: d.progress == 0 ? null : d.progress,
                  ),
                ],
              ],
            ),
          ),
          if (d?.failed == true)
            TextButton(onPressed: onUse, child: const Text('ลองใหม่'))
          else if (active)
            Icon(Icons.check_circle_rounded, color: AppColors.primary)
          else
            TextButton(
              onPressed: d == null ? onUse : null,
              child: const Text('ใช้งาน'),
            ),
          if (onRedownload != null)
            PopupMenuButton<String>(
              tooltip: 'ตัวเลือกเพิ่มเติม',
              onSelected: (_) => onRedownload!(),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'redownload', child: Text('ดาวน์โหลดซ้ำ')),
              ],
            ),
        ],
      ),
    );
  }
}

class _RevokedRow extends StatelessWidget {
  final ThemeListing theme;

  const _RevokedRow({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: AppDecorations.card(radius: 18, color: AppColors.fill),
      child: Row(
        children: [
          Icon(Icons.block_rounded, color: AppColors.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${theme.name} — สิทธิ์ถูกยกเลิก (${ThemeListing.revokeReasonLabel(theme.revokeReason)})',
              style: TextStyle(color: AppColors.subtle, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _TestPaySheet extends StatelessWidget {
  final ThemeListing theme;

  const _TestPaySheet({required this.theme});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined, color: AppColors.warm),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ชำระเงินจำลอง (โหมดทดสอบ)',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${theme.name} ${theme.testPrice ?? ''} — ไม่มีการเก็บเงินจริง เลือกผลลัพธ์ที่ต้องการทดสอบ',
              style: TextStyle(color: AppColors.muted, fontSize: 13.5),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: () => Navigator.of(context).pop('purchased'),
              icon: const Icon(Icons.check_rounded),
              label: const Text('ชำระสำเร็จ'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: () => Navigator.of(context).pop('pending'),
              icon: const Icon(Icons.hourglass_top_rounded),
              label: const Text('รอชำระเงิน'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: () => Navigator.of(context).pop('cancelled'),
              icon: const Icon(Icons.close_rounded),
              label: const Text('ยกเลิกการชำระเงิน'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function()? onRetry;

  const _ErrorState({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.muted),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.navy),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('ลองใหม่')),
            ],
          ],
        ),
      ),
    );
  }
}
