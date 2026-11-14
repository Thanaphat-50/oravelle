<?php

use App\Services\Themes\ThemeCatalog;
use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\Log;

return new class extends Migration
{
    /**
     * โหลดแค็ตตาล็อกธีมใหม่หลังเพิ่มภาพตัวอย่าง (resources/themes/previews) — รันซ้ำได้ ไม่แตะสิทธิ์/ธุรกรรม
     */
    public function up(): void
    {
        foreach (ThemeCatalog::sync() as $error) {
            Log::warning('Theme catalog sync: ' . $error);
        }
    }

    public function down(): void
    {
        // ข้อมูลแค็ตตาล็อกเท่านั้น
    }
};
