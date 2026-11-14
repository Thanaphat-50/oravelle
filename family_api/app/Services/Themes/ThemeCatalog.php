<?php

namespace App\Services\Themes;

use App\Models\Theme;
use App\Models\ThemeProduct;
use App\Models\ThemeVersion;
use Illuminate\Support\Facades\DB;
use RuntimeException;

// =======================================================
// แค็ตตาล็อกธีม + ชุดไฟล์ธีม (อยู่ใน resources/themes ไปกับโค้ด ไม่ต้องใช้ Bucket)
//
// - catalog.json: ชื่อ คำอธิบาย หมวด ราคาเป้าหมาย สิ่งที่เปลี่ยน รหัสสินค้าแต่ละช่องทาง เวอร์ชัน
// - packs/<slug>/v<version>/pack.json + ไฟล์ภาพ (สร้างด้วย tools/theme_packs/make_packs.py)
// - sync(): ตรวจไฟล์ทุกไฟล์ (มีอยู่จริง / ขนาด / sha256 / ชนิด) ก่อนบันทึกเวอร์ชัน — ชุดไหนเสียไม่เปิดให้ดาวน์โหลด
// - ชุดธีมเป็นข้อมูลและภาพเท่านั้น ไม่มีโค้ดให้แอปรัน
// =======================================================

class ThemeCatalog
{
    public const FORMAT = 1;

    public const SLUG_PATTERN = '/^[a-z0-9][a-z0-9\-]{1,48}$/';

    public const ASSET_PATTERN = '/^[a-z0-9_\-]+(\/[a-z0-9_\-]+)*\.(png|webp|jpg)$/';

    public const MIME = ['png' => 'image/png', 'webp' => 'image/webp', 'jpg' => 'image/jpeg'];

    public const PREVIEWS = ['feed', 'chat', 'shop', 'profile', 'activity', 'map'];

    public static function basePath(): string
    {
        return resource_path('themes');
    }

    public static function packDir(string $slug, int $version): string
    {
        return self::basePath() . "/packs/{$slug}/v{$version}";
    }

    public static function previewDir(string $slug): string
    {
        return self::basePath() . "/previews/{$slug}";
    }

    // path ของไฟล์ในชุดธีม (null = ชื่อไม่ถูกรูปแบบ / อยู่นอกโฟลเดอร์ / ไม่มีไฟล์)
    public static function assetFile(string $slug, int $version, string $path): ?string
    {
        if (!preg_match(self::ASSET_PATTERN, $path) || !preg_match(self::SLUG_PATTERN, $slug)) {
            return null;
        }

        $dir = realpath(self::packDir($slug, $version));
        $file = realpath(self::packDir($slug, $version) . '/' . $path);

        if ($dir === false || $file === false || !is_file($file)) {
            return null;
        }

        // กันไฟล์นอกโฟลเดอร์ชุดธีม (เช่น ลิงก์ที่ชี้ออกไปข้างนอก)
        return str_starts_with($file, $dir . DIRECTORY_SEPARATOR) ? $file : null;
    }

    public static function previewFile(string $slug, string $name): ?string
    {
        if (!in_array($name, self::PREVIEWS, true) || !preg_match(self::SLUG_PATTERN, $slug)) {
            return null;
        }

        $file = self::previewDir($slug) . "/{$name}.webp";

        return is_file($file) ? $file : null;
    }

    // =====================================================
    // อ่าน + ตรวจ pack.json ของเวอร์ชันหนึ่ง
    // =====================================================

    public static function readPack(string $slug, int $version): array
    {
        $file = self::packDir($slug, $version) . '/pack.json';

        if (!is_file($file)) {
            throw new RuntimeException("{$slug} v{$version}: ไม่มี pack.json");
        }

        $manifest = json_decode((string) file_get_contents($file), true);

        if (!is_array($manifest)) {
            throw new RuntimeException("{$slug} v{$version}: pack.json อ่านไม่ได้");
        }

        if (($manifest['format'] ?? null) !== self::FORMAT || ($manifest['slug'] ?? null) !== $slug
            || (int) ($manifest['version'] ?? 0) !== $version) {
            throw new RuntimeException("{$slug} v{$version}: format/slug/version ไม่ตรง");
        }

        $total = 0;

        foreach ($manifest['assets'] ?? [] as $asset) {
            $path = (string) ($asset['path'] ?? '');
            $real = self::assetFile($slug, $version, $path);

            if ($real === null) {
                throw new RuntimeException("{$slug} v{$version}: ไฟล์ {$path} ไม่มีหรือชื่อไม่ถูกต้อง");
            }

            $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));

            if (filesize($real) !== (int) ($asset['size'] ?? -1)
                || hash_file('sha256', $real) !== ($asset['sha256'] ?? '')
                || (self::MIME[$ext] ?? null) !== ($asset['type'] ?? null)) {
                throw new RuntimeException("{$slug} v{$version}: ไฟล์ {$path} ไม่ตรงกับ pack.json");
            }

            $total += (int) $asset['size'];
        }

        $manifest['total_bytes'] = $total;

        return $manifest;
    }

    // =====================================================
    // themes:sync — แค็ตตาล็อกจาก resources → ฐานข้อมูล
    // รันซ้ำได้ ไม่ลบธีม/สิทธิ์/ธุรกรรมที่มีอยู่ — คืนรายการข้อผิดพลาด (ว่าง = เรียบร้อย)
    // =====================================================

    public static function sync(): array
    {
        $catalog = json_decode((string) @file_get_contents(self::basePath() . '/catalog.json'), true);

        if (!is_array($catalog['themes'] ?? null)) {
            return ['catalog.json อ่านไม่ได้'];
        }

        $errors = [];

        foreach ($catalog['themes'] as $entry) {
            $slug = (string) ($entry['slug'] ?? '');

            if (!preg_match(self::SLUG_PATTERN, $slug)
                || !in_array($entry['category'] ?? '', Theme::CATEGORIES, true)) {
                $errors[] = "ข้ามธีม {$slug}: slug/หมวดไม่ถูกต้อง";

                continue;
            }

            $version = (int) ($entry['version'] ?? 0);
            $manifest = null;

            if ($version > 0) {
                try {
                    $manifest = self::readPack($slug, $version);
                } catch (RuntimeException $e) {
                    $errors[] = $e->getMessage();
                }
            }

            $previews = array_values(array_filter(
                self::PREVIEWS,
                fn (string $name) => self::previewFile($slug, $name) !== null,
            ));

            DB::transaction(function () use ($entry, $slug, $version, $manifest, $previews) {
                $theme = Theme::query()->updateOrCreate(['slug' => $slug], [
                    'name' => (string) $entry['name'],
                    'description' => (string) $entry['description'],
                    'category' => (string) $entry['category'],
                    'is_free' => (bool) ($entry['is_free'] ?? false),
                    'target_price_thb' => $entry['target_price_thb'] ?? null,
                    'supports_light' => (bool) ($entry['supports_light'] ?? true),
                    'supports_dark' => (bool) ($entry['supports_dark'] ?? true),
                    'changes' => array_values($entry['changes'] ?? []),
                    'previews' => $previews,
                    'swatch' => array_values(array_filter(
                        $entry['swatch'] ?? [],
                        fn ($c) => is_string($c) && preg_match('/^#[0-9A-Fa-f]{6}$/', $c),
                    )),
                    'sort_order' => (int) ($entry['sort_order'] ?? 0),
                    'status' => 'active',
                ]);

                if ($manifest !== null) {
                    $total = $manifest['total_bytes'];
                    unset($manifest['total_bytes']);

                    ThemeVersion::query()->updateOrCreate(
                        ['theme_id' => $theme->id, 'version' => $version],
                        [
                            'format' => self::FORMAT,
                            'min_app_build' => (int) ($manifest['min_app_build'] ?? 1),
                            'manifest' => $manifest,
                            'total_bytes' => $total,
                        ],
                    );

                    if ($theme->current_version < $version) {
                        $theme->update(['current_version' => $version]);
                    }
                }

                foreach ($entry['products'] ?? [] as $provider => $productId) {
                    ThemeProduct::query()->updateOrCreate(
                        ['theme_id' => $theme->id, 'provider' => (string) $provider],
                        ['product_id' => (string) $productId],
                    );
                }
            });
        }

        return $errors;
    }
}
