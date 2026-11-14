import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'app_log.dart';
import 'theme_service.dart';

// =======================================================
// Google Play Billing ฝั่งแอป (ธีม = สินค้าซื้อครั้งเดียว ไม่ใช้หมด)
//
// - ใช้เมื่อเซิร์ฟเวอร์บอกว่าเปิดขายผ่าน google_play เท่านั้น
// - ราคา/สกุลเงินที่แสดงมาจาก Google Play (ProductDetails) = ราคาที่เรียกเก็บจริง
// - ผูกบัญชีตอนซื้อ: applicationUserName = account_ref จากเซิร์ฟเวอร์ (obfuscatedAccountId)
// - ได้หลักฐานแล้วส่งให้เซิร์ฟเวอร์ตรวจกับ Google ก่อนเสมอ แอปไม่ปลดล็อกเอง
// - ซื้อค้าง (แอปปิดก่อนแจ้งเซิร์ฟเวอร์) → purchaseStream ส่งมาอีกตอนเปิดแอป / กดกู้คืนการซื้อ
// ⚠️ ยังไม่ได้ทดสอบกับ Google Play จริง (ต้องมีบัญชี Play Console + แอปในแทร็กทดสอบ)
// =======================================================

class ThemePlayBilling {
  static StreamSubscription<List<PurchaseDetails>>? _subscription;

  static final Map<String, ProductDetails> _products = {};

  // ผลล่าสุดให้หน้าร้านธีมแสดง (snackbar)
  static final ValueNotifier<String?> message = ValueNotifier(null);

  static bool get started => _subscription != null;

  static void start() {
    if (_subscription != null) return;

    _subscription = InAppPurchase.instance.purchaseStream.listen(
      _onPurchases,
      onError: (Object error) =>
          AppLog.warn('Play purchase stream error', error),
    );
  }

  static Future<void> stop() async {
    await _subscription?.cancel();

    _subscription = null;
    _products.clear();
  }

  static Future<bool> available() async {
    try {
      return await InAppPurchase.instance.isAvailable();
    } catch (_) {
      return false;
    }
  }

  // ราคาจริงจาก Google Play ของสินค้าที่ขอ
  static Future<Map<String, ProductDetails>> loadProducts(
    Iterable<String> ids,
  ) async {
    if (ids.isEmpty) return const {};

    final ProductDetailsResponse response = await InAppPurchase.instance
        .queryProductDetails(ids.toSet());

    for (final ProductDetails product in response.productDetails) {
      _products[product.id] = product;
    }

    return Map.unmodifiable(_products);
  }

  static ProductDetails? product(String? id) =>
      id == null ? null : _products[id];

  static Future<void> buy(String productId, String accountRef) async {
    final ProductDetails? product = _products[productId];

    if (product == null) {
      throw const ThemeException(
        'ยังโหลดราคาจาก Google Play ไม่ได้ ลองใหม่อีกครั้ง',
      );
    }

    start();

    final bool launched = await InAppPurchase.instance.buyNonConsumable(
      purchaseParam: PurchaseParam(
        productDetails: product,
        applicationUserName: accountRef,
      ),
    );

    if (!launched) {
      throw const ThemeException('เปิดหน้าชำระเงินของ Google Play ไม่ได้');
    }
  }

  // กู้คืนการซื้อ: Google Play ส่งการซื้อเดิมกลับมาทาง purchaseStream (สถานะ restored)
  static Future<void> restore() async {
    start();

    await InAppPurchase.instance.restorePurchases();
  }

  static Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    final List<PurchaseDetails> toVerify = [];

    for (final PurchaseDetails purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          message.value = 'รอการชำระเงิน เมื่อชำระสำเร็จธีมจะปลดล็อกเอง';
        case PurchaseStatus.canceled:
          message.value = 'ยกเลิกการซื้อแล้ว ไม่มีการเรียกเก็บเงิน';
        case PurchaseStatus.error:
          message.value = 'ซื้อไม่สำเร็จ กรุณาลองใหม่';
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          toVerify.add(purchase);
      }
    }

    if (toVerify.isEmpty) return;

    try {
      // เซิร์ฟเวอร์ตรวจกับ Google + ให้สิทธิ์ + acknowledge (ส่งซ้ำได้ ไม่สร้างสิทธิ์ซ้ำ)
      await ThemeService.restore([
        for (final PurchaseDetails purchase in toVerify)
          {
            'provider': 'google_play',
            'product_id': purchase.productID,
            'purchase_token': purchase.verificationData.serverVerificationData,
          },
      ]);

      for (final PurchaseDetails purchase in toVerify) {
        final ThemeListing? theme = ThemeService.catalog.value?.byProduct(
          purchase.productID,
        );

        // จบธุรกรรมฝั่งแอปด้วย (เซิร์ฟเวอร์ acknowledge แล้วก็ไม่เป็นไร)
        if (theme != null && theme.owned && purchase.pendingCompletePurchase) {
          await InAppPurchase.instance.completePurchase(purchase);
        }
      }

      message.value = 'อัปเดตธีมที่ซื้อแล้ว';
    } catch (e) {
      // ไม่สำเร็จ → ไม่ completePurchase เปิดแอปครั้งหน้า Google Play ส่งมาให้ตรวจใหม่ (ไม่ต้องซื้อซ้ำ)
      AppLog.warn('Theme purchase verify failed', e);

      message.value =
          'ตรวจการซื้อไม่สำเร็จ ระบบจะลองใหม่เมื่อเปิดแอปครั้งถัดไป';
    }
  }
}
