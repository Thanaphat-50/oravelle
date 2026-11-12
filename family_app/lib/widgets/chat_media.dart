import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_theme.dart';

// =======================================================
// สื่อในห้องแชท: ลิงก์ / สิทธิ์กล้อง-ไมค์ / เมนูแนบ / ไฟล์ / ข้อความเสียง
// - ลิงก์: เปิดเฉพาะ http/https ที่พิมพ์ชัดเจน และให้ผู้ใช้เห็นโดเมน + URL ก่อนเปิด
// - ไฟล์: PDF, TXT, DOCX, XLSX, PPTX ไม่เกิน 10 MB (เซิร์ฟเวอร์ตรวจเนื้อไฟล์ซ้ำ)
// - เสียง: M4A (AAC) ยาวไม่เกิน 3 นาที / เล่นได้ทีละข้อความ
// =======================================================

const List<String> chatFileExtensions = ['pdf', 'txt', 'docx', 'xlsx', 'pptx'];
const int chatMaxFileBytes = 10 * 1024 * 1024;
const Duration chatMaxVoice = Duration(minutes: 3);

final RegExp chatLinkPattern = RegExp(
  r'https?://[^\s<>"]+',
  caseSensitive: false,
);

// ลิงก์เว็บที่เปิดได้ (http/https และมีโดเมน) / อื่น ๆ = null
Uri? chatWebUri(String raw) {
  final Uri? uri = Uri.tryParse(raw.trim());

  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }

  return uri;
}

// ตัดวรรคตอนท้ายลิงก์ออก (เช่น "ดูที่ https://a.com/x." ไม่รวมจุด)
String chatTrimLink(String raw) {
  String link = raw;

  while (link.isNotEmpty && '.,!?;:)]}\'"'.contains(link[link.length - 1])) {
    link = link.substring(0, link.length - 1);
  }

  return link;
}

String chatDuration(Duration value) {
  final int seconds = value.inSeconds;

  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String chatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';

  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

// แทรกข้อความที่ตำแหน่งเคอร์เซอร์ (มีข้อความที่เลือก → แทนที่) ไม่ตัดอีโมจิหลาย code point
void chatInsertText(TextEditingController controller, String insert) {
  final TextEditingValue value = controller.value;
  final String text = value.text;
  final TextSelection selection = value.selection;
  int start = selection.isValid ? selection.start : text.length;
  int end = selection.isValid ? selection.end : text.length;

  // เคอร์เซอร์อยู่กลางคู่ surrogate (ไม่ควรเกิด) → ขยับออกนอกตัวอักษร
  bool insideSurrogate(int index) =>
      index > 0 &&
      index < text.length &&
      (text.codeUnitAt(index) & 0xFC00) == 0xDC00 &&
      (text.codeUnitAt(index - 1) & 0xFC00) == 0xD800;

  if (insideSurrogate(start)) start -= 1;
  if (insideSurrogate(end)) end += 1;

  controller.value = TextEditingValue(
    text: text.replaceRange(start, end, insert),
    selection: TextSelection.collapsed(offset: start + insert.length),
  );
}

// =====================================================
// ลิงก์
// =====================================================

class ChatLinkText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color linkColor;

  const ChatLinkText({
    super.key,
    required this.text,
    required this.style,
    required this.linkColor,
  });

  @override
  State<ChatLinkText> createState() => _ChatLinkTextState();
}

class _ChatLinkTextState extends State<ChatLinkText> {
  final List<TapGestureRecognizer> recognizers = [];

  void clearRecognizers() {
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }

    recognizers.clear();
  }

  @override
  void dispose() {
    clearRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    clearRecognizers();

    final String text = widget.text;
    final List<InlineSpan> spans = [];
    int last = 0;

    for (final match in chatLinkPattern.allMatches(text)) {
      if (match.start < last) continue;

      final String link = chatTrimLink(match.group(0)!);
      final Uri? uri = chatWebUri(link);

      if (uri == null) continue;

      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }

      final TapGestureRecognizer recognizer = TapGestureRecognizer()
        ..onTap = () => confirmOpenLink(context, uri);

      recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: link,
          recognizer: recognizer,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      last = match.start + link.length;
    }

    if (spans.isEmpty) return Text(text, style: widget.style);

    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));

    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}

// แสดงโดเมนและ URL เต็มก่อนเปิดในเบราว์เซอร์
Future<void> confirmOpenLink(BuildContext context, Uri uri) async {
  final bool? open = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'เปิดลิงก์ในเบราว์เซอร์',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              uri.host,
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              uri.toString(),
              maxLines: 4,
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            Text(
              'ตรวจชื่อเว็บไซต์ให้แน่ใจก่อนเปิด ลิงก์จากแชทอาจพาไปเว็บไซต์ภายนอก',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                    child: const Text('ยกเลิก'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    child: const Text('เปิดลิงก์'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  if (open != true) return;

  bool opened = false;

  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }

  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('เปิดลิงก์ไม่สำเร็จ')));
  }
}

// กล่องใส่ลิงก์ (แชร์ลิงก์จากเมนูแนบ) → คืนลิงก์ที่ผ่านการตรวจแล้ว
class ChatLinkDialog extends StatefulWidget {
  const ChatLinkDialog({super.key});

  @override
  State<ChatLinkDialog> createState() => _ChatLinkDialogState();
}

class _ChatLinkDialogState extends State<ChatLinkDialog> {
  final TextEditingController controller = TextEditingController();
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    final String link = controller.text.trim();

    if (chatWebUri(link) == null || link.contains(RegExp(r'\s'))) {
      setState(() => error = 'ลิงก์ต้องขึ้นต้นด้วย http:// หรือ https://');
      return;
    }

    Navigator.of(context).pop(link);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('แชร์ลิงก์'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => submit(),
        decoration: InputDecoration(
          hintText: 'https://',
          errorText: error,
          helperText: 'วางลิงก์เว็บไซต์ แล้วส่งพร้อมข้อความได้',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('ยกเลิก'),
        ),
        FilledButton(onPressed: submit, child: const Text('ใส่ในข้อความ')),
      ],
    );
  }
}

// =====================================================
// สิทธิ์กล้อง / ไมโครโฟน
// =====================================================

// ขอสิทธิ์ตอนใช้งานจริง / ปฏิเสธถาวร → บอกทางไปตั้งค่า (กลับมาแล้วกดใหม่ได้เลย)
Future<bool> ensureChatPermission(
  BuildContext context,
  Permission permission,
  String what,
) async {
  PermissionStatus status;

  try {
    status = await permission.status;

    if (!status.isGranted && !status.isLimited) {
      status = await permission.request();
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ตรวจสิทธิ์$whatไม่สำเร็จ ลองใหม่อีกครั้ง')),
      );
    }

    return false;
  }

  if (status.isGranted || status.isLimited) return true;

  if (!context.mounted) return false;

  final bool toSettings = status.isPermanentlyDenied || status.isRestricted;

  final bool? open = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('ยังไม่ได้อนุญาตให้ใช้$what'),
      content: Text(
        toSettings
            ? 'เปิดสิทธิ์$whatได้ที่ การตั้งค่า > แอป > ORAVELLE > สิทธิ์ แล้วกลับมากดใหม่อีกครั้ง'
            : 'แอปใช้$whatเฉพาะตอนที่คุณกดใช้งานเท่านั้น ลองใหม่แล้วกด "อนุญาต"',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('ไม่ใช่ตอนนี้'),
        ),
        if (toSettings)
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('เปิดการตั้งค่า'),
          ),
      ],
    ),
  );

  if (open == true) await openAppSettings();

  return false;
}

// =====================================================
// เมนูแนบ
// =====================================================

Future<String?> showChatAttachMenu(BuildContext context) {
  Widget option(
    BuildContext sheetContext,
    String value,
    IconData icon,
    String label,
    Color color,
  ) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: () => Navigator.of(sheetContext).pop(value),
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: color.withValues(
                    alpha: AppColors.isDark ? 0.24 : 0.13,
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'แนบในแชท',
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 8,
              spacing: 8,
              children: [
                option(
                  sheetContext,
                  'camera',
                  Icons.photo_camera_outlined,
                  'กล้อง',
                  const Color(0xFF7C3AED),
                ),
                option(
                  sheetContext,
                  'gallery',
                  Icons.image_outlined,
                  'รูปภาพ',
                  const Color(0xFF2563EB),
                ),
                option(
                  sheetContext,
                  'file',
                  Icons.insert_drive_file_outlined,
                  'ไฟล์',
                  const Color(0xFF16A34A),
                ),
                option(
                  sheetContext,
                  'link',
                  Icons.link_rounded,
                  'ลิงก์',
                  const Color(0xFFDB2777),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

// =====================================================
// ไฟล์
// =====================================================

class ChatFileTile extends StatelessWidget {
  final String name;
  final int size;
  final bool mine;
  final bool uploading;
  final VoidCallback? onOpen;

  const ChatFileTile({
    super.key,
    required this.name,
    required this.size,
    required this.mine,
    this.uploading = false,
    this.onOpen,
  });

  static ({IconData icon, Color color}) styleOf(String extension) {
    return switch (extension) {
      'pdf' => (
        icon: Icons.picture_as_pdf_rounded,
        color: const Color(0xFFDC2626),
      ),
      'docx' => (
        icon: Icons.description_rounded,
        color: const Color(0xFF2563EB),
      ),
      'xlsx' => (
        icon: Icons.table_chart_rounded,
        color: const Color(0xFF16A34A),
      ),
      'pptx' => (icon: Icons.slideshow_rounded, color: const Color(0xFFEA580C)),
      _ => (icon: Icons.article_rounded, color: const Color(0xFF64748B)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final int dot = name.lastIndexOf('.');
    final String extension = dot < 0
        ? ''
        : name.substring(dot + 1).toLowerCase();
    final style = styleOf(extension);
    final String detail = [
      if (extension.isNotEmpty) extension.toUpperCase(),
      chatBytes(size),
      if (uploading) 'กำลังอัปโหลด…',
    ].join(' · ');

    return Semantics(
      label: 'ไฟล์ $name, $detail',
      excludeSemantics: true,
      button: onOpen != null,
      onTap: onOpen,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: mine ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(style.icon, color: style.color, size: 34),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        detail,
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (onOpen != null)
                  IconButton(
                    tooltip: 'เปิดไฟล์',
                    onPressed: onOpen,
                    icon: Icon(
                      Icons.download_rounded,
                      color: AppColors.primary,
                    ),
                  ),
              ],
            ),
            if (uploading)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 6, 6, 0),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =====================================================
// ข้อความเสียง: เล่นได้ทีละข้อความทั้งแอป
// =====================================================

class ChatVoicePlayer extends ChangeNotifier {
  ChatVoicePlayer._();

  static final ChatVoicePlayer instance = ChatVoicePlayer._();

  String? activeKey;
  bool loading = false;
  VideoPlayerController? _controller;

  Duration get position => _controller?.value.position ?? Duration.zero;

  Duration get duration => _controller?.value.duration ?? Duration.zero;

  bool isActive(String key) => activeKey == key;

  bool isPlaying(String key) =>
      activeKey == key && (_controller?.value.isPlaying ?? false);

  void _tick() => notifyListeners();

  // แตะเล่น/หยุดชั่วคราว / เล่นข้อความอื่น → หยุดข้อความเดิมก่อน
  Future<bool> toggle(String key, Future<String?> Function() resolve) async {
    final VideoPlayerController? current = _controller;

    if (activeKey == key && current != null) {
      final VideoPlayerValue value = current.value;

      if (value.isPlaying) {
        await current.pause();
      } else {
        if (value.position >= value.duration) {
          await current.seekTo(Duration.zero);
        }

        await current.play();
      }

      notifyListeners();
      return true;
    }

    await stop();

    activeKey = key;
    loading = true;
    notifyListeners();

    try {
      final String? path = await resolve();

      if (path == null || activeKey != key) {
        if (activeKey == key) activeKey = null;
        return false;
      }

      final VideoPlayerController controller = VideoPlayerController.file(
        File(path),
      );

      _controller = controller;
      await controller.initialize();

      if (_controller != controller) {
        await controller.dispose();
        return false;
      }

      controller.addListener(_tick);
      await controller.play();

      return true;
    } catch (_) {
      if (activeKey == key) await stop();
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final VideoPlayerController? controller = _controller;

    _controller = null;
    activeKey = null;

    if (controller != null) {
      controller.removeListener(_tick);
      await controller.dispose();
    }

    notifyListeners();
  }
}

class ChatVoiceTile extends StatelessWidget {
  final String playKey;
  final int durationMs;
  final bool mine;
  final Future<String?> Function() resolve;

  const ChatVoiceTile({
    super.key,
    required this.playKey,
    required this.durationMs,
    required this.mine,
    required this.resolve,
  });

  @override
  Widget build(BuildContext context) {
    final ChatVoicePlayer player = ChatVoicePlayer.instance;

    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final bool active = player.isActive(playKey);
        final bool playing = player.isPlaying(playKey);
        final Duration total = active && player.duration > Duration.zero
            ? player.duration
            : Duration(milliseconds: durationMs);
        final Duration position = active ? player.position : Duration.zero;
        final double progress = total.inMilliseconds <= 0
            ? 0
            : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        final Color fore = mine ? Colors.white : AppColors.primary;

        return Container(
          constraints: const BoxConstraints(maxWidth: 250),
          padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
          decoration: BoxDecoration(
            color: mine ? AppColors.primary : AppColors.surface,
            borderRadius: BorderRadius.circular(22),
            border: mine ? null : AppDecorations.cardBorder,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: playing ? 'หยุดชั่วคราว' : 'เล่นข้อความเสียง',
                onPressed: () async {
                  final bool ok = await player.toggle(playKey, resolve);

                  if (!ok && !player.isActive(playKey) && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'เล่นข้อความเสียงไม่สำเร็จ ลองใหม่อีกครั้ง',
                        ),
                      ),
                    );
                  }
                },
                icon: active && player.loading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fore,
                        ),
                      )
                    : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: fore,
                      ),
              ),
              Semantics(
                label:
                    'ความคืบหน้า ${chatDuration(position)} จาก ${chatDuration(total)}',
                child: ChatWaveform(
                  progress: progress,
                  color: fore,
                  seed: playKey.hashCode,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                chatDuration(
                  active && position > Duration.zero ? position : total,
                ),
                style: TextStyle(
                  color: fore,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// คลื่นเสียง (แท่งสูงต่ำคงที่ต่อข้อความ) / ส่วนที่เล่นแล้วสีเข้ม
class ChatWaveform extends StatelessWidget {
  final double progress;
  final Color color;
  final int seed;

  const ChatWaveform({
    super.key,
    required this.progress,
    required this.color,
    required this.seed,
  });

  static const int bars = 22;

  @override
  Widget build(BuildContext context) {
    final int played = (progress * bars).round();

    return ExcludeSemantics(
      child: SizedBox(
        height: 26,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < bars; i++)
              Container(
                width: 3,
                height:
                    6 + (((seed + i * 7919) * 2654435761) & 0x7fffffff) % 17,
                margin: const EdgeInsets.symmetric(horizontal: 1.25),
                decoration: BoxDecoration(
                  color: i < played ? color : color.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// อัดเสียง: ไฟล์ชั่วคราวในเครื่อง / ครบ 3 นาทีหยุดเอง / ยกเลิก → ลบไฟล์
class ChatVoiceRecorder extends ChangeNotifier {
  final AudioRecorder _recorder = AudioRecorder();

  String? path;
  bool recording = false;
  Duration elapsed = Duration.zero;
  DateTime? _startedAt;
  Timer? _timer;
  bool _disposed = false;

  bool get hasRecording => !recording && path != null;

  bool get active => recording || path != null;

  Future<void> start() async {
    if (recording) return;

    await discard();

    final Directory dir = await getTemporaryDirectory();
    final String file =
        '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: file,
    );

    path = file;
    recording = true;
    elapsed = Duration.zero;
    _startedAt = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      elapsed = DateTime.now().difference(_startedAt!);

      if (elapsed >= chatMaxVoice) {
        elapsed = chatMaxVoice;
        stop();
      }

      _notify();
    });

    _notify();
  }

  Future<void> stop() async {
    if (!recording) return;

    _timer?.cancel();
    recording = false;

    final String? saved = await _recorder.stop();

    if (_startedAt != null) {
      final Duration length = DateTime.now().difference(_startedAt!);
      elapsed = length > chatMaxVoice ? chatMaxVoice : length;
    }

    path = saved ?? path;

    // สั้นเกินไป (แตะแล้วหยุดทันที) → ทิ้ง
    if (elapsed < const Duration(milliseconds: 600)) await discard();

    _notify();
  }

  Future<void> discard() async {
    _timer?.cancel();

    if (recording) {
      recording = false;
      await _recorder.cancel();
    } else if (path != null) {
      try {
        await File(path!).delete();
      } catch (_) {}
    }

    path = null;
    elapsed = Duration.zero;
    _notify();
  }

  // ย้ายไฟล์ไปให้คิวส่ง (ไฟล์ไม่ถูกลบที่นี่แล้ว)
  Map<String, dynamic>? take() {
    final String? file = path;

    if (recording || file == null) return null;

    final Map<String, dynamic> voice = {
      'path': file,
      'duration_ms': elapsed.inMilliseconds,
    };

    path = null;
    elapsed = Duration.zero;
    _notify();

    return voice;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();

    if (recording) {
      _recorder.cancel();
    } else if (path != null) {
      try {
        File(path!).deleteSync();
      } catch (_) {}
    }

    _recorder.dispose();
    super.dispose();
  }
}

class ChatVoiceRecorderBar extends StatelessWidget {
  final ChatVoiceRecorder recorder;
  final VoidCallback onSend;

  const ChatVoiceRecorderBar({
    super.key,
    required this.recorder,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        final String? file = recorder.path;

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
              child: Row(
                children: [
                  IconButton(
                    tooltip: recorder.recording
                        ? 'ยกเลิกการอัด'
                        : 'ลบแล้วอัดใหม่',
                    onPressed: recorder.discard,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: AppColors.danger,
                    ),
                  ),
                  if (recorder.recording) ...[
                    const Icon(
                      Icons.fiber_manual_record,
                      color: Colors.red,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          'กำลังอัด ${chatDuration(recorder.elapsed)} / ${chatDuration(chatMaxVoice)}',
                          style: TextStyle(
                            color: AppColors.navy,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: 'หยุดอัด',
                      onPressed: recorder.stop,
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        minimumSize: const Size(44, 44),
                      ),
                      icon: const Icon(Icons.stop_rounded, color: Colors.white),
                    ),
                  ] else ...[
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: file == null
                            ? const SizedBox.shrink()
                            : ChatVoiceTile(
                                playKey: 'draft:$file',
                                durationMs: recorder.elapsed.inMilliseconds,
                                mine: false,
                                resolve: () async => file,
                              ),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: 'ส่งข้อความเสียง',
                      onPressed: file == null ? null : onSend,
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        minimumSize: const Size(44, 44),
                      ),
                      icon: const Icon(
                        Icons.send_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// =====================================================
// แผงอีโมจิ (แยกจาก Reaction ใต้ข้อความ) — แทรกที่ตำแหน่งเคอร์เซอร์
// =====================================================

const Map<String, String> chatEmojiGroups = {
  '😀': '😀 😃 😄 😁 😆 😅 🤣 😂 🙂 😉 😊 😇 🥰 😍 🤩 😘 😋 😛 😜 🤪 🤗 🤔 🤭 🤫 😐 😏 😒 🙄 😬 😌 😔 😪 😴 😷 🤒 🥵 🥶 🤯 🥳 😎 🤓 😕 🙁 😮 😲 😳 🥺 😢 😭 😱 😖 😣 😞 😓 😩 😫 😤 😡 😠',
  '👍': '👍 👎 👌 ✌️ 🤞 🤟 🤙 👋 🙏 👏 🙌 💪 🫶 🤝 ✍️ 👀 👍🏻 👍🏽 👍🏿 👨‍👩‍👧‍👦 👨‍👩‍👧 🧑‍🍳 🧑‍💻 👶 👧 👦 👩 👨 👵 👴',
  '❤️': '❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❤️‍🔥 ❤️‍🩹 💕 💞 💓 💗 💖 💘 💝',
  '🐶': '🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🐤 🐟 🐬 🐳 🌸 🌹 🌻 🌼 🌷 🌳 🍀 🌈 ☀️ 🌙 ⭐ 🔥 💧 ⚡',
  '🍜': '🍎 🍌 🍉 🍇 🍓 🥭 🍍 🥥 🍅 🌶️ 🌽 🍚 🍜 🍲 🍛 🍣 🍤 🍗 🍖 🍕 🍔 🍟 🥗 🍰 🎂 🍩 🍪 🍫 🍦 ☕ 🧋 🍵 🥤',
  '🎉': '🎉 🎊 🎁 🎈 🏆 ⚽ 🏀 🎵 🎶 📷 📱 💻 🏠 🚗 ✈️ ⏰ 📅 ✅ ❌ ⚠️ ❓ ❗ 💯 🆗 🆕 🇹🇭 🏳️‍🌈',
};

const Map<String, String> chatEmojiGroupNames = {
  '😀': 'หน้ายิ้ม',
  '👍': 'มือและผู้คน',
  '❤️': 'หัวใจ',
  '🐶': 'สัตว์และธรรมชาติ',
  '🍜': 'อาหาร',
  '🎉': 'กิจกรรมและสัญลักษณ์',
};

class ChatEmojiPanel extends StatefulWidget {
  final ValueChanged<String> onPick;

  const ChatEmojiPanel({super.key, required this.onPick});

  @override
  State<ChatEmojiPanel> createState() => _ChatEmojiPanelState();
}

class _ChatEmojiPanelState extends State<ChatEmojiPanel> {
  String group = chatEmojiGroups.keys.first;

  @override
  Widget build(BuildContext context) {
    final List<String> emojis = chatEmojiGroups[group]!.split(' ');
    final double height = (MediaQuery.of(context).size.height * 0.34).clamp(
      200.0,
      300.0,
    );

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: [
                  for (final key in chatEmojiGroups.keys)
                    Semantics(
                      selected: key == group,
                      button: true,
                      label: chatEmojiGroupNames[key],
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: () => setState(() => group = key),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 52,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                width: 3,
                                color: key == group
                                    ? AppColors.primary
                                    : Colors.transparent,
                              ),
                            ),
                          ),
                          child: Text(
                            key,
                            textScaler: TextScaler.noScaling,
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(6),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 52,
                  mainAxisExtent: 50,
                ),
                itemCount: emojis.length,
                itemBuilder: (context, index) => Semantics(
                  button: true,
                  label: emojis[index],
                  child: InkResponse(
                    onTap: () => widget.onPick(emojis[index]),
                    radius: 24,
                    child: Center(
                      child: Text(
                        emojis[index],
                        textScaler: TextScaler.noScaling,
                        style: const TextStyle(fontSize: 27),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
