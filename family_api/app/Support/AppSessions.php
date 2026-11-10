<?php

namespace App\Support;

use App\Models\DeviceToken;
use App\Models\User;
use Illuminate\Database\Eloquent\Relations\MorphMany;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Laravel\Sanctum\PersonalAccessToken;

// =======================================================
// เซสชันของแอป = Sanctum personal access token ชื่อ "family-app"
// (token ชื่ออื่น เช่น บัญชีบริการ ไม่นับเป็นอุปกรณ์ของผู้ใช้)
//
// - เข้าสู่ระบบ (รหัสผ่าน / สมัคร / Social) → issue() สร้าง token + ข้อมูลอุปกรณ์จากแอป
// - ข้อมูลอุปกรณ์ใช้แสดงผลเท่านั้น: ตัดอักขระควบคุม จำกัดความยาว ไม่ใช้ยืนยันตัวตน
// - เพิกถอน = ลบ token จริง (ใช้ API ไม่ได้ทันที) + ลบการผูก Push ของ token นั้น
//   (device_tokens.access_token_id ลบตาม cascade อยู่แล้ว ลบเองอีกชั้นให้ชัดเจน)
// =======================================================

class AppSessions
{
    public const TOKEN_NAME = 'family-app';

    public const PLATFORMS = ['android', 'ios'];

    // สร้างเซสชันใหม่ คืน token แบบข้อความ (ส่งให้แอปครั้งเดียว)
    public static function issue(User $user, Request $request): string
    {
        $token = $user->createToken(self::TOKEN_NAME);

        $info = self::deviceInfo($request->all());

        if ($info !== []) {
            $token->accessToken->forceFill($info)->save();
        }

        return $token->plainTextToken;
    }

    // ข้อมูลอุปกรณ์จากแอป (ไม่ส่งมา / รูปแบบไม่ถูก → ไม่เก็บค่านั้น ไม่ทำให้เข้าสู่ระบบไม่ได้)
    public static function deviceInfo(array $input): array
    {
        $platform = $input['device_platform'] ?? null;

        return array_filter([
            'device_name' => self::clean($input['device_name'] ?? null, 80),
            'device_platform' => is_string($platform) && in_array($platform, self::PLATFORMS, true) ? $platform : null,
            // เวอร์ชันระบบ/แอป: ตัวอักษร ตัวเลข ช่องว่าง และ . - _ ( ) + / เท่านั้น
            'os_version' => self::clean($input['os_version'] ?? null, 40, '/^[\p{L}\p{N} .\-_()+\/]+$/u'),
            'app_version' => self::clean($input['app_version'] ?? null, 30, '/^[\p{L}\p{N} .\-_()+\/]+$/u'),
        ], fn ($value) => $value !== null);
    }

    private static function clean(mixed $value, int $max, ?string $pattern = null): ?string
    {
        if (!is_string($value) || !mb_check_encoding($value, 'UTF-8')) {
            return null;
        }

        // อักขระควบคุม / อักขระที่มองไม่เห็น → ช่องว่าง แล้วรวมช่องว่างซ้ำ
        $value = preg_replace('/[\p{Cc}\p{Cf}\p{Co}\p{Cn}]+/u', ' ', $value) ?? '';
        $value = trim(preg_replace('/\s+/u', ' ', $value) ?? '');
        $value = mb_substr($value, 0, $max);

        if ($value === '' || ($pattern !== null && !preg_match($pattern, $value))) {
            return null;
        }

        return $value;
    }

    // เซสชันของแอปที่ยังใช้ได้ (ยังไม่หมดอายุ)
    public static function active(User $user): MorphMany
    {
        return $user->tokens()
            ->where('name', self::TOKEN_NAME)
            ->where(fn ($tokens) => $tokens->whereNull('expires_at')->orWhere('expires_at', '>', now()))
            ->when(config('sanctum.expiration'), fn ($tokens, $minutes) => $tokens->where('created_at', '>', now()->subMinutes((int) $minutes)));
    }

    // id ของ token ในคำขอนี้ (null = ไม่ได้มาจาก token ของแอป เช่น เว็บผู้ดูแล)
    public static function currentId(User $user): ?int
    {
        $token = $user->currentAccessToken();

        return $token instanceof PersonalAccessToken && $token->exists ? (int) $token->getKey() : null;
    }

    // เพิกถอนเซสชันของผู้ใช้คนนี้เท่านั้น (id ของคนอื่นไม่ถูกแตะ) คืนจำนวนที่เพิกถอน
    public static function revoke(User $user, array $tokenIds): int
    {
        if ($tokenIds === []) {
            return 0;
        }

        return DB::transaction(function () use ($user, $tokenIds) {
            $ids = $user->tokens()
                ->where('name', self::TOKEN_NAME)
                ->whereIn('id', $tokenIds)
                ->lockForUpdate()
                ->pluck('id')
                ->all();

            if ($ids === []) {
                return 0;
            }

            // หยุดส่ง Push ไปเครื่องของเซสชันนั้น (เครื่องอื่น/บัญชีอื่นไม่เกี่ยว)
            DeviceToken::whereIn('access_token_id', $ids)->delete();

            return PersonalAccessToken::whereIn('id', $ids)->delete();
        });
    }
}
