<?php

namespace App\Console\Commands;

use App\Services\Themes\BillingUnavailable;
use App\Services\Themes\GooglePlayBilling;
use App\Services\Themes\ThemePurchases;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Cache;

// =======================================================
// ตรวจการซื้อธีมที่ถูกคืนเงิน/เพิกถอน (Google Voided Purchases API) + ลองจบธุรกรรมที่ค้าง
// ทำงานเฉพาะเมื่อเปิด Google Play Billing แล้ว (ยังไม่เปิดขาย = ไม่ทำอะไร)
// =======================================================

class CheckThemePurchases extends Command
{
    protected $signature = 'themes:check-purchases';

    protected $description = 'Revoke refunded/voided theme purchases and retry pending acknowledgements';

    public function handle(GooglePlayBilling $google, ThemePurchases $purchases): int
    {
        $acknowledged = $purchases->retryAcknowledgements();

        if (!$google->enabled()) {
            $this->info('Google Play billing is not enabled');

            return self::SUCCESS;
        }

        // ย้อนหลังจากรอบก่อน (ครั้งแรก 30 วัน) เผื่อเหลื่อม 1 ชั่วโมง
        $since = (int) Cache::get('themes:voided-since', now()->subDays(30)->getTimestampMs());
        $startedAt = now()->getTimestampMs();

        try {
            $voided = $google->voidedPurchases(max(0, $since - 3600 * 1000));
        } catch (BillingUnavailable $e) {
            $this->error('Voided purchases unavailable: ' . $e->getMessage());

            return self::FAILURE;
        }

        $revoked = 0;

        foreach ($voided as $item) {
            $token = (string) ($item['purchaseToken'] ?? '');

            if ($token === '') {
                continue;
            }

            $result = $purchases->handleEvent(
                'google_play',
                'voided:' . hash('sha256', $token) . ':' . ($item['voidedTimeMillis'] ?? ''),
                'voided',
                $token,
                array_intersect_key((array) $item, array_flip(['orderId', 'voidedTimeMillis', 'voidedSource', 'voidedReason', 'voidedQuantity'])),
            );

            $revoked += $result === 'revoked' ? 1 : 0;
        }

        Cache::forever('themes:voided-since', $startedAt);

        $this->info("voided: {$revoked}, acknowledged: {$acknowledged}");

        return self::SUCCESS;
    }
}
