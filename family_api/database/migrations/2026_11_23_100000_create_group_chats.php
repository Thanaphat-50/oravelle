<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * แชทกลุ่มครอบครัว (แยกจากแชทส่วนตัว/ร้านค้าเดิม ไม่แตะตาราง conversations / chat_messages)
     *
     * group_chats:          1 กลุ่ม = 1 ห้อง (family_id ไม่ซ้ำ → เปิดพร้อมกันได้ห้องเดียว)
     *                       ชื่อห้อง = ชื่อกลุ่ม (อ่านจาก families ทุกครั้ง ไม่เก็บซ้ำ)
     *                       ลบกลุ่ม → ห้อง ข้อความ และสิทธิ์ถูกลบตาม (cascade) / ไฟล์รูปลบในโค้ด
     * group_chat_members:   สิทธิ์ของสมาชิก "หนึ่งรอบ" = แถว family_members หนึ่งแถว
     *                       ออก/ถูกนำออก (ลบแถว family_members) → สิทธิ์หายตาม (cascade)
     *                       กลับเข้าใหม่ = แถวใหม่ → เริ่มเห็นใหม่ ไม่คืนประวัติรอบเก่า
     *                       visible_after_id: เห็นเฉพาะข้อความ id มากกว่านี้ (id ของข้อความล่าสุดตอนเข้ากลุ่ม)
     *                       last_read_id: ตำแหน่งอ่านของคนนี้ (ไม่ถอยหลัง) / muted: ปิดเสียงห้องของคนนี้
     * group_chat_messages:  client_id ไม่ซ้ำต่อ ห้อง + ผู้ส่ง → ส่งซ้ำ/retry ได้ข้อความเดิม
     *                       รูปเก็บใน disk ส่วนตัว เปิดผ่านลิงก์ชั่วคราวที่ตรวจสิทธิ์ทุกครั้ง
     *
     * ตารางใหม่ทั้งหมด ไม่แก้ข้อมูลแชทเดิม / รันซ้ำได้
     */
    public function up(): void
    {
        if (!Schema::hasTable('group_chats')) {
            Schema::create('group_chats', function (Blueprint $table) {
                $table->id();
                $table->foreignId('family_id')->unique()->constrained('families')->cascadeOnDelete();
                $table->timestamp('last_message_at')->nullable();
                $table->timestamps();
            });
        }

        if (!Schema::hasTable('group_chat_messages')) {
            Schema::create('group_chat_messages', function (Blueprint $table) {
                $table->id();
                $table->foreignId('group_chat_id')->constrained('group_chats')->cascadeOnDelete();
                // ลบบัญชี → ข้อความของบัญชีนั้นถูกลบตาม (ไฟล์รูปลบในโค้ด)
                $table->foreignId('sender_id')->constrained('users')->cascadeOnDelete();
                $table->string('client_id', 64);
                $table->text('body')->nullable();
                $table->string('image_path')->nullable();
                $table->timestamps();

                $table->unique(['group_chat_id', 'sender_id', 'client_id']);
                $table->index(['group_chat_id', 'id']);
            });
        }

        if (!Schema::hasTable('group_chat_members')) {
            Schema::create('group_chat_members', function (Blueprint $table) {
                $table->id();
                $table->foreignId('group_chat_id')->constrained('group_chats')->cascadeOnDelete();
                $table->foreignId('family_member_id')->unique()->constrained('family_members')->cascadeOnDelete();
                $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
                $table->unsignedBigInteger('visible_after_id')->default(0);
                $table->unsignedBigInteger('last_read_id')->default(0);
                $table->boolean('muted')->default(false);
                $table->timestamps();

                $table->index(['group_chat_id', 'user_id']);
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('group_chat_members');
        Schema::dropIfExists('group_chat_messages');
        Schema::dropIfExists('group_chats');
    }
};
