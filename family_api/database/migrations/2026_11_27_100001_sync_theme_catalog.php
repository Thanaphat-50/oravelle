<?php

use App\Services\Themes\ThemeCatalog;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\Log;

return new class extends Migration
{
    /**
     * ใส่แค็ตตาล็อกธีมเริ่มต้น (Lavender ฟรี + Ocean Blue / Matcha Garden / Cosmic Orbit) จาก resources/themes
     * รันซ้ำได้ (updateOrCreate) ไม่แตะสิทธิ์/ธุรกรรม — เพิ่มธีม/เวอร์ชันใหม่ภายหลัง: เพิ่มไฟล์ + migration ที่เรียก sync อีกครั้ง
     * ชุดไฟล์ไหนตรวจไม่ผ่าน → ข้ามเวอร์ชันนั้น (บันทึก log) ไม่ทำให้ deploy ล้ม
     */
    public function up(): void
    {
        foreach (ThemeCatalog::sync() as $error) {
            Log::warning('Theme catalog sync: ' . $error);
        }
    }

    public function down(): void
    {
        // ข้อมูลแค็ตตาล็อก ลบพร้อมตารางใน migration ก่อนหน้า
    }
};
