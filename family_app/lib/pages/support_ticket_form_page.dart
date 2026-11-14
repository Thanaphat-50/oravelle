import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_helper.dart';
import '../services/support_service.dart';
import '../theme/app_theme.dart';
import '../widgets/support_widgets.dart';
import 'support_ticket_page.dart';

// =======================================================
// แจ้งปัญหาใหม่
// - เข้าจากคำสั่งซื้อ → แนบเลขคำสั่งซื้อให้อัตโนมัติ (แก้ไม่ได้)
//   มีเรื่องที่ยังไม่ปิดของคำสั่งซื้อ + ประเภทเดียวกัน → เสนอเปิดเรื่องเดิมก่อน
// - ไม่ต้องกรอกข้อมูลบัญชี (ระบบรู้จากการเข้าสู่ระบบ)
// - client_id เดียวต่อหน้า → กดซ้ำ / ส่งใหม่หลังหมดเวลา ไม่สร้างซ้ำ
// - ส่งไม่สำเร็จ: ข้อมูลที่กรอกยังอยู่
// - สำเร็จ → pop(ticketId)
// =======================================================

class SupportTicketFormPage extends StatefulWidget {
  final String? category;
  final String? subject;

  // {id, code} ของคำสั่งซื้อที่แจ้ง
  final Map<String, dynamic>? order;

  // {id, code} ของคำร้องเดิมที่อ้างอิง (สร้างเรื่องใหม่จากเรื่องที่ปิดแล้ว)
  final Map<String, dynamic>? previousTicket;

  const SupportTicketFormPage({
    super.key,
    this.category,
    this.subject,
    this.order,
    this.previousTicket,
  });

  @override
  State<SupportTicketFormPage> createState() => _SupportTicketFormPageState();
}

class _SupportTicketFormPageState extends State<SupportTicketFormPage> {
  late String? category = widget.category;
  late final TextEditingController subjectController = TextEditingController(
    text: widget.subject ?? '',
  );
  final TextEditingController bodyController = TextEditingController();

  final List<XFile> images = [];
  final ImagePicker picker = ImagePicker();

  final String clientId =
      'st-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

  bool isSending = false;
  String? error;

  int? get orderId => (widget.order?['id'] as num?)?.toInt();

  @override
  void initState() {
    super.initState();

    // เข้าจากคำสั่งซื้อ → ถามก่อนถ้ามีเรื่องเดิมที่ยังไม่ปิด
    if (orderId != null && category != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => checkOpenTicket());
    }
  }

  Future<void> checkOpenTicket() async {
    try {
      final result = await SupportService.openTicketForOrder(
        orderId: orderId!,
        category: category!,
      );

      final dynamic ticket = result['ticket'];

      if (mounted && ticket is Map) {
        await offerExisting(Map<String, dynamic>.from(ticket));
      }
    } catch (_) {
      // ตรวจไม่ได้ (เน็ต) → กรอกต่อได้ ตอนส่งเซิร์ฟเวอร์ตรวจอีกครั้ง
    }
  }

  // true = ผู้ใช้เลือกเขียนเรื่องใหม่
  Future<bool> offerExisting(Map<String, dynamic> ticket) async {
    final String? choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('มีเรื่องที่ยังไม่ปิดอยู่แล้ว'),
        content: Text(
          'คำร้อง ${ticket['code']} "${ticket['subject']}" '
          'ของคำสั่งซื้อนี้ยังไม่ปิด\n\n'
          'แนะนำให้เปิดเรื่องเดิมแล้วส่งข้อมูลเพิ่ม ทีมงานจะได้ตรวจในเรื่องเดียวกัน',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('new'),
            child: const Text('เขียนเรื่องใหม่'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('open'),
            child: const Text('เปิดเรื่องเดิม'),
          ),
        ],
      ),
    );

    if (!mounted) return false;

    if (choice == 'open') {
      final int? id = (ticket['id'] as num?)?.toInt();

      if (id != null) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => SupportTicketPage(ticketId: id)),
        );
      }

      return false;
    }

    return choice == 'new';
  }

  Future<void> pickImages() async {
    final int room = SupportService.maxImages - images.length;

    if (room <= 0) {
      setState(
        () => error = 'แนบรูปได้ไม่เกิน ${SupportService.maxImages} รูป',
      );
      return;
    }

    try {
      final List<XFile> picked = await picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 2000,
      );

      if (picked.isEmpty || !mounted) return;

      final List<String> problems = [];
      final List<XFile> accepted = [];

      for (final file in picked) {
        final String ext = file.name.split('.').last.toLowerCase();
        final int size = await file.length();

        if (!SupportService.imageTypes.contains(ext)) {
          problems.add('${file.name}: แนบได้เฉพาะรูป JPG, PNG หรือ WEBP');
        } else if (size > SupportService.maxImageMb * 1024 * 1024) {
          problems.add(
            '${file.name}: รูปต้องมีขนาดไม่เกิน ${SupportService.maxImageMb} MB',
          );
        } else if (accepted.length < room) {
          accepted.add(file);
        } else {
          problems.add('แนบรูปได้ไม่เกิน ${SupportService.maxImages} รูป');
          break;
        }
      }

      setState(() {
        images.addAll(accepted);
        error = problems.isEmpty ? null : problems.join('\n');
      });
    } catch (_) {
      if (mounted) setState(() => error = 'เลือกรูปไม่สำเร็จ');
    }
  }

  Future<void> submit({bool confirmNew = false}) async {
    if (isSending) return;

    final String subject = subjectController.text.trim();
    final String body = bodyController.text.trim();

    String? problem;

    if (category == null) {
      problem = 'กรุณาเลือกประเภทปัญหา';
    } else if (subject.isEmpty) {
      problem = 'กรุณาใส่หัวข้อ';
    } else if (body.isEmpty) {
      problem = 'กรุณาเล่ารายละเอียดของปัญหา';
    }

    if (problem != null) {
      setState(() => error = problem);
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      isSending = true;
      error = null;
    });

    try {
      final result = await SupportService.createTicket(
        clientId: clientId,
        category: category!,
        subject: subject,
        body: body,
        orderId: orderId,
        previousTicketId: (widget.previousTicket?['id'] as num?)?.toInt(),
        confirmNew: confirmNew,
        imagePaths: images.map((image) => image.path).toList(),
      );

      if (!mounted) return;

      final dynamic ticket = result['ticket'];

      if (result['status'] == true && ticket is Map) {
        Navigator.of(context).pop((ticket['id'] as num?)?.toInt());
        return;
      }

      // มีเรื่องเดิมที่ยังไม่ปิด → เสนอเปิดเรื่องเดิม / ยืนยันส่งเรื่องใหม่
      if (result['code'] == 'open_ticket_exists' && ticket is Map) {
        setState(() => isSending = false);

        if (await offerExisting(Map<String, dynamic>.from(ticket)) && mounted) {
          await submit(confirmNew: true);
        }
        return;
      }

      setState(
        () => error = result['message']?.toString() ?? 'ส่งเรื่องไม่สำเร็จ',
      );
    } catch (e) {
      if (mounted) setState(() => error = ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isSending = false);
    }
  }

  // =====================================================
  // UI
  // =====================================================

  Widget label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 16),
      child: Text(
        text,
        style: TextStyle(
          color: AppColors.navy,
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget buildImages() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (int i = 0; i < images.length; i++)
          Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(images[i].path),
                  width: 76,
                  height: 76,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                right: -8,
                top: -8,
                child: IconButton.filled(
                  tooltip: 'เอารูปออก',
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.navy,
                    minimumSize: const Size(28, 28),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: isSending
                      ? null
                      : () => setState(() => images.removeAt(i)),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        if (images.length < SupportService.maxImages)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: isSending ? null : pickImages,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('แนบรูป'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? order = widget.order;
    final Map<String, dynamic>? previous = widget.previousTicket;

    return PopScope(
      canPop: !isSending,
      child: Scaffold(
        appBar: AppBar(title: const Text('แจ้งปัญหา')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              18,
              8,
              18,
              24 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (order != null)
                  SupportNote(
                    icon: Icons.receipt_long_rounded,
                    color: AppColors.market,
                    text:
                        'แจ้งเรื่องคำสั่งซื้อ ${order['code']} (แนบให้อัตโนมัติ)\n'
                        'การแจ้งปัญหาไม่เปลี่ยนสถานะคำสั่งซื้อหรือการคืนเงิน '
                        'ทีมงานจะตรวจสอบและตอบกลับในคำร้องนี้',
                  ),
                if (previous != null) ...[
                  if (order != null) const SizedBox(height: 8),
                  SupportNote(
                    icon: Icons.history_rounded,
                    text: 'อ้างอิงเรื่องเดิม ${previous['code']}',
                  ),
                ],
                label('ประเภทปัญหา'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in SupportService.categories.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: category == entry.key,
                        onSelected: isSending
                            ? null
                            : (_) => setState(() => category = entry.key),
                      ),
                  ],
                ),
                label('หัวข้อ'),
                TextField(
                  controller: subjectController,
                  maxLength: 120,
                  enabled: !isSending,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    hintText: 'เช่น ยังไม่ได้รับเงินคืน',
                  ),
                ),
                label('รายละเอียด'),
                TextField(
                  controller: bodyController,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: 3000,
                  enabled: !isSending,
                  decoration: const InputDecoration(
                    hintText: 'เล่าสิ่งที่เกิดขึ้น เกิดเมื่อไร และคุยกับร้านแล้วได้ผลอย่างไร',
                    alignLabelWithHint: true,
                  ),
                ),
                label('รูปประกอบ (ไม่บังคับ)'),
                Text(
                  'แนบได้สูงสุด ${SupportService.maxImages} รูป · JPG, PNG หรือ WEBP · '
                  'รูปละไม่เกิน ${SupportService.maxImageMb} MB',
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                buildImages(),
                const SizedBox(height: 16),
                const SupportNote(
                  icon: Icons.lock_outline_rounded,
                  text:
                      'เรื่องนี้และรูปที่แนบเห็นได้เฉพาะคุณและทีมงาน ORAVELLE '
                      'ร้านค้าไม่เห็น ระบบแนบข้อมูลบัญชีของคุณให้แล้ว ไม่ต้องกรอกเพิ่ม',
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: TextStyle(
                      color: AppColors.danger,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: isSending ? null : submit,
                  child: isSending
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              images.isEmpty
                                  ? 'กำลังส่ง…'
                                  : 'กำลังส่งและอัปโหลดรูป…',
                            ),
                          ],
                        )
                      : const Text('ส่งเรื่องให้ทีมงานตรวจสอบ'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    subjectController.dispose();
    bodyController.dispose();
    super.dispose();
  }
}
