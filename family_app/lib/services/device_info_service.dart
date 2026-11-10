import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

// =======================================================
// ข้อมูลอุปกรณ์ที่ส่งไปตอนเข้าสู่ระบบ (หน้า "อุปกรณ์ที่เข้าสู่ระบบ")
// - รุ่นเครื่อง ระบบปฏิบัติการ เวอร์ชันแอป — ใช้แสดงผลเท่านั้น ไม่ใช้ยืนยันตัวตน
// - ไม่อ่าน IMEI / หมายเลขเครื่อง / ชื่อเครื่องที่ผู้ใช้ตั้งเอง
// - อ่านไม่ได้ → ส่งเท่าที่ได้ (เซิร์ฟเวอร์แสดง "อุปกรณ์ไม่ทราบชื่อ")
// =======================================================

class DeviceInfoService {
  // ทดสอบ: กำหนดข้อมูลเอง (ไม่เรียกเครื่อง)
  static Map<String, String>? override;

  static Map<String, String>? _cached;

  // เครื่องตอบช้า/ไม่ตอบ → ไม่ค้างการเข้าสู่ระบบ
  static const Duration _timeLimit = Duration(seconds: 2);

  static Future<Map<String, String>> payload() async {
    final Map<String, String>? fixed = override;
    if (fixed != null) return fixed;

    final Map<String, String>? cached = _cached;
    if (cached != null) return cached;

    final Map<String, String> info = {};

    try {
      final PackageInfo package = await PackageInfo.fromPlatform().timeout(
        _timeLimit,
      );
      info['app_version'] = '${package.version} (${package.buildNumber})';
    } catch (_) {}

    try {
      final DeviceInfoPlugin plugin = DeviceInfoPlugin();

      if (Platform.isAndroid) {
        final AndroidDeviceInfo android = await plugin.androidInfo.timeout(
          _timeLimit,
        );
        info['device_name'] = modelName(android.manufacturer, android.model);
        info['device_platform'] = 'android';
        info['os_version'] = 'Android ${android.version.release}';
      } else if (Platform.isIOS) {
        final IosDeviceInfo ios = await plugin.iosInfo.timeout(_timeLimit);
        info['device_name'] = ios.modelName.isNotEmpty
            ? ios.modelName
            : ios.model;
        info['device_platform'] = 'ios';
        info['os_version'] = '${ios.systemName} ${ios.systemVersion}';
      }
    } catch (_) {}

    info.removeWhere((key, value) => value.trim().isEmpty);

    return _cached = info;
  }

  // "Google" + "Pixel 7" → "Google Pixel 7" / "samsung" + "SM-S918B" → "Samsung SM-S918B"
  // รุ่นที่ขึ้นต้นด้วยชื่อยี่ห้ออยู่แล้วไม่ซ้ำ
  static String modelName(String manufacturer, String model) {
    final String maker = manufacturer.trim();
    final String name = model.trim();

    if (maker.isEmpty) return name;
    if (name.toLowerCase().startsWith(maker.toLowerCase())) return name;

    return '${maker[0].toUpperCase()}${maker.substring(1)} $name'.trim();
  }
}
