<?php

namespace App\Services\Themes;

interface ThemeBillingProvider
{
    // google_play / test
    public function name(): string;

    public function enabled(): bool;

    // ถามสถานะล่าสุดของหลักฐานการซื้อจากผู้ให้บริการ (ห้ามเชื่อข้อมูลจากแอป)
    // ติดต่อไม่ได้ → BillingUnavailable
    public function check(string $productId, string $token): BillingCheck;

    // จบขั้นตอนธุรกรรมตามที่ผู้ให้บริการกำหนด (Google: acknowledge ภายใน 3 วัน ไม่งั้นคืนเงินอัตโนมัติ)
    public function acknowledge(string $productId, string $token): bool;
}
