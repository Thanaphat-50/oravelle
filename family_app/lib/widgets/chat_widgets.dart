import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_theme.dart';
import 'user_avatar.dart';

// =======================================================
// ส่วนประกอบห้องแชท (ใช้ร่วมกัน: แชทส่วนตัว / ร้านค้า / กลุ่ม)
// - ข้อความต่อเนื่องจากผู้ส่งคนเดียวกัน (วันเดียวกัน ห่างไม่เกิน 5 นาที) = ชุดเดียวกัน
//   ชื่อ/รูปแสดงครั้งเดียวต่อชุด เวลาอยู่ใต้ข้อความสุดท้ายของชุด
// - ตัวแบ่งวัน / เส้น "ข้อความที่ยังไม่ได้อ่าน" / ปุ่ม "↓ ข้อความใหม่"
// - เคารพการตั้งค่าลดการเคลื่อนไหว (MediaQuery.disableAnimations)
// =======================================================

class ChatFormat {
  static DateTime? timeOf(Map<String, dynamic> message) =>
      DateTime.tryParse(message['created_at']?.toString() ?? '')?.toLocal();

  static String time(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  static bool sameDay(DateTime? a, DateTime? b) =>
      a != null &&
      b != null &&
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day;

  static String dayLabel(DateTime time) {
    const months = [
      '',
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.',
    ];

    final DateTime now = DateTime.now();
    final int diff = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(time.year, time.month, time.day)).inDays;

    if (diff == 0) return 'วันนี้';
    if (diff == 1) return 'เมื่อวาน';

    return '${time.day} ${months[time.month]} ${time.year}';
  }

  // ชุดเดียวกัน: ผู้ส่งเดียวกัน วันเดียวกัน ห่างกันไม่เกิน 5 นาที
  static bool sameRun(
    Map<String, dynamic>? previous,
    Map<String, dynamic> current,
    Object? Function(Map<String, dynamic>) senderOf,
  ) {
    if (previous == null || senderOf(previous) != senderOf(current)) {
      return false;
    }

    final DateTime? a = timeOf(previous);
    final DateTime? b = timeOf(current);

    if (a == null || b == null) return true;

    return sameDay(a, b) && b.difference(a).inMinutes.abs() <= 5;
  }
}

class ChatDayDivider extends StatelessWidget {
  final DateTime day;

  const ChatDayDivider({super.key, required this.day});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.fill,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Text(
            ChatFormat.dayLabel(day),
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

// เส้นบอกว่าข้อความถัดจากนี้ยังไม่ได้อ่าน (ตามตำแหน่งอ่านตอนเปิดห้อง)
class ChatUnreadDivider extends StatelessWidget {
  const ChatUnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final Color color = AppColors.primary;

    return Semantics(
      label: 'ข้อความที่ยังไม่ได้อ่านเริ่มจากตรงนี้',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(child: Divider(color: color.withValues(alpha: 0.5))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'ข้อความที่ยังไม่ได้อ่าน',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(child: Divider(color: color.withValues(alpha: 0.5))),
          ],
        ),
      ),
    );
  }
}

class ChatNewMessagesButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const ChatNewMessagesButton({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(48, 40)),
      onPressed: onTap,
      icon: const Icon(Icons.arrow_downward_rounded, size: 18),
      label: Text(count > 0 ? 'ข้อความใหม่ $count' : 'ข้อความใหม่'),
    );
  }
}

// ฟองข้อความ: มุมโค้ง "หาง" เฉพาะข้อความสุดท้ายของชุด / ระยะห่างแคบในชุดเดียวกัน
class ChatBubble extends StatelessWidget {
  final bool mine;
  final String body;

  // กลุ่ม: ชื่อและรูปผู้ส่ง (ข้อความของคนอื่น) — แสดงเฉพาะข้อความแรก/สุดท้ายของชุด
  final String? senderName;
  final Map<String, dynamic>? senderAvatar;
  final bool showSenderName;
  final bool showAvatar;
  final bool reserveAvatarSpace;

  final Widget? image;
  final Widget? header;
  final Widget? below;
  final String? footer;
  final Color? footerColor;
  final bool endOfRun;
  final bool dim;
  final bool highlight;
  final String semanticsLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ChatBubble({
    super.key,
    required this.mine,
    required this.body,
    required this.semanticsLabel,
    this.senderName,
    this.senderAvatar,
    this.showSenderName = false,
    this.showAvatar = false,
    this.reserveAvatarSpace = false,
    this.image,
    this.header,
    this.below,
    this.footer,
    this.footerColor,
    this.endOfRun = true,
    this.dim = false,
    this.highlight = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;
    const Radius round = Radius.circular(18);
    const Radius tail = Radius.circular(5);

    final Widget column = Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (showSenderName && senderName != null)
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 3),
            child: ExcludeSemantics(
              child: Text(
                senderName!,
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ?header,
        if (image != null)
          Padding(padding: const EdgeInsets.only(bottom: 3), child: image),
        if (body.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
            decoration: BoxDecoration(
              color: mine ? AppColors.primary : AppColors.surface,
              border: mine ? null : AppDecorations.cardBorder,
              borderRadius: BorderRadius.only(
                topLeft: round,
                topRight: round,
                bottomLeft: mine || !endOfRun ? round : tail,
                bottomRight: mine && endOfRun ? tail : round,
              ),
            ),
            child: ExcludeSemantics(
              child: Text(
                body,
                style: TextStyle(
                  color: mine ? Colors.white : AppColors.navy,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ?below,
        if (footer != null && footer!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 3, 6, 0),
            child: ExcludeSemantics(
              child: Text(
                footer!,
                style: TextStyle(
                  color: footerColor ?? AppColors.muted,
                  fontSize: 11,
                  fontWeight: footerColor == null
                      ? FontWeight.w500
                      : FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );

    return Semantics(
      label: semanticsLabel,
      button: onTap != null || onLongPress != null,
      excludeSemantics: false,
      child: AnimatedContainer(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 250),
        color: highlight
            ? AppColors.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        padding: EdgeInsets.only(bottom: endOfRun ? 10 : 2),
        child: Row(
          mainAxisAlignment: mine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!mine && reserveAvatarSpace)
              Padding(
                padding: EdgeInsets.only(
                  right: 6,
                  bottom: footer == null ? 0 : 18,
                ),
                child: showAvatar && senderAvatar != null
                    ? UserAvatar(user: senderAvatar, radius: 15)
                    : const SizedBox(width: 30),
              ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.74,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  onLongPress: onLongPress,
                  child: Opacity(opacity: dim ? 0.72 : 1, child: column),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ช่องพิมพ์: มุมโค้ง ขยายได้สูงสุด 5 บรรทัด / ปุ่มแนบรูป / ปุ่มส่งแสดงสถานะ / รูปตัวอย่างก่อนส่ง
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final XFile? image;
  final bool canSend;
  final String hint;
  final VoidCallback onPickImage;
  final VoidCallback onRemoveImage;
  final VoidCallback onSend;
  final Widget? top;
  final FocusNode? focusNode;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.image,
    required this.canSend,
    required this.onPickImage,
    required this.onRemoveImage,
    required this.onSend,
    this.hint = 'พิมพ์ข้อความ...',
    this.top,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final XFile? picked = image;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(26),
            border: AppDecorations.cardBorder,
            boxShadow: AppDecorations.cardShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?top,
              if (picked != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(picked.path),
                          width: 76,
                          height: 76,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'พิมพ์คำบรรยายได้ในช่องด้านล่าง',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'เอารูปออก',
                        onPressed: onRemoveImage,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'แนบรูป',
                    onPressed: onPickImage,
                    icon: Icon(
                      Icons.add_photo_alternate_outlined,
                      color: AppColors.primary,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 2000,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: hint,
                        counterText: '',
                        isDense: true,
                        filled: true,
                        fillColor: AppColors.fill,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: 'ส่ง',
                    onPressed: canSend ? onSend : null,
                    style: IconButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      disabledBackgroundColor: AppColors.border,
                      minimumSize: const Size(44, 44),
                    ),
                    icon: const Icon(
                      Icons.send_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =======================================================
// ตอบกลับ (Reply) และ Reaction
// =======================================================

const List<String> chatReactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

// กรอบอ้างอิงในข้อความ — ไม่พร้อมใช้งาน (ถูกลบ / ไม่มีสิทธิ์เห็น) → ไม่แสดงเนื้อหาต้นทาง
class ChatReplyPreview extends StatelessWidget {
  final Map<String, dynamic> reply;
  final VoidCallback? onTap;

  const ChatReplyPreview({super.key, required this.reply, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bool available = reply['available'] == true;
    final String name = reply['is_mine'] == true
        ? 'คุณ'
        : (reply['sender_name']?.toString() ?? 'สมาชิก');
    final String body = reply['body']?.toString() ?? '';
    final String text = !available
        ? 'ข้อความนี้ไม่พร้อมใช้งาน'
        : body.isNotEmpty
        ? body
        : (reply['has_image'] == true ? '📷 รูปภาพ' : '');

    return Semantics(
      button: available && onTap != null,
      label: available ? 'ตอบกลับ $name: $text' : text,
      child: InkWell(
        onTap: available ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.only(bottom: 3),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: AppColors.fill,
            borderRadius: BorderRadius.circular(12),
            border: Border(
              left: BorderSide(color: AppColors.primary, width: 3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (available)
                Text(
                  name,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 12.5,
                  fontStyle: available ? FontStyle.normal : FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// แถบ "กำลังตอบกลับ" เหนือช่องพิมพ์
class ChatReplyBar extends StatelessWidget {
  final String name;
  final String preview;
  final VoidCallback onCancel;

  const ChatReplyBar({
    super.key,
    required this.name,
    required this.preview,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 4, 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: AppColors.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ตอบกลับ $name',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'ยกเลิกการตอบกลับ',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

// อีโมจิ + จำนวนใต้ข้อความ (ที่เราเลือกเน้นสี) แตะเพื่อเลือก/ถอนของเรา
class ChatReactionsRow extends StatelessWidget {
  final List<Map<String, dynamic>> reactions;
  final bool mine;
  final ValueChanged<String>? onTap;

  const ChatReactionsRow({
    super.key,
    required this.reactions,
    required this.mine,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: mine ? WrapAlignment.end : WrapAlignment.start,
        children: [
          for (final reaction in reactions)
            Semantics(
              button: onTap != null,
              selected: reaction['mine'] == true,
              label: '${reaction['emoji']} ${reaction['count']} คน',
              child: InkWell(
                onTap: onTap == null
                    ? null
                    : () => onTap!(reaction['emoji'].toString()),
                borderRadius: BorderRadius.circular(99),
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: 36,
                    minWidth: 48,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: reaction['mine'] == true
                        ? AppColors.primary.withValues(alpha: 0.15)
                        : AppColors.fill,
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: reaction['mine'] == true
                          ? AppColors.primary
                          : AppColors.border,
                    ),
                  ),
                  // กว้างตามเนื้อหา (ไม่ขยายเต็มแถว) แต่ไม่เล็กกว่าขนาดแตะขั้นต่ำ
                  child: Center(
                    widthFactor: 1,
                    heightFactor: 1,
                    child: Text(
                      '${reaction['emoji']} ${reaction['count']}',
                      style: TextStyle(color: AppColors.navy, fontSize: 13),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ตัวเลือกเพิ่มเติมในเมนูกดค้าง (ตามสิทธิ์เดิมของแต่ละห้อง)
class ChatMenuAction {
  final String value;
  final IconData icon;
  final String label;
  final bool danger;
  final String? subtitle;

  const ChatMenuAction(
    this.value,
    this.icon,
    this.label, {
    this.danger = false,
    this.subtitle,
  });
}

// เมนูกดค้าง: แถบอีโมจิ + ตอบกลับ + คัดลอก + ตัวเลือกเดิม (ไม่แสดงปุ่มที่ใช้ไม่ได้)
// คืน 'emoji:<อีโมจิ>' / 'unreact' / ค่าของการกระทำ / null
Future<String?> showChatMessageMenu(
  BuildContext context, {
  required bool canReact,
  String? myReaction,
  required bool canReply,
  required bool canCopy,
  List<ChatMenuAction> extra = const [],
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canReact)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 6,
                  children: [
                    for (final emoji in chatReactionEmojis)
                      Semantics(
                        button: true,
                        selected: myReaction == emoji,
                        label: myReaction == emoji
                            ? 'ถอน $emoji'
                            : 'แสดงความรู้สึก $emoji',
                        child: InkResponse(
                          onTap: () => Navigator.of(sheetContext).pop(
                            myReaction == emoji ? 'unreact' : 'emoji:$emoji',
                          ),
                          radius: 26,
                          child: Container(
                            width: 48,
                            height: 48,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: myReaction == emoji
                                  ? AppColors.primary.withValues(alpha: 0.15)
                                  : Colors.transparent,
                            ),
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 26),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (canReply)
              ListTile(
                leading: Icon(Icons.reply_rounded, color: AppColors.primary),
                title: const Text('ตอบกลับ'),
                onTap: () => Navigator.of(sheetContext).pop('reply'),
              ),
            if (canCopy)
              ListTile(
                leading: Icon(Icons.copy_rounded, color: AppColors.navy),
                title: const Text('คัดลอกข้อความ'),
                onTap: () => Navigator.of(sheetContext).pop('copy'),
              ),
            for (final action in extra)
              ListTile(
                leading: Icon(
                  action.icon,
                  color: action.danger ? AppColors.danger : AppColors.navy,
                ),
                title: Text(
                  action.label,
                  style: TextStyle(
                    color: action.danger ? AppColors.danger : null,
                  ),
                ),
                subtitle: action.subtitle == null
                    ? null
                    : Text(action.subtitle!),
                onTap: () => Navigator.of(sheetContext).pop(action.value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

// ปัดข้อความไปทางขวาเพื่อตอบกลับ (ลดการเคลื่อนไหว → ไม่เลื่อนตามนิ้ว แต่ยังตอบกลับได้)
class SwipeToReply extends StatefulWidget {
  final Widget child;
  final VoidCallback? onReply;

  const SwipeToReply({super.key, required this.child, this.onReply});

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  double dx = 0;
  bool fired = false;

  void reset() => setState(() {
    dx = 0;
    fired = false;
  });

  @override
  Widget build(BuildContext context) {
    final VoidCallback? onReply = widget.onReply;

    if (onReply == null) return widget.child;

    final bool reduceMotion = MediaQuery.of(context).disableAnimations;

    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        final double next = (dx + details.delta.dx).clamp(0, 72).toDouble();

        if (next >= 56 && !fired) {
          fired = true;
          onReply();
        }

        if (!reduceMotion) setState(() => dx = next);
      },
      onHorizontalDragEnd: (_) => reset(),
      onHorizontalDragCancel: reset,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (dx > 8)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.reply_rounded, color: AppColors.primary),
            ),
          Transform.translate(offset: Offset(dx, 0), child: widget.child),
        ],
      ),
    );
  }
}
