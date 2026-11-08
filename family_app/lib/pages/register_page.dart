import 'package:flutter/material.dart';

import '../config/app_info.dart';
import '../services/api_helper.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/orbit_background.dart';

import 'home_page.dart';

class RegisterPage
    extends StatefulWidget {
  const RegisterPage({
    super.key,
  });

  @override
  State<RegisterPage>
      createState() =>
          _RegisterPageState();
}

class _RegisterPageState
    extends State<RegisterPage> {
  final nameController =
      TextEditingController();

  final emailController =
      TextEditingController();

  final passwordController =
      TextEditingController();

  final confirmPasswordController =
      TextEditingController();

  bool isLoading = false;

  bool obscurePassword = true;

  bool obscureConfirmPassword =
      true;

  Future<void> register() async {
    final name =
        nameController.text.trim();

    final email =
        emailController.text.trim();

    final password =
        passwordController.text;

    final confirmPassword =
        confirmPasswordController.text;

    if (name.isEmpty ||
        email.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty) {
      showMessage(
        'กรุณากรอกข้อมูลให้ครบ',
      );
      return;
    }

    if (password.length < 8) {
      showMessage(
        'รหัสผ่านต้องมีอย่างน้อย 8 ตัวอักษร',
      );
      return;
    }

    if (password !=
        confirmPassword) {
      showMessage(
        'ยืนยันรหัสผ่านไม่ตรงกัน',
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final result =
          await AuthService.register(
        name: name,
        email: email,
        password: password,
        passwordConfirmation:
            confirmPassword,
      );

      if (!mounted) return;

      final bool success =
          result['status'] == true ||
              result['token'] != null;

      if (success) {
        final dynamic user =
            result['user'];

        String userName = name;

        if (user is Map) {
          userName =
              user['name']
                      ?.toString() ??
                  name;
        }

        Navigator.of(context)
            .pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) =>
                HomePage(
              userName: userName,
            ),
          ),
          (route) => false,
        );
      } else {
        showMessage(
          getErrorMessage(
            result,
          ),
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

  String getErrorMessage(
    Map<String, dynamic> result,
  ) {
    if (result['message'] != null) {
      return result['message']
          .toString();
    }

    final errors =
        result['errors'];

    if (errors is Map &&
        errors.isNotEmpty) {
      final firstError =
          errors.values.first;

      if (firstError is List &&
          firstError.isNotEmpty) {
        return firstError.first
            .toString();
      }
    }

    return 'สมัครสมาชิกไม่สำเร็จ';
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
              15,
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
                    Align(
                      alignment:
                          Alignment
                              .centerLeft,
                      child: IconButton(
                        onPressed: () {
                          Navigator.of(
                            context,
                          ).pop();
                        },
                        icon:
                            const Icon(
                          Icons
                              .arrow_back_rounded,
                        ),
                      ),
                    ),

                    const Center(
                      child:
                          AppLogo(
                        size: 70,
                      ),
                    ),

                    const SizedBox(
                      height: 14,
                    ),

                    Text(
                      'สร้างบัญชีของคุณ',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        color:
                            AppColors.navy,
                        fontSize: 27,
                        fontWeight:
                            FontWeight.w800,
                      ),
                    ),

                    const SizedBox(
                      height: 7,
                    ),

                    Text(
                      'เริ่มต้นเชื่อมต่อกับคนสำคัญของคุณ',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        color:
                            AppColors.muted,
                        fontSize: 14,
                      ),
                    ),

                    const SizedBox(
                      height: 25,
                    ),

                    Container(
                      padding:
                          const EdgeInsets
                              .all(22),

                      decoration:
                          BoxDecoration(
                        color: AppColors.surface
                            .withValues(
                          alpha: 0.94,
                        ),

                        borderRadius:
                            BorderRadius
                                .circular(
                          28,
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
                        children: [
                          TextField(
                            controller:
                                nameController,
                            textInputAction:
                                TextInputAction
                                    .next,
                            decoration:
                                const InputDecoration(
                              labelText:
                                  'ชื่อ',
                              hintText:
                                  'ชื่อของคุณ',
                              prefixIcon:
                                  Icon(
                                Icons
                                    .person_outline_rounded,
                              ),
                            ),
                          ),

                          const SizedBox(
                            height: 14,
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
                            decoration:
                                const InputDecoration(
                              labelText:
                                  'Email',
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
                            height: 14,
                          ),

                          TextField(
                            controller:
                                passwordController,
                            obscureText:
                                obscurePassword,
                            textInputAction:
                                TextInputAction
                                    .next,
                            decoration:
                                InputDecoration(
                              labelText:
                                  'Password',
                              helperText:
                                  'อย่างน้อย 8 ตัวอักษร',
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

                          const SizedBox(
                            height: 14,
                          ),

                          TextField(
                            controller:
                                confirmPasswordController,
                            obscureText:
                                obscureConfirmPassword,
                            textInputAction:
                                TextInputAction
                                    .done,
                            onSubmitted:
                                (_) {
                              if (!isLoading) {
                                register();
                              }
                            },
                            decoration:
                                InputDecoration(
                              labelText:
                                  'ยืนยัน Password',
                              prefixIcon:
                                  const Icon(
                                Icons
                                    .verified_user_outlined,
                              ),
                              suffixIcon:
                                  IconButton(
                                onPressed:
                                    () {
                                  setState(
                                    () {
                                      obscureConfirmPassword =
                                          !obscureConfirmPassword;
                                    },
                                  );
                                },
                                icon: Icon(
                                  obscureConfirmPassword
                                      ? Icons
                                          .visibility_outlined
                                      : Icons
                                          .visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(
                            height: 22,
                          ),

                          ElevatedButton(
                            onPressed:
                                isLoading
                                    ? null
                                    : register,
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
                                    : const Text(
                                        'สร้างบัญชี',
                                      ),
                          ),

                          const SizedBox(
                            height: 12,
                          ),

                          // การสมัคร = ยอมรับข้อกำหนดและนโยบาย (กดอ่านได้)
                          Wrap(
                            alignment:
                                WrapAlignment.center,
                            crossAxisAlignment:
                                WrapCrossAlignment.center,
                            children: [
                              Text(
                                'การสร้างบัญชีถือว่าคุณยอมรับ',
                                style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                              buildPolicyLink(
                                'ข้อกำหนดการใช้งาน',
                                AppInfo.termsUrl,
                              ),
                              Text(
                                'และ',
                                style: TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                              buildPolicyLink(
                                'นโยบายความเป็นส่วนตัว',
                                AppInfo.privacyUrl,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(
                      height: 18,
                    ),

                    TextButton(
                      onPressed:
                          isLoading
                              ? null
                              : () {
                                  Navigator.of(
                                    context,
                                  ).pop();
                                },
                      child:
                          const Text(
                        'มีบัญชีอยู่แล้ว?  เข้าสู่ระบบ',
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

  Widget buildPolicyLink(String label, String url) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      onPressed: () async {
        final bool opened = await AppInfo.openUrl(url);

        if (!opened && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('เปิดหน้าเว็บไม่สำเร็จ: $url')),
          );
        }
      },
      child: Text(label),
    );
  }

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();

    super.dispose();
  }
}