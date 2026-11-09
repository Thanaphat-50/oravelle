<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * คืนเงิน 2 ขั้น
     * refunded_at          = ร้านแจ้งว่าคืนเงินแล้ว (refund_status refunded)
     * refund_confirmed_at  = ผู้ซื้อยืนยันว่าได้รับเงินคืนแล้ว
     *
     * รันซ้ำได้
     */
    public function up(): void
    {
        if (!Schema::hasColumn('orders', 'refund_confirmed_at')) {
            Schema::table('orders', function (Blueprint $table) {
                $table->timestamp('refund_confirmed_at')->nullable()->after('refunded_at');
            });
        }
    }

    public function down(): void
    {
        if (Schema::hasColumn('orders', 'refund_confirmed_at')) {
            Schema::table('orders', function (Blueprint $table) {
                $table->dropColumn('refund_confirmed_at');
            });
        }
    }
};
