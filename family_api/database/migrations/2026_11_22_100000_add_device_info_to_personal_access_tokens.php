<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * อุปกรณ์ที่เข้าสู่ระบบ (หน้า ตั้งค่า → บัญชี → อุปกรณ์ที่เข้าสู่ระบบ)
     *
     * ข้อมูลอุปกรณ์จากแอปตอนเข้าสู่ระบบ — ใช้แสดงผลเท่านั้น ไม่ใช้ยืนยันตัวตน
     * device_name:     รุ่นเครื่อง เช่น Google Pixel 7 (ไม่เก็บ IMEI / หมายเลขเครื่อง)
     * device_platform: android / ios
     * os_version:      เช่น Android 14
     * app_version:     เช่น 1.4.0 (12)
     *
     * เพิ่มคอลัมน์ว่างเท่านั้น: Token เดิมยังใช้ได้ทุกตัว (ไม่มีใครหลุดจากระบบ)
     * เซสชันเดิมไม่มีข้อมูล → แอปแสดง "อุปกรณ์ไม่ทราบชื่อ" / รันซ้ำได้
     */
    public function up(): void
    {
        $columns = [
            'device_name' => fn (Blueprint $table) => $table->string('device_name', 80)->nullable()->after('name'),
            'device_platform' => fn (Blueprint $table) => $table->string('device_platform', 16)->nullable()->after('device_name'),
            'os_version' => fn (Blueprint $table) => $table->string('os_version', 40)->nullable()->after('device_platform'),
            'app_version' => fn (Blueprint $table) => $table->string('app_version', 30)->nullable()->after('os_version'),
        ];

        foreach ($columns as $column => $add) {
            if (!Schema::hasColumn('personal_access_tokens', $column)) {
                Schema::table('personal_access_tokens', $add);
            }
        }
    }

    public function down(): void
    {
        Schema::table('personal_access_tokens', function (Blueprint $table) {
            foreach (['app_version', 'os_version', 'device_platform', 'device_name'] as $column) {
                if (Schema::hasColumn('personal_access_tokens', $column)) {
                    $table->dropColumn($column);
                }
            }
        });
    }
};
