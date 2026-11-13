import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/background_location.dart';
import '../services/chat_service.dart';
import '../services/location_service.dart';
import '../services/location_tracker.dart';
import '../services/post_service.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';
import '../widgets/background_location_prompt.dart';
import 'chat_room_page.dart';
import 'user_profile_page.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  GoogleMapController? mapController;

  StreamSubscription<Position>? positionSubscription;

  Timer? refreshTimer;

  Position? currentPosition;

  List<Map<String, dynamic>> familyLocations = [];

  // ชื่อสมาชิกคนอื่นที่ปิดการแชร์ตำแหน่งอยู่
  List<String> pausedNames = [];

  bool isTurningOnSharing = false;

  bool locationAllowed = false;

  bool isLoadingLocation = false;

  DateTime? lastRefresh;

  // ปัญหาตำแหน่งของเครื่องเรา (null = ใช้ได้)
  _LocationProblem? locationProblem;

  // กลับเข้าแอป (เช่น จากหน้าตั้งค่า) → เช็กสิทธิ์ตำแหน่งใหม่
  late final AppLifecycleListener lifecycle;

  // สมาชิกที่กำลังดูรายละเอียด (วาดเส้นทางจากเราไปหา)
  int? focusedUserId;

  // แผ่นรายละเอียดลากขึ้นลงได้ แผนที่ด้านบนยังซูม/เลื่อนได้
  final DraggableScrollableController detailSheet =
      DraggableScrollableController();

  static const double detailMinSize = 0.22;
  static const double detailInitialSize = 0.56;
  static const double detailMaxSize = 0.92;

  // ความสูงแผ่นตอนนี้ (สัดส่วนของหน้า) → เว้นขอบล่างแผนที่ให้จุดไม่ถูกบัง
  double detailSize = detailInitialSize;

  // เส้นทางตามถนนไปหาสมาชิกที่กำลังดู
  // {user_id, mode, distance, duration, points}
  Map<String, dynamic>? route;

  String routeMode = 'drive';

  bool routeLoading = false;

  // หาเส้นทางไม่ได้ → บอกเหตุผล
  String? routeNote;

  // Server ยังไม่ได้ตั้งค่า Routes API → ใช้ระยะเส้นตรง
  bool routesDisabled = false;

  // คำนวณเส้นทางใหม่เมื่อสมาชิกขยับไกลกว่านี้ (และห่างจากครั้งก่อนพอสมควร)
  // กันเรียก Routes API ถี่เกินตอนเขากำลังเดินทาง
  static const double rerouteAfterMeters = 150;
  static const Duration rerouteEvery = Duration(seconds: 45);

  // เราออกนอกเส้นทางเกินนี้ → คำนวณเส้นทางใหม่
  static const double offRouteMeters = 120;

  // จุดบนเส้นทางที่เราผ่านมาแล้ว (ตัดส่วนที่ผ่านแล้วออกจากเส้น)
  int routeProgress = 0;

  // เส้นทางแรก / เปลี่ยนโหมด → ซูมให้เห็นทั้งเส้น
  bool routeNeedsFit = false;

  DateTime? routeFetchedAt;

  // ทิ้งผลที่ตอบกลับช้ากว่าคำขอล่าสุด
  int routeRequest = 0;

  // ที่อยู่โดยประมาณ แปลงจากพิกัดในเครื่อง (ไม่เสียค่าบริการ)
  final Geocoding geocoder = Geocoding(locale: const Locale('th', 'TH'));

  final Map<String, String?> addresses = {};

  final Set<String> loadingAddresses = {};

  // หมู่บ้าน/ชุมชน + สถานที่ใกล้เคียง (จาก Server) แยกตามสมาชิก
  // เก็บพิกัดและเวลาที่หาไว้ → ขยับไม่ไกลก็ใช้ข้อมูลเดิม
  final Map<int, Map<String, dynamic>> placeDetails = {};

  final Set<int> loadingPlaceDetails = {};

  // โหมดเดินทาง → ชื่อ / ไอคอน / travelmode ของ Google Maps
  static const Map<String, ({String label, IconData icon, String googleMode})>
  travelModes = {
    'drive': (
      label: 'รถยนต์',
      icon: Icons.directions_car_rounded,
      googleMode: 'driving',
    ),
    'motorcycle': (
      label: 'มอเตอร์ไซค์',
      icon: Icons.two_wheeler_rounded,
      googleMode: 'two-wheeler',
    ),
    'walk': (
      label: 'เดิน',
      icon: Icons.directions_walk_rounded,
      googleMode: 'walking',
    ),
  };

  // เพิ่มทุกครั้งที่ตำแหน่งเปลี่ยน → แผ่นรายละเอียดคำนวณระยะทางใหม่
  final ValueNotifier<int> locationsVersion = ValueNotifier(0);

  // ตำแหน่งเกินเวลานี้ = อาจไม่ใช่ตำแหน่งปัจจุบัน (แอปของเขาอาจปิดอยู่)
  static const Duration staleAfter = Duration(minutes: 15);

  // รูปป้ายข้อความเหนือหมุด (วาดครั้งเดียวต่อข้อความ/โหมดสี)
  final Map<String, BitmapDescriptor> statusBubbles = {};

  final Set<String> drawingBubbles = {};

  // ตำแหน่งตั้งต้นของ Map
  // ใช้ก่อน GPS โหลดเสร็จ
  static const LatLng defaultPosition = LatLng(13.7563, 100.5018);

  // ยังไม่รู้ตำแหน่งเรา (ปิด GPS / ไม่อนุญาต) → พาไปดูสมาชิกแทนแผนที่ตั้งต้นครั้งเดียว
  bool shownFamilyFirst = false;

  // ชวนเปิด "แชร์แม้ไม่ได้เปิดแอป" (ซ่อนเมื่อเปิดแล้ว / กดปิด)
  bool showBackgroundInvite = false;

  static const String backgroundInviteKey = 'background_location_invite_closed';

  static const FlutterSecureStorage inviteStorage = FlutterSecureStorage();

  Future<void> loadBackgroundInvite() async {
    if (!BackgroundLocation.supported) return;

    final bool on =
        await BackgroundLocation.isEnabled() &&
        await BackgroundLocation.hasAlwaysPermission();

    final bool closed =
        await inviteStorage.read(key: backgroundInviteKey) == '1';

    if (mounted) setState(() => showBackgroundInvite = !on && !closed);
  }

  Future<void> closeBackgroundInvite() async {
    setState(() => showBackgroundInvite = false);

    await inviteStorage.write(key: backgroundInviteKey, value: '1');
  }

  Widget buildBackgroundInvite() {
    return Positioned(
      top: 104,
      left: 14,
      right: 14,

      child: Material(
        color: AppColors.surface,

        elevation: 4,

        shadowColor: AppColors.navy.withValues(alpha: 0.16),

        borderRadius: BorderRadius.circular(18),

        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),

          child: Row(
            children: [
              Icon(
                Icons.share_location_rounded,
                color: AppColors.primary,
                size: 24,
              ),

              const SizedBox(width: 10),

              Expanded(
                child: Text(
                  'ให้สมาชิกในกลุ่มเห็นตำแหน่งแม้คุณปิดแอป',

                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),

              TextButton(
                onPressed: () async {
                  final bool on = await enableBackgroundLocation(context);

                  if (on && mounted) {
                    setState(() => showBackgroundInvite = false);
                  }
                },
                child: const Text('เปิด'),
              ),

              IconButton(
                tooltip: 'ไม่ต้องแสดงอีก',
                visualDensity: VisualDensity.compact,
                onPressed: closeBackgroundInvite,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();

    lifecycle = AppLifecycleListener(onResume: recheckLocation);

    loadBackgroundInvite();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      initializePage();
    });
  }

  // =====================================================
  // START
  // =====================================================

  Future<void> initializePage() async {
    startRefreshTimer();

    // โหลดสองระบบแยกจากกัน
    // Map จะไม่ต้องรอ
    loadFamilyLocations();
    prepareLocation();
  }

  // =====================================================
  // GPS / PERMISSION
  // =====================================================

  Future<void> prepareLocation() async {
    if (isLoadingLocation) {
      return;
    }

    isLoadingLocation = true;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        if (!mounted) return;

        setState(() {
          locationProblem = _LocationProblem.serviceOff;
        });

        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        if (!mounted) return;

        setState(() {
          locationProblem = _LocationProblem.denied;
        });

        return;
      }

      if (permission == LocationPermission.deniedForever) {
        if (!mounted) return;

        setState(() {
          locationProblem = _LocationProblem.deniedForever;
        });

        return;
      }

      if (!mounted) return;

      setState(() {
        locationAllowed = true;
        locationProblem = null;
      });

      const settings = LocationSettings(accuracy: LocationAccuracy.high);

      final position = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      );

      if (!mounted) return;

      setState(() {
        currentPosition = position;
      });

      // ส่งตำแหน่งนี้ทันที แล้วให้ LocationTracker ส่งต่อเองขณะเปิดแอป (ทุกแท็บ)
      await LocationTracker.start(current: position);

      await moveToMyLocation();

      startPositionStream();

      // โหลดข้อมูลใหม่หลังเราเพิ่งส่ง
      // Location ของตัวเอง
      await loadFamilyLocations();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        locationProblem = _LocationProblem.failed;
      });
    } finally {
      isLoadingLocation = false;
    }
  }

  // แถบเตือนตำแหน่ง → "เปิดตั้งค่า"
  // - ปิดตำแหน่งของเครื่อง → หน้าตั้งค่าตำแหน่ง
  // - ไม่อนุญาตถาวร → หน้าตั้งค่าแอป
  // - ยังขอสิทธิ์ได้ / อ่านตำแหน่งไม่สำเร็จ → ขอสิทธิ์หรืออ่านใหม่
  Future<void> fixLocationProblem() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        await Geolocator.openLocationSettings();

        return;
      }

      // ถูกปฏิเสธถาวร (รู้จากผลขอสิทธิ์ครั้งก่อน หรือจากการเช็ก) → ขอซ้ำไม่ได้แล้ว
      if (locationProblem == _LocationProblem.deniedForever ||
          await Geolocator.checkPermission() ==
              LocationPermission.deniedForever) {
        await Geolocator.openAppSettings();

        return;
      }
    } catch (_) {
      // เช็กไม่ได้ → ลองอ่านตำแหน่งตามปกติ
    }

    await prepareLocation();
  }

  // กลับเข้าแอป (เช่น จากหน้าตั้งค่า) → เปิดสิทธิ์และตำแหน่งแล้วจึงเริ่มใช้ทันที
  // ห้ามขอสิทธิ์ตรงนี้: หน้าต่างขอสิทธิ์ทำให้แอปพัก/กลับมาใหม่ → วนไม่จบ
  Future<void> recheckLocation() async {
    if (locationProblem == null || isLoadingLocation) return;

    try {
      final bool service = await Geolocator.isLocationServiceEnabled();

      final LocationPermission permission = await Geolocator.checkPermission();

      if (service &&
          (permission == LocationPermission.always ||
              permission == LocationPermission.whileInUse)) {
        await prepareLocation();

        return;
      }

      if (!mounted) return;

      // ยังแก้ไม่ครบ → ปรับแค่ข้อความบนแถบเตือน
      if (!service) {
        setState(() => locationProblem = _LocationProblem.serviceOff);
      } else if (locationProblem == _LocationProblem.serviceOff) {
        setState(() => locationProblem = _LocationProblem.denied);
      }
    } catch (_) {
      // เช็กไม่ได้ → รอผู้ใช้กด "เปิดตั้งค่า" เอง
    }
  }

  // =====================================================
  // LOCATION STREAM
  // =====================================================

  void startPositionStream() {
    positionSubscription?.cancel();

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,

      // ส่งใหม่เมื่อขยับประมาณ 10 เมตร
      distanceFilter: 10,
    );

    positionSubscription =
        Geolocator.getPositionStream(locationSettings: settings)
            .listen((position) {
              if (!mounted) return;

              // ใช้แสดงจุดของเราบนแผนที่เท่านั้น
              // (LocationTracker เป็นคนส่งตำแหน่งให้ครอบครัว)
              setState(() {
                currentPosition = position;
              });

              locationsVersion.value++;

              followRoute(position);
            });
  }

  // =====================================================
  // LOAD FAMILY LOCATIONS
  // =====================================================

  Future<void> loadFamilyLocations() async {
    try {
      final result = await LocationService.getFamilyLocations();

      if (!mounted) return;

      if (result['status'] == true) {
        final rawLocations = result['locations'];

        final List<Map<String, dynamic>> locations = [];

        if (rawLocations is List) {
          for (final item in rawLocations) {
            if (item is Map) {
              locations.add(Map<String, dynamic>.from(item));
            }
          }
        }

        final dynamic rawPaused = result['paused'];

        setState(() {
          familyLocations = locations;

          pausedNames = rawPaused is List
              ? rawPaused
                    .whereType<Map>()
                    .map((member) => member['name']?.toString() ?? '')
                    .where((name) => name.isNotEmpty)
                    .toList()
              : [];

          lastRefresh = DateTime.now();
        });

        locationsVersion.value++;

        prepareStatusBubbles();

        prepareAvatarPins();

        if (!shownFamilyFirst &&
            currentPosition == null &&
            mapController != null &&
            locations.isNotEmpty) {
          shownFamilyFirst = true;

          showAllMembers();
        }

        // สมาชิกที่กำลังดูขยับไป → หาที่อยู่ใหม่
        final int? focused = focusedUserId;

        final Map<String, dynamic>? member = focused == null
            ? null
            : locationOf(focused);

        if (member != null) {
          loadAddress(member);

          loadPlaceDetails(member);

          if (memberMovedFromRoute(member)) loadRoute();
        }
      }
    } catch (_) {
      // Timer จะลองใหม่อีกรอบ
    }
  }

  // เปิดการแชร์ตำแหน่งอีกครั้ง (จากแถบแจ้งบนแผนที่)
  Future<void> turnOnSharing() async {
    setState(() => isTurningOnSharing = true);

    try {
      final result = await SettingsService.updateSettings(
        locationSharing: true,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        await prepareLocation();

        // ถ้าหน้านี้กำลังอ่าน GPS อยู่ตอนกดเปิด prepareLocation จะไม่ทำซ้ำ
        // → สั่งเริ่มส่งตรงนี้ด้วย (ถ้าเริ่มไปแล้วจะไม่ส่งซ้ำ)
        await LocationTracker.start();
      } else {
        showSnack(result['message']?.toString() ?? 'เปิดการแชร์ไม่สำเร็จ');
      }
    } catch (e) {
      if (mounted) showSnack(e.toString());
    } finally {
      if (mounted) setState(() => isTurningOnSharing = false);
    }
  }

  void showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // REFRESH ทุก 10 วินาที
  // =====================================================

  // ดูรายละเอียดสมาชิกอยู่ → รีเฟรชถี่ขึ้น ให้หมุดของเขาขยับแบบเรียลไทม์
  void startRefreshTimer({bool fast = false}) {
    refreshTimer?.cancel();

    refreshTimer = Timer.periodic(Duration(seconds: fast ? 5 : 10), (_) {
      loadFamilyLocations();
    });
  }

  // =====================================================
  // HELPERS
  // =====================================================

  double? toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(value?.toString() ?? '');
  }

  String getMemberName(Map<String, dynamic> location) {
    final user = location['user'];

    if (user is Map) {
      return user['name']?.toString() ?? 'สมาชิก';
    }

    return 'สมาชิก';
  }

  String? getProfileImageUrl(Map<String, dynamic> location) {
    final user = location['user'];

    if (user is! Map) {
      return null;
    }

    const keys = [
      'profile_image_url',
      'profile_photo_url',
      'avatar_url',
      'photo_url',
      'image_url',
      'profile_image',
      'avatar',
      'photo',
      'image',
    ];

    for (final key in keys) {
      final rawValue = user[key];

      if (rawValue == null) {
        continue;
      }

      final value = rawValue.toString().trim();

      if (value.isNotEmpty && value.toLowerCase() != 'null') {
        return value;
      }
    }

    return null;
  }

  String getInitial(String name) {
    final value = name.trim();

    if (value.isEmpty) {
      return '?';
    }

    return value.characters.first.toUpperCase();
  }

  // =====================================================
  // เวลาอัปเดต
  // =====================================================

  String formatLastSeen(dynamic value) {
    if (value == null) {
      return 'ยังไม่มีข้อมูลเวลา';
    }

    try {
      final date = DateTime.parse(value.toString()).toLocal();

      final difference = DateTime.now().difference(date);

      if (difference.isNegative || difference.inMinutes < 1) {
        return 'เมื่อสักครู่';
      }

      if (difference.inMinutes < 60) {
        return '${difference.inMinutes} นาทีที่แล้ว';
      }

      if (difference.inHours < 24) {
        return '${difference.inHours} ชั่วโมงที่แล้ว';
      }

      return '${difference.inDays} วันที่แล้ว';
    } catch (_) {
      return 'มีข้อมูลตำแหน่ง';
    }
  }

  bool isMe(Map<String, dynamic> location) => location['is_me'] == true;

  int? userIdOf(Map<String, dynamic> location) {
    final dynamic id = location['user_id'];

    return id is num ? id.toInt() : int.tryParse(id?.toString() ?? '');
  }

  Map<String, dynamic>? locationOf(int userId) {
    for (final location in familyLocations) {
      if (userIdOf(location) == userId) return location;
    }

    return null;
  }

  DateTime? lastSeenOf(Map<String, dynamic> location) {
    return DateTime.tryParse(location['last_seen_at']?.toString() ?? '')
        ?.toLocal();
  }

  bool isStale(Map<String, dynamic> location) {
    final DateTime? lastSeen = lastSeenOf(location);

    return lastSeen == null || DateTime.now().difference(lastSeen) > staleAfter;
  }

  // ระยะทางเส้นตรงจากเรา (เมตร) / ยังไม่รู้ตำแหน่งเรา → null
  double? distanceTo(Map<String, dynamic> location) {
    final Position? me = currentPosition;

    final latitude = toDouble(location['latitude']);

    final longitude = toDouble(location['longitude']);

    if (me == null || latitude == null || longitude == null) return null;

    return Geolocator.distanceBetween(
      me.latitude,
      me.longitude,
      latitude,
      longitude,
    );
  }

  static String formatDistance(double meters) {
    if (meters < 1000) {
      // ใกล้มาก ๆ ปัดเป็นสิบเมตร อ่านง่ายกว่า
      final int rounded = meters < 100
          ? meters.round()
          : (meters / 10).round() * 10;

      return '$rounded ม.';
    }

    final double km = meters / 1000;

    return km < 10 ? '${km.toStringAsFixed(1)} กม.' : '${km.round()} กม.';
  }

  // 14:32 น.
  static String formatClock(DateTime date) {
    return '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')} น.';
  }

  // อัปเดตวันนี้ / อัปเดตเมื่อวาน / อัปเดต 26 ต.ค.
  static String formatUpdatedDay(DateTime date) {
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

    final DateTime today = DateTime(now.year, now.month, now.day);

    final DateTime day = DateTime(date.year, date.month, date.day);

    if (day == today) return 'อัปเดตวันนี้';

    if (day == today.subtract(const Duration(days: 1))) {
      return 'อัปเดตเมื่อวาน';
    }

    return 'อัปเดต ${date.day} ${months[date.month]}';
  }

  // ข้อความบนแผนที่ (โพสต์ครอบครัวที่เลือก "แสดงบนแผนที่")
  Map<String, dynamic>? statusOf(Map<String, dynamic> location) {
    final dynamic status = location['status'];

    if (status is! Map) return null;

    final String text = status['text']?.toString().trim() ?? '';

    return text.isEmpty ? null : Map<String, dynamic>.from(status);
  }

  String? statusTextOf(Map<String, dynamic> location) {
    return statusOf(location)?['text']?.toString().trim();
  }

  String bubbleKey(String text) =>
      '${AppColors.isDark ? 'dark' : 'light'}|$text';

  // วาดป้ายของข้อความที่ยังไม่มีรูป แล้ววาดแผนที่ใหม่
  Future<void> prepareStatusBubbles() async {
    if (!mounted) return;

    final double ratio = MediaQuery.devicePixelRatioOf(context);

    bool added = false;

    for (final location in List.of(familyLocations)) {
      final String? text = statusTextOf(location);

      if (text == null) continue;

      final String key = bubbleKey(text);

      if (statusBubbles.containsKey(key) || !drawingBubbles.add(key)) continue;

      try {
        statusBubbles[key] = await drawStatusBubble(text, ratio);

        added = true;
      } catch (_) {
        // วาดไม่ได้ → ไม่มีป้ายบนแผนที่ (ยังเห็นข้อความในการ์ดด้านล่าง)
      } finally {
        drawingBubbles.remove(key);
      }
    }

    if (added && mounted) setState(() {});
  }

  // ป้ายคำพูดเหนือหมุด: Marker ใส่ Widget ไม่ได้ จึงวาดเป็นรูป
  // เว้นที่ด้านล่างเท่าความสูงหมุด → ใช้จุดยึดล่างกลางแล้วลอยเหนือหมุดพอดี
  static Future<BitmapDescriptor> drawStatusBubble(
    String text,
    double ratio,
  ) async {
    const double maxTextWidth = 170;
    const double padX = 11;
    const double padY = 6;
    const double tail = 7;
    const double pinGap = pinHeight + 2;
    const double margin = 4;

    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: AppColors.navy,
          fontSize: 13 * ratio,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxTextWidth * ratio);

    final double bubbleWidth = painter.width + padX * 2 * ratio;
    final double bubbleHeight = painter.height + padY * 2 * ratio;

    final double width = bubbleWidth + margin * 2 * ratio;
    final double height = bubbleHeight + (tail + pinGap + margin * 2) * ratio;

    final Rect rect = Rect.fromLTWH(
      margin * ratio,
      margin * ratio,
      bubbleWidth,
      bubbleHeight,
    );

    final Path shape = Path.combine(
      PathOperation.union,
      Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(14 * ratio))),
      Path()
        ..moveTo(rect.center.dx - tail * ratio, rect.bottom - 2)
        ..lineTo(rect.center.dx, rect.bottom + tail * ratio)
        ..lineTo(rect.center.dx + tail * ratio, rect.bottom - 2)
        ..close(),
    );

    final ui.PictureRecorder recorder = ui.PictureRecorder();

    final Canvas canvas = Canvas(recorder);

    canvas.drawShadow(shape, Colors.black, 2.5 * ratio, false);

    canvas.drawPath(shape, Paint()..color = AppColors.surface);

    canvas.drawPath(
      shape,
      Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * ratio,
    );

    painter.paint(
      canvas,
      Offset(rect.left + padX * ratio, rect.top + padY * ratio),
    );

    final ui.Image image = await recorder.endRecording().toImage(
      width.ceil(),
      height.ceil(),
    );

    final data = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.bytes(
      data!.buffer.asUint8List(),
      imagePixelRatio: ratio,
    );
  }

  // =====================================================
  // หมุดรูปโปรไฟล์ (วงกลมขอบขาว + ปลายแหลมชี้ตำแหน่ง)
  // Marker ใส่ Widget ไม่ได้ จึงวาดเป็นรูป / ยังวาดไม่เสร็จ → หมุดปกติ
  // =====================================================

  static const double pinCircle = 42;
  static const double pinRing = 3;
  static const double pinTail = 8;
  static const double pinMargin = 4;

  // ความสูงหมุดเหนือจุดที่ปัก (ป้ายข้อความลอยเหนือระยะนี้)
  static const double pinHeight = pinCircle + pinRing * 2 + pinTail;

  // จุดยึด = ปลายแหลมของหมุด
  static const Offset pinAnchor = Offset(
    0.5,
    (pinMargin + pinHeight) / (pinHeight + pinMargin * 2),
  );

  final Map<String, BitmapDescriptor> avatarPins = {};

  final Set<String> drawingPins = {};

  String pinKey(Map<String, dynamic> location) =>
      '${isMe(location)}|${getProfileImageUrl(location) ?? ''}|'
      '${getMemberName(location)}';

  // วาดหมุดของสมาชิกที่ยังไม่มีรูปหมุด แล้ววาดแผนที่ใหม่
  Future<void> prepareAvatarPins() async {
    if (!mounted) return;

    final double ratio = MediaQuery.devicePixelRatioOf(context);

    bool added = false;

    for (final location in List.of(familyLocations)) {
      final String key = pinKey(location);

      if (avatarPins.containsKey(key) || !drawingPins.add(key)) continue;

      ui.Image? photo;

      try {
        photo = await loadPinPhoto(getProfileImageUrl(location));

        avatarPins[key] = await drawAvatarPin(
          photo: photo,
          name: getMemberName(location),
          me: isMe(location),
          ratio: ratio,
        );

        added = true;
      } catch (_) {
        // วาดไม่ได้ → ใช้หมุดปกติ
      } finally {
        photo?.dispose();

        drawingPins.remove(key);
      }
    }

    if (added && mounted) setState(() {});
  }

  // รูปโปรไฟล์สำหรับหมุด (ไม่มีรูป / โหลดไม่ได้ → null = ใช้ตัวอักษรแรกของชื่อ)
  static Future<ui.Image?> loadPinPhoto(String? url) async {
    final String value = url?.trim() ?? '';

    if (value.isEmpty) return null;

    final Completer<ui.Image?> done = Completer<ui.Image?>();

    final ImageStream stream = NetworkImage(value)
        .resolve(ImageConfiguration.empty);

    final ImageStreamListener listener = ImageStreamListener(
      (info, _) {
        if (!done.isCompleted) done.complete(info.image.clone());

        info.dispose();
      },
      onError: (_, _) {
        if (!done.isCompleted) done.complete(null);
      },
    );

    stream.addListener(listener);

    try {
      return await done.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => null,
      );
    } finally {
      stream.removeListener(listener);
    }
  }

  static Future<BitmapDescriptor> drawAvatarPin({
    required ui.Image? photo,
    required String name,
    required bool me,
    required double ratio,
  }) async {
    final double outer = (pinCircle + pinRing * 2) * ratio;
    final double margin = pinMargin * ratio;
    final double width = outer + margin * 2;
    final double height = (pinHeight + pinMargin * 2) * ratio;
    final double radius = outer / 2;

    final Offset center = Offset(width / 2, margin + radius);

    final Path shape = Path.combine(
      PathOperation.union,
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
      Path()
        ..moveTo(center.dx - radius * 0.45, center.dy + radius * 0.89)
        ..lineTo(center.dx, (pinMargin + pinHeight) * ratio)
        ..lineTo(center.dx + radius * 0.45, center.dy + radius * 0.89)
        ..close(),
    );

    final ui.PictureRecorder recorder = ui.PictureRecorder();

    final Canvas canvas = Canvas(recorder);

    canvas.drawShadow(shape, Colors.black, 2.5 * ratio, false);

    // ขอบหมุด: ของเรา = สีหลัก / คนอื่น = ขาว
    canvas.drawPath(
      shape,
      Paint()..color = me ? AppColors.primary : Colors.white,
    );

    final Rect photoRect = Rect.fromCircle(
      center: center,
      radius: pinCircle / 2 * ratio,
    );

    canvas.save();

    canvas.clipPath(Path()..addOval(photoRect));

    if (photo != null) {
      // ครอบกลางรูปให้เป็นสี่เหลี่ยมจัตุรัส
      final double side =
          (photo.width < photo.height ? photo.width : photo.height).toDouble();

      canvas.drawImageRect(
        photo,
        Rect.fromCenter(
          center: Offset(photo.width / 2, photo.height / 2),
          width: side,
          height: side,
        ),
        photoRect,
        Paint()..filterQuality = FilterQuality.medium,
      );
    } else {
      canvas.drawRect(
        photoRect,
        Paint()
          ..shader = ui.Gradient.linear(
            photoRect.topLeft,
            photoRect.bottomRight,
            [AppColors.primary, const Color(0xFF767BFF)],
          ),
      );

      final String trimmed = name.trim();

      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase(),
          style: TextStyle(
            color: Colors.white,
            fontSize: pinCircle * 0.4 * ratio,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      painter.paint(
        canvas,
        center - Offset(painter.width / 2, painter.height / 2),
      );
    }

    canvas.restore();

    final ui.Image image = await recorder.endRecording().toImage(
      width.ceil(),
      height.ceil(),
    );

    final data = await image.toByteData(format: ui.ImageByteFormat.png);

    image.dispose();

    return BitmapDescriptor.bytes(
      data!.buffer.asUint8List(),
      imagePixelRatio: ratio,
    );
  }

  // ข้อความบนแผนที่ในแผ่นรายละเอียด: "ทำงานอยู่" + เวลาโพสต์
  Widget buildStatusQuote(Map<String, dynamic> status) {
    final DateTime? until = DateTime.tryParse(status['until']?.toString() ?? '')
        ?.toLocal();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),

      decoration: BoxDecoration(
        color: AppColors.softPrimary,
        borderRadius: BorderRadius.circular(16),
      ),

      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Icon(Icons.chat_bubble_rounded, size: 18, color: AppColors.primary),

          const SizedBox(width: 10),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  status['text']?.toString() ?? '',

                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  'โพสต์ ${formatLastSeen(status['created_at'])}'
                  '${until == null ? '' : ' · แสดงถึง ${until.day == DateTime.now().day ? '' : 'พรุ่งนี้ '}${formatClock(until)}'}',

                  style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // แตะจุดของเราที่มีข้อความ → ดู / เอาออกจากแผนที่
  Future<void> showMyStatus(Map<String, dynamic> location) async {
    final Map<String, dynamic>? status = statusOf(location);

    final dynamic postId = status?['post_id'];

    if (status == null || postId is! num) return;

    final bool? remove = await showModalBottomSheet<bool>(
      context: context,

      showDragHandle: true,

      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),

            child: Column(
              mainAxisSize: MainAxisSize.min,

              crossAxisAlignment: CrossAxisAlignment.stretch,

              children: [
                Text(
                  'ข้อความของคุณบนแผนที่',
                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),

                const SizedBox(height: 12),

                buildStatusQuote(status),

                const SizedBox(height: 16),

                OutlinedButton.icon(
                  onPressed: () => Navigator.of(sheetContext).pop(true),

                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    minimumSize: const Size(double.infinity, 48),
                  ),

                  icon: const Icon(Icons.location_off_outlined),

                  label: const Text('เอาออกจากแผนที่'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (remove != true || !mounted) return;

    try {
      final result = await PostService.setOnMap(postId.toInt(), false);

      if (!mounted) return;

      showMessage(
        result['message']?.toString() ??
            (result['status'] == true
                ? 'เอาข้อความออกจากแผนที่แล้ว'
                : 'เอาออกไม่สำเร็จ'),
      );

      if (result['status'] == true) await loadFamilyLocations();
    } catch (e) {
      showMessage(e.toString());
    }
  }

  // บรรทัดใต้ชื่อ: "อัปเดต 3 นาทีที่แล้ว" / คนอื่น: "1.2 กม. · อัปเดต 3 นาทีที่แล้ว"
  String memberSummary(Map<String, dynamic> location) {
    final String updated = updatedAgo(location);

    if (isMe(location)) return updated;

    final double? distance = distanceTo(location);

    return distance == null
        ? updated
        : '${formatDistance(distance)} · $updated';
  }

  // อัปเดตเมื่อสักครู่ / อัปเดต 11 นาทีที่แล้ว
  String updatedAgo(Map<String, dynamic> location) {
    if (lastSeenOf(location) == null) return 'ยังไม่มีข้อมูลเวลา';

    final String ago = formatLastSeen(location['last_seen_at']);

    return ago == 'เมื่อสักครู่' ? 'อัปเดตเมื่อสักครู่' : 'อัปเดต $ago';
  }

  // บรรทัดใต้หัวการ์ดบนแผนที่
  String getSyncText() {
    if (lastRefresh == null) {
      return 'กำลังโหลดตำแหน่ง...';
    }

    final difference = DateTime.now().difference(lastRefresh!);

    if (difference.inMinutes < 1) {
      return 'อัปเดตเมื่อสักครู่';
    }

    return 'อัปเดต ${difference.inMinutes} นาทีที่แล้ว';
  }

  // =====================================================
  // MARKERS
  // =====================================================

  Set<Marker> buildMarkers() {
    final Set<Marker> markers = {};

    for (int index = 0; index < familyLocations.length; index++) {
      final location = familyLocations[index];

      final latitude = toDouble(location['latitude']);

      final longitude = toDouble(location['longitude']);

      if (latitude == null || longitude == null) {
        continue;
      }

      final userId = location['user_id']?.toString() ?? '$index';

      final name = getMemberName(location);

      final BitmapDescriptor? pin = avatarPins[pinKey(location)];

      markers.add(
        Marker(
          markerId: MarkerId('family_$userId'),

          position: LatLng(latitude, longitude),

          // หมุดรูปโปรไฟล์ (ยังวาดไม่เสร็จ → หมุดปกติ)
          icon:
              pin ??
              BitmapDescriptor.defaultMarkerWithHue(
                index.isEven
                    ? BitmapDescriptor.hueViolet
                    : BitmapDescriptor.hueAzure,
              ),

          anchor: pin == null ? const Offset(0.5, 1) : pinAnchor,

          infoWindow: InfoWindow(
            title: isMe(location) ? '$name (คุณ)' : name,

            snippet: memberSummary(location),
          ),

          onTap: () => openMember(location),
        ),
      );

      // ป้ายข้อความ (เช่น "ทำงานอยู่") ลอยเหนือหมุด
      final String? status = statusTextOf(location);

      final BitmapDescriptor? bubble = status == null
          ? null
          : statusBubbles[bubbleKey(status)];

      if (bubble != null) {
        markers.add(
          Marker(
            markerId: MarkerId('status_$userId'),

            position: LatLng(latitude, longitude),

            icon: bubble,

            zIndexInt: 2,

            consumeTapEvents: true,

            onTap: () => openMember(location),
          ),
        );
      }
    }

    return markers;
  }

  // เส้นทางตามถนน (ถ้ามี) หรือเส้นประตรงจากเราไปหาสมาชิกที่กำลังดู
  Set<Polyline> buildPolylines() {
    final int? userId = focusedUserId;

    final Position? me = currentPosition;

    if (userId == null || me == null) return {};

    final Map<String, dynamic>? current = route;

    final dynamic points = current?['points'];

    if (current != null &&
        current['user_id'] == userId &&
        points is List<LatLng> &&
        points.length >= 2) {
      final List<LatLng> live = liveRoutePoints(points, me);

      return {
        // ขอบสีขาวให้เส้นเด่นบนถนน
        Polyline(
          polylineId: const PolylineId('route_outline'),
          points: live,
          color: AppColors.isDark ? const Color(0xFF0F1A2B) : Colors.white,
          width: 9,
          zIndex: 1,
        ),
        Polyline(
          polylineId: const PolylineId('route'),
          points: live,
          color: AppColors.primary,
          width: 6,
          zIndex: 2,
        ),
      };
    }

    final Map<String, dynamic>? location = locationOf(userId);

    final latitude = location == null ? null : toDouble(location['latitude']);

    final longitude = location == null ? null : toDouble(location['longitude']);

    if (latitude == null || longitude == null) return {};

    return {
      Polyline(
        polylineId: const PolylineId('to_member'),
        points: [
          LatLng(me.latitude, me.longitude),
          LatLng(latitude, longitude),
        ],
        color: AppColors.primary,
        width: 4,
        patterns: [PatternItem.dash(18), PatternItem.gap(12)],
      ),
    };
  }

  // =====================================================
  // MOVE TO MEMBER
  // =====================================================

  Future<void> moveToMember(Map<String, dynamic> location) async {
    if (mapController == null) {
      return;
    }

    final latitude = toDouble(location['latitude']);

    final longitude = toDouble(location['longitude']);

    if (latitude == null || longitude == null) {
      return;
    }

    await mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: LatLng(latitude, longitude), zoom: 16),
      ),
    );
  }

  Future<void> zoomBy(double amount) async {
    await mapController?.animateCamera(CameraUpdate.zoomBy(amount));
  }

  // ให้เห็นทุกจุดในรายการ (เว้นขอบเท่าแผ่นรายละเอียด)
  Future<void> showPoints(List<LatLng> points) async {
    final controller = mapController;

    if (controller == null || points.isEmpty) return;

    double south = points.first.latitude;
    double north = points.first.latitude;
    double west = points.first.longitude;
    double east = points.first.longitude;

    for (final point in points.skip(1)) {
      if (point.latitude < south) south = point.latitude;
      if (point.latitude > north) north = point.latitude;
      if (point.longitude < west) west = point.longitude;
      if (point.longitude > east) east = point.longitude;
    }

    // อยู่ใกล้กันมาก → ซูมที่จุดแรกแทน
    if ((north - south).abs() < 0.0005 && (east - west).abs() < 0.0005) {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: points.last, zoom: 16),
        ),
      );
      return;
    }

    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(south, west),
            northeast: LatLng(north, east),
          ),
          50,
        ),
      );
    } catch (_) {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: points.last, zoom: 15),
        ),
      );
    }
  }

  // =====================================================
  // MEMBER DETAILS
  // แผ่นลากขึ้นลงได้: ที่อยู่ ระยะทาง/เวลาตามถนน นำทาง แชท โปรไฟล์
  // =====================================================

  // เห็นทั้งเราและสมาชิกบนแผนที่ (เหนือแผ่นรายละเอียด)
  Future<void> showMeAndMember(Map<String, dynamic> location) async {
    final Position? me = currentPosition;

    final latitude = toDouble(location['latitude']);

    final longitude = toDouble(location['longitude']);

    if (latitude == null || longitude == null) return;

    await showPoints([
      if (me != null) LatLng(me.latitude, me.longitude),
      LatLng(latitude, longitude),
    ]);
  }

  Future<void> openMember(Map<String, dynamic> location) async {
    final int? userId = userIdOf(location);

    // จุดของเราเอง → เลื่อนไปที่ตัวเรา (มีข้อความบนแผนที่ → ดู/เอาออกได้)
    if (isMe(location) || userId == null) {
      await moveToMember(location);

      if (isMe(location) && statusOf(location) != null && mounted) {
        await showMyStatus(location);
      }

      return;
    }

    final bool switching = focusedUserId != null;

    setState(() {
      focusedUserId = userId;
      route = null;
      routeNote = null;
      detailSize = detailInitialSize;
    });

    if (switching && detailSheet.isAttached) {
      detailSheet.jumpTo(detailInitialSize);
    }

    loadAddress(location);

    loadPlaceDetails(location);

    startRefreshTimer(fast: true);

    // รอให้แผนที่รับระยะขอบใหม่ก่อน แล้วค่อยเลื่อนกล้อง
    await Future<void>.delayed(const Duration(milliseconds: 150));

    if (!mounted || focusedUserId != userId) return;

    showMeAndMember(location);

    loadRoute();
  }

  void closeMember() {
    setState(() {
      focusedUserId = null;
      route = null;
      routeNote = null;
      routeLoading = false;
      routeRequest++;
    });

    startRefreshTimer();
  }

  // =====================================================
  // เส้นทางตามถนน (คำนวณที่ Server ด้วย Google Routes API)
  // =====================================================

  Future<void> loadRoute() async {
    final int? userId = focusedUserId;

    final Position? me = currentPosition;

    if (userId == null || me == null || routesDisabled) return;

    final int request = ++routeRequest;

    final String mode = routeMode;

    setState(() {
      routeLoading = true;
      routeNote = null;
    });

    try {
      final result = await LocationService.getRoute(
        userId: userId,
        fromLat: me.latitude,
        fromLng: me.longitude,
        mode: mode,
      );

      if (!mounted || request != routeRequest) return;

      if (result['status'] == true) {
        final List<LatLng> points = decodePolyline(
          result['polyline']?.toString() ?? '',
        );

        setState(() {
          final bool first = route?['user_id'] != userId;

          route = {
            'user_id': userId,
            'mode': mode,
            'distance': toDouble(result['distance_meters']),
            'duration': toDouble(result['duration_seconds']),
            'points': points,
            'line_meters': pathLength(points),
          };

          routeProgress = 0;

          routeFetchedAt = DateTime.now();

          // เส้นทางแรกของคนนี้ → ซูมให้เห็นทั้งเส้น
          // (คำนวณใหม่ระหว่างทางไม่ย้ายกล้อง ผู้ใช้อาจซูมดูอยู่)
          if (first) routeNeedsFit = true;
        });

        if (routeNeedsFit && points.length >= 2) {
          routeNeedsFit = false;

          showPoints(points);
        }
      } else if (result['code'] == 'routes_disabled') {
        setState(() {
          routesDisabled = true;
          route = null;
        });
      } else {
        setState(() {
          route = null;
          routeNote = result['message']?.toString() ?? 'คำนวณเส้นทางไม่สำเร็จ';
        });
      }
    } catch (_) {
      if (mounted && request == routeRequest) {
        setState(() {
          route = null;
          routeNote = 'คำนวณเส้นทางไม่สำเร็จ ลองแตะโหมดเดินทางอีกครั้ง';
        });
      }
    } finally {
      if (mounted && request == routeRequest) {
        setState(() => routeLoading = false);
      }
    }
  }

  // =====================================================
  // เส้นทางแบบเรียลไทม์
  // - เราขยับ → ตัดส่วนที่ผ่านแล้วออก ระยะทาง/เวลาที่เหลือลดลงตาม
  // - ออกนอกเส้นทาง / สมาชิกขยับไกล → คำนวณใหม่ (ไม่ถี่กว่าทุก 45 วินาที)
  // =====================================================

  bool canReroute() {
    final DateTime? fetchedAt = routeFetchedAt;

    return !routeLoading &&
        (fetchedAt == null ||
            DateTime.now().difference(fetchedAt) >= rerouteEvery);
  }

  void followRoute(Position me) {
    final dynamic points = route?['points'];

    if (focusedUserId == null || points is! List<LatLng> || points.length < 2) {
      return;
    }

    int nearest = routeProgress;

    double best = double.infinity;

    for (int i = routeProgress; i < points.length; i++) {
      final double distance = Geolocator.distanceBetween(
        me.latitude,
        me.longitude,
        points[i].latitude,
        points[i].longitude,
      );

      if (distance < best) {
        best = distance;
        nearest = i;
      }
    }

    if (best > offRouteMeters) {
      if (canReroute()) loadRoute();
      return;
    }

    if (nearest != routeProgress) setState(() => routeProgress = nearest);
  }

  // เส้นที่วาด: จากตำแหน่งเรา → ส่วนที่ยังไม่ผ่าน → ตำแหน่งล่าสุดของสมาชิก
  List<LatLng> liveRoutePoints(List<LatLng> points, Position me) {
    final int start = (routeProgress + 1).clamp(0, points.length - 1);

    final List<LatLng> live = [
      LatLng(me.latitude, me.longitude),
      ...points.sublist(start),
    ];

    final int? userId = focusedUserId;

    final Map<String, dynamic>? member = userId == null
        ? null
        : locationOf(userId);

    final latitude = member == null ? null : toDouble(member['latitude']);

    final longitude = member == null ? null : toDouble(member['longitude']);

    // สมาชิกขยับไปจากปลายเส้นทาง → ต่อเส้นไปถึงหมุดของเขา
    if (latitude != null &&
        longitude != null &&
        Geolocator.distanceBetween(
              points.last.latitude,
              points.last.longitude,
              latitude,
              longitude,
            ) >
            20) {
      live.add(LatLng(latitude, longitude));
    }

    return live;
  }

  static double pathLength(List<LatLng> points) {
    double meters = 0;

    for (int i = 1; i < points.length; i++) {
      meters += Geolocator.distanceBetween(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }

    return meters;
  }

  // ระยะทาง/เวลาที่เหลือ (เทียบสัดส่วนกับเส้นทางที่ Google คำนวณ)
  ({double? meters, double? seconds}) routeRemaining(
    Map<String, dynamic> current,
  ) {
    final double? distance = toDouble(current['distance']);

    final double? duration = toDouble(current['duration']);

    final double? lineMeters = toDouble(current['line_meters']);

    final dynamic points = current['points'];

    final Position? me = currentPosition;

    if (me == null ||
        points is! List<LatLng> ||
        points.length < 2 ||
        lineMeters == null ||
        lineMeters <= 0) {
      return (meters: distance, seconds: duration);
    }

    final double ratio = (pathLength(liveRoutePoints(points, me)) / lineMeters)
        .clamp(0.0, 1.5);

    return (
      meters: distance == null ? null : distance * ratio,
      seconds: duration == null ? null : duration * ratio,
    );
  }

  // เส้นทางเดิมไปไม่ถึงตำแหน่งใหม่ของสมาชิกแล้ว?
  bool memberMovedFromRoute(Map<String, dynamic> member) {
    final dynamic points = route?['points'];

    final DateTime? fetchedAt = routeFetchedAt;

    final latitude = toDouble(member['latitude']);

    final longitude = toDouble(member['longitude']);

    if (routeLoading ||
        points is! List<LatLng> ||
        points.isEmpty ||
        fetchedAt == null ||
        latitude == null ||
        longitude == null) {
      return false;
    }

    if (!canReroute()) return false;

    return Geolocator.distanceBetween(
          points.last.latitude,
          points.last.longitude,
          latitude,
          longitude,
        ) >
        rerouteAfterMeters;
  }

  void selectRouteMode(String mode) {
    if (routeLoading && mode == routeMode) return;

    setState(() {
      routeMode = mode;
      routeNeedsFit = true;
    });

    loadRoute();
  }

  // Google Encoded Polyline → รายการพิกัด
  static List<LatLng> decodePolyline(String encoded) {
    final List<LatLng> points = [];

    int index = 0;
    int latitude = 0;
    int longitude = 0;

    int? readValue() {
      int shift = 0;
      int result = 0;
      int byte;

      do {
        if (index >= encoded.length) return null;

        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);

      return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
    }

    while (index < encoded.length) {
      final int? deltaLat = readValue();
      final int? deltaLng = readValue();

      if (deltaLat == null || deltaLng == null) break;

      latitude += deltaLat;
      longitude += deltaLng;

      points.add(LatLng(latitude / 1e5, longitude / 1e5));
    }

    return points;
  }

  // 45 วินาที → 1 นาที / 12 นาที / 1 ชม. 5 นาที
  static String formatDuration(double seconds) {
    final int minutes = (seconds / 60).round();

    if (minutes < 1) return '1 นาที';

    if (minutes < 60) return '$minutes นาที';

    final int hours = minutes ~/ 60;

    final int rest = minutes % 60;

    return rest == 0 ? '$hours ชม.' : '$hours ชม. $rest นาที';
  }

  // =====================================================
  // ที่อยู่โดยประมาณจากพิกัด
  // =====================================================

  String addressKey(double latitude, double longitude) {
    return '${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}';
  }

  Future<void> loadAddress(Map<String, dynamic> location) async {
    final latitude = toDouble(location['latitude']);

    final longitude = toDouble(location['longitude']);

    if (latitude == null || longitude == null) return;

    final String key = addressKey(latitude, longitude);

    if (addresses.containsKey(key) || !loadingAddresses.add(key)) return;

    String? address;

    try {
      final places = await geocoder.placemarkFromCoordinates(
        latitude,
        longitude,
      );

      address = places.isEmpty ? null : formatPlacemark(places.first);
    } catch (_) {
      // ไม่มีเน็ต / เครื่องไม่รองรับ → แสดงพิกัดแทน
    } finally {
      loadingAddresses.remove(key);
    }

    if (!mounted) return;

    setState(() => addresses[key] = address);
  }

  // หาใหม่เมื่อขยับเกินระยะนี้ และห่างจากครั้งก่อนเกินเวลานี้
  static const double placeRefreshMeters = 300;
  static const Duration placeRefreshAfter = Duration(minutes: 1);

  Future<void> loadPlaceDetails(Map<String, dynamic> location) async {
    final int? userId = userIdOf(location);

    final double? latitude = toDouble(location['latitude']);

    final double? longitude = toDouble(location['longitude']);

    if (userId == null || latitude == null || longitude == null) return;

    final Map<String, dynamic>? known = placeDetails[userId];

    if (known != null) {
      final DateTime fetchedAt = known['fetched_at'] as DateTime;

      if (DateTime.now().difference(fetchedAt) < placeRefreshAfter) return;

      // หาไม่สำเร็จครั้งก่อน → ลองใหม่ได้เลย / สำเร็จ → รอให้ขยับไกลพอ
      if (known['failed'] != true) {
        final double moved = Geolocator.distanceBetween(
          latitude,
          longitude,
          known['latitude'] as double,
          known['longitude'] as double,
        );

        if (moved < placeRefreshMeters) return;
      }
    }

    if (!loadingPlaceDetails.add(userId)) return;

    Map<String, dynamic>? result;

    try {
      result = await LocationService.getMemberPlace(userId);
    } catch (_) {
      // ไม่มีเน็ต / เกินจำนวนครั้ง → แสดงเฉพาะที่อยู่จากมือถือ
    } finally {
      loadingPlaceDetails.remove(userId);
    }

    if (!mounted) return;

    final bool ok = result != null && result['status'] == true;

    final dynamic area = ok ? result['area'] : null;

    final dynamic places = ok ? result['places'] : null;

    setState(() {
      placeDetails[userId] = {
        'latitude': latitude,
        'longitude': longitude,
        'fetched_at': DateTime.now(),
        'failed': !ok,
        'area': area is Map ? Map<String, dynamic>.from(area) : null,
        'places': places is List
            ? places
                  .whereType<Map>()
                  .map((place) => Map<String, dynamic>.from(place))
                  .toList()
            : <Map<String, dynamic>>[],
      };
    });
  }

  // ถนน ตำบล อำเภอ จังหวัด (ตัดค่าซ้ำและ Plus Code)
  static String? formatPlacemark(Placemark place) {
    final List<String> parts = [];

    final RegExp plusCode = RegExp(r'^[23456789CFGHJMPQRVWX]{4,}\+');

    for (final String? value in [
      place.street,
      place.subLocality,
      place.locality,
      place.subAdministrativeArea,
      place.administrativeArea,
      place.postalCode,
    ]) {
      final String text = value?.trim() ?? '';

      if (text.isEmpty || plusCode.hasMatch(text)) continue;

      if (parts.any((part) => part.contains(text))) continue;

      parts.add(text);
    }

    return parts.isEmpty ? null : parts.join(' ');
  }

  // ส่งต่อให้ Google Maps นำทางแบบบอกทางเลี้ยว
  // ไปยังตำแหน่งล่าสุดของสมาชิก ณ ตอนที่กด
  Future<void> openDirections(Map<String, dynamic> location) async {
    final int? userId = userIdOf(location);

    // ดึงตำแหน่งล่าสุดก่อน (เขาอาจเพิ่งขยับ)
    await loadFamilyLocations();

    final Map<String, dynamic> latest =
        (userId == null ? null : locationOf(userId)) ?? location;

    final latitude = toDouble(latest['latitude']);

    final longitude = toDouble(latest['longitude']);

    if (latitude == null || longitude == null) return;

    const Map<String, String> navigationModes = {
      'drive': 'd',
      'motorcycle': 'l',
      'walk': 'w',
    };

    bool opened = false;

    // แอป Google Maps: เข้าโหมดนำทางทันที
    try {
      opened = await launchUrl(
        Uri.parse(
          'google.navigation:q=$latitude,$longitude'
          '&mode=${navigationModes[routeMode] ?? 'd'}',
        ),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }

    // ไม่มีแอป Google Maps → เปิดผ่านลิงก์ (เบราว์เซอร์)
    if (!opened) {
      try {
        opened = await launchUrl(
          Uri.https('www.google.com', '/maps/dir/', {
            'api': '1',
            'destination': '$latitude,$longitude',
            'travelmode': travelModes[routeMode]!.googleMode,
            'dir_action': 'navigate',
          }),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        opened = false;
      }
    }

    if (!opened) showMessage('เปิด Google Maps ไม่ได้');
  }

  Future<void> openChatWith(int userId) async {
    try {
      final result = await ChatService.openChat(userId);

      if (!mounted) return;

      final dynamic room = result['conversation'];

      if (result['status'] == true && room is Map && room['id'] is num) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatRoomPage(
              conversationId: (room['id'] as num).toInt(),
              user: room['user'] is Map
                  ? Map<String, dynamic>.from(room['user'])
                  : null,
            ),
          ),
        );
      } else {
        showMessage(result['message']?.toString() ?? 'เปิดแชทไม่สำเร็จ');
      }
    } catch (e) {
      showMessage(e.toString());
    }
  }

  Widget buildMemberDetailPanel() {
    final int? userId = focusedUserId;

    final Map<String, dynamic>? location = userId == null
        ? null
        : locationOf(userId);

    if (location == null) return const SizedBox.shrink();

    return NotificationListener<DraggableScrollableNotification>(
      onNotification: (notification) {
        if ((notification.extent - detailSize).abs() > 0.02) {
          setState(() => detailSize = notification.extent);
        }

        return false;
      },

      child: DraggableScrollableSheet(
        controller: detailSheet,

        initialChildSize: detailInitialSize,

        minChildSize: detailMinSize,

        maxChildSize: detailMaxSize,

        snap: true,

        snapSizes: const [detailInitialSize],

        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: AppColors.surface,

              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(27),
              ),

              boxShadow: [
                BoxShadow(
                  color: AppColors.navy.withValues(alpha: 0.14),
                  blurRadius: 28,
                  offset: const Offset(0, -8),
                ),
              ],
            ),

            child: ListView(
              controller: scrollController,

              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),

              children: [
                SizedBox(
                  height: 34,

                  child: Stack(
                    children: [
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,

                          decoration: BoxDecoration(
                            color: AppColors.border,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),

                      Positioned(
                        right: -10,
                        top: -2,

                        child: IconButton(
                          tooltip: 'ปิด',
                          onPressed: closeMember,
                          icon: Icon(
                            Icons.close_rounded,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                ...buildMemberDetails(location),
              ],
            ),
          );
        },
      ),
    );
  }

  // หมู่บ้าน/ชุมชน + สถานที่ใกล้เคียง (null = ไม่มีข้อมูล)
  Widget? buildPlaceDetails(int? userId) {
    if (userId == null) return null;

    final Map<String, dynamic>? details = placeDetails[userId];

    if (details == null) {
      if (!loadingPlaceDetails.contains(userId)) return null;

      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'กำลังหารายละเอียดสถานที่…',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
          ],
        ),
      );
    }

    final Map<String, dynamic>? area = details['area'];

    final List<Map<String, dynamic>> places = details['places'];

    String? text(String key) {
      final String value = area?[key]?.toString().trim() ?? '';

      return value.isEmpty ? null : value;
    }

    final String? community = text('community');

    final String region = [
      text('subdistrict'),
      text('district'),
      text('province'),
    ].whereType<String>().join(' · ');

    if (community == null && region.isEmpty && places.isEmpty) return null;

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (community != null || region.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.holiday_village_rounded,
                    size: 19,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        community ?? region,
                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (community != null && region.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          region,
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          if (places.isNotEmpty) ...[
            if (community != null || region.isNotEmpty)
              const SizedBox(height: 12),
            Text(
              'สถานที่ใกล้เคียง',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            for (final place in places.take(4)) buildNearbyPlace(place),
          ],
          if (area != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'ข้อมูลพื้นที่ © OpenStreetMap',
                  style: TextStyle(color: AppColors.muted, fontSize: 10.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget buildNearbyPlace(Map<String, dynamic> place) {
    final bool tourist = place['tourist'] == true;

    final double? meters = toDouble(place['distance_meters']);

    final String type = place['type']?.toString() ?? '';

    final bool here = meters != null && meters <= 50;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            tourist ? Icons.attractions_rounded : Icons.place_outlined,
            size: 17,
            color: tourist ? AppColors.warm : AppColors.muted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: place['name']?.toString() ?? '',
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (type.isNotEmpty)
                    TextSpan(
                      text: '  $type',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (meters != null) ...[
            const SizedBox(width: 8),
            Text(
              here ? 'อยู่ตรงนี้' : formatDistance(meters),
              style: TextStyle(
                color: here ? AppColors.success : AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> buildMemberDetails(Map<String, dynamic> location) {
    final String name = getMemberName(location);

    final int? userId = userIdOf(location);

    final DateTime? lastSeen = lastSeenOf(location);

    final bool stale = isStale(location);

    final double? accuracy = toDouble(location['accuracy']);

    final double? latitude = toDouble(location['latitude']);

    final double? longitude = toDouble(location['longitude']);

    final Map<String, dynamic>? current =
        route != null && route!['user_id'] == userId ? route : null;

    final ({double? meters, double? seconds})? remaining = current == null
        ? null
        : routeRemaining(current);

    final double? roadDistance = remaining?.meters;

    final double? duration = remaining?.seconds;

    final double? straight = distanceTo(location);

    final String key = latitude == null || longitude == null
        ? ''
        : addressKey(latitude, longitude);

    final String? address = addresses[key];

    final bool addressLoading = !addresses.containsKey(key);

    final String distanceText = roadDistance != null
        ? formatDistance(roadDistance)
        : routeLoading
        ? '…'
        : straight == null
        ? '—'
        : formatDistance(straight);

    final String distanceLabel = roadDistance != null
        ? 'ระยะทางตามถนน'
        : 'ระยะทางเส้นตรง';

    final String durationText = duration != null
        ? formatDuration(duration)
        : routeLoading
        ? '…'
        : '—';

    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          _MemberProfileAvatar(
            imageUrl: getProfileImageUrl(location),
            name: name,
            size: 54,
          ),

          const SizedBox(width: 13),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  name,

                  maxLines: 1,

                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),

                const SizedBox(height: 4),

                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,

                      decoration: BoxDecoration(
                        color: stale ? AppColors.warm : AppColors.success,
                        shape: BoxShape.circle,
                      ),
                    ),

                    const SizedBox(width: 6),

                    Expanded(
                      child: Text(
                        stale
                            ? 'ตำแหน่งล่าสุด ${formatLastSeen(location['last_seen_at'])}'
                            : 'อัปเดต ${formatLastSeen(location['last_seen_at'])}',

                        style: TextStyle(
                          color: stale ? AppColors.warm : AppColors.muted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 6),

                // ที่อยู่โดยประมาณ (+ ความแม่นยำ)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.place_rounded,
                        size: 15,
                        color: AppColors.danger,
                      ),
                    ),

                    const SizedBox(width: 4),

                    Expanded(
                      child: Text(
                        [
                          addressLoading
                              ? 'กำลังหาที่อยู่…'
                              : address ??
                                    (latitude == null || longitude == null
                                        ? 'ไม่ทราบที่อยู่'
                                        : '${latitude.toStringAsFixed(5)}, '
                                              '${longitude.toStringAsFixed(5)}'),
                          if (accuracy != null)
                            '(±${formatDistance(accuracy)})',
                        ].join(' '),

                        maxLines: 3,

                        overflow: TextOverflow.ellipsis,

                        style: TextStyle(
                          color: AppColors.navy,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),

      if (statusOf(location) != null) ...[
        const SizedBox(height: 14),

        buildStatusQuote(statusOf(location)!),
      ],

      ?buildPlaceDetails(userId),

      const SizedBox(height: 14),

      // โหมดเดินทาง (มีเมื่อ Server เปิดใช้การคำนวณเส้นทาง)
      if (!routesDisabled && currentPosition != null) ...[
        SegmentedButton<String>(
          showSelectedIcon: false,

          segments: [
            for (final entry in travelModes.entries)
              ButtonSegment<String>(
                value: entry.key,
                icon: Icon(entry.value.icon, size: 18),
                label: Text(
                  entry.value.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],

          selected: {routeMode},

          onSelectionChanged: (selection) => selectRouteMode(selection.first),

          style: SegmentedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),

        const SizedBox(height: 12),
      ],

      Row(
        children: [
          Expanded(
            child: _MemberInfoTile(
              icon: Icons.route_rounded,
              label: distanceLabel,
              value: distanceText,
              color: AppColors.primary,
            ),
          ),

          const SizedBox(width: 9),

          Expanded(
            child: _MemberInfoTile(
              icon: travelModes[routeMode]!.icon,
              label: 'เวลาเดินทาง',
              value: durationText,
              color: AppColors.warm,
            ),
          ),

          const SizedBox(width: 9),

          Expanded(
            child: _MemberInfoTile(
              icon: Icons.schedule_rounded,
              label: lastSeen == null
                  ? 'อัปเดตเมื่อ'
                  : formatUpdatedDay(lastSeen),
              value: lastSeen == null ? '—' : formatClock(lastSeen),
              color: AppColors.sky,
            ),
          ),
        ],
      ),

      if (currentPosition == null || routeNote != null || routesDisabled) ...[
        const SizedBox(height: 10),

        Text(
          currentPosition == null
              ? 'เปิดตำแหน่งของคุณเพื่อดูระยะทางและเส้นทาง'
              : routeNote ?? 'ระยะทางเป็นเส้นตรง กด "เริ่มนำทาง" เพื่อดูเส้นทางและเวลาจริง',

          textAlign: TextAlign.center,

          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],

      const SizedBox(height: 16),

      FilledButton.icon(
        onPressed: () => openDirections(location),

        style: FilledButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
        ),

        icon: Icon(travelModes[routeMode]!.icon),

        label: const Text('นำทางด้วย Google Maps'),
      ),

      if (stale) ...[
        const SizedBox(height: 12),

        Container(
          padding: const EdgeInsets.all(12),

          decoration: BoxDecoration(
            color: AppColors.softWarm,
            borderRadius: BorderRadius.circular(14),
          ),

          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Icon(Icons.info_outline_rounded, size: 18, color: AppColors.warm),

              const SizedBox(width: 8),

              Expanded(
                child: Text(
                  'อาจไม่ใช่ตำแหน่งปัจจุบัน มือถือของ $name '
                  'อาจปิดตำแหน่ง ไม่มีเน็ต หรือยังไม่ได้อนุญาต'
                  'ให้แชร์ตำแหน่งตลอดเวลา',

                  style: TextStyle(
                    color: AppColors.navy,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],

      const SizedBox(height: 10),

      Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: userId == null ? null : () => openChatWith(userId),
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              label: const Text('แชท'),
            ),
          ),

          const SizedBox(width: 10),

          Expanded(
            child: OutlinedButton.icon(
              onPressed: userId == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            UserProfilePage(userId: userId, name: name),
                      ),
                    ),
              icon: const Icon(Icons.person_outline_rounded),
              label: const Text('โปรไฟล์'),
            ),
          ),
        ],
      ),
    ];
  }

  // =====================================================
  // MY LOCATION
  // =====================================================

  Future<void> moveToMyLocation() async {
    if (currentPosition == null) {
      if (!locationAllowed) {
        await prepareLocation();
      }

      return;
    }

    if (mapController == null) {
      return;
    }

    final position = currentPosition!;

    await mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(position.latitude, position.longitude),
          zoom: 16,
        ),
      ),
    );
  }

  // =====================================================
  // SHOW ALL MEMBERS
  // =====================================================

  Future<void> showAllMembers() async {
    if (mapController == null) {
      return;
    }

    final List<LatLng> points = [];

    for (final location in familyLocations) {
      final latitude = toDouble(location['latitude']);

      final longitude = toDouble(location['longitude']);

      if (latitude != null && longitude != null) {
        points.add(LatLng(latitude, longitude));
      }
    }

    if (points.isEmpty) {
      showMessage('ยังไม่มีข้อมูลตำแหน่งสมาชิก');

      return;
    }

    // มีคนเดียว
    if (points.length == 1) {
      await mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: points.first, zoom: 15.5),
        ),
      );

      return;
    }

    double minLat = points.first.latitude;

    double maxLat = points.first.latitude;

    double minLng = points.first.longitude;

    double maxLng = points.first.longitude;

    for (final point in points.skip(1)) {
      if (point.latitude < minLat) {
        minLat = point.latitude;
      }

      if (point.latitude > maxLat) {
        maxLat = point.latitude;
      }

      if (point.longitude < minLng) {
        minLng = point.longitude;
      }

      if (point.longitude > maxLng) {
        maxLng = point.longitude;
      }
    }

    // ทุกคนอยู่พิกัดเดียวกัน
    if (minLat == maxLat && minLng == maxLng) {
      await mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: points.first, zoom: 15.5),
        ),
      );

      return;
    }

    try {
      await mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),

            northeast: LatLng(maxLat, maxLng),
          ),
          70,
        ),
      );
    } catch (_) {}
  }

  // =====================================================
  // SNACKBAR
  // =====================================================

  void showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // =====================================================
  // TOP FAMILY MAP CARD
  // =====================================================

  Widget buildMapHeader() {
    return Positioned(
      top: 14,
      left: 14,
      right: 14,

      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),

        decoration: BoxDecoration(
          color: AppColors.surface,

          borderRadius: BorderRadius.circular(20),

          border: AppDecorations.cardBorder,

          boxShadow: [
            BoxShadow(
              color: AppColors.navy.withValues(alpha: 0.10),
              blurRadius: 25,
              offset: const Offset(0, 8),
            ),
          ],
        ),

        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.softPrimary,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.location_on_rounded,
                color: AppColors.primary,
                size: 24,
              ),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'สมาชิกบนแผนที่ ${familyLocations.length} คน',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                  const SizedBox(height: 1),

                  Text(
                    getSyncText(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),

            IconButton(
              tooltip: 'รีเฟรช',
              onPressed: loadFamilyLocations,
              icon: Icon(Icons.refresh_rounded, color: AppColors.navy),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // LOCATION ERROR: แถบเหลือง "ยังไม่ได้เปิดสิทธิ์ตำแหน่ง" + เปิดตั้งค่า
  // =====================================================

  Widget buildLocationError() {
    final _LocationProblem? problem = locationProblem;

    if (problem == null) {
      return buildSharingNotice();
    }

    final String message = switch (problem) {
      _LocationProblem.serviceOff => 'ยังไม่ได้เปิดตำแหน่งของเครื่อง',
      _LocationProblem.failed => 'อ่านตำแหน่งของคุณไม่สำเร็จ',
      _ => 'ยังไม่ได้เปิดสิทธิ์ตำแหน่ง',
    };

    final bool dark = AppColors.isDark;

    return Positioned(
      top: 88,
      left: 14,
      right: 14,

      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),

        decoration: BoxDecoration(
          color: dark ? AppColors.softWarm : const Color(0xFFFFF8E1),

          borderRadius: BorderRadius.circular(16),

          border: Border.all(
            color: dark
                ? AppColors.warm.withValues(alpha: 0.4)
                : const Color(0xFFFFE08A),
          ),
        ),

        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: dark ? AppColors.warm : const Color(0xFFF59E0B),
              size: 22,
            ),

            const SizedBox(width: 10),

            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),

            TextButton(
              onPressed: fixLocationProblem,
              child: Text(
                problem == _LocationProblem.failed ? 'ลองใหม่' : 'เปิดตั้งค่า',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =====================================================
  // แถบแจ้งการปิดแชร์ตำแหน่ง
  // - เราปิดอยู่: มีปุ่มเปิดแชร์อีกครั้ง
  // - คนอื่นปิดอยู่: บอกชื่อ ครอบครัวจะได้รู้ว่าทำไมไม่เห็น
  // =====================================================

  Widget buildSharingNotice() {
    return ValueListenableBuilder<bool?>(
      valueListenable: SettingsService.locationSharing,
      builder: (context, sharing, child) {
        final bool selfPaused = sharing == false;

        if (!selfPaused && pausedNames.isEmpty) {
          return const SizedBox.shrink();
        }

        final String message = selfPaused
            ? 'คุณปิดการแชร์ตำแหน่งอยู่ สมาชิกในกลุ่มจะไม่เห็นตำแหน่งของคุณ'
            : 'ปิดการแชร์ตำแหน่งอยู่: ${pausedNames.join(', ')}';

        return Positioned(
          top: 88,
          left: 14,
          right: 14,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(17),
              border: AppDecorations.cardBorder,
              boxShadow: [
                BoxShadow(
                  color: AppColors.navy.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(
                  Icons.location_off_outlined,
                  color: AppColors.muted,
                  size: 21,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
                if (selfPaused)
                  TextButton(
                    onPressed: isTurningOnSharing ? null : turnOnSharing,
                    child: Text(isTurningOnSharing ? 'กำลังเปิด' : 'เปิดแชร์'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // =====================================================
  // MAP ACTION BUTTONS
  // =====================================================

  // ปุ่มด้านขวา (ซูม / ดูทุกคน / ตำแหน่งของฉัน) อยู่เหนือแผงด้านล่าง
  // → ไม่บังแถบแจ้งเตือนด้านบน
  Widget buildMapButtons({required bool detailOpen, required double height}) {
    final double bottom = (detailOpen ? height * detailSize : 155) + 12;

    // ลากแผ่นรายละเอียดขึ้นสูงมาก → ไม่มีที่วางปุ่ม
    if (bottom + 110 > height - 96) return const SizedBox.shrink();

    return Positioned(
      right: 14,
      bottom: bottom,

      child: Column(
        mainAxisSize: MainAxisSize.min,

        children: [
          _FamilyMapButton(
            icon: Icons.add_rounded,
            tooltip: 'ซูมเข้า',
            onPressed: () => zoomBy(1),
          ),

          const SizedBox(height: 8),

          _FamilyMapButton(
            icon: Icons.remove_rounded,
            tooltip: 'ซูมออก',
            onPressed: () => zoomBy(-1),
          ),

          if (!detailOpen) ...[
            const SizedBox(height: 16),

            _FamilyMapButton(
              icon: Icons.groups_rounded,
              tooltip: 'ดูสมาชิกทั้งหมด',
              onPressed: showAllMembers,
            ),

            const SizedBox(height: 10),

            _FamilyMapButton(
              icon: Icons.my_location_rounded,
              tooltip: 'ตำแหน่งของฉัน',
              primary: true,
              onPressed: moveToMyLocation,
            ),
          ],
        ],
      ),
    );
  }

  // =====================================================
  // MEMBER PANEL
  // =====================================================

  Widget buildMemberPanel() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,

      // แผงสูงคงที่ → จำกัดขนาดตัวอักษรไม่ให้ล้นการ์ด
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: Container(
          height: 150,

          decoration: BoxDecoration(
            color: AppColors.surface,

            borderRadius: const BorderRadius.vertical(top: Radius.circular(27)),

            boxShadow: [
              BoxShadow(
                color: AppColors.navy.withValues(alpha: 0.11),
                blurRadius: 28,
                offset: const Offset(0, -8),
              ),
            ],
          ),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 9),

              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Text(
                      'สมาชิกบนแผนที่',
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    const SizedBox(width: 8),

                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.softPrimary,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        '${familyLocations.length}',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: familyLocations.isEmpty
                    ? Center(
                        child: Text(
                          'ยังไม่มีตำแหน่งของสมาชิกในกลุ่ม',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        itemCount: familyLocations.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, index) =>
                            buildMemberCard(familyLocations[index]),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // การ์ดสมาชิกในแผงล่าง: รูป ชื่อ (คุณ) ข้อความบนแผนที่ "อัปเดต X ที่แล้ว" >
  Widget buildMemberCard(Map<String, dynamic> location) {
    final String name = getMemberName(location);

    final String? status = statusTextOf(location);

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => openMember(location),
        child: Ink(
          width: 214,
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _MemberProfileAvatar(
                    imageUrl: getProfileImageUrl(location),
                    name: name,
                    size: 44,
                  ),

                  // จุดสถานะ: เขียว = เพิ่งอัปเดต / ส้ม = นานแล้ว
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: isStale(location)
                            ? AppColors.warm
                            : AppColors.success,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.surface, width: 2),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(width: 10),

              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isMe(location) ? '$name (คุณ)' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.navy,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),

                    if (status != null) ...[
                      const SizedBox(height: 1),

                      Text(
                        '💬 $status',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.primary,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],

                    const SizedBox(height: 2),

                    Text(
                      memberSummary(location),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),

              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.muted,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =====================================================
  // UI
  // =====================================================

  @override
  Widget build(BuildContext context) {
    final bool detailOpen = focusedUserId != null;

    // ปุ่มย้อนกลับ: ปิดแผ่นรายละเอียดก่อน
    return PopScope(
      canPop: !detailOpen,

      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && focusedUserId != null) closeMember();
      },

      child: LayoutBuilder(
        builder: (context, constraints) => buildMapStack(
          detailOpen: detailOpen,
          height: constraints.maxHeight,
        ),
      ),
    );
  }

  Widget buildMapStack({required bool detailOpen, required double height}) {
    return Stack(
      fit: StackFit.expand,

      children: [
        // =================================================
        // GOOGLE MAP
        // =================================================

        GoogleMap(
          mapType: MapType.normal,

          // โหมดมืด: แผนที่สีเข้ม
          style: AppColors.isDark ? darkMapStyle : null,

          initialCameraPosition: const CameraPosition(
            target: defaultPosition,
            zoom: 11,
          ),

          onMapCreated: (controller) {
            mapController = controller;

            if (currentPosition != null) {
              moveToMyLocation();
            }
          },

          markers: buildMarkers(),

          polylines: buildPolylines(),

          myLocationEnabled: locationAllowed,

          myLocationButtonEnabled: false,

          zoomControlsEnabled: false,

          mapToolbarEnabled: false,

          compassEnabled: false,

          buildingsEnabled: true,

          // เว้นขอบให้จุดไม่ถูกการ์ด/แผ่นรายละเอียดบัง
          // มีแถบเตือนตำแหน่ง → เว้นด้านบนเพิ่ม หมุดจะไม่ไปอยู่ใต้แถบ
          padding: EdgeInsets.only(
            top: locationProblem == null ? 90 : 146,
            right: 56,
            bottom: detailOpen ? height * detailSize + 8 : 155,
          ),
        ),

        // =================================================
        // FAMILY ORBIT UI
        // =================================================
        buildMapHeader(),

        buildLocationError(),

        if (showBackgroundInvite && !detailOpen && locationProblem == null)
          ValueListenableBuilder<bool?>(
            valueListenable: SettingsService.locationSharing,
            builder: (context, sharing, child) => sharing == false
                ? const SizedBox.shrink()
                : buildBackgroundInvite(),
          ),

        buildMapButtons(detailOpen: detailOpen, height: height),

        if (detailOpen) buildMemberDetailPanel() else buildMemberPanel(),
      ],
    );
  }

  // =====================================================
  // DISPOSE
  // =====================================================

  @override
  void dispose() {
    refreshTimer?.cancel();

    lifecycle.dispose();

    positionSubscription?.cancel();

    locationsVersion.dispose();

    detailSheet.dispose();

    super.dispose();
  }
}

// =======================================================
// MEMBER PROFILE AVATAR
// =======================================================

class _MemberProfileAvatar extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final double size;

  const _MemberProfileAvatar({
    required this.imageUrl,
    required this.name,
    this.size = 41,
  });

  String get initial {
    final value = name.trim();

    if (value.isEmpty) {
      return '?';
    }

    return value.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final url = imageUrl?.trim();

    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      child: url == null || url.isEmpty
          ? _buildFallback()
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return _buildFallback();
              },
            ),
    );
  }

  Widget _buildFallback() {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, Color(0xFF767BFF)],
        ),
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.37,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// =======================================================
// MEMBER INFO TILE (ระยะทาง / เวลา / ความแม่นยำ)
// =======================================================

class _MemberInfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MemberInfoTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(11, 11, 8, 11),

      decoration: BoxDecoration(
        color: AppColors.fill,
        borderRadius: BorderRadius.circular(16),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Icon(icon, size: 19, color: color),

          const SizedBox(height: 8),

          Text(
            value,

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: TextStyle(
              color: AppColors.navy,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 2),

          Text(
            label,

            maxLines: 1,

            overflow: TextOverflow.ellipsis,

            style: TextStyle(color: AppColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// =======================================================
// MAP BUTTON
// =======================================================

class _FamilyMapButton extends StatelessWidget {
  final IconData icon;

  final String tooltip;

  final bool primary;

  final VoidCallback onPressed;

  const _FamilyMapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary ? AppColors.primary : AppColors.surface,

      elevation: 4,

      shadowColor: AppColors.navy.withValues(alpha: 0.16),

      borderRadius: BorderRadius.circular(16),

      child: InkWell(
        onTap: onPressed,

        borderRadius: BorderRadius.circular(16),

        child: Tooltip(
          message: tooltip,

          child: SizedBox(
            width: 48,
            height: 48,

            child: Icon(
              icon,

              color: primary ? Colors.white : AppColors.primary,

              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

// สีแผนที่สำหรับโหมดมืด (Google Maps JSON style)
const String darkMapStyle = '''
[
  {"elementType": "geometry", "stylers": [{"color": "#1d2026"}]},
  {"elementType": "labels.text.fill", "stylers": [{"color": "#98a2b3"}]},
  {"elementType": "labels.text.stroke", "stylers": [{"color": "#1d2026"}]},
  {"featureType": "poi", "elementType": "geometry", "stylers": [{"color": "#23272f"}]},
  {"featureType": "poi.park", "elementType": "geometry", "stylers": [{"color": "#1b2a22"}]},
  {"featureType": "road", "elementType": "geometry", "stylers": [{"color": "#2b3039"}]},
  {"featureType": "road", "elementType": "geometry.stroke", "stylers": [{"color": "#1d2026"}]},
  {"featureType": "road.highway", "elementType": "geometry", "stylers": [{"color": "#3a404b"}]},
  {"featureType": "transit", "elementType": "geometry", "stylers": [{"color": "#23272f"}]},
  {"featureType": "water", "elementType": "geometry", "stylers": [{"color": "#0f1a2b"}]},
  {"featureType": "water", "elementType": "labels.text.fill", "stylers": [{"color": "#5c6b80"}]}
]
''';

// ปัญหาตำแหน่งของเครื่องเรา → ข้อความและปุ่มบนแถบเตือน
enum _LocationProblem { serviceOff, denied, deniedForever, failed }
