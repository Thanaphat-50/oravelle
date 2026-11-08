import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config/app_info.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'pages/register_page.dart';

import 'services/api_helper.dart';
import 'services/auth_service.dart';

import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/orbit_background.dart';
import 'pages/splash_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await setUpFirebase();

  // ===============================================
  // Token หมดอายุ / ไม่ถูกต้อง (API ตอบ 401 ระหว่างใช้งาน)
  // → ลบ token แล้วไปหน้าเข้าสู่ระบบ พร้อมบอกเหตุผล
  // (เน็ตล่ม / เซิร์ฟเวอร์ผิดพลาด ไม่มาที่นี่ token ยังอยู่)
  // ===============================================

  ApiHelper.onUnauthorized = () async {
    await AuthService.clearToken();

    final navigator = navigatorKey.currentState;

    if (navigator == null) {
      return;
    }

    navigator.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) =>
            const LoginPage(notice: ApiHelper.sessionExpiredMessage),
      ),
      (route) => false,
    );
  };

  // โหมดสีที่เลือกไว้ (ตามเครื่อง / สว่าง / มืด)
  await ThemeController.load();

  runApp(const FamilyOrbitApp());
}

// =======================================================
// Firebase: แจ้งเตือนเด้ง + รายงานแอปเด้ง (Crashlytics)
// ตั้งค่าไม่สำเร็จ → แอปยังใช้งานได้ปกติ แค่ไม่มี 2 อย่างนี้
// =======================================================

Future<void> setUpFirebase() async {
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase init failed: $e');
    return;
  }

  // ส่งรายงานเฉพาะแอปจริง (release) ตอนพัฒนาไม่ส่ง
  if (kDebugMode) {
    await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(false);
    return;
  }

  await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(true);

  // Error ใน Flutter (เช่น หน้าจอวาดไม่ได้)
  FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

  // Error ที่ไม่มีใครจับ (async)
  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);

    return true;
  };
}

class FamilyOrbitApp extends StatefulWidget {
  const FamilyOrbitApp({super.key});

  @override
  State<FamilyOrbitApp> createState() => _FamilyOrbitAppState();
}

// สลับโหมดสี: ตั้งชุดสีของ AppColors ใหม่ แล้วสั่งทุกหน้าวาดใหม่
// (หน้าที่เปิดค้างอยู่ใช้สีใหม่ทันที ไม่ต้องปิดแอป)
class _FamilyOrbitAppState extends State<FamilyOrbitApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    ThemeController.mode.addListener(onThemeChanged);

    applyPalette();
  }

  // เครื่องเปลี่ยนโหมดสว่าง/มืด (ใช้เมื่อเลือก "ตามเครื่อง")
  @override
  void didChangePlatformBrightness() {
    onThemeChanged();
  }

  Brightness get effectiveBrightness {
    switch (ThemeController.mode.value) {
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.system:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  void applyPalette() {
    AppColors.palette = effectiveBrightness == Brightness.dark
        ? AppPalette.dark
        : AppPalette.light;
  }

  void onThemeChanged() {
    final AppPalette before = AppColors.palette;

    applyPalette();

    if (!mounted) return;

    setState(() {});

    if (!identical(before, AppColors.palette)) {
      void rebuild(Element element) {
        element.markNeedsBuild();
        element.visitChildren(rebuild);
      }

      (context as Element).visitChildren(rebuild);
    }
  }

  @override
  void dispose() {
    ThemeController.mode.removeListener(onThemeChanged);

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,

      debugShowCheckedModeBanner: false,

      title: AppInfo.name,

      theme: AppTheme.light(),

      darkTheme: AppTheme.dark(),

      themeMode: ThemeController.mode.value,

      home: const SplashPage(nextPage: AuthCheckPage()),

      routes: {
        '/login': (context) => const LoginPage(),

        '/register': (context) => const RegisterPage(),
      },
    );
  }
}

// =======================================================
// ตรวจ Login ตอนเปิดแอป (AuthService.checkSession)
// - ไม่มี token → หน้าเข้าสู่ระบบ
// - token ใช้ได้ → หน้าแรก
// - token หมดอายุ (401) → หน้าเข้าสู่ระบบ + บอกว่าเซสชันหมดอายุ
// - มี token แต่เน็ตล่ม / เซิร์ฟเวอร์ผิดพลาด → หน้า "ลองอีกครั้ง" (ยังไม่ออกจากระบบ)
// รอไม่เกินเวลาของ ApiHelper.timeout ไม่มีหน้ารอไม่สิ้นสุด
// =======================================================

class AuthCheckPage extends StatefulWidget {
  const AuthCheckPage({super.key});

  @override
  State<AuthCheckPage> createState() => _AuthCheckPageState();
}

class _AuthCheckPageState extends State<AuthCheckPage> {
  // null = กำลังตรวจ
  SessionCheck? session;

  bool isSigningOut = false;

  @override
  void initState() {
    super.initState();

    checkLogin();
  }

  Future<void> checkLogin() async {
    if (session != null) {
      setState(() => session = null);
    }

    final SessionCheck result = await AuthService.checkSession();

    if (!mounted) return;

    setState(() => session = result);
  }

  // ออกจากระบบตอนเชื่อมต่อไม่ได้ (ลบ token ในเครื่องทันที)
  Future<void> signOut() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ออกจากระบบ?'),
        content: const Text(
          'ต้องเข้าสู่ระบบใหม่เมื่อกลับมาใช้งาน\n'
          'ถ้าแค่เน็ตไม่ดี กด "ลองอีกครั้ง" ได้โดยไม่ต้องออกจากระบบ',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('ยกเลิก'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('ออกจากระบบ'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => isSigningOut = true);

    await AuthService.logout();

    if (!mounted) return;

    setState(() {
      isSigningOut = false;
      session = const SessionCheck(SessionState.signedOut);
    });
  }

  // หน้านี้ไม่มี AppBar → กำหนดสีไอคอนแถบสถานะเอง (ต่อจากหน้า Splash ที่เป็นพื้นเข้ม)
  Widget withStatusBar(Widget child) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.isDark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: child,
    );
  }

  Widget buildChecking() {
    return withStatusBar(
      Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppLogo(size: 72),

              const SizedBox(height: 20),

              Text(
                AppInfo.name,
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),

              const SizedBox(height: 24),

              const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildRetry(SessionCheck result) {
    final bool offline = result.state == SessionState.offline;

    // หัวข้อบอกปัญหาแล้ว → ข้อความด้านล่างบอกสิ่งที่ทำได้ (ไม่พูดซ้ำ)
    final String detail = switch (result.message) {
      ApiHelper.networkMessage =>
        'ตรวจสอบอินเทอร์เน็ตหรือ Wi-Fi แล้วลองอีกครั้ง',
      ApiHelper.serverMessage => 'กรุณาลองใหม่อีกสักครู่',
      null => 'กรุณาลองอีกครั้ง',
      final String message => message,
    };

    return withStatusBar(
      Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLogo(size: 64),

                  const SizedBox(height: 24),

                  Icon(
                    offline ? Icons.wifi_off_rounded : Icons.cloud_off_rounded,
                    size: 44,
                    color: AppColors.muted,
                  ),

                  const SizedBox(height: 12),

                  Text(
                    offline ? 'เชื่อมต่อไม่ได้' : 'ระบบขัดข้องชั่วคราว',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.navy,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),

                  const SizedBox(height: 6),

                  Text(
                    'บัญชีของคุณยังเข้าสู่ระบบอยู่',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.subtle, fontSize: 13),
                  ),

                  const SizedBox(height: 24),

                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(200, 48),
                    ),
                    onPressed: isSigningOut ? null : checkLogin,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('ลองอีกครั้ง'),
                  ),

                  const SizedBox(height: 8),

                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: isSigningOut ? null : signOut,
                    child: Text(
                      isSigningOut ? 'กำลังออกจากระบบ...' : 'ออกจากระบบ',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SessionCheck? result = session;

    if (result == null) {
      return buildChecking();
    }

    switch (result.state) {
      case SessionState.signedIn:
        return HomePage(userName: result.user?['name']?.toString() ?? 'User');
      case SessionState.signedOut:
        return const LoginPage();
      case SessionState.expired:
        return LoginPage(notice: result.message);
      case SessionState.offline:
      case SessionState.serverError:
        return buildRetry(result);
    }
  }
}
