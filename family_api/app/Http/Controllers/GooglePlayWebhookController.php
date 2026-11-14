<?php

namespace App\Http\Controllers;

use App\Services\Themes\ThemePurchases;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Support\Facades\Log;

// =======================================================
// Real-time developer notifications (Google Play → Pub/Sub push → ที่นี่)
// POST /api/billing/google/rtdn/{token}
// - token ในลิงก์ต้องตรงกับ GOOGLE_PLAY_RTDN_TOKEN (ไม่ตั้ง = ปิด)
// - messageId ของ Pub/Sub เป็นคีย์กันซ้ำ → ส่งซ้ำกี่ครั้งก็ประมวลผลครั้งเดียว
// - ไม่เชื่อข้อมูลในข้อความ: ถามสถานะจริงจาก Google Play อีกครั้งเสมอ
// =======================================================

class GooglePlayWebhookController extends Controller
{
    public function rtdn(Request $request, string $token, ThemePurchases $purchases): Response
    {
        $secret = (string) config('themes.google_play.rtdn_token');

        if ($secret === '' || !hash_equals($secret, $token)) {
            return response('', 403);
        }

        $message = (array) $request->input('message', []);
        $messageId = (string) ($message['messageId'] ?? $message['message_id'] ?? '');
        $data = json_decode((string) base64_decode((string) ($message['data'] ?? ''), true), true);

        // ข้อความผิดรูปแบบ → ตอบ 204 (ไม่ให้ Pub/Sub ส่งซ้ำไม่จบ) แต่บันทึก log
        if ($messageId === '' || !is_array($data)) {
            Log::warning('RTDN malformed message');

            return response()->noContent();
        }

        if (($data['packageName'] ?? null) !== config('themes.google_play.package_name')) {
            return response()->noContent();
        }

        if (isset($data['oneTimeProductNotification'])) {
            $n = (array) $data['oneTimeProductNotification'];

            // 1 = ONE_TIME_PRODUCT_PURCHASED, 2 = ONE_TIME_PRODUCT_CANCELED
            $type = (int) ($n['notificationType'] ?? 0) === 2 ? 'cancelled' : 'purchased';

            if (is_string($n['purchaseToken'] ?? null)) {
                $purchases->handleEvent('google_play', 'rtdn:' . $messageId, $type, $n['purchaseToken'], $data, isset($n['sku']) ? (string) $n['sku'] : null);
            }
        } elseif (isset($data['voidedPurchaseNotification'])) {
            $n = (array) $data['voidedPurchaseNotification'];

            if (is_string($n['purchaseToken'] ?? null) && (int) ($n['productType'] ?? 2) === 2) {
                $purchases->handleEvent('google_play', 'rtdn:' . $messageId, 'voided', $n['purchaseToken'], $data);
            }
        }

        return response()->noContent();
    }
}
