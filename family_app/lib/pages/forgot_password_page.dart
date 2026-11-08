import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_helper.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

// =======================================================
// ลืมรหัสผ่าน
// 1) กรอกอีเมล → เซิร์ฟเวอร์ส่งรหัส 6 หลักทางอีเมล (ถ้ามีบัญชี)
// 2) กรอกรหัส + รหัสผ่านใหม่ → ตั้งรหัสผ่านใหม่ → กลับหน้าเข้าสู่ระบบ (pop(อีเมล))
// - บันทึกไม่สำเร็จ: ข้อมูลที่กรอกยังอยู่ แก้แล้วกดใหม่ได้
// - ขอรหัสใหม่ได้หลังนับถอยหลัง (ตามที่เซิร์ฟเวอร์บอก)
// =======================================================

class ForgotPasswordPage extends StatefulWidget {
  // อีเมลที่กรอกไว้ในหน้าเข้าสู่ระบบ
  final String? email;

  const ForgotPasswordPage({super.key, this.email});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  late final TextEditingController emailController = TextEditingController(
    text: widget.email ?? '',
  );
  final TextEditingController codeController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmController = TextEditingController();

  // false = ขั้นกรอกอีเมล / true = ขั้นกรอกรหัสและรหัสผ่านใหม่
  bool codeSent = false;

  bool isBusy = false;
  bool obscurePassword = true;

  // ข้อความจากเซิร์ฟเวอร์หลังขอรหัส
  String? sentMessage;

  // ข้อผิดพลาดล่าสุด (แสดงใต้ฟอร์ม)
  String? error;

  int resendIn = 0;
  Timer? resendTimer;

  static final RegExp emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  Future<void> requestCode() async {
    final String email = emailController.text.trim();

    if (!emailPattern.hasMatch(email)) {
      setState(() => error = 'กรุณาใส่อีเมลให้ถูกต้อง');
      return;
    }

    setState(() {
      isBusy = true;
      error = null;
    });

    try {
      final result = await AuthService.requestPasswordCode(email);

      if (!mounted) return;

      if (result['status'] == true) {
        setState(() {
          codeSent = true;
          sentMessage = result['message']?.toString();
        });

        startCooldown((result['resend_seconds'] as num?)?.toInt() ?? 60);
      } else {
        setState(() {
          error = result['message']?.toString() ?? 'ส่งรหัสไม่สำเร็จ';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isBusy = false);
    }
  }

  void startCooldown(int seconds) {
    resendTimer?.cancel();

    setState(() => resendIn = seconds);

    resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || resendIn <= 1) {
        timer.cancel();
        if (mounted) setState(() => resendIn = 0);
        return;
      }

      setState(() => resendIn--);
    });
  }

  Future<void> resetPassword() async {
    final String code = codeController.text.trim();
    final String password = passwordController.text;

    String? problem;

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      problem = 'กรุณาใส่รหัส 6 หลักจากอีเมล';
    } else if (password.length < 8) {
      problem = 'รหัสผ่านต้องมีอย่างน้อย 8 ตัวอักษร';
    } else if (password != confirmController.text) {
      problem = 'ยืนยันรหัสผ่านไม่ตรงกัน';
    }

    if (problem != null) {
      setState(() => error = problem);
      return;
    }

    setState(() {
      isBusy = true;
      error = null;
    });

    try {
      final result = await AuthService.resetPassword(
        email: emailController.text.trim(),
        code: code,
        password: password,
        passwordConfirmation: confirmController.text,
      );

      if (!mounted) return;

      if (result['status'] == true) {
        Navigator.of(context).pop(emailController.text.trim());
        return;
      }

      // ไม่สำเร็จ: เก็บข้อมูลที่กรอกไว้ให้แก้แล้วลองใหม่
      setState(() {
        error = result['message']?.toString() ?? 'ตั้งรหัสผ่านไม่สำเร็จ';
      });
    } catch (e) {
      if (mounted) setState(() => error = ApiHelper.messageOf(e));
    } finally {
      if (mounted) setState(() => isBusy = false);
    }
  }

  // =====================================================
  // UI
  // =====================================================

  Widget buildError() {
    final String? message = error;

    if (message == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: AppColors.danger,
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildButton(String label, VoidCallback onPressed) {
    return FilledButton(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
      onPressed: isBusy ? null : onPressed,
      child: isBusy
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Colors.white,
              ),
            )
          : Text(label),
    );
  }

  List<Widget> buildEmailStep() {
    return [
      Text(
        'กรอกอีเมลของบัญชี เราจะส่งรหัส 6 หลักไปให้ เพื่อใช้ตั้งรหัสผ่านใหม่',
        style: TextStyle(color: AppColors.muted, fontSize: 14, height: 1.5),
      ),
      const SizedBox(height: 18),
      TextField(
        controller: emailController,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.email],
        onSubmitted: (_) => requestCode(),
        decoration: const InputDecoration(
          labelText: 'อีเมล',
          hintText: 'example@email.com',
          prefixIcon: Icon(Icons.alternate_email_rounded),
        ),
      ),
      buildError(),
      const SizedBox(height: 20),
      buildButton('ส่งรหัสไปที่อีเมล', requestCode),
    ];
  }

  List<Widget> buildCodeStep() {
    return [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.mark_email_read_outlined, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                sentMessage ?? 'ถ้าอีเมลนี้มีบัญชี เราส่งรหัส 6 หลักไปให้แล้ว กรุณาตรวจกล่องจดหมาย',
                style: TextStyle(
                  color: AppColors.navy,
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: Text(
              emailController.text.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: isBusy
                ? null
                : () => setState(() {
                    codeSent = false;
                    error = null;
                  }),
            child: const Text('เปลี่ยนอีเมล'),
          ),
        ],
      ),
      TextField(
        controller: codeController,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        maxLength: 6,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        autofillHints: const [AutofillHints.oneTimeCode],
        decoration: const InputDecoration(
          labelText: 'รหัส 6 หลักจากอีเมล',
          counterText: '',
          prefixIcon: Icon(Icons.pin_outlined),
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: passwordController,
        obscureText: obscurePassword,
        textInputAction: TextInputAction.next,
        autofillHints: const [AutofillHints.newPassword],
        decoration: InputDecoration(
          labelText: 'รหัสผ่านใหม่',
          helperText: 'อย่างน้อย 8 ตัวอักษร',
          prefixIcon: const Icon(Icons.lock_outline_rounded),
          suffixIcon: IconButton(
            tooltip: obscurePassword ? 'แสดงรหัสผ่าน' : 'ซ่อนรหัสผ่าน',
            onPressed: () => setState(() => obscurePassword = !obscurePassword),
            icon: Icon(
              obscurePassword
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
          ),
        ),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: confirmController,
        obscureText: obscurePassword,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => resetPassword(),
        decoration: const InputDecoration(
          labelText: 'ยืนยันรหัสผ่านใหม่',
          prefixIcon: Icon(Icons.verified_user_outlined),
        ),
      ),
      buildError(),
      const SizedBox(height: 20),
      buildButton('ตั้งรหัสผ่านใหม่', resetPassword),
      const SizedBox(height: 6),
      Center(
        child: TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: isBusy || resendIn > 0 ? null : requestCode,
          child: Text(
            resendIn > 0
                ? 'ขอรหัสใหม่ได้ใน $resendIn วินาที'
                : 'ไม่ได้รับรหัส? ส่งรหัสอีกครั้ง',
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ลืมรหัสผ่าน')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: codeSent ? buildCodeStep() : buildEmailStep(),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    resendTimer?.cancel();
    emailController.dispose();
    codeController.dispose();
    passwordController.dispose();
    confirmController.dispose();
    super.dispose();
  }
}
