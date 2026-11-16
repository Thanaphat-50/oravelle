import 'package:flutter/widgets.dart';

// =======================================================
// จังหวะการเคลื่อนไหวกลางของแอป (ปรับที่นี่ที่เดียว มีผลทั้งแอป)
//
// - ปุ่ม/ไอคอน 120–180 ms, เมนู/แผง 200–300 ms
// - นุ่ม กระชับ ไม่เด้งมาก ไม่หน่วงการใช้งานเพื่อรอเอฟเฟกต์
// - เครื่องตั้ง "ลดการเคลื่อนไหว / ปิดภาพเคลื่อนไหว" → ข้าม motion แต่ยังเปลี่ยนสถานะครบ
// =======================================================

class AppMotion {
  // ปุ่ม/ไอคอน (เช่น หัวใจ, ＋ หมุนเป็น ×)
  static const Duration button = Duration(milliseconds: 160);

  // เมนู/แผง/ตัวเลือกแท็บ (เมนูสร้างโพสต์, แผงแนบในแชท, พื้นหลังแท็บ)
  static const Duration panel = Duration(milliseconds: 240);

  // เลื่อนหน้าแท็บ / เปิดรูปเต็มจอ
  static const Duration page = Duration(milliseconds: 280);

  // ระยะเหลื่อมระหว่างรายการในเมนู
  static const Duration stagger = Duration(milliseconds: 35);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve move = Curves.easeInOutCubic;

  // เครื่องปิด/ลดภาพเคลื่อนไหว
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  // ระยะเวลาจริง (ลดการเคลื่อนไหว = 0 → เปลี่ยนทันที)
  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}
