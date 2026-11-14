<?php

namespace App\Services\Themes;

use App\Support\GoogleServiceAccount;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Http\Client\Response;
use Illuminate\Support\Facades\Http;

// =======================================================
// Google Play Billing ฝั่งเซิร์ฟเวอร์ (สินค้าแบบซื้อครั้งเดียว ไม่ใช้หมด)
// - ตรวจ: purchases.products.get  (purchaseState 0=ซื้อแล้ว 1=ยกเลิก 2=รอชำระ, purchaseType 0=ซื้อทดสอบ)
// - จบธุรกรรม: purchases.products.acknowledge (ต้องทำภายใน 3 วัน ไม่งั้น Google คืนเงิน + เพิกถอนอัตโนมัติ)
// - คืนเงิน/เพิกถอน: purchases.voidedpurchases.list + Real-time developer notifications
// ต้องตั้ง THEME_BILLING=google_play + บัญชีบริการ (ดู docs/themes.md) — ยังไม่ตั้ง = ปิดอยู่
// =======================================================

class GooglePlayBilling implements ThemeBillingProvider
{
    private const BASE = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/';

    private const SCOPE = 'https://www.googleapis.com/auth/androidpublisher';

    private ?GoogleServiceAccount $account = null;

    public function name(): string
    {
        return 'google_play';
    }

    public function enabled(): bool
    {
        return config('themes.billing') === 'google_play' && $this->account()->configured();
    }

    public function packageName(): string
    {
        return (string) config('themes.google_play.package_name');
    }

    public function check(string $productId, string $token): BillingCheck
    {
        $response = $this->call('get', $this->productUrl($productId, $token));

        // token ไม่มีจริง / ไม่ใช่ของสินค้านี้ / แอปอื่น
        if (in_array($response->status(), [400, 404, 410], true)) {
            return BillingCheck::invalid(['http' => $response->status()]);
        }

        if (!$response->successful()) {
            throw new BillingUnavailable('Google Play HTTP ' . $response->status());
        }

        $data = (array) $response->json();

        $state = match ((int) ($data['purchaseState'] ?? -1)) {
            0 => BillingCheck::PURCHASED,
            1 => BillingCheck::CANCELLED,
            2 => BillingCheck::PENDING,
            default => BillingCheck::INVALID,
        };

        return new BillingCheck(
            state: $state,
            productId: $productId,
            orderId: isset($data['orderId']) ? (string) $data['orderId'] : null,
            // purchaseType 0 = ซื้อแบบทดสอบ (ผู้ทดสอบใบอนุญาต) / ไม่มีค่า = ซื้อจริง
            environment: array_key_exists('purchaseType', $data) && (int) $data['purchaseType'] === 0 ? 'sandbox' : 'production',
            accountRef: isset($data['obfuscatedExternalAccountId']) ? (string) $data['obfuscatedExternalAccountId'] : null,
            acknowledged: (int) ($data['acknowledgementState'] ?? 0) === 1,
            purchaseTimeMs: isset($data['purchaseTimeMillis']) ? (int) $data['purchaseTimeMillis'] : null,
            raw: array_intersect_key($data, array_flip([
                'purchaseState', 'purchaseType', 'acknowledgementState', 'consumptionState', 'orderId',
                'purchaseTimeMillis', 'regionCode', 'quantity', 'refundableQuantity',
            ])),
        );
    }

    public function acknowledge(string $productId, string $token): bool
    {
        $response = $this->call('post', $this->productUrl($productId, $token) . ':acknowledge', []);

        return $response->successful();
    }

    // รายการที่ถูกยกเลิก/คืนเงิน/ชาร์จแบ็ก ตั้งแต่ startMs (type 0 = สินค้าซื้อครั้งเดียว)
    public function voidedPurchases(int $startMs): array
    {
        $items = [];
        $pageToken = null;

        do {
            $query = ['startTime' => $startMs, 'type' => 0, 'maxResults' => 1000];

            if ($pageToken !== null) {
                $query['token'] = $pageToken;
            }

            $response = $this->call('get', self::BASE . rawurlencode($this->packageName()) . '/purchases/voidedpurchases', $query);

            if (!$response->successful()) {
                throw new BillingUnavailable('Google Play voided HTTP ' . $response->status());
            }

            array_push($items, ...((array) $response->json('voidedPurchases', [])));

            $pageToken = $response->json('tokenPagination.nextPageToken');
        } while (is_string($pageToken) && $pageToken !== '');

        return $items;
    }

    private function productUrl(string $productId, string $token): string
    {
        return self::BASE . rawurlencode($this->packageName())
            . '/purchases/products/' . rawurlencode($productId)
            . '/tokens/' . rawurlencode($token);
    }

    private function call(string $method, string $url, ?array $data = null): Response
    {
        try {
            $request = Http::withToken($this->account()->accessToken())->acceptJson()->timeout(15);

            return $method === 'get' ? $request->get($url, $data ?? []) : $request->post($url, $data ?? []);
        } catch (ConnectionException $e) {
            throw new BillingUnavailable($e->getMessage(), 0, $e);
        } catch (\RuntimeException $e) {
            throw new BillingUnavailable($e->getMessage(), 0, $e);
        }
    }

    private function account(): GoogleServiceAccount
    {
        return $this->account ??= new GoogleServiceAccount(
            config('themes.google_play.service_account'),
            config('themes.google_play.service_account_path'),
            self::SCOPE,
        );
    }
}
