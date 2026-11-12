<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * สายโทร 1 ต่อ 1 (แชทส่วนตัว / ร้านค้า) — เก็บแค่สถานะ ไม่บันทึกเสียงหรือวิดีโอ
     *
     * room:            ชื่อห้อง LiveKit (สุ่ม ไม่ส่งให้แอปตรง ๆ — อยู่ใน token)
     * *_token_id:      เซสชันที่ใช้เริ่ม/รับสาย (ถูกเพิกถอน → สายจบ)
     * ring_expires_at: เรียกเข้าได้ถึงเวลานี้ (เลย → missed)
     * last_seen_at:    สัญญาณล่าสุดระหว่างสาย (หายนาน → failed)
     *
     * ตารางใหม่เท่านั้น ไม่แตะข้อมูลเดิม / รันซ้ำได้
     */
    public function up(): void
    {
        if (Schema::hasTable('calls')) {
            return;
        }

        Schema::create('calls', function (Blueprint $table) {
            $table->id();
            $table->foreignId('conversation_id')->constrained('conversations')->cascadeOnDelete();
            $table->foreignId('caller_id')->constrained('users')->cascadeOnDelete();
            $table->foreignId('callee_id')->constrained('users')->cascadeOnDelete();
            $table->string('type', 10);
            $table->string('status', 12);
            $table->string('room', 64)->unique();
            $table->unsignedBigInteger('caller_token_id')->nullable();
            $table->unsignedBigInteger('callee_token_id')->nullable();
            $table->timestamp('ring_expires_at');
            $table->timestamp('accepted_at')->nullable();
            $table->timestamp('ended_at')->nullable();
            $table->timestamp('last_seen_at')->nullable();
            $table->string('end_reason', 32)->nullable();
            $table->timestamps();

            $table->index(['caller_id', 'status']);
            $table->index(['callee_id', 'status']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('calls');
    }
};
