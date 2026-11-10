<?php

namespace App\Http\Controllers;

use App\Models\DeviceToken;
use Illuminate\Http\Request;
use Laravel\Sanctum\PersonalAccessToken;

// =======================================================
// มือถือสำหรับแจ้งเตือนเด้ง
// แอปส่งรหัสเครื่องมาทุกครั้งที่เข้าหน้าหลัก
// ออกจากระบบ → Token ของแอปถูกลบ → แถวของเครื่องนี้ถูกลบตาม (cascade)
// =======================================================

class DeviceTokenController extends Controller
{
    // POST /api/device-tokens
    public function store(Request $request)
    {
        $data = $request->validate([
            'token' => 'required|string|max:512',
            'platform' => 'nullable|in:android,ios',
        ]);

        $user = $request->user();

        $accessToken = $user->currentAccessToken();

        $accessTokenId = $accessToken instanceof PersonalAccessToken && $accessToken->exists
            ? $accessToken->getKey()
            : null;

        // เครื่องเดิมเปลี่ยนบัญชี → รหัสเครื่องย้ายมาเป็นของบัญชีนี้ (และผูกกับเซสชันนี้)
        DeviceToken::updateOrCreate(
            ['token' => $data['token']],
            [
                'user_id' => $user->id,
                'access_token_id' => $accessTokenId,
                'platform' => $data['platform'] ?? 'android',
                'last_used_at' => now(),
            ]
        );

        // 1 เซสชัน = 1 เครื่อง: รหัส Push ของเครื่องนี้เปลี่ยน → รหัสเก่าของเซสชันเดียวกันใช้ไม่ได้แล้ว
        // (ไม่แตะเซสชันอื่น / แถวเก่าที่ไม่ได้ผูกเซสชัน)
        if ($accessTokenId !== null) {
            DeviceToken::where('access_token_id', $accessTokenId)
                ->where('token', '!=', $data['token'])
                ->delete();
        }

        // เก็บเฉพาะเครื่องล่าสุด
        $staleIds = DeviceToken::where('user_id', $user->id)
            ->orderByDesc('last_used_at')
            ->orderByDesc('id')
            ->skip(DeviceToken::MAX_PER_USER)
            ->take(PHP_INT_MAX)
            ->pluck('id');

        if ($staleIds->isNotEmpty()) {
            DeviceToken::whereIn('id', $staleIds)->delete();
        }

        return response()->json([
            'status' => true,
        ]);
    }
}
