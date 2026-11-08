<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * chat_messages.client_id: รหัสข้อความที่แอปสร้างก่อนส่ง
     * - แอปส่งใหม่ด้วยรหัสเดิม (หมดเวลารอ / กดส่งใหม่) → ได้ข้อความเดิม ไม่สร้างซ้ำ
     * - unique ต่อ ห้อง + ผู้ส่ง (ข้อความเดิมไม่มี client_id = NULL ซ้ำได้)
     *
     * รันซ้ำได้ (เพิ่มคอลัมน์/ดัชนีที่ยังไม่มีเท่านั้น)
     */
    public function up(): void
    {
        if (!Schema::hasColumn('chat_messages', 'client_id')) {
            Schema::table('chat_messages', function (Blueprint $table) {
                $table->string('client_id', 64)->nullable()->after('sender_id');
            });
        }

        if (!Schema::hasIndex('chat_messages', 'chat_messages_client_unique')) {
            Schema::table('chat_messages', function (Blueprint $table) {
                $table->unique(['conversation_id', 'sender_id', 'client_id'], 'chat_messages_client_unique');
            });
        }
    }

    public function down(): void
    {
        Schema::table('chat_messages', function (Blueprint $table) {
            $table->dropUnique('chat_messages_client_unique');
            $table->dropColumn('client_id');
        });
    }
};
