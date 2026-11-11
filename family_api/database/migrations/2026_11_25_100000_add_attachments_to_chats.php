<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * ไฟล์แนบในแชท (ไฟล์เอกสาร + ข้อความเสียง) — แชทส่วนตัว/ร้านค้า และแชทกลุ่ม
     *
     * attachment_path:   เส้นทางใน disk ส่วนตัว (ชื่อสุ่ม ไม่ใช้ชื่อจากผู้ใช้)
     * attachment_kind:   file | voice
     * attachment_name:   ชื่อที่แสดง (ทำความสะอาดแล้ว)
     * attachment_mime:   ชนิดที่เซิร์ฟเวอร์ตรวจจากเนื้อไฟล์
     * attachment_size:   ขนาด (ไบต์)
     * voice_duration_ms: ความยาวเสียงที่อ่านจากไฟล์เอง
     *
     * เพิ่มคอลัมน์ว่างได้เท่านั้น ข้อความ รูป และความสัมพันธ์เดิมไม่เปลี่ยน / รันซ้ำได้
     */
    public function up(): void
    {
        foreach (['chat_messages', 'group_chat_messages'] as $table) {
            $columns = [
                'attachment_path' => fn (Blueprint $t) => $t->string('attachment_path')->nullable(),
                'attachment_kind' => fn (Blueprint $t) => $t->string('attachment_kind', 10)->nullable(),
                'attachment_name' => fn (Blueprint $t) => $t->string('attachment_name')->nullable(),
                'attachment_mime' => fn (Blueprint $t) => $t->string('attachment_mime', 100)->nullable(),
                'attachment_size' => fn (Blueprint $t) => $t->unsignedInteger('attachment_size')->nullable(),
                'voice_duration_ms' => fn (Blueprint $t) => $t->unsignedInteger('voice_duration_ms')->nullable(),
            ];

            foreach ($columns as $column => $add) {
                if (!Schema::hasColumn($table, $column)) {
                    Schema::table($table, fn (Blueprint $blueprint) => $add($blueprint));
                }
            }
        }
    }

    public function down(): void
    {
        foreach (['chat_messages', 'group_chat_messages'] as $table) {
            foreach (['voice_duration_ms', 'attachment_size', 'attachment_mime', 'attachment_name', 'attachment_kind', 'attachment_path'] as $column) {
                if (Schema::hasColumn($table, $column)) {
                    Schema::table($table, fn (Blueprint $blueprint) => $blueprint->dropColumn($column));
                }
            }
        }
    }
};
