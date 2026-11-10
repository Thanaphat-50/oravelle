<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * ตอบกลับข้อความ (Reply) + Reaction — แชทส่วนตัว/ร้านค้า และแชทกลุ่ม
     *
     * reply_to_id: ข้อความต้นทาง (ห้องเดียวกันเท่านั้น ตรวจตอนส่ง) — ต้นทางถูกลบ → NULL
     * is_reply:    เป็นข้อความตอบกลับ (ต้นทางถูกลบแล้วยังรู้ว่าเคยตอบ → แสดง "ข้อความนี้ไม่พร้อมใช้งาน")
     *              ไม่เก็บสำเนาข้อความต้นทาง: ตัวอย่างข้อความคำนวณใหม่ตามสิทธิ์ของผู้ชมแต่ละคน
     * *_reactions: 1 คน 1 Reaction ต่อข้อความ (unique) เปลี่ยน/ถอนได้
     *
     * เพิ่มคอลัมน์/ตารางใหม่เท่านั้น ข้อความเดิมไม่มี Reply/Reaction ใช้งานได้ตามเดิม / รันซ้ำได้
     */
    public function up(): void
    {
        foreach (['chat_messages', 'group_chat_messages'] as $table) {
            if (!Schema::hasColumn($table, 'reply_to_id')) {
                Schema::table($table, function (Blueprint $blueprint) use ($table) {
                    $blueprint->foreignId('reply_to_id')->nullable()->after('image_path')
                        ->constrained($table)->nullOnDelete();
                });
            }

            if (!Schema::hasColumn($table, 'is_reply')) {
                Schema::table($table, function (Blueprint $blueprint) {
                    $blueprint->boolean('is_reply')->default(false)->after('reply_to_id');
                });
            }
        }

        if (!Schema::hasTable('chat_message_reactions')) {
            Schema::create('chat_message_reactions', function (Blueprint $table) {
                $table->id();
                $table->foreignId('chat_message_id')->constrained('chat_messages')->cascadeOnDelete();
                $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
                $table->string('emoji', 16);
                $table->timestamps();

                $table->unique(['chat_message_id', 'user_id']);
            });
        }

        if (!Schema::hasTable('group_chat_message_reactions')) {
            Schema::create('group_chat_message_reactions', function (Blueprint $table) {
                $table->id();
                $table->foreignId('group_chat_message_id')->constrained('group_chat_messages')->cascadeOnDelete();
                $table->foreignId('user_id')->constrained('users')->cascadeOnDelete();
                $table->string('emoji', 16);
                $table->timestamps();

                // ชื่อสั้น: ชื่ออัตโนมัติยาว 65 ตัวอักษร เกินที่ MySQL รับ (64)
                $table->unique(['group_chat_message_id', 'user_id'], 'gcm_reactions_message_user_unique');
            });
        }

        // รอบ deploy ที่ล้มบน MySQL สร้างตารางแล้วแต่ยังไม่มี unique → เติมให้ (รันซ้ำได้)
        if (!Schema::hasIndex('group_chat_message_reactions', 'gcm_reactions_message_user_unique')) {
            Schema::table('group_chat_message_reactions', function (Blueprint $table) {
                $table->unique(['group_chat_message_id', 'user_id'], 'gcm_reactions_message_user_unique');
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('group_chat_message_reactions');
        Schema::dropIfExists('chat_message_reactions');

        foreach (['group_chat_messages', 'chat_messages'] as $table) {
            if (Schema::hasColumn($table, 'reply_to_id')) {
                Schema::table($table, function (Blueprint $blueprint) {
                    $blueprint->dropConstrainedForeignId('reply_to_id');
                });
            }

            if (Schema::hasColumn($table, 'is_reply')) {
                Schema::table($table, function (Blueprint $blueprint) {
                    $blueprint->dropColumn('is_reply');
                });
            }
        }
    }
};
