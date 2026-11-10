<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * แจ้งเตือนกิจกรรมล่วงหน้า (App\Models\ActivityReminder)
     *
     * activities.starts_at (UTC) + activities.timezone (IANA เช่น Asia/Bangkok)
     * = ช่วงเวลาจริงของกิจกรรม (คนต่างเขตเวลาเห็นเวลาท้องถิ่นของตัวเองที่ตรงกัน)
     * - กิจกรรมเดิมมีแค่ activity_date (นาฬิกาผู้ใช้ ไม่รู้เขตเวลา) → starts_at = NULL
     *   ไม่แปลงให้ (ไม่เดาว่าเป็นเวลาไทย) เจ้าของต้องยืนยันวันเวลาก่อนเปิดการเตือน
     * - activity_date ยังเก็บต่อ (แอปเวอร์ชันเก่า + ตัวกรองวันนี้/เกินกำหนด)
     *
     * activity_reminders: การเตือนของแต่ละคน (1 คน 1 ค่าต่อกิจกรรม)
     * - remind_at (UTC) = starts_at - offset_minutes
     * - version เพิ่มทุกครั้งที่คำนวณกำหนดใหม่ → งานส่งที่ค้างของกำหนดเก่าไม่ส่ง
     * - status: pending / sent / cancelled / expired (เวลาผ่านไปแล้ว ไม่ส่งย้อนหลัง)
     *
     * เพิ่มคอลัมน์/ตารางใหม่เท่านั้น ไม่แก้ข้อมูลเดิม / รันซ้ำได้
     */
    public function up(): void
    {
        if (!Schema::hasColumn('activities', 'starts_at')) {
            Schema::table('activities', function (Blueprint $table) {
                $table->timestamp('starts_at')->nullable()->after('activity_date');
            });
        }

        if (!Schema::hasColumn('activities', 'timezone')) {
            Schema::table('activities', function (Blueprint $table) {
                $table->string('timezone', 64)->nullable()->after('starts_at');
            });
        }

        if (!Schema::hasTable('activity_reminders')) {
            Schema::create('activity_reminders', function (Blueprint $table) {
                $table->id();
                $table->foreignId('activity_id')->constrained('activities')->cascadeOnDelete();
                $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
                $table->unsignedInteger('offset_minutes');
                $table->timestamp('remind_at')->nullable();
                $table->unsignedInteger('version')->default(1);
                $table->string('status', 12)->default('pending');
                $table->timestamp('sent_at')->nullable();
                $table->timestamps();

                $table->unique(['activity_id', 'user_id']);
                $table->index(['status', 'remind_at']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('activity_reminders');

        Schema::table('activities', function (Blueprint $table) {
            if (Schema::hasColumn('activities', 'timezone')) {
                $table->dropColumn('timezone');
            }

            if (Schema::hasColumn('activities', 'starts_at')) {
                $table->dropColumn('starts_at');
            }
        });
    }
};
