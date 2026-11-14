<?php

namespace App\Support;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use RuntimeException;

// =======================================================
// Access token จากบัญชีบริการของ Google (JWT RS256 → oauth2 token) แคชไว้ 50 นาที
// ใช้กับ Google Play Developer API (ตรวจการซื้อธีม)
// ไฟล์ JSON ของบัญชีบริการ: base64 ทั้งไฟล์ (Laravel Cloud) หรือ path (ในเครื่อง) — ห้ามใส่ในโค้ด
// =======================================================

class GoogleServiceAccount
{
    private const TOKEN_URL = 'https://oauth2.googleapis.com/token';

    private ?array $credentials = null;

    private bool $loaded = false;

    public function __construct(
        private readonly ?string $base64,
        private readonly ?string $path,
        private readonly string $scope,
    ) {
    }

    public function configured(): bool
    {
        return $this->credentials() !== null;
    }

    public function accessToken(): string
    {
        $credentials = $this->credentials() ?? throw new RuntimeException('Google service account is not configured');

        $key = 'google-sa-token:' . sha1($credentials['client_email'] . '|' . $this->scope);

        return Cache::remember($key, now()->addMinutes(50), function () use ($credentials) {
            $now = time();

            $jwt = $this->signedJwt([
                'iss' => $credentials['client_email'],
                'scope' => $this->scope,
                'aud' => self::TOKEN_URL,
                'iat' => $now,
                'exp' => $now + 3600,
            ], $credentials['private_key']);

            $response = Http::asForm()->timeout(15)->post(self::TOKEN_URL, [
                'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                'assertion' => $jwt,
            ]);

            $token = $response->json('access_token');

            if (!$response->successful() || !is_string($token)) {
                throw new RuntimeException('Google token request failed: HTTP ' . $response->status());
            }

            return $token;
        });
    }

    private function signedJwt(array $claims, string $privateKey): string
    {
        $input = $this->base64Url(json_encode(['alg' => 'RS256', 'typ' => 'JWT']))
            . '.' . $this->base64Url(json_encode($claims));

        if (!openssl_sign($input, $signature, $privateKey, OPENSSL_ALGO_SHA256)) {
            throw new RuntimeException('Cannot sign Google service account JWT');
        }

        return $input . '.' . $this->base64Url($signature);
    }

    private function base64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }

    private function credentials(): ?array
    {
        if ($this->loaded) {
            return $this->credentials;
        }

        $this->loaded = true;

        $json = null;

        if (is_string($this->base64) && $this->base64 !== '') {
            $json = base64_decode($this->base64, true) ?: null;
        } elseif (is_string($this->path) && $this->path !== '' && is_file($this->path)) {
            $json = (string) file_get_contents($this->path);
        }

        $data = is_string($json) ? json_decode($json, true) : null;

        if (is_array($data) && isset($data['client_email'], $data['private_key'])) {
            $this->credentials = $data;
        }

        return $this->credentials;
    }
}
