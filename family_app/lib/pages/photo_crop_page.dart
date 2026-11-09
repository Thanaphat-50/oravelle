import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// =======================================================
// ครอปรูปโปรไฟล์ (สี่เหลี่ยมจัตุรัส แสดงเป็นวงกลม) + ดูตัวอย่างก่อนอัปโหลด
// - บีบนิ้วซูม / ลากเลื่อนรูปให้อยู่ในวงกลม (รูปเต็มกรอบเสมอ ไม่มีขอบว่าง)
// - ในวงกลม = รูปโปรไฟล์ที่คนอื่นจะเห็น
// - "ใช้รูปนี้" → pop(PNG ขนาดไม่เกิน 720×720) / ยกเลิก → pop(null)
// ใช้ Flutter ล้วน ไม่ต้องติดตั้งแพ็กเกจเพิ่ม
// =======================================================

class PhotoCropPage extends StatefulWidget {
  final Uint8List bytes;

  const PhotoCropPage({super.key, required this.bytes});

  @override
  State<PhotoCropPage> createState() => _PhotoCropPageState();
}

class _PhotoCropPageState extends State<PhotoCropPage> {
  static const int maxOutput = 720;

  ui.Image? image;
  String? error;
  bool isSaving = false;

  TransformationController? controller;

  // ขนาดกรอบครอปบนจอ และขนาดรูปที่แสดง (เต็มกรอบที่ซูม 1 เท่า)
  double viewport = 0;
  double baseScale = 1;

  @override
  void initState() {
    super.initState();

    decode();
  }

  Future<void> decode() async {
    try {
      final ui.Image decoded = await decodeImageFromList(widget.bytes);

      if (mounted) setState(() => image = decoded);
    } catch (_) {
      if (mounted) setState(() => error = 'เปิดรูปนี้ไม่ได้ กรุณาเลือกรูปอื่น');
    }
  }

  // เริ่มที่กึ่งกลางรูป
  void prepare(double size) {
    final ui.Image? img = image;

    if (img == null || (controller != null && size == viewport)) return;

    viewport = size;
    baseScale = size / (img.width < img.height ? img.width : img.height);

    final double shownWidth = img.width * baseScale;
    final double shownHeight = img.height * baseScale;

    controller?.dispose();
    controller = TransformationController(
      Matrix4.translationValues(
        -(shownWidth - size) / 2,
        -(shownHeight - size) / 2,
        0,
      ),
    );
  }

  Future<void> useCrop() async {
    final ui.Image? img = image;
    final TransformationController? transform = controller;

    if (img == null || transform == null) return;

    setState(() => isSaving = true);

    try {
      // มุมของกรอบบนจอ → ตำแหน่งบนรูปจริง
      final Offset topLeft = transform.toScene(Offset.zero) / baseScale;
      final Offset bottomRight =
          transform.toScene(Offset(viewport, viewport)) / baseScale;

      final Rect source = Rect.fromPoints(topLeft, bottomRight).intersect(
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      );

      final int size = source.width.round().clamp(1, maxOutput);

      final recorder = ui.PictureRecorder();

      Canvas(recorder).drawImageRect(
        img,
        source,
        Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );

      final ui.Image cropped = await recorder.endRecording().toImage(
        size,
        size,
      );

      final ByteData? png = await cropped.toByteData(
        format: ui.ImageByteFormat.png,
      );

      cropped.dispose();

      if (!mounted) return;

      if (png == null) {
        setState(() => error = 'ครอปรูปไม่สำเร็จ กรุณาลองอีกครั้ง');
        return;
      }

      Navigator.of(context).pop(png.buffer.asUint8List());
    } catch (_) {
      if (mounted) setState(() => error = 'ครอปรูปไม่สำเร็จ กรุณาลองอีกครั้ง');
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  Widget buildCropArea(double size) {
    final ui.Image img = image!;

    prepare(size);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          ClipRect(
            child: InteractiveViewer(
              transformationController: controller,
              constrained: false,
              boundaryMargin: EdgeInsets.zero,
              minScale: 1,
              maxScale: 5,
              child: SizedBox(
                width: img.width * baseScale,
                height: img.height * baseScale,
                child: RawImage(image: img, fit: BoxFit.fill),
              ),
            ),
          ),
          // นอกวงกลมมืดลง (ไม่รับการแตะ)
          IgnorePointer(
            child: CustomPaint(
              size: Size(size, size),
              painter: _CircleMaskPainter(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        // ธีมของแอปตั้งสีหัวข้อเป็นสีเข้ม → พื้นดำต้องกำหนดเอง
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
        title: const Text('ครอปรูปโปรไฟล์'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (error != null && image == null) {
                    return Center(
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    );
                  }

                  if (image == null) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final double size =
                      (constraints.maxWidth < constraints.maxHeight
                          ? constraints.maxWidth
                          : constraints.maxHeight) -
                      32;

                  return Center(child: buildCropArea(size));
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                error != null && image != null ? error! : 'บีบนิ้วเพื่อซูม ลากเพื่อเลื่อน รูปในวงกลมคือรูปโปรไฟล์ที่คนอื่นจะเห็น',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: error != null && image != null
                      ? Colors.redAccent
                      : Colors.white70,
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: isSaving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('ยกเลิก'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: image == null || isSaving ? null : useCrop,
                      child: isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('ใช้รูปนี้'),
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

  @override
  void dispose() {
    controller?.dispose();
    image?.dispose();
    super.dispose();
  }
}

class _CircleMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Rect area = Offset.zero & size;

    final Path mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(area)
      ..addOval(area.deflate(1));

    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    canvas.drawCircle(
      area.center,
      size.width / 2 - 1,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
