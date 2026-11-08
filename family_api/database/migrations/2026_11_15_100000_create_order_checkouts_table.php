<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * order_checkouts: 1 แถวต่อการกดสั่งซื้อ 1 ครั้ง (buyer_id + checkout_id ไม่ซ้ำ)
     * - กันคำขอสั่งซื้อเดียวกันที่เข้าพร้อมกัน (กดซ้ำ / แอปส่งใหม่หลังหมดเวลา) สร้างคำสั่งซื้อซ้ำ
     * - 1 checkout ซื้อได้หลายร้าน → ไม่ใส่ unique ที่ orders (1 checkout มีหลายคำสั่งซื้อ)
     *
     * คัดลอก checkout เดิมจาก orders แบบไม่ซ้ำ (DISTINCT) → ข้อมูลเดิมที่เคยซ้ำไม่ทำให้ล้ม
     * และไม่ลบหรือแก้คำสั่งซื้อเดิม (ตรวจคำสั่งซื้อซ้ำเดิม: php artisan orders:find-duplicates)
     *
     * รันซ้ำได้ (สร้างตารางแล้วข้าม / คัดลอกซ้ำใช้ insertOrIgnore)
     */
    public function up(): void
    {
        if (!Schema::hasTable('order_checkouts')) {
            Schema::create('order_checkouts', function (Blueprint $table) {
                $table->id();
                $table->foreignId('buyer_id')->constrained('users')->cascadeOnDelete();
                $table->string('checkout_id', 40);
                $table->timestamps();

                $table->unique(['buyer_id', 'checkout_id']);
            });
        }

        DB::table('orders')
            ->whereNotNull('checkout_id')
            ->select('buyer_id', 'checkout_id', DB::raw('min(created_at) as created_at'))
            ->groupBy('buyer_id', 'checkout_id')
            ->orderBy('buyer_id')
            ->orderBy('checkout_id')
            ->get()
            ->chunk(500)
            ->each(fn ($rows) => DB::table('order_checkouts')->insertOrIgnore(
                $rows->map(fn ($row) => [
                    'buyer_id' => $row->buyer_id,
                    'checkout_id' => $row->checkout_id,
                    'created_at' => $row->created_at,
                    'updated_at' => $row->created_at,
                ])->all()
            ));
    }

    public function down(): void
    {
        Schema::dropIfExists('order_checkouts');
    }
};
