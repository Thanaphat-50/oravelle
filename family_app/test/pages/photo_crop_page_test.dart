import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:family_app/pages/photo_crop_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ครอปรูปโปรไฟล์: รูปแนวนอน 400×200 → ได้รูปสี่เหลี่ยมจัตุรัสจากกลางรูป

Future<Uint8List> landscapePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  // ซ้ายแดง กลางเขียว ขวาน้ำเงิน
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 100, 200),
    Paint()..color = const Color(0xFFFF0000),
  );
  canvas.drawRect(
    const Rect.fromLTWH(100, 0, 200, 200),
    Paint()..color = const Color(0xFF00FF00),
  );
  canvas.drawRect(
    const Rect.fromLTWH(300, 0, 100, 200),
    Paint()..color = const Color(0xFF0000FF),
  );

  final image = await recorder.endRecording().toImage(400, 200);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);

  return data!.buffer.asUint8List();
}

Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('crops the centre square and returns a PNG', (tester) async {
    final Uint8List bytes = (await tester.runAsync(landscapePng))!;

    Uint8List? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<Uint8List>(
                MaterialPageRoute(builder: (_) => PhotoCropPage(bytes: bytes)),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 500));

    // ถอดรหัสรูปทำงานนอก fake async → รอแบบวนตรวจ (วงหมุนโหลดทำให้ pumpAndSettle ไม่จบ)
    await waitUntil(
      tester,
      () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
    );

    expect(find.text('ใช้รูปนี้'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tester.tap(find.text('ใช้รูปนี้'));
    await waitUntil(tester, () => result != null);

    expect(result, isNotNull);

    final ui.Image cropped = (await tester.runAsync(
      () => decodeImageFromList(result!),
    ))!;

    // จัตุรัส ขนาดเท่าด้านสั้น (200) และเป็นส่วนกลาง (สีเขียว)
    expect(cropped.width, 200);
    expect(cropped.height, 200);

    final ByteData pixels = (await tester.runAsync<ByteData?>(
      () => cropped.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;

    final int centre = (100 * 200 + 100) * 4;
    expect(pixels.getUint8(centre), lessThan(40)); // R
    expect(pixels.getUint8(centre + 1), greaterThan(200)); // G
  });
}
