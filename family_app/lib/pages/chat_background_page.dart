import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/chat_background_store.dart';
import '../theme/app_theme.dart';

// =======================================================
// ตั้งพื้นหลังห้องแชท (ส่วนตัว เฉพาะบัญชีนี้ในเครื่องนี้)
// สีพื้น / พื้นหลังสำเร็จรูป / รูปจากเครื่อง + ความจาง / ดูตัวอย่างก่อนบันทึก / คืนค่าเริ่มต้น
// คืนค่า true เมื่อมีการเปลี่ยน (ห้องโหลดพื้นหลังใหม่)
// =======================================================

class ChatBackgroundPage extends StatefulWidget {
  final int userId;
  final String roomKey;
  final ChatBackground? initial;

  const ChatBackgroundPage({
    super.key,
    required this.userId,
    required this.roomKey,
    this.initial,
  });

  @override
  State<ChatBackgroundPage> createState() => _ChatBackgroundPageState();
}

class _ChatBackgroundPageState extends State<ChatBackgroundPage> {
  late ChatBackground? selected = widget.initial;
  late double dim = widget.initial?.dim ?? 0.3;
  bool saving = false;

  void choose(String kind, String value) {
    setState(
      () => selected = ChatBackground(kind: kind, value: value, dim: dim),
    );
  }

  Future<void> pickPhoto() async {
    try {
      final XFile? image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 85,
      );

      if (image != null && mounted) choose('image', image.path);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('เลือกรูปไม่สำเร็จ')));
      }
    }
  }

  Future<void> save() async {
    final ChatBackground? value = selected;

    setState(() => saving = true);

    try {
      if (value == null) {
        await ChatBackgroundStore.reset(widget.userId, widget.roomKey);
      } else {
        await ChatBackgroundStore.save(
          widget.userId,
          widget.roomKey,
          value.copyWith(dim: dim),
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() => saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('บันทึกพื้นหลังไม่สำเร็จ')),
        );
      }
    }
  }

  Widget swatch({
    required String label,
    required bool chosen,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Semantics(
      button: true,
      selected: chosen,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: chosen ? AppColors.primary : AppColors.border,
              width: chosen ? 3 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }

  Widget bubble(String text, bool mine) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: mine ? AppColors.primary : AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: mine ? null : AppDecorations.cardBorder,
        ),
        child: Text(
          text,
          style: TextStyle(color: mine ? Colors.white : AppColors.navy),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ChatBackground? preview = selected?.copyWith(dim: dim);
    final TextStyle heading = TextStyle(
      color: AppColors.navy,
      fontSize: 15,
      fontWeight: FontWeight.w800,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('พื้นหลังแชท')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Semantics(
              label: 'ตัวอย่างพื้นหลัง',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  height: 200,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: AppColors.background),
                      ChatBackgroundLayer(background: preview),
                      Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            bubble('สวัสดีจ้า', false),
                            bubble('พื้นหลังใหม่อ่านง่ายไหม', true),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('สีพื้น', style: heading),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                swatch(
                  label: 'ค่าเริ่มต้น',
                  chosen: selected == null,
                  onTap: () => setState(() => selected = null),
                  child: Icon(Icons.block_rounded, color: AppColors.muted),
                ),
                for (final color in chatBackgroundColors)
                  swatch(
                    label: 'สีพื้น',
                    chosen:
                        selected?.kind == 'color' &&
                        selected?.value == '${color.toARGB32()}',
                    onTap: () => choose('color', '${color.toARGB32()}'),
                    child: ColoredBox(color: color),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Text('พื้นหลังสำเร็จรูป', style: heading),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final entry in chatBackgroundPresets.entries)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      swatch(
                        label: entry.value.name,
                        chosen:
                            selected?.kind == 'preset' &&
                            selected?.value == entry.key,
                        onTap: () => choose('preset', entry.key),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: entry.value.colors,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.value.name,
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: pickPhoto,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('ใช้รูปจากเครื่อง'),
            ),
            const SizedBox(height: 18),
            Text('ความจางของพื้นหลัง', style: heading),
            Slider(
              value: dim,
              max: 0.7,
              divisions: 7,
              label: '${(dim * 100).round()}%',
              semanticFormatterCallback: (value) =>
                  'ความจาง ${(value * 100).round()} เปอร์เซ็นต์',
              onChanged: selected == null
                  ? null
                  : (value) => setState(() => dim = value),
            ),
            Text(
              'พื้นหลังนี้เก็บไว้ในเครื่องนี้และบัญชีนี้เท่านั้น '
              'ไม่ซิงก์ไปเครื่องอื่น และสมาชิกคนอื่นไม่เห็น',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: saving
                        ? null
                        : () => setState(() => selected = null),
                    child: const Text('คืนค่าเริ่มต้น'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: saving ? null : save,
                    child: const Text('บันทึก'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
