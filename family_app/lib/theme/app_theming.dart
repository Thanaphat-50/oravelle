import 'package:flutter/material.dart';

import 'theme_spec.dart';

// =======================================================
// ธีมที่ใช้อยู่ตอนนี้ (ส่วนกลาง ทุกหน้าอ่านจากที่นี่ผ่าน AppColors / AppShapes / ThemedIcon)
//
// - active: ธีมที่ผู้ใช้เลือกใช้ (ThemeService บันทึกแยกต่อบัญชีในเครื่องนี้)
// - trial:  ธีมที่กำลัง "ลองธีม" อยู่ในหน่วยความจำเท่านั้น
//           ไม่บันทึก ไม่ใช่สิทธิ์ ออกจากหน้าลอง/ปิดแอป = กลับธีมเดิม
// main.dart ฟัง revision แล้วสั่งทุกหน้าวาดใหม่ (ไม่ล้างข้อความที่พิมพ์ค้าง/ตำแหน่งเลื่อน)
// =======================================================

class AppTheming {
  static AppThemeSpec _active = AppThemeSpec.lavender;

  static AppThemeSpec? _trial;

  // ห้องแชทที่ตั้งพื้นหลังเองไว้: true = ใช้พื้นหลังของธีมแทน (ผู้ใช้เลือกตอนเปิดใช้ธีม)
  static bool _preferThemeChat = false;

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static AppThemeSpec get active => _active;

  static AppThemeSpec? get trial => _trial;

  static AppThemeSpec get effective => _trial ?? _active;

  static bool get isTrying => _trial != null;

  static ThemeDecor get decor => effective.decor;

  static bool get preferThemeChatBackground =>
      _trial != null || _preferThemeChat;

  static void setActive(AppThemeSpec spec, {bool? preferThemeChat}) {
    _active = spec;

    if (preferThemeChat != null) _preferThemeChat = preferThemeChat;

    _changed();
  }

  static void setPreferThemeChat(bool value) {
    if (_preferThemeChat == value) return;

    _preferThemeChat = value;

    _changed();
  }

  static void startTrial(AppThemeSpec spec) {
    _trial = spec;

    _changed();
  }

  static void endTrial() {
    if (_trial == null) return;

    _trial = null;

    _changed();
  }

  // ออกจากระบบ / เปลี่ยนบัญชี → ธีมฟรี ไม่ใช้ค่าของบัญชีก่อนหน้า
  static void reset() {
    _active = AppThemeSpec.lavender;
    _trial = null;
    _preferThemeChat = false;

    _changed();
  }

  static void _changed() => revision.value++;
}
