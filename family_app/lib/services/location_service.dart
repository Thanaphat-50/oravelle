import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_helper.dart';
import 'auth_service.dart';
import '../config/api_config.dart';

class LocationService {
  static const String baseUrl = ApiConfig.baseUrl;

  static Future<Map<String, dynamic>> updateLocation({
    required double latitude,
    required double longitude,
    double? accuracy,
  }) async {
    final token = await AuthService.getToken();

    final response = await ApiHelper.request(
      () => http.post(
        Uri.parse('$baseUrl/location'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'latitude': latitude,
          'longitude': longitude,
          'accuracy': accuracy,
        }),
      ),
    );

    return ApiHelper.decode(response);
  }

  // เส้นทางตามถนนจากเราไปหาสมาชิก
  // mode: drive / motorcycle / walk
  // ตอบ distance_meters, duration_seconds, polyline
  // code routes_disabled = Server ยังไม่ตั้งค่า → แอปใช้ระยะเส้นตรงแทน
  static Future<Map<String, dynamic>> getRoute({
    required int userId,
    required double fromLat,
    required double fromLng,
    String mode = 'drive',
  }) async {
    final token = await AuthService.getToken();

    final Uri uri = Uri.parse('$baseUrl/family/members/$userId/route').replace(
      queryParameters: {
        'from_lat': fromLat.toStringAsFixed(6),
        'from_lng': fromLng.toStringAsFixed(6),
        'mode': mode,
      },
    );

    final response = await ApiHelper.request(
      () => http.get(
        uri,
        headers: {
          'Accept': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
      ),
    );

    return ApiHelper.decode(response);
  }

  // รายละเอียดตำแหน่งสมาชิก
  // area:   หมู่บ้าน/ชุมชน ตำบล อำเภอ จังหวัด (OpenStreetMap)
  // places: สถานที่ใกล้เคียง (null = Server ยังไม่เปิด Google Places)
  static Future<Map<String, dynamic>> getMemberPlace(int userId) async {
    final token = await AuthService.getToken();

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/family/members/$userId/place'),
        headers: {
          'Accept': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
      ),
    );

    return ApiHelper.decode(response);
  }

  static Future<Map<String, dynamic>> getFamilyLocations() async {
    final token = await AuthService.getToken();

    final response = await ApiHelper.request(
      () => http.get(
        Uri.parse('$baseUrl/family/locations'),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ),
    );

    return ApiHelper.decode(response);
  }
}
