import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../config/api_config.dart';
import 'photo_viewer.dart';

class UserAvatar extends StatelessWidget {
  final dynamic user;
  final double radius;

  final bool showBorder;

  // ใส่ tag → รูปขยายต่อเนื่องไปหน้าดูรูปเต็มจอ (ต้องไม่ซ้ำกันในจอ)
  final Object? heroTag;

  const UserAvatar({
    super.key,
    required this.user,
    this.radius = 22,
    this.showBorder = false,
    this.heroTag,
  });

  // ลิงก์รูปโปรไฟล์ที่ใช้แสดง (ไม่มีรูป = null)
  String? get photoUrl => _photoUrl;

  static const String _serverUrl = ApiConfig.baseUrl;

  // =====================================================
  // แปลง User เป็น Map
  // =====================================================

  Map<String, dynamic> get _userData {
    if (user is Map) {
      return Map<String, dynamic>.from(user as Map);
    }

    return {};
  }

  // =====================================================
  // รองรับกรณีข้อมูลเป็น
  //
  // user = {
  //   name,
  //   profile_photo
  // }
  //
  // หรือ
  //
  // member = {
  //   role,
  //   user: {
  //     name,
  //     profile_photo
  //   }
  // }
  // =====================================================

  Map<String, dynamic> get _nestedUser {
    final nested = _userData['user'];

    if (nested is Map) {
      return Map<String, dynamic>.from(nested);
    }

    return {};
  }

  // =====================================================
  // NAME
  // =====================================================

  String get _name {
    final direct = _userData['name']?.toString().trim();

    if (direct != null && direct.isNotEmpty) {
      return direct;
    }

    final nested = _nestedUser['name']?.toString().trim();

    if (nested != null && nested.isNotEmpty) {
      return nested;
    }

    return 'สมาชิก';
  }

  // =====================================================
  // INITIAL
  // =====================================================

  String get _initial {
    final name = _name.trim();

    if (name.isEmpty) {
      return '?';
    }

    return name.substring(0, 1).toUpperCase();
  }

  // =====================================================
  // PHOTO URL
  // =====================================================

  String? get _photoUrl {
    // ---------------------------------------------
    // profile_photo_url จาก API
    // ---------------------------------------------

    dynamic value = _userData['profile_photo_url'];

    if (value == null || value.toString().trim().isEmpty) {
      value = _nestedUser['profile_photo_url'];
    }

    if (value != null) {
      final url = value.toString().trim();

      if (url.isNotEmpty) {
        // บาง API อาจส่ง localhost มา
        return url
            .replaceFirst('http://127.0.0.1:8000', _serverUrl)
            .replaceFirst('http://localhost:8000', _serverUrl);
      }
    }

    // ---------------------------------------------
    // profile_photo แบบ path
    //
    // profile_photos/abc.jpg
    // ---------------------------------------------

    value = _userData['profile_photo'];

    if (value == null || value.toString().trim().isEmpty) {
      value = _nestedUser['profile_photo'];
    }

    if (value == null) {
      return null;
    }

    final path = value.toString().trim();

    if (path.isEmpty) {
      return null;
    }

    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }

    final cleanPath = path.startsWith('/') ? path.substring(1) : path;

    return '$_serverUrl/storage/$cleanPath';
  }

  // =====================================================
  // FALLBACK
  // =====================================================

  Widget _buildFallback() {
    return Container(
      width: radius * 2,
      height: radius * 2,

      alignment: Alignment.center,

      color: AppColors.primary.withValues(alpha: 0.10),

      child: Text(
        _initial,

        style: TextStyle(
          color: AppColors.primary,

          fontSize: radius * 0.75,

          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  // =====================================================
  // AVATAR
  // =====================================================

  @override
  Widget build(BuildContext context) {
    final url = _photoUrl;

    final avatar = ClipOval(
      child: url == null
          ? _buildFallback()
          : PhotoHero(
              tag: heroTag,
              child: Image.network(
                url,

                width: radius * 2,

                height: radius * 2,

                fit: BoxFit.cover,

                errorBuilder: (context, error, stackTrace) {
                  return _buildFallback();
                },

                loadingBuilder: (context, child, progress) {
                  if (progress == null) {
                    return child;
                  }

                  return Container(
                    width: radius * 2,

                    height: radius * 2,

                    alignment: Alignment.center,

                    color: AppColors.primary.withValues(alpha: 0.06),

                    child: SizedBox(
                      width: radius * 0.65,

                      height: radius * 0.65,

                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                },
              ),
            ),
    );

    if (!showBorder) {
      return SizedBox(width: radius * 2, height: radius * 2, child: avatar);
    }

    return Container(
      width: radius * 2,
      height: radius * 2,

      padding: const EdgeInsets.all(2),

      decoration: BoxDecoration(
        shape: BoxShape.circle,

        border: Border.all(color: Colors.white, width: 2),
      ),

      child: avatar,
    );
  }
}
