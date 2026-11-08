<?php

namespace App\Console\Commands;

use App\Models\Order;
use Illuminate\Console\Command;

// =======================================================
// คำสั่งซื้อที่ครบกำหนดเวลา (Scheduler รันทุกนาที ดู routes/console.php)
// - เลยเวลาชำระ (awaiting_payment) → ยกเลิก + คืนสต็อก + แจ้งผู้ซื้อและร้าน
// - ส่งแล้วครบกำหนด (shipped) → ระบบยืนยันรับสินค้าให้
//
// ทำเป็นชุด (--batch) จนหมดหรือถึง --max ต่อรอบ
// รันซ้อนกันได้อย่างปลอดภัย (Order::transition ล็อกแถว → แต่ละคำสั่งซื้อเปลี่ยนครั้งเดียว)
//
// php artisan orders:expire
// =======================================================

class ExpireOrders extends Command
{
    protected $signature = 'orders:expire
        {--batch=100 : จำนวนคำสั่งซื้อต่อชุด}
        {--max=2000 : จำนวนสูงสุดต่อรอบ (ที่เหลือทำรอบถัดไป)}';

    protected $description = 'ยกเลิกคำสั่งซื้อที่เลยเวลาชำระ (คืนสต็อก) และยืนยันรับสินค้าที่ครบกำหนด';

    public function handle(): int
    {
        $batch = max(1, (int) $this->option('batch'));
        $max = max($batch, (int) $this->option('max'));

        $cancelled = 0;
        $completed = 0;
        $seen = 0;

        do {
            $result = Order::expireStale(null, $batch);

            $cancelled += $result['cancelled'];
            $completed += $result['completed'];
            $seen += $batch;
        } while ($result['more'] && $seen < $max);

        $this->info("ยกเลิก (เลยเวลาชำระ) {$cancelled} รายการ · ยืนยันรับสินค้า {$completed} รายการ");

        return self::SUCCESS;
    }
}
