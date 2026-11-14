<?php

namespace App\Console\Commands;

use App\Models\ThemePurchase;
use App\Services\Themes\TestBilling;
use App\Services\Themes\ThemePurchases;
use Illuminate\Console\Command;

// =======================================================
// จำลองเหตุการณ์จากผู้ให้บริการ (เฉพาะโหมดทดสอบ ไม่ใช่ production)
//   complete = รอชำระ → ชำระสำเร็จ (เหมือน RTDN PURCHASED)
//   cancel   = ผู้ให้บริการยกเลิก
//   refund   = คืนเงิน (เหมือน Voided purchase)
//   revoke   = เพิกถอนสิทธิ์
// ใช้: php artisan themes:test-event {purchase_id} {complete|cancel|refund|revoke}
// =======================================================

class ThemeTestEvent extends Command
{
    protected $signature = 'themes:test-event {purchase : theme_purchases.id} {event : complete|cancel|refund|revoke}';

    protected $description = 'Simulate a billing provider event for a TEST theme purchase (non-production only)';

    public function handle(TestBilling $test, ThemePurchases $purchases): int
    {
        if (!$test->enabled()) {
            $this->error('Test purchases are disabled (or this is production)');

            return self::FAILURE;
        }

        $purchase = ThemePurchase::query()->where('provider', 'test')->find($this->argument('purchase'));

        if ($purchase === null) {
            $this->error('Test purchase not found');

            return self::FAILURE;
        }

        $event = (string) $this->argument('event');
        $key = 'test:' . $purchase->id . ':' . $event . ':' . now()->getTimestampMs();

        $result = match ($event) {
            'complete' => (function () use ($test, $purchases, $purchase, $key) {
                $test->setState($purchase->purchase_token, 'purchased');

                return $purchases->handleEvent('test', $key, 'purchased', $purchase->purchase_token, [], $purchase->product_id);
            })(),
            'cancel' => (function () use ($test, $purchases, $purchase, $key) {
                $test->setState($purchase->purchase_token, 'cancelled');

                return $purchases->handleEvent('test', $key, 'cancelled', $purchase->purchase_token, [], $purchase->product_id);
            })(),
            'refund' => $purchases->handleEvent('test', $key, 'voided', $purchase->purchase_token, ['voidedSource' => 0, 'voidedReason' => 1]),
            'revoke' => $purchases->handleEvent('test', $key, 'voided', $purchase->purchase_token, ['voidedSource' => 2, 'voidedReason' => 0]),
            default => null,
        };

        if ($result === null) {
            $this->error('Unknown event');

            return self::FAILURE;
        }

        $this->info("{$event}: {$result}");

        return self::SUCCESS;
    }
}
