import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

// ส่วนประกอบที่ใช้ร่วมกันในศูนย์ช่วยเหลือ

Color supportStatusColor(String? status) {
  switch (status) {
    case 'submitted':
      return AppColors.primary;
    case 'in_review':
      return AppColors.sky;
    case 'waiting_user':
      return const Color(0xFFF79009);
    case 'closed':
      return AppColors.success;
    default:
      return AppColors.muted;
  }
}

class SupportStatusBadge extends StatelessWidget {
  final String? status;
  final String label;

  const SupportStatusBadge({
    super.key,
    required this.status,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = supportStatusColor(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// กล่องข้อความแจ้ง (ข้อมูลส่วนตัว / ข้อจำกัด)
class SupportNote extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const SupportNote({
    super.key,
    required this.icon,
    required this.text,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final Color tint = color ?? AppColors.primary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: tint, size: 19),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.navy,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
