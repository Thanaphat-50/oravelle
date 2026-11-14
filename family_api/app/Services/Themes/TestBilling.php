<?php

namespace App\Services\Themes;

use Illuminate\Support\Facades\Cache;

// =======================================================
// ช่องทางจำลองสำหรับทดสอบ (ไม่เก็บเงินจริง ไม่ใช่ sandbox ของ Google)
// - เปิดได้เฉพาะเครื่องที่ไม่ใช่ production + THEME_TEST_PURCHASES=true
// - หลักฐานการซื้อออกโดยเซิร์ฟเวอร์และลงลายเซ็น (แก้/ปลอมในแอปไม่ได้)
// - สถานะเปลี่ยนได้ด้วย themes:test-event (ชำระสำเร็จภายหลัง / ยกเลิก / คืนเงิน / เพิกถอน)
//   เพื่อทดสอบวงจรเดียวกับของจริง: รอชำระ → สำเร็จ, คืนเงิน → เพิกถอนสิทธิ์
// =======================================================

class TestBilling implements ThemeBillingProvider
{
    public const OUTCOMES = ['purchased', 'pending', 'cancelled'];

    public function name(): string
    {
        return 'test';
    }

    public function enabled(): bool
    {
        return (bool) config('themes.test_purchases') && !app()->environment('production');
    }

    // ออกหลักฐานการซื้อจำลอง (เหมือนผู้ให้บริการคืน purchase token)
    public function issue(int $userId, string $productId, string $outcome): string
    {
        $body = rtrim(strtr(base64_encode(json_encode([
            'u' => $userId,
            'p' => $productId,
            'o' => $outcome,
            'n' => bin2hex(random_bytes(8)),
            't' => now()->getTimestampMs(),
        ])), '+/', '-_'), '=');

        return 'tp1.' . $body . '.' . $this->sign($body);
    }

    public function check(string $productId, string $token): BillingCheck
    {
        $data = $this->decode($token);

        if ($data === null || ($data['p'] ?? null) !== $productId) {
            return BillingCheck::invalid();
        }

        $hash = hash('sha256', $token);

        $state = Cache::get('theme-test-state:' . $hash, (string) $data['o']);

        return new BillingCheck(
            state: in_array($state, ['purchased', 'pending', 'cancelled'], true) ? $state : BillingCheck::CANCELLED,
            productId: $productId,
            orderId: 'TEST.' . strtoupper(substr($hash, 0, 12)),
            environment: 'test',
            accountRef: app(ThemePurchases::class)->accountRef((int) $data['u']),
            acknowledged: (bool) Cache::get('theme-test-ack:' . $hash, false),
            purchaseTimeMs: (int) ($data['t'] ?? 0),
            raw: ['simulated' => true, 'state' => $state],
        );
    }

    public function acknowledge(string $productId, string $token): bool
    {
        Cache::forever('theme-test-ack:' . hash('sha256', $token), true);

        return true;
    }

    // จำลองการเปลี่ยนสถานะฝั่งผู้ให้บริการ (themes:test-event)
    public function setState(string $token, string $state): void
    {
        Cache::forever('theme-test-state:' . hash('sha256', $token), $state);
    }

    public function decode(string $token): ?array
    {
        $parts = explode('.', $token);

        if (count($parts) !== 3 || $parts[0] !== 'tp1' || !hash_equals($this->sign($parts[1]), $parts[2])) {
            return null;
        }

        $data = json_decode((string) base64_decode(strtr($parts[1], '-_', '+/')), true);

        return is_array($data) && isset($data['u'], $data['p'], $data['o']) ? $data : null;
    }

    private function sign(string $body): string
    {
        return hash_hmac('sha256', 'theme-test-purchase|' . $body, (string) config('app.key'));
    }
}
