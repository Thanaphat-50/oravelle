<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * แก้ไขข้อความโพสต์ (PATCH /api/posts/{post})
     *
     * edited_at:    เวลาที่ข้อความเปลี่ยนจริงครั้งล่าสุด (แยกจาก updated_at ที่เปลี่ยนได้จากเรื่องอื่น)
     *               NULL = ยังไม่เคยแก้ → ไม่แสดง "แก้ไขแล้ว"
     * edit_version: เพิ่มทุกครั้งที่ข้อความเปลี่ยน → แก้จากสองเครื่องพร้อมกันแล้วไม่เขียนทับกันเงียบ ๆ
     *
     * เพิ่มคอลัมน์ใหม่เท่านั้น ไม่แก้ข้อมูลเดิม / รันซ้ำได้
     */
    public function up(): void
    {
        if (!Schema::hasColumn('posts', 'edited_at')) {
            Schema::table('posts', function (Blueprint $table) {
                $table->timestamp('edited_at')->nullable()->after('content');
            });
        }

        if (!Schema::hasColumn('posts', 'edit_version')) {
            Schema::table('posts', function (Blueprint $table) {
                $table->unsignedInteger('edit_version')->default(0)->after('edited_at');
            });
        }
    }

    public function down(): void
    {
        Schema::table('posts', function (Blueprint $table) {
            if (Schema::hasColumn('posts', 'edit_version')) {
                $table->dropColumn('edit_version');
            }

            if (Schema::hasColumn('posts', 'edited_at')) {
                $table->dropColumn('edited_at');
            }
        });
    }
};
