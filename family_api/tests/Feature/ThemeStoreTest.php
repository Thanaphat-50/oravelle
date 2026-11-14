<?php

namespace Tests\Feature;

use App\Models\Theme;
use App\Models\ThemeBillingEvent;
use App\Models\ThemeEntitlement;
use App\Models\ThemePurchase;
use App\Models\User;
use App\Services\Themes\ThemePurchases;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request as HttpRequest;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

// ร้านธีม: แค็ตตาล็อก / ชุดไฟล์ / สิทธิ์ / ซื้อจำลอง / Google Play (ปลอมด้วย Http::fake) / RTDN / คืนเงิน
// ฐานข้อมูลทดสอบแยก — ไม่เรียก Google จริง ไม่เก็บเงินจริง
class ThemeStoreTest extends TestCase
{
    use RefreshDatabase;

    private const PLAY = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/com.familyorbit.app/purchases/';

    protected function setUp(): void
    {
        parent::setUp();

        Http::preventStrayRequests();
    }

    private function enableTestMode(): void
    {
        config(['themes.test_purchases' => true, 'themes.billing' => 'none']);
    }

    private function testToken(User $user, string $slug, string $outcome = 'purchased'): string
    {
        Sanctum::actingAs($user);

        return $this->postJson("/api/themes/{$slug}/test-purchase", ['outcome' => $outcome])
            ->assertOk()
            ->json('purchase_token');
    }

    private function verify(User $user, string $slug, string $token, string $provider = 'test')
    {
        Sanctum::actingAs($user);

        return $this->postJson("/api/themes/{$slug}/purchases", ['provider' => $provider, 'purchase_token' => $token]);
    }

    private function theme(string $slug): Theme
    {
        return Theme::query()->where('slug', $slug)->firstOrFail();
    }

    public function test_catalog_lists_free_and_paid_themes_without_sale_by_default(): void
    {
        $user = User::factory()->create();
        Sanctum::actingAs($user);

        $response = $this->getJson('/api/themes')->assertOk();

        $themes = collect($response->json('themes'))->keyBy('slug');

        $this->assertSame(['lavender-original', 'ocean-blue', 'matcha-garden', 'cosmic-orbit'], $themes->keys()->all());
        $this->assertTrue($themes['lavender-original']['owned']);
        $this->assertFalse($themes['ocean-blue']['owned']);
        $this->assertFalse($themes['cosmic-orbit']['supports_light']);
        $this->assertSame(1, $themes['matcha-garden']['version']);
        $this->assertNull($response->json('billing.provider'));
        $this->assertNull($themes['ocean-blue']['test_price']);
        $this->assertStringStartsWith('u' . $user->id . '.', $response->json('billing.account_ref'));
    }

    public function test_pack_trial_is_open_but_use_needs_entitlement_and_files_are_signed(): void
    {
        $user = User::factory()->create();
        Sanctum::actingAs($user);

        $this->getJson('/api/themes/ocean-blue/pack')->assertForbidden()->assertJsonPath('code', 'not_owned');
        $this->getJson('/api/themes/lavender-original/pack')->assertStatus(422)->assertJsonPath('code', 'built_in');

        $pack = $this->getJson('/api/themes/cosmic-orbit/pack?purpose=trial')->assertOk()->json('pack');

        $this->assertSame('cosmic-orbit', $pack['slug']);
        $this->assertNotEmpty($pack['assets']);

        $asset = collect($pack['assets'])->firstWhere('path', 'icons/nav_home.png');
        $file = $this->get($asset['url'])->assertOk();
        $this->assertSame('image/png', $file->headers->get('Content-Type'));
        $this->assertSame($asset['sha256'], hash('sha256', $file->streamedContent()));

        // ลิงก์ไม่มีลายเซ็น / ลายเซ็นปลอม / ไฟล์นอกชุดธีม
        $version = $this->theme('cosmic-orbit')->currentVersion();
        $this->get("/api/theme-files/{$version->id}/icons/nav_home.png")->assertForbidden();
        $this->get($asset['url'] . 'x')->assertForbidden();
        $this->get("/api/theme-files/{$version->id}/../../../.env")->assertNotFound();
    }

    public function test_test_purchase_grants_once_and_cannot_be_reused_by_another_account(): void
    {
        $this->enableTestMode();
        $buyer = User::factory()->create();
        $other = User::factory()->create();

        $token = $this->testToken($buyer, 'ocean-blue');

        $this->verify($buyer, 'ocean-blue', $token)->assertOk()
            ->assertJsonPath('purchase_status', 'purchased')
            ->assertJsonPath('entitlement.active', true)
            ->assertJsonPath('acknowledged', true);

        // ส่งซ้ำ → ผลเดิม ไม่มีแถวซ้ำ
        $this->verify($buyer, 'ocean-blue', $token)->assertOk();
        $this->assertSame(1, ThemePurchase::query()->count());
        $this->assertSame(1, ThemeEntitlement::query()->count());

        // บัญชีอื่นเอาหลักฐานเดียวกันมาใช้ไม่ได้
        $this->verify($other, 'ocean-blue', $token)->assertStatus(409)->assertJsonPath('code', 'purchase_other_account');
        $this->assertSame(0, ThemeEntitlement::query()->where('user_id', $other->id)->count());

        Sanctum::actingAs($buyer);
        $this->getJson('/api/themes/ocean-blue/pack')->assertOk();
        $owned = collect($this->getJson('/api/themes')->json('themes'))->firstWhere('slug', 'ocean-blue');
        $this->assertTrue($owned['owned']);
        $this->assertSame(19, $owned['test_price']['amount']);
    }

    public function test_pending_cancelled_and_forged_proofs_do_not_unlock(): void
    {
        $this->enableTestMode();
        $user = User::factory()->create();

        $pending = $this->testToken($user, 'matcha-garden', 'pending');
        $this->verify($user, 'matcha-garden', $pending)->assertStatus(202)
            ->assertJsonPath('purchase_status', 'pending')
            ->assertJsonPath('entitlement', null);

        $cancelled = $this->testToken($user, 'matcha-garden', 'cancelled');
        $this->verify($user, 'matcha-garden', $cancelled)->assertStatus(202)->assertJsonPath('purchase_status', 'cancelled');

        // แก้ข้อมูลในหลักฐาน / ใช้หลักฐานของธีมอื่น
        $good = $this->testToken($user, 'ocean-blue');
        [$prefix, $body, $sig] = explode('.', $good);
        $this->verify($user, 'matcha-garden', $prefix . '.' . $body . 'x.' . $sig)->assertStatus(422)->assertJsonPath('code', 'invalid_purchase');
        $this->verify($user, 'matcha-garden', $good)->assertStatus(422)->assertJsonPath('code', 'invalid_purchase');
        $this->verify($user, 'matcha-garden', 'made-up-token')->assertStatus(422);

        $this->assertSame(0, ThemeEntitlement::query()->count());
    }

    public function test_pending_purchase_completes_later_and_refund_revokes_with_reason(): void
    {
        $this->enableTestMode();
        $user = User::factory()->create();

        $token = $this->testToken($user, 'cosmic-orbit', 'pending');
        $this->verify($user, 'cosmic-orbit', $token)->assertStatus(202);

        $purchase = ThemePurchase::query()->firstOrFail();

        // ชำระสำเร็จภายหลัง (แอปปิดไปแล้ว) → ให้สิทธิ์จากเหตุการณ์ของผู้ให้บริการ
        $this->artisan('themes:test-event', ['purchase' => $purchase->id, 'event' => 'complete'])->assertSuccessful();
        $this->assertTrue(ThemeEntitlement::query()->where('user_id', $user->id)->firstOrFail()->isActive());

        // คืนเงิน → เพิกถอน + เหตุผล / ส่งหลักฐานเดิมซ้ำไม่เปิดคืน
        $this->artisan('themes:test-event', ['purchase' => $purchase->id, 'event' => 'refund'])->assertSuccessful();

        $entitlement = ThemeEntitlement::query()->firstOrFail();
        $this->assertNotNull($entitlement->revoked_at);
        $this->assertSame('refunded', $entitlement->revoke_reason);
        $this->assertSame(ThemePurchase::REFUNDED, $purchase->fresh()->status);

        $this->verify($user, 'cosmic-orbit', $token)->assertStatus(202)->assertJsonPath('purchase_status', 'refunded');
        $this->assertNotNull($entitlement->fresh()->revoked_at);

        Sanctum::actingAs($user);
        $this->getJson('/api/themes/cosmic-orbit/pack')->assertForbidden();
        $row = collect($this->getJson('/api/themes')->json('themes'))->firstWhere('slug', 'cosmic-orbit');
        $this->assertFalse($row['owned']);
        $this->assertSame('refunded', $row['entitlement']['revoke_reason']);
    }

    public function test_duplicate_provider_event_is_processed_once(): void
    {
        $this->enableTestMode();
        $user = User::factory()->create();
        $token = $this->testToken($user, 'ocean-blue');
        $this->verify($user, 'ocean-blue', $token)->assertOk();

        $service = app(ThemePurchases::class);

        $this->assertSame('revoked', $service->handleEvent('test', 'evt-1', 'voided', $token));
        $this->assertSame('duplicate', $service->handleEvent('test', 'evt-1', 'voided', $token));
        $this->assertSame(1, ThemeBillingEvent::query()->count());
    }

    public function test_test_mode_never_runs_in_production(): void
    {
        config(['themes.test_purchases' => true]);
        $this->app['env'] = 'production';

        $user = User::factory()->create();
        Sanctum::actingAs($user);

        $this->assertNull($this->getJson('/api/themes')->json('billing.provider'));
        $this->postJson('/api/themes/ocean-blue/test-purchase', ['outcome' => 'purchased'])->assertNotFound();
        $this->postJson('/api/themes/ocean-blue/purchases', ['provider' => 'test', 'purchase_token' => 'x'])
            ->assertStatus(409)->assertJsonPath('code', 'billing_unavailable');
    }

    // =====================================================
    // Google Play (ปลอม)
    // =====================================================

    private function enableGooglePlay(): void
    {
        config([
            'themes.billing' => 'google_play',
            'themes.google_play.service_account' => base64_encode(json_encode([
                'client_email' => 'billing@test.iam.gserviceaccount.com',
                'private_key' => 'unused-cached-token',
            ])),
            'themes.google_play.rtdn_token' => 'rtdn-secret',
        ]);

        Cache::put('google-sa-token:' . sha1('billing@test.iam.gserviceaccount.com|https://www.googleapis.com/auth/androidpublisher'), 'access-token', 600);
    }

    // คำตอบปลอมของ Google Play (เปลี่ยนได้ระหว่างเทสต์ — Http::fake ลงทะเบียนครั้งเดียว)
    private array $play = [[], 200, []];

    private bool $playFaked = false;

    private function fakePlay(array $purchase, int $status = 200, array $voided = []): void
    {
        $this->play = [$purchase, $status, $voided];

        if ($this->playFaked) {
            return;
        }

        $this->playFaked = true;

        Http::fake(function (HttpRequest $request) {
            [$purchase, $status, $voided] = $this->play;

            if (str_ends_with($request->url(), ':acknowledge')) {
                return Http::response('', 204);
            }

            if (str_contains($request->url(), '/voidedpurchases')) {
                return Http::response(['voidedPurchases' => $voided]);
            }

            return Http::response($purchase, $status);
        });
    }

    public function test_google_play_purchase_is_verified_bound_to_account_and_acknowledged(): void
    {
        $this->enableGooglePlay();
        $user = User::factory()->create();
        $ref = app(ThemePurchases::class)->accountRef($user->id);

        $this->fakePlay(['purchaseState' => 0, 'acknowledgementState' => 0, 'orderId' => 'GPA.1', 'obfuscatedExternalAccountId' => $ref]);

        $this->verify($user, 'matcha-garden', 'play-token-1', 'google_play')->assertOk()
            ->assertJsonPath('purchase_status', 'purchased')
            ->assertJsonPath('acknowledged', true);

        Http::assertSent(fn (HttpRequest $r) => $r->url() === self::PLAY . 'products/theme_matcha_garden/tokens/play-token-1:acknowledge');
        $this->assertSame('production', ThemePurchase::query()->firstOrFail()->environment);
    }

    public function test_google_play_rejects_pending_other_account_and_sandbox_in_production(): void
    {
        $this->enableGooglePlay();
        $user = User::factory()->create();
        $other = User::factory()->create();
        $service = app(ThemePurchases::class);

        $this->fakePlay(['purchaseState' => 2, 'obfuscatedExternalAccountId' => $service->accountRef($user->id)]);
        $this->verify($user, 'ocean-blue', 'pending-token', 'google_play')->assertStatus(202)->assertJsonPath('entitlement', null);

        $this->fakePlay(['purchaseState' => 0, 'obfuscatedExternalAccountId' => $service->accountRef($other->id)]);
        $this->verify($user, 'ocean-blue', 'others-token', 'google_play')->assertStatus(409);

        $this->app['env'] = 'production';
        $this->fakePlay(['purchaseState' => 0, 'purchaseType' => 0, 'obfuscatedExternalAccountId' => $service->accountRef($user->id)]);
        $this->verify($user, 'ocean-blue', 'sandbox-token', 'google_play')->assertStatus(422)->assertJsonPath('code', 'sandbox_not_accepted');

        config(['themes.accept_sandbox' => true]);
        $this->verify($user, 'ocean-blue', 'sandbox-token', 'google_play')->assertOk();
        $this->assertSame('sandbox', ThemePurchase::query()->where('status', 'purchased')->firstOrFail()->environment);

        $this->fakePlay([], 404);
        $this->verify($user, 'matcha-garden', 'fake-token', 'google_play')->assertStatus(422);

        $this->fakePlay([], 500);
        $this->verify($user, 'matcha-garden', 'later-token', 'google_play')->assertStatus(503)->assertJsonPath('code', 'verify_unavailable');
        $this->assertNull(ThemePurchase::query()->where('token_hash', hash('sha256', 'later-token'))->first());
    }

    public function test_rtdn_grants_after_app_closed_ignores_duplicates_and_revokes_on_cancel(): void
    {
        $this->enableGooglePlay();
        $user = User::factory()->create();
        $ref = app(ThemePurchases::class)->accountRef($user->id);

        $message = fn (string $id, int $type) => ['message' => [
            'messageId' => $id,
            'data' => base64_encode(json_encode([
                'packageName' => 'com.familyorbit.app',
                'oneTimeProductNotification' => ['notificationType' => $type, 'purchaseToken' => 'closed-app-token', 'sku' => 'theme_cosmic_orbit'],
            ])),
        ]];

        $this->postJson('/api/billing/google/rtdn/wrong', $message('m1', 1))->assertForbidden();

        $this->fakePlay(['purchaseState' => 0, 'acknowledgementState' => 0, 'obfuscatedExternalAccountId' => $ref]);
        $this->postJson('/api/billing/google/rtdn/rtdn-secret', $message('m1', 1))->assertNoContent();
        $this->postJson('/api/billing/google/rtdn/rtdn-secret', $message('m1', 1))->assertNoContent();

        $this->assertTrue(ThemeEntitlement::query()->where('user_id', $user->id)->firstOrFail()->isActive());
        $this->assertSame(1, ThemeBillingEvent::query()->count());

        $this->fakePlay(['purchaseState' => 1, 'obfuscatedExternalAccountId' => $ref]);
        $this->postJson('/api/billing/google/rtdn/rtdn-secret', $message('m2', 2))->assertNoContent();

        $this->assertNotNull(ThemeEntitlement::query()->firstOrFail()->revoked_at);
    }

    public function test_voided_purchases_command_revokes_chargebacks(): void
    {
        $this->enableGooglePlay();
        $user = User::factory()->create();
        $ref = app(ThemePurchases::class)->accountRef($user->id);

        $this->fakePlay(['purchaseState' => 0, 'acknowledgementState' => 1, 'obfuscatedExternalAccountId' => $ref]);
        $this->verify($user, 'ocean-blue', 'cb-token', 'google_play')->assertOk();

        $this->fakePlay([], 200, [['purchaseToken' => 'cb-token', 'voidedTimeMillis' => '1700000000000', 'voidedSource' => 0, 'voidedReason' => 7]]);
        $this->artisan('themes:check-purchases')->assertSuccessful();
        $this->artisan('themes:check-purchases')->assertSuccessful();

        $entitlement = ThemeEntitlement::query()->firstOrFail();
        $this->assertSame('chargeback', $entitlement->revoke_reason);
        $this->assertSame(1, ThemeBillingEvent::query()->count());
    }

    public function test_restore_reverifies_purchases_for_this_account(): void
    {
        $this->enableTestMode();
        $user = User::factory()->create();
        $token = $this->testToken($user, 'matcha-garden');

        Sanctum::actingAs($user);
        $response = $this->postJson('/api/themes/purchases/restore', ['purchases' => [
            ['provider' => 'test', 'product_id' => 'test_theme_matcha_garden', 'purchase_token' => $token],
            ['provider' => 'test', 'product_id' => 'unknown_product', 'purchase_token' => 'x'],
        ]])->assertOk();

        $this->assertSame('matcha-garden', $response->json('entitlements.0.theme'));
        $this->assertSame('unknown_product', $response->json('results.1.code'));
    }
}
