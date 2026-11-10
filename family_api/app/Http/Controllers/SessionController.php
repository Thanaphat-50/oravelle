<?php

namespace App\Http\Controllers;

use App\Support\AppSessions;
use Illuminate\Http\Request;
use Laravel\Sanctum\PersonalAccessToken;

// =======================================================
// อุปกรณ์ที่เข้าสู่ระบบ (เซสชันของแอปในบัญชีนี้)
//
// GET    /api/sessions                 รายการ (เครื่องนี้ก่อน แล้วตามการใช้งานล่าสุด)
// PUT    /api/sessions/current         แอปบอกข้อมูลอุปกรณ์ของเซสชันนี้ (เซสชันเก่าที่ยังไม่มีชื่อ)
// DELETE /api/sessions/{id}            ออกจากระบบเครื่องอื่น (เครื่องนี้ใช้ปุ่มออกจากระบบเดิม)
// POST   /api/sessions/revoke-others   ออกจากระบบเครื่องอื่นทั้งหมด (คงเครื่องนี้ไว้)
//
// - จัดการได้เฉพาะเซสชันของตัวเอง: id ของคนอื่น / ที่ยกเลิกไปแล้ว → ตอบเหมือนกัน (ไม่บอกว่ามีอยู่)
// - "เครื่องนี้" = token ของคำขอนี้ (ไม่เดาจากชื่อรุ่น)
// - ไม่ส่ง token / hash / abilities กลับ / ไม่บอกว่า "ออนไลน์" (มีแค่เวลาใช้งานล่าสุดจริง)
// - เพิกถอน = ลบ token จริง → เครื่องนั้นเรียก API ครั้งถัดไปได้ 401 แล้วแอปพาไปหน้าเข้าสู่ระบบ
//   (เครื่องที่ออฟไลน์อยู่จะรู้ตอนต่อเน็ตครั้งถัดไป)
// =======================================================

class SessionController extends Controller
{
    public function index(Request $request)
    {
        $user = $request->user();
        $currentId = AppSessions::currentId($user);

        $sessions = AppSessions::active($user)
            ->get()
            ->sortBy([
                fn (PersonalAccessToken $a, PersonalAccessToken $b) => ((int) $b->getKey() === $currentId) <=> ((int) $a->getKey() === $currentId),
                fn (PersonalAccessToken $a, PersonalAccessToken $b) => ($b->last_used_at?->getTimestamp() ?? 0) <=> ($a->last_used_at?->getTimestamp() ?? 0),
                fn (PersonalAccessToken $a, PersonalAccessToken $b) => $b->getKey() <=> $a->getKey(),
            ])
            ->values()
            ->map(fn (PersonalAccessToken $token) => [
                'id' => $token->getKey(),
                'device_name' => $token->device_name,
                'device_platform' => $token->device_platform,
                'os_version' => $token->os_version,
                'app_version' => $token->app_version,
                'signed_in_at' => $token->created_at?->toIso8601String(),
                'last_used_at' => $token->last_used_at?->toIso8601String(),
                'is_current' => (int) $token->getKey() === $currentId,
            ]);

        return response()->json([
            'status' => true,
            'sessions' => $sessions,
            'others_count' => $sessions->where('is_current', false)->count(),
        ]);
    }

    public function updateCurrent(Request $request)
    {
        $request->validate([
            'device_name' => 'nullable|string|max:80',
            'device_platform' => 'nullable|in:' . implode(',', AppSessions::PLATFORMS),
            'os_version' => 'nullable|string|max:40',
            'app_version' => 'nullable|string|max:30',
        ]);

        $user = $request->user();
        $currentId = AppSessions::currentId($user);

        if ($currentId === null) {
            return response()->json([
                'status' => false,
                'message' => 'ใช้ได้เฉพาะการเข้าสู่ระบบจากแอป',
            ], 422);
        }

        $info = AppSessions::deviceInfo($request->all());

        if ($info !== []) {
            PersonalAccessToken::whereKey($currentId)->update($info);
        }

        return response()->json(['status' => true]);
    }

    public function destroy(Request $request, int $session)
    {
        $user = $request->user();

        if ($session === AppSessions::currentId($user)) {
            return response()->json([
                'status' => false,
                'code' => 'current_session',
                'message' => 'เครื่องนี้ใช้ปุ่ม "ออกจากระบบ" ในหน้าตั้งค่า',
            ], 422);
        }

        $revoked = AppSessions::revoke($user, [$session]);

        return response()->json([
            'status' => true,
            'revoked' => $revoked,
            // ยกเลิกไปแล้ว / ไม่ใช่ของเรา → ตอบแบบเดียวกัน ไม่มีผลกับเซสชันอื่น
            'message' => $revoked > 0
                ? 'ยกเลิกสิทธิ์ของอุปกรณ์นี้แล้ว อุปกรณ์นั้นต้องเข้าสู่ระบบใหม่'
                : 'อุปกรณ์นี้ถูกยกเลิกสิทธิ์ไปแล้ว',
        ]);
    }

    public function revokeOthers(Request $request)
    {
        $user = $request->user();
        $currentId = AppSessions::currentId($user);

        if ($currentId === null) {
            return response()->json([
                'status' => false,
                'message' => 'ใช้ได้เฉพาะการเข้าสู่ระบบจากแอป',
            ], 422);
        }

        // ทุกเซสชันของแอป (รวมที่หมดอายุแล้ว) ยกเว้นเครื่องนี้
        $ids = $user->tokens()
            ->where('name', AppSessions::TOKEN_NAME)
            ->whereKeyNot($currentId)
            ->pluck('id')
            ->all();

        $revoked = AppSessions::revoke($user, $ids);

        return response()->json([
            'status' => true,
            'revoked' => $revoked,
            'message' => $revoked > 0
                ? "ยกเลิกสิทธิ์อุปกรณ์อื่นแล้ว {$revoked} เครื่อง คุณยังใช้งานบนเครื่องนี้ต่อได้"
                : 'ไม่มีอุปกรณ์อื่นที่เข้าสู่ระบบอยู่',
        ]);
    }
}
