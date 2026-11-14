<?php

namespace App\Services\Themes;

use App\Models\Theme;
use App\Models\ThemeBillingEvent;
use App\Models\ThemeEntitlement;
use App\Models\ThemePurchase;
use App\Models\User;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

// =======================================================
// ตรวจการซื้อธีม → ให้สิทธิ์ → จบธุรกรรม / เพิกถอนเมื่อคืนเงิน
//
// กติกา:
// - ให้สิทธิ์เมื่อผู้ให้บริการยืนยันว่า "ซื้อแล้ว" เท่านั้น (รอชำระ/ยกเลิก/หลักฐานปลอม = ไม่ให้)
// - หลักฐาน 1 ใบผูกกับบัญชีเดียว (unique provider + token_hash + รหัสบัญชีที่แอปผูกไว้ตอนซื้อ)
// - ส่งหลักฐานเดิมซ้ำ / เหตุการณ์ซ้ำ → ผลเดิม ไม่สร้างธุรกรรมหรือสิทธิ์ซ้ำ
// - ซื้อแล้วแอปปิดก่อนแจ้งเซิร์ฟเวอร์ → แอปส่งมาใหม่ภายหลัง (กู้คืนการซื้อ) หรือ RTDN จาก Google ให้สิทธิ์แทน
// - คืนเงิน/เพิกถอน → ปิดสิทธิ์ + เก็บเหตุผลให้แอปแจ้งผู้ใช้และกลับธีมฟรี
// =======================================================

class ThemePurchases
{
    public function __construct(
        private readonly GooglePlayBilling $google,
        private readonly TestBilling $test,
    ) {
    }

    // =====================================================
    // ช่องทาง
    // =====================================================

    public function provider(?string $name): ?ThemeBillingProvider
    {
        $provider = match ($name) {
            'google_play' => $this->google,
            'test' => $this->test,
            default => null,
        };

        return $provider?->enabled() ? $provider : null;
    }

    // ช่องทางที่แอปควรใช้ซื้อตอนนี้ (null = ยังไม่เปิดขาย)
    public function activeProviderName(): ?string
    {
        if ($this->google->enabled()) {
            return 'google_play';
        }

        return $this->test->enabled() ? 'test' : null;
    }

    public function acceptsEnvironment(string $environment): bool
    {
        return match ($environment) {
            'production' => true,
            'test' => $this->test->enabled(),
            'sandbox' => (bool) (config('themes.accept_sandbox') ?? !app()->environment('production')),
            default => false,
        };
    }

    // =====================================================
    // รหัสบัญชีที่แอปแนบไปตอนซื้อ (obfuscatedAccountId ≤ 64 ตัว)
    // "u<id>.<ลายเซ็น>" → รู้ว่าเป็นบัญชีไหนและปลอมไม่ได้ ไม่มีข้อมูลส่วนตัว
    // =====================================================

    public function accountRef(int $userId): string
    {
        return 'u' . $userId . '.' . substr(hash_hmac('sha256', 'theme-account|' . $userId, (string) config('app.key')), 0, 32);
    }

    public function userIdFromAccountRef(?string $ref): ?int
    {
        if (!is_string($ref) || !preg_match('/^u(\d{1,18})\.[0-9a-f]{32}$/', $ref, $m)) {
            return null;
        }

        return hash_equals($this->accountRef((int) $m[1]), $ref) ? (int) $m[1] : null;
    }

    // =====================================================
    // ตรวจหลักฐานการซื้อที่แอปส่งมา
    // คืน [http, body] ให้ Controller ส่งต่อ
    // =====================================================

    public function verify(User $user, Theme $theme, string $providerName, string $token): array
    {
        $provider = $this->provider($providerName);

        if ($provider === null) {
            return $this->fail(409, 'billing_unavailable', 'ยังไม่เปิดขายธีมผ่านช่องทางนี้');
        }

        $productId = $theme->loadMissing('products')->productId($providerName);

        if ($theme->is_free || $productId === null) {
            return $this->fail(422, 'not_for_sale', 'ธีมนี้ไม่ได้ขายผ่านช่องทางนี้');
        }

        $hash = ThemePurchase::hashToken($token);

        $existing = ThemePurchase::query()->where('provider', $providerName)->where('token_hash', $hash)->first();

        if ($existing !== null && (int) $existing->user_id !== (int) $user->id) {
            return $this->fail(409, 'purchase_other_account', 'หลักฐานการซื้อนี้ถูกใช้กับบัญชีอื่นแล้ว');
        }

        if ($existing !== null && (int) $existing->theme_id !== (int) $theme->id) {
            return $this->fail(422, 'invalid_purchase', 'หลักฐานการซื้อไม่ตรงกับธีมนี้');
        }

        try {
            $check = $provider->check($productId, $token);
        } catch (BillingUnavailable $e) {
            Log::warning('Theme purchase check unavailable', ['provider' => $providerName, 'error' => $e->getMessage()]);

            return $this->fail(503, 'verify_unavailable', 'ตรวจการชำระเงินไม่ได้ชั่วคราว ระบบจะลองใหม่เอง ไม่ต้องซื้อซ้ำ');
        }

        if ($check->state === BillingCheck::INVALID || ($check->productId !== null && $check->productId !== $productId)) {
            return $this->fail(422, 'invalid_purchase', 'ตรวจสอบการซื้อไม่ผ่าน');
        }

        // ผูกบัญชีไว้ตอนซื้อ → ต้องเป็นบัญชีนี้เท่านั้น
        if ($check->accountRef !== null && $this->userIdFromAccountRef($check->accountRef) !== (int) $user->id) {
            return $this->fail(409, 'purchase_other_account', 'การซื้อนี้เป็นของบัญชีอื่น');
        }

        if (!$this->acceptsEnvironment($check->environment)) {
            return $this->fail(422, 'sandbox_not_accepted', 'การซื้อแบบทดสอบใช้กับระบบนี้ไม่ได้');
        }

        $purchase = $this->record($user, $theme, $providerName, $productId, $token, $hash, $check);

        if ($purchase === null) {
            return $this->fail(409, 'purchase_other_account', 'หลักฐานการซื้อนี้ถูกใช้กับบัญชีอื่นแล้ว');
        }

        if ($purchase->status === ThemePurchase::PURCHASED && $purchase->acknowledged_at === null) {
            $this->acknowledge($purchase, $provider, $check->acknowledged);
        }

        $entitlement = ThemeEntitlement::query()->where('user_id', $user->id)->where('theme_id', $theme->id)->first();

        return [
            $purchase->status === ThemePurchase::PURCHASED ? 200 : 202,
            [
                'status' => true,
                'purchase_status' => $purchase->status,
                'acknowledged' => $purchase->acknowledged_at !== null,
                'entitlement' => $entitlement ? $this->entitlementPayload($entitlement) : null,
                'message' => match ($purchase->status) {
                    ThemePurchase::PURCHASED => 'ซื้อธีมสำเร็จ ใช้งานได้ทันที',
                    ThemePurchase::PENDING => 'รอการชำระเงิน เมื่อชำระสำเร็จธีมจะปลดล็อกเอง',
                    default => 'การซื้อไม่สำเร็จหรือถูกยกเลิก ไม่มีการปลดล็อกธีม',
                },
            ],
        ];
    }

    // บันทึก/อัปเดตธุรกรรม + สิทธิ์ ในทรานแซกชันเดียว (null = token ถูกบัญชีอื่นแย่งบันทึกก่อน)
    private function record(User $user, Theme $theme, string $provider, string $productId, string $token, string $hash, BillingCheck $check): ?ThemePurchase
    {
        $status = match ($check->state) {
            BillingCheck::PURCHASED => ThemePurchase::PURCHASED,
            BillingCheck::PENDING => ThemePurchase::PENDING,
            default => ThemePurchase::CANCELLED,
        };

        try {
            return DB::transaction(function () use ($user, $theme, $provider, $productId, $token, $hash, $check, $status) {
                $purchase = ThemePurchase::query()
                    ->where('provider', $provider)
                    ->where('token_hash', $hash)
                    ->lockForUpdate()
                    ->first();

                if ($purchase !== null && (int) $purchase->user_id !== (int) $user->id) {
                    return null;
                }

                // คืนเงิน/เพิกถอนแล้ว → ไม่เปิดสิทธิ์กลับจากการส่งหลักฐานเดิมซ้ำ
                if ($purchase !== null && in_array($purchase->status, [ThemePurchase::REFUNDED, ThemePurchase::REVOKED], true)) {
                    return $purchase;
                }

                $purchase ??= new ThemePurchase([
                    'user_id' => $user->id,
                    'theme_id' => $theme->id,
                    'provider' => $provider,
                    'product_id' => $productId,
                    'token_hash' => $hash,
                    'purchase_token' => $token,
                ]);

                $purchase->fill([
                    'order_id' => $check->orderId ?? $purchase->order_id,
                    'environment' => $check->environment,
                    'status' => $status,
                    'purchased_at' => $status === ThemePurchase::PURCHASED
                        ? ($purchase->purchased_at ?? ($check->purchaseTimeMs ? now()->setTimestamp(intdiv($check->purchaseTimeMs, 1000)) : now()))
                        : $purchase->purchased_at,
                    'acknowledged_at' => $check->acknowledged ? ($purchase->acknowledged_at ?? now()) : $purchase->acknowledged_at,
                    'verified_at' => now(),
                    'raw' => $check->raw,
                ])->save();

                if ($status === ThemePurchase::PURCHASED) {
                    $this->grant($purchase, $provider === 'test' ? 'test' : 'purchase');
                } elseif ($status === ThemePurchase::CANCELLED) {
                    $this->revokeEntitlementOf($purchase, 'cancelled');
                }

                return $purchase;
            });
        } catch (UniqueConstraintViolationException) {
            // อีกคำขอบันทึก token เดียวกันพร้อมกัน → อ่านผลที่บันทึกแล้ว
            $purchase = ThemePurchase::query()->where('provider', $provider)->where('token_hash', $hash)->first();

            return $purchase !== null && (int) $purchase->user_id === (int) $user->id ? $purchase : null;
        }
    }

    private function grant(ThemePurchase $purchase, string $source): void
    {
        $entitlement = ThemeEntitlement::query()
            ->where('user_id', $purchase->user_id)
            ->where('theme_id', $purchase->theme_id)
            ->lockForUpdate()
            ->first();

        if ($entitlement === null) {
            ThemeEntitlement::query()->create([
                'user_id' => $purchase->user_id,
                'theme_id' => $purchase->theme_id,
                'purchase_id' => $purchase->id,
                'source' => $source,
                'granted_at' => now(),
            ]);

            return;
        }

        if ($entitlement->revoked_at !== null || $entitlement->purchase_id === null) {
            $entitlement->update([
                'purchase_id' => $purchase->id,
                'source' => $source,
                'granted_at' => now(),
                'revoked_at' => null,
                'revoke_reason' => null,
            ]);
        }
    }

    private function revokeEntitlementOf(ThemePurchase $purchase, string $reason): void
    {
        ThemeEntitlement::query()
            ->where('user_id', $purchase->user_id)
            ->where('theme_id', $purchase->theme_id)
            ->where('purchase_id', $purchase->id)
            ->whereNull('revoked_at')
            ->update(['revoked_at' => now(), 'revoke_reason' => $reason]);
    }

    private function acknowledge(ThemePurchase $purchase, ThemeBillingProvider $provider, bool $already): void
    {
        $ok = $already;

        if (!$ok) {
            try {
                $ok = $provider->acknowledge($purchase->product_id, $purchase->purchase_token);
            } catch (BillingUnavailable $e) {
                Log::warning('Theme purchase acknowledge failed', ['purchase' => $purchase->id, 'error' => $e->getMessage()]);
            }
        }

        if ($ok) {
            $purchase->forceFill(['acknowledged_at' => now()])->save();
        }
    }

    // ลองจบธุรกรรมที่ยังค้าง (เช่น ติดต่อ Google ไม่ได้ตอนซื้อ) — เรียกจาก themes:check-voided
    public function retryAcknowledgements(): int
    {
        $done = 0;

        ThemePurchase::query()
            ->where('status', ThemePurchase::PURCHASED)
            ->whereNull('acknowledged_at')
            ->where('created_at', '>=', now()->subDays(3))
            ->each(function (ThemePurchase $purchase) use (&$done) {
                $provider = $this->provider($purchase->provider);

                if ($provider !== null) {
                    $this->acknowledge($purchase, $provider, false);
                    $done += $purchase->acknowledged_at !== null ? 1 : 0;
                }
            });

        return $done;
    }

    // =====================================================
    // เหตุการณ์จากผู้ให้บริการ (RTDN / voided purchases / จำลอง)
    // eventKey ไม่ซ้ำ → รับซ้ำกี่ครั้งก็ประมวลผลครั้งเดียว
    // type: purchased / cancelled / voided
    // =====================================================

    public function handleEvent(string $providerName, string $eventKey, string $type, string $token, array $payload = [], ?string $productId = null): string
    {
        $hash = ThemePurchase::hashToken($token);

        try {
            $event = ThemeBillingEvent::query()->create([
                'provider' => $providerName,
                'event_key' => substr($eventKey, 0, 191),
                'type' => $type,
                'token_hash' => $hash,
                'payload' => $payload,
            ]);
        } catch (UniqueConstraintViolationException) {
            return 'duplicate';
        }

        $result = $this->processEvent($providerName, $type, $token, $hash, $payload, $productId);

        $event->update(['result' => $result, 'processed_at' => now()]);

        return $result;
    }

    private function processEvent(string $providerName, string $type, string $token, string $hash, array $payload, ?string $productId): string
    {
        $purchase = ThemePurchase::query()->where('provider', $providerName)->where('token_hash', $hash)->first();

        // คืนเงิน / ชาร์จแบ็ก / เพิกถอน (voided = ผลสุดท้ายจากผู้ให้บริการ)
        if ($type === 'voided') {
            if ($purchase === null) {
                return 'unknown_purchase';
            }

            $reason = (int) ($payload['voidedReason'] ?? -1) === 7 ? 'chargeback' : ((int) ($payload['voidedSource'] ?? -1) === 2 ? 'revoked' : 'refunded');

            $this->revoke($purchase, $reason === 'revoked' ? ThemePurchase::REVOKED : ThemePurchase::REFUNDED, $reason);

            return 'revoked';
        }

        $provider = $this->provider($providerName);

        if ($provider === null) {
            return 'provider_disabled';
        }

        // หาเจ้าของ: จากธุรกรรมที่มี หรือรหัสบัญชีที่แอปผูกไว้ตอนซื้อ (กรณีแอปปิดก่อนแจ้งเซิร์ฟเวอร์)
        $productId ??= $purchase?->product_id;

        if ($productId === null) {
            return 'unknown_product';
        }

        try {
            $check = $provider->check($productId, $token);
        } catch (BillingUnavailable) {
            return 'unavailable';
        }

        $userId = $purchase?->user_id ?? $this->userIdFromAccountRef($check->accountRef);
        $user = $userId ? User::query()->find($userId) : null;
        $theme = $purchase?->theme ?? Theme::query()->whereHas('products', fn ($q) => $q->where('provider', $providerName)->where('product_id', $productId))->first();

        if ($user === null || $theme === null) {
            return 'unknown_owner';
        }

        if ($check->state === BillingCheck::CANCELLED && $purchase !== null && $purchase->status === ThemePurchase::PURCHASED) {
            $this->revoke($purchase, ThemePurchase::REVOKED, 'cancelled');

            return 'revoked';
        }

        [$http] = $this->verify($user, $theme, $providerName, $token);

        return 'verified_' . $http;
    }

    public function revoke(ThemePurchase $purchase, string $status, string $reason): void
    {
        DB::transaction(function () use ($purchase, $status, $reason) {
            $purchase->forceFill([
                'status' => $status,
                'revoked_at' => $purchase->revoked_at ?? now(),
                'revoke_reason' => $reason,
            ])->save();

            $this->revokeEntitlementOf($purchase, $reason);
        });
    }

    // =====================================================
    // ข้อมูลส่งให้แอป
    // =====================================================

    public function entitlementPayload(ThemeEntitlement $entitlement): array
    {
        return [
            'theme' => $entitlement->theme?->slug,
            'source' => $entitlement->source,
            'granted_at' => $entitlement->granted_at?->toIso8601String(),
            'revoked_at' => $entitlement->revoked_at?->toIso8601String(),
            'revoke_reason' => $entitlement->revoke_reason,
            'active' => $entitlement->revoked_at === null,
        ];
    }

    private function fail(int $http, string $code, string $message): array
    {
        return [$http, ['status' => false, 'code' => $code, 'message' => $message]];
    }
}
