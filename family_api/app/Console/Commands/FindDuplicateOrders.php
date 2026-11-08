<?php

namespace App\Console\Commands;

use App\Models\Order;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;

// =======================================================
// ตรวจคำสั่งซื้อที่อาจซ้ำ (เกิดก่อนมี order_checkouts) — อ่านอย่างเดียว ไม่ลบ/แก้อะไร
// 1) checkout เดียวกัน ร้านเดียวกัน มีมากกว่า 1 คำสั่งซื้อ (กดสั่งพร้อมกัน)
// 2) แอปเวอร์ชันเก่า (ไม่มี checkout_id): ผู้ซื้อ ร้าน สินค้า ยอดเงินเดียวกัน ห่างกันไม่เกิน --seconds
//
// พบแล้ว: ตรวจใน /admin → คำสั่งซื้อ แล้วให้ร้าน/ผู้ซื้อยกเลิกรายการที่เกิน (คืนสต็อกให้เอง)
//
// php artisan orders:find-duplicates
// =======================================================

class FindDuplicateOrders extends Command
{
    protected $signature = 'orders:find-duplicates
        {--seconds=60 : คำสั่งซื้อแบบเดิมที่ห่างกันไม่เกินกี่วินาทีถือว่าอาจซ้ำ}';

    protected $description = 'แสดงคำสั่งซื้อที่อาจสร้างซ้ำ (อ่านอย่างเดียว)';

    public function handle(): int
    {
        $rows = [];

        // 1) checkout เดียวกัน ร้านเดียวกัน
        DB::table('orders')
            ->whereNotNull('checkout_id')
            ->select('buyer_id', 'checkout_id', 'shop_id')
            ->groupBy('buyer_id', 'checkout_id', 'shop_id')
            ->havingRaw('count(*) > 1')
            ->orderBy('buyer_id')
            ->get()
            ->each(function ($group) use (&$rows) {
                $orders = Order::where('buyer_id', $group->buyer_id)
                    ->where('checkout_id', $group->checkout_id)
                    ->where('shop_id', $group->shop_id)
                    ->orderBy('id')
                    ->get();

                $rows[] = $this->row('checkout ซ้ำ', $orders);
            });

        // 2) คำสั่งซื้อแบบเดิม (ไม่มี checkout_id) ที่เหมือนกันและห่างกันไม่กี่วินาที
        $seconds = max(1, (int) $this->option('seconds'));
        $previous = null;
        $cluster = collect();

        $flush = function () use (&$cluster, &$rows) {
            if ($cluster->count() > 1) {
                $rows[] = $this->row('สั่งซ้ำติดกัน', $cluster);
            }

            $cluster = collect();
        };

        Order::whereNull('checkout_id')
            ->orderBy('buyer_id')
            ->orderBy('shop_id')
            ->orderBy('product_title')
            ->orderBy('total')
            ->orderBy('created_at')
            ->cursor()
            ->each(function (Order $order) use (&$previous, &$cluster, $flush, $seconds) {
                $same = $previous
                    && $previous->buyer_id === $order->buyer_id
                    && $previous->shop_id === $order->shop_id
                    && $previous->product_title === $order->product_title
                    && (string) $previous->total === (string) $order->total
                    && abs($order->created_at->diffInSeconds($previous->created_at)) <= $seconds;

                if (!$same) {
                    $flush();
                }

                $cluster->push($order);
                $previous = $order;
            });

        $flush();

        if ($rows === []) {
            $this->info('ไม่พบคำสั่งซื้อที่อาจซ้ำ');

            return self::SUCCESS;
        }

        $this->warn('พบ ' . count($rows) . ' กลุ่มที่อาจซ้ำ (ยังไม่ได้แก้ไขอะไร)');
        $this->table(['ประเภท', 'ผู้ซื้อ', 'ร้าน', 'คำสั่งซื้อ (สถานะ)', 'สั่งเมื่อ'], $rows);

        return self::SUCCESS;
    }

    private function row(string $type, $orders): array
    {
        $first = $orders->first();

        return [
            $type,
            $first->buyer_id,
            $first->shop_id,
            $orders->map(fn (Order $order) => "{$order->code} ({$order->status})")->join(', '),
            $first->created_at?->toDateTimeString(),
        ];
    }
}
