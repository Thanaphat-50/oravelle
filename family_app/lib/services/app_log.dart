import 'dart:developer' as developer;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

// =======================================================
// บันทึกรายละเอียดทางเทคนิค (ผู้ใช้ไม่เห็น)
// - ตอนพัฒนา: ดูใน debug console / logcat (ชื่อ oravelle)
// - แอปจริง: แนบไปกับรายงาน Crashlytics (ถ้าตั้งค่า Firebase ไว้)
// ห้ามใส่ token รหัสผ่าน อีเมล หรือเนื้อหาที่ผู้ใช้ส่ง — ใส่แค่ประเภทปัญหา / path / รหัส HTTP
// =======================================================

class AppLog {
  static void warn(String event, [Object? detail]) {
    final String text = detail == null ? event : '$event: $detail';

    developer.log(text, name: 'oravelle');

    if (kDebugMode) return;

    try {
      if (Firebase.apps.isNotEmpty) {
        FirebaseCrashlytics.instance.log(text);
      }
    } catch (_) {
      // ไม่มี Firebase → มีแค่ log ในเครื่อง
    }
  }
}
