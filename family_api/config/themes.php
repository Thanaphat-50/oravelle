<?php

// =======================================================
// ธีมและการตกแต่ง (ร้านธีม / สิทธิ์ใช้ธีม / ตรวจการซื้อ)
// รายละเอียด: docs/themes.md
// =======================================================

return [

    // ช่องทางเก็บเงินจริงของธีม
    // - none:        ยังไม่เปิดขาย (ค่าเริ่มต้น) — ดู/ลองธีมได้ ใช้ธีมฟรีได้ ซื้อไม่ได้
    // - google_play: Google Play Billing (ต้องตั้งค่า google_play ด้านล่างครบ)
    // ห้ามใช้ระบบชำระเงินของร้านค้า (พร้อมเพย์/สลิป) กับธีม — นโยบาย Google Play กำหนดให้สินค้าดิจิทัลในแอปใช้ Play Billing
    'billing' => env('THEME_BILLING', 'none'),

    // โหมดจำลองการซื้อ (ไม่เก็บเงินจริง) สำหรับทดสอบในเครื่อง/เซิร์ฟเวอร์ทดสอบ
    // เปิดบน production ไม่ได้เสมอ แม้ตั้งค่าเป็น true
    'test_purchases' => (bool) env('THEME_TEST_PURCHASES', false),

    // การซื้อแบบทดสอบของ Google (ผู้ทดสอบใบอนุญาต / บัตรทดสอบ) ให้สิทธิ์จริงหรือไม่
    // ค่าเริ่มต้น: ให้เฉพาะเครื่องที่ไม่ใช่ production — ช่วงทดสอบก่อนเปิดขายตั้ง THEME_ACCEPT_SANDBOX=true ได้
    'accept_sandbox' => env('THEME_ACCEPT_SANDBOX'),

    'google_play' => [
        'package_name' => env('GOOGLE_PLAY_PACKAGE', 'com.familyorbit.app'),

        // บัญชีบริการที่มีสิทธิ์ "ดูข้อมูลการเงิน / จัดการคำสั่งซื้อ" ใน Play Console
        // ไฟล์ JSON ทั้งไฟล์แปลงเป็น base64 (Laravel Cloud) หรือ path ของไฟล์ (ในเครื่อง)
        'service_account' => env('GOOGLE_PLAY_SERVICE_ACCOUNT_BASE64'),
        'service_account_path' => env('GOOGLE_PLAY_SERVICE_ACCOUNT_PATH'),

        // รหัสลับในลิงก์ที่ Pub/Sub ส่งการแจ้งเตือนมา (Real-time developer notifications)
        'rtdn_token' => env('GOOGLE_PLAY_RTDN_TOKEN'),
    ],

    // ลิงก์ดาวน์โหลดไฟล์ชุดธีมใช้ได้กี่นาที
    'file_link_minutes' => 30,

    // แอปใช้ธีมเสียเงินแบบออฟไลน์ได้กี่วันนับจากตรวจสิทธิ์สำเร็จครั้งล่าสุด (ส่งให้แอปใน /api/themes)
    'offline_grace_days' => 14,
];
