<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * ลืมรหัสผ่าน (App\Http\Controllers\PasswordResetController)
     * password_reset_tokens.attempts: กรอกรหัส 6 หลักผิดกี่ครั้งแล้ว (ครบ 5 ครั้ง → ต้องขอรหัสใหม่)
     * token เก็บเป็น hash ของรหัส (ไม่เก็บรหัสจริง)
     *
     * รันซ้ำได้
     */
    public function up(): void
    {
        if (!Schema::hasColumn('password_reset_tokens', 'attempts')) {
            Schema::table('password_reset_tokens', function (Blueprint $table) {
                $table->unsignedTinyInteger('attempts')->default(0)->after('token');
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('password_reset_tokens', 'attempts')) {
            Schema::table('password_reset_tokens', function (Blueprint $table) {
                $table->dropColumn('attempts');
            });
        }
    }
};
