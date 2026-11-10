import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_helper.dart';
import '../services/post_service.dart';
import '../theme/app_theme.dart';

// =======================================================
// แก้ไขข้อความโพสต์ของตัวเอง
// - แก้เฉพาะข้อความ (รูป วิดีโอ หมวด ผู้ชม และต้นฉบับที่แชร์ไม่เปลี่ยน)
// - ยาวไม่เกิน 5,000 ตัวอักษร (ตรงกับตอนสร้างโพสต์)
// - บันทึกไม่สำเร็จ → ข้อความร่างยังอยู่ / ย้อนกลับโดยยังไม่บันทึก → ถามก่อนทิ้ง
// - แก้จากอีกเครื่องไปแล้ว (409) → แสดงข้อความล่าสุด ให้เลือกใช้ข้อความล่าสุดหรือแก้ต่อจากของเรา
// - pop(post) = บันทึกแล้ว (ข้อมูลโพสต์ล่าสุดจากเซิร์ฟเวอร์)
// =======================================================

class PostEditPage extends StatefulWidget {
  final Map<String, dynamic> post;

  const PostEditPage({super.key, required this.post});

  // ตรงกับ Laravel (content max:5000)
  static const int maxLength = 5000;

  @override
  State<PostEditPage> createState() => _PostEditPageState();
}

class _PostEditPageState extends State<PostEditPage> {
  late final TextEditingController controller = TextEditingController(
    text: widget.post['content']?.toString() ?? '',
  );

  // ข้อความและ version ที่บันทึกอยู่บนเซิร์ฟเวอร์ (เปลี่ยนเมื่อรู้ว่ามีเวอร์ชันใหม่กว่า)
  late String savedText = widget.post['content']?.toString() ?? '';
  late int version = _intOf(widget.post['edit_version']);

  bool isSaving = false;
  String? error;

  // โพสต์ถูกลบ / หมดสิทธิ์ระหว่างแก้ → บันทึกไม่ได้แล้ว
  bool unavailable = false;

  static int _intOf(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;

  // โพสต์ที่มีรูป/วิดีโอ หรือโพสต์แชร์ → ข้อความว่างได้
  bool get canBeEmpty {
    final dynamic images = widget.post['images'];

    return widget.post['shared_post_id'] != null ||
        widget.post['shared_post'] is Map ||
        (images is List && images.isNotEmpty) ||
        widget.post['video'] is Map;
  }

  bool get dirty => controller.text.trim() != savedText.trim();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final String text = controller.text.trim();

    if (text.isEmpty && !canBeEmpty) {
      setState(
        () =>
            error = 'กรุณาพิมพ์ข้อความ โพสต์ที่ไม่มีรูปหรือวิดีโอต้องมีข้อความ',
      );
      return;
    }

    final dynamic rawId = widget.post['id'];

    if (rawId is! num) return;

    FocusScope.of(context).unfocus();

    setState(() {
      isSaving = true;
      error = null;
    });

    try {
      final result = await PostService.updatePost(
        postId: rawId.toInt(),
        content: text,
        version: version,
      );

      if (!mounted) return;

      final dynamic post = result['post'];

      if (result['status'] == true && post is Map) {
        Navigator.of(context).pop(Map<String, dynamic>.from(post));
        return;
      }

      if (result['code'] == 'edit_conflict' && post is Map) {
        // หยุดสถานะกำลังบันทึกก่อนถาม
        setState(() => isSaving = false);
        await showConflict(Map<String, dynamic>.from(post));
        return;
      }

      setState(() {
        error = result['message']?.toString() ?? 'บันทึกไม่สำเร็จ';

        // ถูกลบ / ถูกซ่อน / ไม่มีสิทธิ์แล้ว → ข้อความร่างยังอยู่ให้คัดลอกได้ แต่บันทึกไม่ได้
        unavailable = const {
          'post_missing',
          'post_hidden',
          'not_owner',
          'not_in_group',
        }.contains(result['code']);
      });
    } catch (e) {
      // เน็ตหลุด / เซิร์ฟเวอร์ขัดข้อง → ข้อความร่างยังอยู่ กดบันทึกใหม่ได้
      if (mounted) setState(() => error = ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  // มีเวอร์ชันใหม่กว่าจากอีกเครื่อง → ให้ผู้ใช้เลือก (ไม่เขียนทับเงียบ ๆ)
  Future<void> showConflict(Map<String, dynamic> latest) async {
    final String latestText = latest['content']?.toString() ?? '';

    final String? choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('มีการแก้ไขจากอีกเครื่อง'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('ข้อความล่าสุดบนเซิร์ฟเวอร์คือ'),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.fill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(latestText.isEmpty ? '(ไม่มีข้อความ)' : latestText),
              ),
              const SizedBox(height: 10),
              const Text(
                'เลือกใช้ข้อความล่าสุด หรือแก้ต่อจากข้อความของคุณแล้วกดบันทึกอีกครั้ง',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('mine'),
            child: const Text('แก้ต่อจากของฉัน'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('latest'),
            child: const Text('ใช้ข้อความล่าสุด'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    setState(() {
      // รับรู้เวอร์ชันล่าสุดแล้ว → บันทึกครั้งถัดไปจะไม่ชนอีก
      version = _intOf(latest['edit_version']);
      savedText = latestText;

      if (choice == 'latest') {
        controller.text = latestText;
        error = null;
      } else {
        error = 'ข้อความของคุณยังไม่ถูกบันทึก ตรวจแล้วกดบันทึกอีกครั้ง';
      }
    });
  }

  Future<bool> confirmDiscard() async {
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ทิ้งการแก้ไข?'),
        content: const Text('ข้อความที่แก้ไว้ยังไม่ได้บันทึก'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('แก้ต่อ'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('ทิ้ง', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );

    return discard == true;
  }

  @override
  Widget build(BuildContext context) {
    final bool shared =
        widget.post['shared_post_id'] != null ||
        widget.post['shared_post'] is Map;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || isSaving) return;

        if (!dirty || unavailable || await confirmDiscard()) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('แก้ไขโพสต์'),
          leading: IconButton(
            tooltip: 'ยกเลิก',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton(
                onPressed: isSaving || unavailable || !dirty ? null : save,
                child: isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('บันทึก'),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          children: [
            Text(
              shared
                  ? 'แก้ได้เฉพาะข้อความที่คุณเขียนประกอบ ต้นฉบับที่แชร์มาไม่เปลี่ยน'
                  : 'แก้ได้เฉพาะข้อความ รูป วิดีโอ หมวด และผู้ที่เห็นโพสต์ไม่เปลี่ยน',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 5,
              maxLines: 14,
              enabled: !isSaving && !unavailable,
              keyboardType: TextInputType.multiline,
              inputFormatters: [
                LengthLimitingTextInputFormatter(PostEditPage.maxLength),
              ],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: canBeEmpty
                    ? 'เขียนข้อความ (ไม่ใส่ก็ได้)'
                    : 'เขียนข้อความ',
                counterText:
                    '${controller.text.characters.length}/${PostEditPage.maxLength}',
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      color: AppColors.danger,
                      size: 19,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        error!,
                        style: TextStyle(color: AppColors.navy, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
