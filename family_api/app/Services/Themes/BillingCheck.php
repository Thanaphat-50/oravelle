<?php

namespace App\Services\Themes;

// ผลตรวจหลักฐานการซื้อจากผู้ให้บริการ (แปลงให้เหมือนกันทุกช่องทาง)
final class BillingCheck
{
    public const PURCHASED = 'purchased';
    public const PENDING = 'pending';
    public const CANCELLED = 'cancelled';
    public const INVALID = 'invalid';

    public function __construct(
        // purchased / pending / cancelled / invalid (หลักฐานปลอม / ไม่ใช่สินค้านี้)
        public readonly string $state,
        public readonly ?string $productId = null,
        public readonly ?string $orderId = null,
        // production / sandbox (การซื้อทดสอบของ Google) / test (จำลองในระบบนี้)
        public readonly string $environment = 'production',
        // รหัสบัญชีที่แอปผูกไว้ตอนซื้อ (obfuscatedAccountId) null = ไม่ได้ผูก
        public readonly ?string $accountRef = null,
        public readonly bool $acknowledged = false,
        public readonly ?int $purchaseTimeMs = null,
        public readonly array $raw = [],
    ) {
    }

    public static function invalid(array $raw = []): self
    {
        return new self(self::INVALID, raw: $raw);
    }
}
