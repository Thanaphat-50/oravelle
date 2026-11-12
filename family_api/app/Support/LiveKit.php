<?php

namespace App\Support;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;
use Throwable;

// =======================================================
// LiveKit (เสียง/วิดีโอแบบ WebRTC — สื่อไม่ผ่าน Laravel)
// - คีย์อยู่ที่เซิร์ฟเวอร์เท่านั้น (LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET)
// - แอปได้ token อายุสั้น (TOKEN_TTL) เฉพาะห้องของสายนั้น ออกให้หลังตรวจสิทธิ์แล้ว
// - LIVEKIT_URL ใส่ได้ทั้ง wss:// และ https:// (แอปใช้ wss / เรียก API ใช้ https)
// - TURN/การเชื่อมต่อข้ามเครือข่าย: LiveKit Cloud จัดการให้
// =======================================================

class LiveKit
{
    // token ใช้เข้าห้องภายในเวลานี้ (ต่อสายแล้ว LiveKit ต่ออายุให้เองระหว่างสาย)
    public const TOKEN_TTL = 300;

    public static function configured(): bool
    {
        return filled(config('services.livekit.url'))
            && filled(config('services.livekit.api_key'))
            && filled(config('services.livekit.api_secret'));
    }

    public static function clientUrl(): string
    {
        return self::withScheme('wss');
    }

    public static function apiUrl(): string
    {
        return self::withScheme('https');
    }

    private static function withScheme(string $scheme): string
    {
        $url = trim((string) config('services.livekit.url'));
        $host = (string) preg_replace('#^(wss?|https?)://#i', '', $url);

        return $scheme . '://' . rtrim($host, '/');
    }

    // เข้าห้องของสายนี้ได้ห้องเดียว / ส่งได้เฉพาะไมค์ (+ กล้องถ้าเป็นวิดีโอคอล)
    public static function joinToken(string $room, string $identity, string $name, bool $video): string
    {
        return self::token($identity, $name, [
            'room' => $room,
            'roomJoin' => true,
            'canPublish' => true,
            'canSubscribe' => true,
            'canPublishData' => false,
            'canPublishSources' => $video ? ['microphone', 'camera'] : ['microphone'],
        ]);
    }

    // ยุติสายฝั่งเซิร์ฟเวอร์: ลบห้อง → ผู้ร่วมสายทุกคนหลุดทันที
    public static function deleteRoom(string $room): void
    {
        if (!self::configured()) {
            return;
        }

        try {
            Http::withToken(self::token('oravelle-server', 'ORAVELLE', ['roomCreate' => true], 60))
                ->timeout(5)
                ->post(self::apiUrl() . '/twirp/livekit.RoomService/DeleteRoom', ['room' => $room]);
        } catch (Throwable $e) {
            Log::warning('LiveKit delete room failed', ['error' => $e->getMessage()]);
        }
    }

    public static function token(string $identity, string $name, array $videoGrant, int $ttl = self::TOKEN_TTL): string
    {
        $now = time();

        return self::jwt([
            'iss' => (string) config('services.livekit.api_key'),
            'sub' => $identity,
            'nbf' => $now - 5,
            'exp' => $now + $ttl,
            'jti' => $identity . '-' . bin2hex(random_bytes(8)),
            'name' => $name,
            'video' => $videoGrant,
        ]);
    }

    // JWT HS256 (ไม่ต้องใช้แพ็กเกจเพิ่ม)
    private static function jwt(array $claims): string
    {
        $encode = fn (string $data) => rtrim(strtr(base64_encode($data), '+/', '-_'), '=');

        $header = $encode((string) json_encode(['alg' => 'HS256', 'typ' => 'JWT']));
        $payload = $encode((string) json_encode($claims, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
        $signature = $encode(hash_hmac('sha256', $header . '.' . $payload, (string) config('services.livekit.api_secret'), true));

        return $header . '.' . $payload . '.' . $signature;
    }
}
