import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../config/api_config.dart';
import '../config/app_info.dart';
import 'auth_service.dart';
import 'settings_service.dart';

// =======================================================
// แชร์ตำแหน่งแม้ไม่ได้เปิดแอป (Android)
//
// - ทำงานใน Foreground Service แยกจากหน้าแอป → ล็อกจอ / ปัดแอปทิ้งแล้วยังส่งต่อ
//   (Android บังคับให้มีแจ้งเตือนค้าง "ORAVELLE กำลังแชร์ตำแหน่ง")
// - ส่งเมื่อขยับเกิน 50 เมตร และอย่างน้อยทุก 5 นาที (ครอบครัวรู้ว่ายังออนไลน์)
// - เปิดเองไม่ได้: ผู้ใช้ต้องเปิดสวิตช์ + อนุญาตตำแหน่ง "ตลอดเวลา"
// - หยุดเอง: ออกจากระบบ / ปิดแชร์ตำแหน่ง / ออกจากครอบครัว / ถอนสิทธิ์ / ปิด GPS
//   (เปิดแอปครั้งถัดไป sync() จะเริ่มใหม่ให้ถ้ายังเปิดสวิตช์ไว้)
// =======================================================

// หัวข้อแจ้งเตือนค้าง (หน้าอธิบายก่อนขอสิทธิ์ใช้ข้อความเดียวกัน)
const String locationSharingTitle = '${AppInfo.name} กำลังแชร์ตำแหน่ง';

class BackgroundLocation {
  static const String _enabledKey = 'background_location_enabled';

  // ส่งใหม่เมื่อขยับเกินนี้ (เมตร)
  static const int moveMeters = 50;

  // ส่งตำแหน่งอย่างน้อยทุก ๆ เท่านี้ แม้ไม่ขยับ
  static const Duration heartbeat = Duration(minutes: 5);

  // ไม่ส่งถี่กว่านี้
  static const Duration minSendInterval = Duration(seconds: 30);

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static final FlutterBackgroundService _service = FlutterBackgroundService();

  static bool _configured = false;

  static bool get supported => Platform.isAndroid;

  static Future<bool> isEnabled() async {
    return await _storage.read(key: _enabledKey) == '1';
  }

  static Future<void> _setEnabled(bool value) async {
    if (value) {
      await _storage.write(key: _enabledKey, value: '1');
    } else {
      await _storage.delete(key: _enabledKey);
    }
  }

  static Future<bool> hasAlwaysPermission() async {
    return await Geolocator.checkPermission() == LocationPermission.always;
  }

  static Future<void> _configure() async {
    if (_configured) return;

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundLocationMain,
        autoStart: false,
        // เปิดเครื่องใหม่ → เริ่มเอง (ตรวจสวิตช์/สิทธิ์อีกครั้งใน backgroundLocationMain)
        autoStartOnBoot: true,
        isForegroundMode: true,
        // ช่องแจ้งเตือนระดับต่ำสุด (สร้างใน MainActivity.kt) → ย่อเล็กที่สุด
        notificationChannelId: 'location_sharing',
        initialNotificationTitle: locationSharingTitle,
        initialNotificationContent:
            'สมาชิกในกลุ่มเห็นตำแหน่งของคุณ ปิดได้ที่ ตั้งค่า',
        foregroundServiceNotificationId: 4410,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );

    _configured = true;
  }

  // เริ่ม/หยุดให้ตรงกับสถานะตอนนี้ (เปิดแอป / เปลี่ยนการตั้งค่า)
  static Future<void> sync() async {
    if (!supported) return;

    try {
      final bool shouldRun =
          await isEnabled() &&
          SettingsService.locationSharing.value != false &&
          await AuthService.getToken() != null &&
          await hasAlwaysPermission() &&
          await Geolocator.isLocationServiceEnabled();

      await _configure();

      final bool running = await _service.isRunning();

      if (shouldRun && !running) {
        await _service.startService();
      } else if (!shouldRun && running) {
        _service.invoke('stop');
      }
    } catch (_) {
      // เริ่มไม่ได้ (เช่น เครื่องไม่รองรับ) → ใช้การส่งตอนเปิดแอปแทน
    }
  }

  // หยุดชั่วคราว (เช่น ยังไม่มีครอบครัว) แต่จำสวิตช์ไว้
  static Future<void> pause() async {
    if (!supported) return;

    try {
      if (await _service.isRunning()) _service.invoke('stop');
    } catch (_) {}
  }

  // ปิดสวิตช์ / ออกจากระบบ / ลบบัญชี
  static Future<void> turnOff() async {
    if (!supported) return;

    await _setEnabled(false);

    await pause();
  }

  // เปิดสวิตช์: ขอสิทธิ์ "ตลอดเวลา" แล้วเริ่ม
  // คืนข้อความบอกผู้ใช้เมื่อยังเปิดไม่ได้ (null = เปิดแล้ว)
  static Future<String?> turnOn() async {
    if (!supported) return 'ตอนนี้ใช้ได้เฉพาะ Android';

    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'กรุณาเปิดตำแหน่ง (GPS) ของเครื่องก่อน';
    }

    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // ได้แค่ "ขณะใช้แอป" → ขอ "ตลอดเวลา" แยกต่างหาก
    // (Android 11 ขึ้นไปไม่รับถ้าขอพร้อมสิทธิ์ปกติ และจะพาไปหน้าสิทธิ์ตำแหน่ง
    //  ให้เลือก "อนุญาตตลอดเวลา")
    if (permission == LocationPermission.whileInUse) {
      await Permission.locationAlways.request();

      permission = await Geolocator.checkPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();

      return 'เปิดสิทธิ์ตำแหน่งในหน้าตั้งค่าของเครื่อง แล้วเลือก "อนุญาตตลอดเวลา"';
    }

    if (permission != LocationPermission.always) {
      return 'ต้องเลือก "อนุญาตตลอดเวลา" ที่สิทธิ์ตำแหน่ง จึงจะแชร์ตอนปิดแอปได้';
    }

    await _setEnabled(true);

    await sync();

    return null;
  }
}

// =======================================================
// โค้ดที่รันใน Service (แยกจากหน้าแอป ไม่มีหน้าจอ)
// =======================================================

@pragma('vm:entry-point')
Future<void> backgroundLocationMain(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  StreamSubscription<Position>? subscription;

  Timer? timer;

  DateTime? lastSentAt;

  bool stopping = false;

  Future<void> stop() async {
    if (stopping) return;

    stopping = true;

    await subscription?.cancel();

    timer?.cancel();

    await service.stopSelf();
  }

  service.on('stop').listen((_) => stop());

  // ปิดสวิตช์ไว้ / ถอนสิทธิ์ "ตลอดเวลา" ไปแล้ว (เช่น เริ่มเองตอนเปิดเครื่อง)
  if (!await BackgroundLocation.isEnabled() ||
      !await BackgroundLocation.hasAlwaysPermission()) {
    await stop();
    return;
  }

  Future<void> send(Position position, {bool force = false}) async {
    final DateTime now = DateTime.now();

    final DateTime? last = lastSentAt;

    if (!force &&
        last != null &&
        now.difference(last) < BackgroundLocation.minSendInterval) {
      return;
    }

    final String? token = await AuthService.getToken();

    // ออกจากระบบแล้ว
    if (token == null) {
      await stop();
      return;
    }

    lastSentAt = now;

    try {
      final response = await http
          .post(
            Uri.parse('${ApiConfig.baseUrl}/location'),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'latitude': position.latitude,
              'longitude': position.longitude,
              'accuracy': position.accuracy,
            }),
          )
          .timeout(const Duration(seconds: 20));

      // เซสชันหมดอายุ / ถูกยกเลิกสิทธิ์จากเครื่องอื่น → ปิดสวิตช์ด้วย
      // (ไม่เริ่มเองอีกตอนเปิดเครื่อง / บัญชีถัดไปบนเครื่องนี้ต้องเปิดเอง เหมือนออกจากระบบ)
      if (response.statusCode == 401) {
        await BackgroundLocation._setEnabled(false);
        await stop();
        return;
      }

      // ออกจากครอบครัว
      if (response.statusCode == 403) {
        await stop();
        return;
      }

      final dynamic data = jsonDecode(response.body);

      // ปิดการแชร์ตำแหน่งในแอป → ไม่ต้องส่งต่อ
      if (data is Map && data['shared'] == false) {
        await stop();
        return;
      }

      if (service is AndroidServiceInstance) {
        final String time =
            '${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}';

        service.setForegroundNotificationInfo(
          title: locationSharingTitle,
          content: 'ล่าสุด $time น. · ปิดได้ที่ ตั้งค่า ในแอป',
        );
      }
    } catch (_) {
      // ไม่มีเน็ต / Server มีปัญหา → รอบหน้าลองใหม่
    }
  }

  // ส่งตามรอบ แม้ไม่ขยับ (และเช็กว่ายังได้รับอนุญาตอยู่)
  Future<void> beat() async {
    try {
      if (!await BackgroundLocation.hasAlwaysPermission() ||
          !await Geolocator.isLocationServiceEnabled()) {
        await stop();
        return;
      }

      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 30),
        ),
      );

      await send(position, force: true);
    } catch (_) {
      // อ่านตำแหน่งไม่ทัน → รอบหน้า
    }
  }

  subscription =
      Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: BackgroundLocation.moveMeters,
          intervalDuration: BackgroundLocation.minSendInterval,
        ),
      ).listen(
        (position) => send(position),
        // ปิด GPS / ถอนสิทธิ์ระหว่างทำงาน
        onError: (_) => stop(),
      );

  timer = Timer.periodic(BackgroundLocation.heartbeat, (_) => beat());

  await beat();
}
