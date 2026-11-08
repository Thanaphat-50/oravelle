import 'package:flutter/material.dart';

import '../config/app_info.dart';
import '../services/api_helper.dart';
import '../services/auth_service.dart';
import '../services/social_auth_service.dart';
import '../widgets/social_login_buttons.dart';
import '../theme/app_theme.dart';
import '../widgets/orbit_background.dart';

import 'forgot_password_page.dart';
import 'home_page.dart';
import 'register_page.dart';

class LoginPage
    extends StatefulWidget {
  // ข้อความแจ้งตอนเปิดหน้า เช่น "เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่"
  final String? notice;

  const LoginPage({
    super.key,
    this.notice,
  });

  @override
  State<LoginPage> createState() =>
      _LoginPageState();
}

class _LoginPageState
    extends State<LoginPage> {
  final emailController =
      TextEditingController();

  final passwordController =
      TextEditingController();

  final passwordFocus = FocusNode();

  bool isLoading = false;
  bool obscurePassword = true;

  @override
  void initState() {
    super.initState();

    final String? notice = widget.notice;

    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showMessage(notice);
      });
    }
  }

  // กำลังเข้าสู่ระบบด้วย Google / LINE / Facebook
  SocialProvider? socialBusy;

  // LINE / Facebook ที่เจออีเมลซ้ำ → เข้าสู่ระบบด้วยวิธีเดิมแล้วถามว่าจะเชื่อมไหม
  SocialProvider? pendingLink;

  Future<void> loginWith(SocialProvider provider) async {
    setState(() => socialBusy = provider);

    SocialProvider? next;

    try {
      final result = await SocialAuthService.signIn(provider);

      if (!mounted) return;

      if (result['token'] != null) {
        await finishSignIn(result['user'], signedInWith: provider);
      } else if (result['code'] == 'email_in_use') {
        next = await askOriginalSignIn(provider, result);
      } else {
        showMessage(
          result['message']?.toString() ??
              'เข้าสู่ระบบด้วย ${provider.label} ไม่สำเร็จ',
        );
      }
    } on SocialLoginCanceled {
      // ผู้ใช้ปิดหน้าล็อกอินเอง
    } catch (e) {
      if (mounted) showMessage(ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => socialBusy = null);
    }

    // เลือกเข้าด้วยบัญชีโซเชียลที่เชื่อมไว้เดิม
    if (next != null && mounted) await loginWith(next);
  }

  // อีเมลนี้มีบัญชีอยู่แล้ว → อธิบาย แล้วพาไปเข้าสู่ระบบด้วยวิธีเดิม
  // คืนค่าเจ้าที่จะเข้าต่อ (null = กรอกรหัสผ่าน หรือปิดหน้าต่าง)
  Future<SocialProvider?> askOriginalSignIn(
    SocialProvider provider,
    Map<String, dynamic> result,
  ) async {
    final String email = result['email']?.toString() ?? '';

    final dynamic signInWith = result['sign_in_with'];

    final bool usesPassword =
        signInWith is! Map || signInWith['password'] == true;

    final dynamic linkedKeys = signInWith is Map ? signInWith['providers'] : null;

    final List<SocialProvider> linked = linkedKeys is List
        ? SocialProvider.values
            .where((p) => p != provider && linkedKeys.contains(p.key))
            .toList()
        : [];

    final List<String> ways = [
      if (usesPassword) 'อีเมลและรหัสผ่าน',
      for (final p in linked) p.label,
    ];

    final String? choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.manage_accounts_outlined,
          color: AppColors.primary,
          size: 36,
        ),
        title: const Text('มีบัญชีที่ใช้อีเมลนี้อยู่แล้ว'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${email.isEmpty ? 'อีเมลจาก ${provider.label}' : email} '
                'สมัครไว้แล้ว'
                '${ways.isEmpty ? '' : 'ด้วย${ways.join(' หรือ ')}'}\n\n'
                'เพื่อความปลอดภัย กรุณาเข้าสู่ระบบด้วยวิธีเดิมก่อน '
                'แล้วกดเชื่อม ${provider.label} '
                'ครั้งหน้าจะเข้าด้วย ${provider.label} ได้เลย',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 18),
              for (final p in linked) ...[
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(p.key),
                  child: Text('เข้าสู่ระบบด้วย ${p.label}'),
                ),
                const SizedBox(height: 8),
              ],
              if (usesPassword)
                FilledButton.tonal(
                  onPressed: () =>
                      Navigator.of(dialogContext).pop('password'),
                  child: const Text('เข้าสู่ระบบด้วยอีเมลและรหัสผ่าน'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('ปิด'),
          ),
        ],
      ),
    );

    if (choice == null || !mounted) return null;

    pendingLink = provider;

    if (choice == 'password') {
      if (email.isNotEmpty) emailController.text = email;

      passwordController.clear();
      passwordFocus.requestFocus();

      showMessage('กรอกรหัสผ่านของบัญชีนี้ แล้วกด "เข้าสู่ระบบ"');

      return null;
    }

    return SocialProvider.values.firstWhere((p) => p.key == choice);
  }

  // เข้าสู่ระบบสำเร็จ → ถ้าเพิ่งเจออีเมลซ้ำจาก LINE / Facebook
  // ถามว่าจะเชื่อมกับบัญชีนี้เลยไหม แล้วค่อยเข้าหน้าแรก
  Future<void> finishSignIn(
    dynamic user, {
    SocialProvider? signedInWith,
  }) async {
    final SocialProvider? provider = pendingLink;

    pendingLink = null;

    if (provider != null && provider != signedInWith && mounted) {
      final bool? link = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('เชื่อม ${provider.label} กับบัญชีนี้?'),
          content: Text(
            'ครั้งหน้ากดปุ่ม ${provider.label} '
            'แล้วเข้าบัญชีนี้ได้เลย ไม่ต้องใช้รหัสผ่าน',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('ไม่ใช่ตอนนี้'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('เชื่อม ${provider.label}'),
            ),
          ],
        ),
      );

      if (link == true && mounted) {
        String message;

        try {
          final result = await SocialAuthService.link(provider);

          message = result['message']?.toString() ??
              (result['status'] == true
                  ? 'เชื่อม ${provider.label} แล้ว'
                  : 'เชื่อม ${provider.label} ไม่สำเร็จ');
        } on SocialLoginCanceled {
          message = 'ยังไม่ได้เชื่อม ${provider.label} '
              'เชื่อมภายหลังได้ที่ ตั้งค่า → บัญชีที่เชื่อมต่อ';
        } catch (e) {
          message = ApiHelper.messageOf(e);
        }

        if (mounted) showMessage(message);
      }
    }

    if (mounted) openHome(user);
  }

  void openHome(dynamic user) {
    final String userName = user is Map
        ? (user['name']?.toString() ?? 'User')
        : 'User';

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => HomePage(userName: userName)),
      (route) => false,
    );
  }

  // ตั้งรหัสผ่านใหม่สำเร็จ → กลับมาพร้อมอีเมล ให้กรอกรหัสผ่านใหม่
  Future<void> openForgotPassword() async {
    final String? email = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ForgotPasswordPage(
          email: emailController.text.trim(),
        ),
      ),
    );

    if (email == null || !mounted) return;

    emailController.text = email;
    passwordController.clear();
    passwordFocus.requestFocus();

    showMessage('ตั้งรหัสผ่านใหม่แล้ว เข้าสู่ระบบด้วยรหัสผ่านใหม่ได้เลย');
  }

  Future<void> login() async {
    final email =
        emailController.text.trim();

    final password =
        passwordController.text;

    if (email.isEmpty ||
        password.isEmpty) {
      showMessage(
        'กรุณากรอกอีเมลและรหัสผ่าน',
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final result =
          await AuthService.login(
        email: email,
        password: password,
      );

      if (!mounted) return;

      final bool success =
          result['status'] == true ||
              result['token'] != null;

      if (success) {
        await finishSignIn(result['user']);
      } else {
        showMessage(
          result['message']?.toString() ??
              'อีเมลหรือรหัสผ่านไม่ถูกต้อง',
        );
      }
    } catch (e) {
      // เน็ตล่ม / หมดเวลารอ / เซิร์ฟเวอร์ผิดพลาด → ข้อความภาษาไทยจาก ApiHelper
      if (!mounted) return;

      showMessage(ApiHelper.messageOf(e));
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void showMessage(
    String message,
  ) {
    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content:
            Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          Colors.transparent,

      body: OrbitBackground(
        child: SafeArea(
          child:
              SingleChildScrollView(
            padding:
                const EdgeInsets
                    .fromLTRB(
              24,
              30,
              24,
              30,
            ),

            child: Center(
              child:
                  ConstrainedBox(
                constraints:
                    const BoxConstraints(
                  maxWidth: 480,
                ),

                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment
                          .stretch,
                  children: [
                    const SizedBox(
                      height: 15,
                    ),

                    // ===================================
                    // Brand
                    // ===================================

                    const Center(
                      child:
                          AppLogo(),
                    ),

                    const SizedBox(
                      height: 22,
                    ),

                    Text(
                      AppInfo.name,
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        color:
                            AppColors.navy,
                        fontSize: 18,
                        fontWeight:
                            FontWeight.w800,
                      ),
                    ),

                    const SizedBox(
                      height: 14,
                    ),

                    Text(
                      'อยู่ใกล้กัน\nไม่ว่าจะอยู่ที่ไหน',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        color:
                            AppColors.navy,
                        fontSize: 30,
                        height: 1.18,
                        fontWeight:
                            FontWeight.w800,
                      ),
                    ),

                    const SizedBox(
                      height: 12,
                    ),

                    Text(
                      'เชื่อมต่อ พูดคุย แชร์กิจกรรม\nและดูแลสมาชิกในกลุ่มได้ในที่เดียว',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        color:
                            AppColors.muted,
                        fontSize: 14,
                        height: 1.55,
                      ),
                    ),

                    const SizedBox(
                      height: 32,
                    ),

                    // ===================================
                    // Login Card
                    // ===================================

                    Container(
                      padding:
                          const EdgeInsets
                              .all(22),

                      decoration:
                          BoxDecoration(
                        color: AppColors.surface
                            .withValues(
                          alpha: 0.92,
                        ),

                        borderRadius:
                            BorderRadius
                                .circular(
                          28,
                        ),

                        border:
                            Border.all(
                          color:
                              AppColors.surface,
                        ),

                        boxShadow: [
                          BoxShadow(
                            color:
                                AppColors
                                    .navy
                                    .withValues(
                              alpha:
                                  0.06,
                            ),
                            blurRadius:
                                35,
                            offset:
                                const Offset(
                              0,
                              14,
                            ),
                          ),
                        ],
                      ),

                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment
                                .stretch,
                        children: [
                          Text(
                            'ยินดีต้อนรับกลับมา',
                            style:
                                TextStyle(
                              color:
                                  AppColors
                                      .navy,
                              fontSize:
                                  20,
                              fontWeight:
                                  FontWeight
                                      .w800,
                            ),
                          ),

                          const SizedBox(
                            height: 5,
                          ),

                          Text(
                            'เข้าสู่บัญชี ${AppInfo.name} ของคุณ',
                            style:
                                TextStyle(
                              color:
                                  AppColors
                                      .muted,
                              fontSize:
                                  13,
                            ),
                          ),

                          const SizedBox(
                            height: 24,
                          ),

                          TextField(
                            controller:
                                emailController,
                            keyboardType:
                                TextInputType
                                    .emailAddress,
                            textInputAction:
                                TextInputAction
                                    .next,
                            autofillHints:
                                const [
                              AutofillHints
                                  .email,
                            ],
                            decoration:
                                const InputDecoration(
                              labelText:
                                  'อีเมล',
                              hintText:
                                  'example@email.com',
                              prefixIcon:
                                  Icon(
                                Icons
                                    .alternate_email_rounded,
                              ),
                            ),
                          ),

                          const SizedBox(
                            height: 15,
                          ),

                          TextField(
                            controller:
                                passwordController,
                            focusNode:
                                passwordFocus,
                            obscureText:
                                obscurePassword,
                            textInputAction:
                                TextInputAction
                                    .done,
                            autofillHints:
                                const [
                              AutofillHints
                                  .password,
                            ],
                            onSubmitted:
                                (_) {
                              if (!isLoading) {
                                login();
                              }
                            },
                            decoration:
                                InputDecoration(
                              labelText:
                                  'รหัสผ่าน',
                              prefixIcon:
                                  const Icon(
                                Icons
                                    .lock_outline_rounded,
                              ),
                              suffixIcon:
                                  IconButton(
                                onPressed:
                                    () {
                                  setState(
                                    () {
                                      obscurePassword =
                                          !obscurePassword;
                                    },
                                  );
                                },
                                icon: Icon(
                                  obscurePassword
                                      ? Icons
                                          .visibility_outlined
                                      : Icons
                                          .visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),

                          // ลืมรหัสผ่าน → ขอรหัส 6 หลักทางอีเมล
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 44),
                              ),
                              onPressed: isLoading ? null : openForgotPassword,
                              child: const Text('ลืมรหัสผ่าน?'),
                            ),
                          ),

                          const SizedBox(
                            height: 6,
                          ),

                          ElevatedButton(
                            onPressed:
                                isLoading
                                    ? null
                                    : login,
                            child:
                                isLoading
                                    ? const SizedBox(
                                        width:
                                            23,
                                        height:
                                            23,
                                        child:
                                            CircularProgressIndicator(
                                          strokeWidth:
                                              2.4,
                                          color:
                                              Colors.white,
                                        ),
                                      )
                                    : const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            'เข้าสู่ระบบ',
                                          ),
                                          SizedBox(
                                            width:
                                                8,
                                          ),
                                          Icon(
                                            Icons
                                                .arrow_forward_rounded,
                                            size:
                                                19,
                                          ),
                                        ],
                                      ),
                          ),

                          const SizedBox(
                            height: 20,
                          ),

                          Row(
                            children: [
                              const Expanded(
                                child:
                                    Divider(),
                              ),

                              Padding(
                                padding:
                                    const EdgeInsets
                                        .symmetric(
                                  horizontal:
                                      12,
                                ),
                                child: Text(
                                  'หรือ',
                                  style:
                                      TextStyle(
                                    color:
                                        Colors
                                            .grey
                                            .shade500,
                                  ),
                                ),
                              ),

                              const Expanded(
                                child:
                                    Divider(),
                              ),
                            ],
                          ),

                          const SizedBox(
                            height: 16,
                          ),

                          // Google / LINE / Facebook (เฉพาะเจ้าที่เปิดใช้)
                          SocialLoginButtons(
                            busy: socialBusy,
                            enabled: !isLoading,
                            onPressed: loginWith,
                          ),

                          OutlinedButton(
                            onPressed:
                                isLoading || socialBusy != null
                                    ? null
                                    : () {
                                        Navigator.of(
                                          context,
                                        ).push(
                                          MaterialPageRoute(
                                            builder:
                                                (_) =>
                                                    const RegisterPage(),
                                          ),
                                        );
                                      },
                            child:
                                const Text(
                              'สร้างบัญชีใหม่',
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(
                      height: 24,
                    ),

                    Text(
                      'Your people. Your circle.',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        color:
                            AppColors.muted,
                        fontSize: 12,
                        letterSpacing:
                            0.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    passwordFocus.dispose();

    super.dispose();
  }
}