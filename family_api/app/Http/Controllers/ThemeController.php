<?php

namespace App\Http\Controllers;

use App\Models\Theme;
use App\Models\ThemeEntitlement;
use App\Models\ThemeVersion;
use App\Services\Themes\TestBilling;
use App\Services\Themes\ThemeCatalog;
use App\Services\Themes\ThemePurchases;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\URL;
use Symfony\Component\HttpFoundation\BinaryFileResponse;

// =======================================================
// ร้านธีม / ธีมของฉัน / ชุดไฟล์ธีม / ตรวจการซื้อ
// - ราคาที่แสดงตอนซื้อจริงมาจาก Google Play (แอปถาม Play เอง) ไม่ได้มาจากเซิร์ฟเวอร์นี้
// - โหมดทดสอบ (test) ใช้ราคาเป้าหมายจากแค็ตตาล็อก และไม่เก็บเงินจริง
// =======================================================

class ThemeController extends Controller
{
    public function __construct(private readonly ThemePurchases $purchases)
    {
    }

    // GET /api/themes — แค็ตตาล็อก + สิทธิ์ของบัญชีนี้ + ช่องทางซื้อที่เปิดอยู่
    public function index(Request $request): JsonResponse
    {
        $user = $request->user();

        $provider = $this->purchases->activeProviderName();

        $entitlements = ThemeEntitlement::query()->where('user_id', $user->id)->get()->keyBy('theme_id');

        $themes = Theme::query()
            ->where('status', 'active')
            ->with(['products', 'versions'])
            ->orderBy('sort_order')
            ->get()
            ->map(function (Theme $theme) use ($entitlements, $provider) {
                $version = $theme->versions->firstWhere('version', $theme->current_version);
                $entitlement = $entitlements->get($theme->id);

                return [
                    'slug' => $theme->slug,
                    'name' => $theme->name,
                    'description' => $theme->description,
                    'category' => $theme->category,
                    'is_free' => $theme->is_free,
                    'supports_light' => $theme->supports_light,
                    'supports_dark' => $theme->supports_dark,
                    'changes' => $theme->changes ?? [],
                    'previews' => collect($theme->previews ?? [])->map(fn (string $name) => [
                        'name' => $name,
                        'url' => route('themes.preview', ['slug' => $theme->slug, 'name' => $name]),
                    ])->values(),
                    'version' => $version?->version,
                    'min_app_build' => $version?->min_app_build,
                    'pack_bytes' => $version?->total_bytes,
                    'product_id' => $provider ? $theme->productId($provider) : null,
                    // ราคาเฉพาะโหมดทดสอบ (ของจริงแสดงราคาจาก Google Play)
                    'test_price' => $provider === 'test' && !$theme->is_free && $theme->target_price_thb
                        ? ['amount' => $theme->target_price_thb, 'currency' => 'THB', 'formatted' => '฿' . $theme->target_price_thb]
                        : null,
                    'owned' => $theme->is_free || ($entitlement?->revoked_at === null && $entitlement !== null),
                    'entitlement' => $entitlement ? $this->purchases->entitlementPayload($entitlement) : null,
                ];
            });

        return response()->json([
            'status' => true,
            'billing' => [
                'provider' => $provider,
                'test_mode' => $provider === 'test',
                'account_ref' => $this->purchases->accountRef((int) $user->id),
            ],
            'offline_grace_days' => (int) config('themes.offline_grace_days'),
            'checked_at' => now()->toIso8601String(),
            'themes' => $themes,
        ]);
    }

    // GET /api/themes/mine — สิทธิ์ของบัญชีนี้ (รวมที่ถูกเพิกถอนพร้อมเหตุผล)
    public function mine(Request $request): JsonResponse
    {
        $entitlements = ThemeEntitlement::query()
            ->where('user_id', $request->user()->id)
            ->with('theme')
            ->get()
            ->map(fn (ThemeEntitlement $e) => $this->purchases->entitlementPayload($e))
            ->values();

        return response()->json(['status' => true, 'entitlements' => $entitlements]);
    }

    // GET /api/themes/{slug}/pack?purpose=use|trial
    // use: ต้องมีสิทธิ์ / trial: ลองธีมได้ทุกคน (ไม่ใช่สิทธิ์ แอปไม่บันทึกเป็นธีมที่ใช้)
    public function pack(Request $request, Theme $theme): JsonResponse
    {
        $purpose = $request->query('purpose') === 'trial' ? 'trial' : 'use';

        if ($theme->status !== 'active') {
            abort(404);
        }

        $version = $theme->currentVersion();

        if ($version === null) {
            return response()->json([
                'status' => false,
                'code' => 'built_in',
                'message' => 'ธีมนี้อยู่ในแอปแล้ว ไม่ต้องดาวน์โหลด',
            ], 422);
        }

        if ($purpose === 'use' && !$theme->is_free && !$this->owns($request->user()->id, $theme)) {
            return response()->json([
                'status' => false,
                'code' => 'not_owned',
                'message' => 'บัญชีนี้ยังไม่มีสิทธิ์ใช้ธีมนี้',
            ], 403);
        }

        $expires = now()->addMinutes((int) config('themes.file_link_minutes'));

        $manifest = $version->manifest;

        $manifest['assets'] = collect($manifest['assets'] ?? [])->map(fn (array $asset) => $asset + [
            'url' => URL::temporarySignedRoute('themes.file', $expires, [
                'version' => $version->id,
                'path' => $asset['path'],
            ]),
        ])->values()->all();

        return response()->json([
            'status' => true,
            'purpose' => $purpose,
            'pack' => $manifest,
            'total_bytes' => $version->total_bytes,
        ]);
    }

    // POST /api/themes/{slug}/purchases {provider, purchase_token}
    public function verifyPurchase(Request $request, Theme $theme): JsonResponse
    {
        $data = $request->validate([
            'provider' => ['required', 'in:google_play,test'],
            'purchase_token' => ['required', 'string', 'max:4096'],
        ]);

        [$http, $body] = $this->purchases->verify($request->user(), $theme, $data['provider'], $data['purchase_token']);

        return response()->json($body, $http);
    }

    // POST /api/themes/purchases/restore {purchases: [{provider, product_id, purchase_token}]}
    // กู้คืนการซื้อ / ส่งการซื้อที่ค้าง (เช่น แอปปิดหลังชำระเงิน)
    public function restore(Request $request): JsonResponse
    {
        $data = $request->validate([
            'purchases' => ['present', 'array', 'max:20'],
            'purchases.*.provider' => ['required', 'in:google_play,test'],
            'purchases.*.product_id' => ['required', 'string', 'max:100'],
            'purchases.*.purchase_token' => ['required', 'string', 'max:4096'],
        ]);

        $results = [];

        foreach ($data['purchases'] as $item) {
            $theme = Theme::query()->whereHas('products', fn ($q) => $q
                ->where('provider', $item['provider'])
                ->where('product_id', $item['product_id']))->first();

            if ($theme === null) {
                $results[] = ['product_id' => $item['product_id'], 'status' => false, 'code' => 'unknown_product'];

                continue;
            }

            [$http, $body] = $this->purchases->verify($request->user(), $theme, $item['provider'], $item['purchase_token']);

            $results[] = ['product_id' => $item['product_id'], 'theme' => $theme->slug, 'http' => $http] + $body;
        }

        $entitlements = ThemeEntitlement::query()
            ->where('user_id', $request->user()->id)
            ->with('theme')
            ->get()
            ->map(fn (ThemeEntitlement $e) => $this->purchases->entitlementPayload($e))
            ->values();

        return response()->json(['status' => true, 'results' => $results, 'entitlements' => $entitlements]);
    }

    // POST /api/themes/{slug}/test-purchase {outcome} — โหมดทดสอบเท่านั้น (ไม่เก็บเงินจริง)
    public function testPurchase(Request $request, Theme $theme, TestBilling $test): JsonResponse
    {
        if (!$test->enabled()) {
            abort(404);
        }

        $data = $request->validate(['outcome' => ['required', 'in:' . implode(',', TestBilling::OUTCOMES)]]);

        $productId = $theme->loadMissing('products')->productId('test');

        if ($theme->is_free || $productId === null) {
            return response()->json(['status' => false, 'code' => 'not_for_sale', 'message' => 'ธีมนี้ไม่ได้ขาย'], 422);
        }

        return response()->json([
            'status' => true,
            'provider' => 'test',
            'product_id' => $productId,
            'purchase_token' => $test->issue((int) $request->user()->id, $productId, $data['outcome']),
        ]);
    }

    // GET /theme-files/{version}/{path} — ลิงก์ลงลายเซ็นชั่วคราวจาก pack
    public function file(ThemeVersion $version, string $path): BinaryFileResponse
    {
        $theme = $version->theme;

        $file = $theme ? ThemeCatalog::assetFile($theme->slug, (int) $version->version, $path) : null;

        if ($file === null) {
            abort(404);
        }

        $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));

        return response()->file($file, [
            'Content-Type' => ThemeCatalog::MIME[$ext] ?? 'application/octet-stream',
            'Cache-Control' => 'private, max-age=3600',
            'X-Content-Type-Options' => 'nosniff',
        ]);
    }

    // GET /theme-previews/{slug}/{name} — ภาพตัวอย่างในร้านธีม (ดูได้โดยไม่ต้องมีสิทธิ์)
    public function preview(string $slug, string $name): BinaryFileResponse
    {
        $file = ThemeCatalog::previewFile($slug, $name);

        if ($file === null) {
            abort(404);
        }

        return response()->file($file, [
            'Content-Type' => 'image/webp',
            'Cache-Control' => 'public, max-age=86400',
            'X-Content-Type-Options' => 'nosniff',
        ]);
    }

    private function owns(int $userId, Theme $theme): bool
    {
        return ThemeEntitlement::query()
            ->where('user_id', $userId)
            ->where('theme_id', $theme->id)
            ->whereNull('revoked_at')
            ->exists();
    }
}
