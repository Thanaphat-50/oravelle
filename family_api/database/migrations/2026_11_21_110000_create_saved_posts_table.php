<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * โพสต์ที่บันทึกไว้อ่าน (ส่วนตัว: เห็นเฉพาะคนที่บันทึก)
     * - ความสัมพันธ์กับโพสต์เดิม (ไม่คัดลอกข้อความ/สื่อ)
     * - user_id + post_id ไม่ซ้ำ → บันทึกซ้ำ/ส่งคำขอซ้ำไม่เกิดรายการซ้ำ
     * - ลบบัญชี / ลบโพสต์ → ลบรายการบันทึกตาม (cascade)
     * - เรียงล่าสุดก่อนด้วย id (บันทึกใหม่ = id ใหม่กว่า)
     */
    public function up(): void
    {
        if (Schema::hasTable('saved_posts')) {
            return;
        }

        Schema::create('saved_posts', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
            $table->foreignId('post_id')->constrained('posts')->cascadeOnDelete();
            $table->timestamps();

            $table->unique(['user_id', 'post_id']);
            $table->index(['user_id', 'id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('saved_posts');
    }
};
