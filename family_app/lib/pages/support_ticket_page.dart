import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/market_data.dart';
import '../services/api_helper.dart';
import '../services/support_service.dart';
import '../theme/app_theme.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/support_widgets.dart';
import 'support_ticket_form_page.dart';

// =======================================================
// รายละเอียดคำร้อง: ข้อความกับทีมงานตามลำดับเวลา + ส่งข้อมูลเพิ่ม
// - เรื่องที่ยังไม่ปิด: ส่งข้อความ/รูปเพิ่มได้
//   ส่งไม่สำเร็จ → ข้อความร่างและรูปยังอยู่ ส่งใหม่ใช้ client_id เดิม (เซิร์ฟเวอร์ไม่สร้างซ้ำ)
// - ปิดแล้ว: อ่านได้ + สร้างเรื่องใหม่โดยอ้างอิงเรื่องนี้
// - เปิดได้เฉพาะเจ้าของคำร้อง (เซิร์ฟเวอร์ตรวจ — ของคนอื่นได้ "ไม่พบคำร้องนี้")
// =======================================================

class SupportTicketPage extends StatefulWidget {
  final int ticketId;

  const SupportTicketPage({super.key, required this.ticketId});

  @override
  State<SupportTicketPage> createState() => _SupportTicketPageState();
}

class _SupportTicketPageState extends State<SupportTicketPage> {
  Map<String, dynamic>? ticket;
  bool isLoading = true;
  String? loadError;

  final TextEditingController inputController = TextEditingController();
  final List<XFile> images = [];
  final ImagePicker picker = ImagePicker();

  bool isSending = false;
  String? sendError;

  // รหัสของข้อความที่กำลังส่ง: ส่งไม่สำเร็จแล้วกดใหม่ใช้รหัสเดิม
  String? pendingClientId;

  @override
  void initState() {
    super.initState();
    load();
  }

  List<Map<String, dynamic>> get messages {
    final dynamic raw = ticket?['messages'];

    if (raw is! List) return [];

    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  bool get canReply => ticket?['can_reply'] == true;

  Future<void> load() async {
    try {
      final result = await SupportService.getTicket(widget.ticketId);

      if (!mounted) return;

      final dynamic data = result['ticket'];

      if (result['status'] == true && data is Map) {
        setState(() {
          ticket = Map<String, dynamic>.from(data);
          loadError = null;
        });
      } else if (ticket == null) {
        setState(
          () => loadError =
              result['message']?.toString() ?? 'เปิดคำร้องไม่สำเร็จ',
        );
      }
    } catch (e) {
      if (!mounted) return;

      if (ticket == null) {
        setState(() => loadError = ApiHelper.messageOf(e));
      } else {
        showMessage(ApiHelper.messageOf(e));
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> pickImages() async {
    final int room = SupportService.maxImages - images.length;

    if (room <= 0) return;

    try {
      final List<XFile> picked = await picker.pickMultiImage(
        imageQuality: 85,
        maxWidth: 2000,
      );

      final List<XFile> accepted = [];
      String? problem;

      for (final file in picked) {
        final String ext = file.name.split('.').last.toLowerCase();

        if (!SupportService.imageTypes.contains(ext)) {
          problem = 'แนบได้เฉพาะรูป JPG, PNG หรือ WEBP';
        } else if (await file.length() >
            SupportService.maxImageMb * 1024 * 1024) {
          problem = 'รูปต้องมีขนาดไม่เกิน ${SupportService.maxImageMb} MB';
        } else if (accepted.length < room) {
          accepted.add(file);
        } else {
          problem = 'แนบรูปได้ไม่เกิน ${SupportService.maxImages} รูป';
        }
      }

      if (!mounted) return;

      setState(() {
        images.addAll(accepted);
        sendError = problem;
      });
    } catch (_) {
      if (mounted) setState(() => sendError = 'เลือกรูปไม่สำเร็จ');
    }
  }

  Future<void> send() async {
    final String body = inputController.text.trim();

    if (isSending || (body.isEmpty && images.isEmpty)) return;

    pendingClientId ??=
        'sm-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';

    setState(() {
      isSending = true;
      sendError = null;
    });

    try {
      final result = await SupportService.sendMessage(
        ticketId: widget.ticketId,
        clientId: pendingClientId!,
        body: body,
        imagePaths: images.map((image) => image.path).toList(),
      );

      if (!mounted) return;

      final dynamic message = result['message'];

      if (result['status'] == true && message is Map) {
        final dynamic summary = result['ticket'];

        setState(() {
          final List<Map<String, dynamic>> list = messages;

          if (!list.any((m) => m['id'] == message['id'])) {
            list.add(Map<String, dynamic>.from(message));
          }

          ticket = {
            ...?ticket,
            if (summary is Map) ...Map<String, dynamic>.from(summary),
            'messages': list,
          };

          // ส่งสำเร็จแล้วค่อยล้างร่าง
          inputController.clear();
          images.clear();
          pendingClientId = null;
        });

        return;
      }

      // เรื่องถูกปิดระหว่างนี้ → โหลดใหม่ (ร่างยังอยู่ให้คัดลอกไปเรื่องใหม่)
      if (result['code'] == 'ticket_closed') {
        await load();
      }

      if (mounted) {
        setState(
          () => sendError = result['message']?.toString() ?? 'ส่งไม่สำเร็จ',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => sendError =
              '${ApiHelper.messageOf(e)} ข้อความยังอยู่ กดส่งอีกครั้งได้',
        );
      }
    } finally {
      if (mounted) setState(() => isSending = false);
    }
  }

  Future<void> createFollowUp() async {
    final Map<String, dynamic>? data = ticket;

    if (data == null) return;

    final dynamic order = data['order'];

    final int? createdId = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => SupportTicketFormPage(
          category: data['category']?.toString(),
          order: order is Map ? Map<String, dynamic>.from(order) : null,
          previousTicket: {'id': data['id'], 'code': data['code']},
        ),
      ),
    );

    if (createdId != null && mounted) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SupportTicketPage(ticketId: createdId),
        ),
      );
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildHeader(Map<String, dynamic> data) {
    final dynamic order = data['order'];
    final dynamic previous = data['previous_ticket'];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: AppDecorations.cardBorder,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  data['code']?.toString() ?? '',
                  style: TextStyle(
                    color: AppColors.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SupportStatusBadge(
                status: data['status']?.toString(),
                label: data['status_label']?.toString() ?? '',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            data['subject']?.toString() ?? '',
            style: TextStyle(
              color: AppColors.navy,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [
              data['category_label']?.toString() ?? '',
              if (order is Map) 'คำสั่งซื้อ ${order['code']}',
              if (previous is Map) 'อ้างอิง ${previous['code']}',
              'อัปเดต ${formatDateTime(data['updated_at'])}',
            ].join(' · '),
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildMessage(Map<String, dynamic> message) {
    final bool mine = message['from'] == 'me';
    final String body = message['body']?.toString() ?? '';

    final List<String> urls = (message['attachments'] is List)
        ? (message['attachments'] as List)
              .whereType<Map>()
              .map((a) => a['url']?.toString() ?? '')
              .where((url) => url.isNotEmpty)
              .toList()
        : [];

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: mine
                ? AppColors.primary.withValues(alpha: 0.12)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: mine ? null : AppDecorations.cardBorder,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${message['author'] ?? ''} · ${formatDateTime(message['created_at'])}',
                style: TextStyle(
                  color: mine ? AppColors.primary : AppColors.sky,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (body.isNotEmpty) ...[
                const SizedBox(height: 5),
                SelectableText(
                  body,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 14.5,
                    height: 1.5,
                  ),
                ),
              ],
              if (urls.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (int i = 0; i < urls.length; i++)
                      GestureDetector(
                        onTap: () => showPhotoViewer(
                          context,
                          urls: urls,
                          initialIndex: i,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.network(
                            urls[i],
                            width: 86,
                            height: 86,
                            fit: BoxFit.cover,
                            // ลิงก์ชั่วคราวหมดอายุ → ดึงลงเพื่อโหลดใหม่
                            errorBuilder: (context, error, stack) => Container(
                              width: 86,
                              height: 86,
                              color: AppColors.fill,
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.refresh_rounded,
                                color: AppColors.muted,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget buildClosed(Map<String, dynamic> data) {
    final String resolution = data['resolution']?.toString() ?? '';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'ปิดเรื่องแล้ว · ${formatDateTime(data['closed_at'])}',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (resolution.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'สรุปผล: $resolution',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
            onPressed: createFollowUp,
            icon: const Icon(Icons.add_comment_outlined),
            label: const Text('ยังมีปัญหา? สร้างเรื่องใหม่โดยอ้างอิงเรื่องนี้'),
          ),
        ],
      ),
    );
  }

  Widget buildComposer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (images.isNotEmpty)
              SizedBox(
                height: 64,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (int i = 0; i < images.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: isSending
                              ? null
                              : () => setState(() => images.removeAt(i)),
                          child: Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(images[i].path),
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const Positioned(
                                right: 2,
                                top: 2,
                                child: Icon(
                                  Icons.cancel,
                                  size: 18,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (sendError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  sendError!,
                  style: TextStyle(color: AppColors.danger, fontSize: 12.5),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip:
                      'แนบรูป (สูงสุด ${SupportService.maxImages} รูป · JPG, PNG, WEBP · ไม่เกิน ${SupportService.maxImageMb} MB)',
                  onPressed:
                      isSending || images.length >= SupportService.maxImages
                      ? null
                      : pickImages,
                  icon: Icon(
                    Icons.add_photo_alternate_outlined,
                    color: AppColors.primary,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: inputController,
                    readOnly: isSending,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 3000,
                    decoration: const InputDecoration(
                      hintText: 'ส่งข้อมูลเพิ่มเติมให้ทีมงาน…',
                      counterText: '',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: 'ส่ง',
                  onPressed: isSending ? null : send,
                  icon: isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? data = ticket;

    Widget body;

    if (isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (data == null) {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(28, 80, 28, 28),
        children: [
          Icon(Icons.cloud_off_rounded, size: 44, color: AppColors.muted),
          const SizedBox(height: 10),
          Text(
            loadError ?? 'เปิดคำร้องไม่สำเร็จ',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.navy, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 14),
          Center(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(160, 44)),
              onPressed: () {
                setState(() => isLoading = true);
                load();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('ลองอีกครั้ง'),
            ),
          ),
        ],
      );
    } else {
      body = Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
                children: [
                  buildHeader(data),
                  if (data['status'] == 'waiting_user') ...[
                    const SizedBox(height: 10),
                    const SupportNote(
                      icon: Icons.info_outline_rounded,
                      color: Color(0xFFF79009),
                      text: 'ทีมงานขอข้อมูลเพิ่มเติม ส่งข้อมูลหรือรูปได้ที่ช่องด้านล่าง',
                    ),
                  ],
                  const SizedBox(height: 14),
                  ...messages.map(buildMessage),
                  if (!canReply) ...[
                    const SizedBox(height: 6),
                    buildClosed(data),
                  ],
                ],
              ),
            ),
          ),
          if (canReply) buildComposer(),
        ],
      );
    }

    return PopScope(
      canPop: !isSending,
      child: Scaffold(
        appBar: AppBar(title: const Text('คำร้อง')),
        body: body,
      ),
    );
  }

  @override
  void dispose() {
    inputController.dispose();
    super.dispose();
  }
}
