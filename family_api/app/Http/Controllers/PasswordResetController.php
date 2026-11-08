<?php

namespace App\Http\Controllers;

use App\Mail\PasswordResetCode;
use App\Models\SocialAccount;
use App\Models\User;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Mail;
use Illuminate\Support\Str;
use Throwable;

// =======================================================
// ลืมรหัสผ่าน (ไม่ต้องเข้าสู่ระบบ)
//
// 1) POST /api/password/forgot {email}
//    → ส่งรหัส 6 หลักทางอีเมล (ถ้ามีบัญชี) ตอบข้อความเดียวกันเสมอ ไม่บอกว่ามีบัญชีหรือไม่
// 2) POST /api/password/reset {email, code, password, password_confirmation}
//    → ตั้งรหัสผ่านใหม่ แล้วออกจากระบบทุกเครื่อง
//
// - รหัสหมดอายุใน 15 นาที ใช้ได้ครั้งเดียว ผิดครบ 5 ครั้ง → ต้องขอใหม่
// - เก็บเฉพาะ hash ของรหัส (password_reset_tokens)
// - ขอรหัสใหม่ได้ทุก 60 วินาที (ก่อนนั้นตอบเหมือนเดิมแต่ไม่ส่งซ้ำ) + จำกัดจำนวนคำขอ (throttle:password-reset)
// - บัญชีที่สมัครด้วย Google / LINE / Facebook (ไม่มีรหัสผ่าน): ได้อีเมลที่บอกให้เข้าด้วยบริการเดิม
//   และตั้งรหัสผ่านเพิ่มได้ด้วยรหัสในอีเมล (พิสูจน์แล้วว่าเป็นเจ้าของอีเมล)
// - ระบบส่งอีเมลยังไม่ตั้งค่า (MAIL_MAILER=log บน production) → ตอบ 503 ไม่แกล้งว่าส่งแล้ว
// =======================================================

class PasswordResetController extends Controller
{
    public const CODE_MINUTES = 15;
    public const RESEND_SECONDS = 60;
    public const MAX_ATTEMPTS = 5;

    public function forgot(Request $request): JsonResponse
    {
        $data = $request->validate(
            ['email' => 'required|email|max:255'],
            [
                'email.required' => 'กรุณาใส่อีเมล',
                'email.email' => 'รูปแบบอีเมลไม่ถูกต้อง',
                'email.max' => 'อีเมลยาวเกินไป',
            ]
        );

        if (!$this->mailReady()) {
            return $this->fail('ระบบส่งอีเมลยังไม่เปิดใช้งาน กรุณาติดต่อผู้ดูแลระบบ', 503);
        }

        $user = $this->findUser($data['email']);

        if ($user && !$this->sentRecently($user)) {
            $code = (string) random_int(100000, 999999);

            DB::table('password_reset_tokens')->updateOrInsert(
                ['email' => $user->email],
                ['token' => Hash::make($code), 'attempts' => 0, 'created_at' => now()]
            );

            $providers = $user->socialAccounts()
                ->pluck('provider')
                ->map(fn (string $provider) => SocialAccount::LABELS[$provider] ?? $provider)
                ->values()
                ->all();

            try {
                Mail::to($user->email)->send(new PasswordResetCode(
                    $user,
                    $code,
                    self::CODE_MINUTES,
                    $user->hasPassword(),
                    $providers
                ));
            } catch (Throwable $e) {
                DB::table('password_reset_tokens')->where('email', $user->email)->delete();

                Log::error('Password reset mail failed', ['user_id' => $user->id, 'error' => $e->getMessage()]);

                return $this->fail('ส่งอีเมลไม่สำเร็จ กรุณาลองใหม่ภายหลัง', 503);
            }
        }

        // ข้อความเดียวกันทุกกรณี (มี/ไม่มีบัญชี, เพิ่งส่งไป) → เดาไม่ได้ว่าอีเมลไหนมีบัญชี
        return response()->json([
            'status' => true,
            'message' => 'ถ้าอีเมลนี้มีบัญชี ORAVELLE เราส่งรหัส 6 หลักไปให้แล้ว '
                . 'กรุณาตรวจกล่องจดหมาย (รวมถึงจดหมายขยะ) รหัสใช้ได้ ' . self::CODE_MINUTES . ' นาที',
            'code_minutes' => self::CODE_MINUTES,
            'resend_seconds' => self::RESEND_SECONDS,
        ]);
    }

    public function reset(Request $request): JsonResponse
    {
        $data = $request->validate([
            'email' => 'required|email|max:255',
            'code' => 'required|digits:6',
            'password' => 'required|string|min:8|confirmed',
        ], [
            'email.required' => 'กรุณาใส่อีเมล',
            'email.email' => 'รูปแบบอีเมลไม่ถูกต้อง',
            'code.required' => 'กรุณาใส่รหัส 6 หลักจากอีเมล',
            'code.digits' => 'รหัสต้องเป็นตัวเลข 6 หลัก',
            'password.required' => 'กรุณาตั้งรหัสผ่านใหม่',
            'password.min' => 'รหัสผ่านต้องมีอย่างน้อย 8 ตัวอักษร',
            'password.confirmed' => 'ยืนยันรหัสผ่านไม่ตรงกัน',
        ]);

        $user = $this->findUser($data['email']);

        $row = $user
            ? DB::table('password_reset_tokens')->where('email', $user->email)->first()
            : null;

        if (!$row) {
            return $this->invalidCode();
        }

        $expired = Carbon::parse($row->created_at)->lt(now()->subMinutes(self::CODE_MINUTES));

        if ($expired || (int) $row->attempts >= self::MAX_ATTEMPTS) {
            DB::table('password_reset_tokens')->where('email', $user->email)->delete();

            return $this->invalidCode();
        }

        if (!Hash::check($data['code'], $row->token)) {
            DB::table('password_reset_tokens')->where('email', $user->email)->increment('attempts');

            return $this->invalidCode();
        }

        // ใช้ได้ครั้งเดียว: ลบรหัสพร้อมเปลี่ยนรหัสผ่าน แล้วออกจากระบบทุกเครื่อง
        $changed = DB::transaction(function () use ($user, $row, $data) {
            $deleted = DB::table('password_reset_tokens')
                ->where('email', $user->email)
                ->where('token', $row->token)
                ->delete();

            if ($deleted === 0) {
                return false;
            }

            $user->forceFill(['password' => Hash::make($data['password'])])->save();

            $user->tokens()->delete();

            return true;
        });

        if (!$changed) {
            return $this->invalidCode();
        }

        return response()->json([
            'status' => true,
            'message' => 'ตั้งรหัสผ่านใหม่แล้ว เข้าสู่ระบบด้วยรหัสผ่านใหม่ได้เลย',
        ]);
    }

    // =====================================================
    // HELPERS
    // =====================================================

    private function findUser(string $email): ?User
    {
        return User::whereRaw('lower(email) = ?', [Str::lower(trim($email))])->first();
    }

    private function sentRecently(User $user): bool
    {
        $createdAt = DB::table('password_reset_tokens')->where('email', $user->email)->value('created_at');

        return $createdAt !== null
            && Carbon::parse($createdAt)->gt(now()->subSeconds(self::RESEND_SECONDS));
    }

    // production ที่ยังใช้ log / array = ไม่มีอีเมลถึงผู้ใช้จริง
    private function mailReady(): bool
    {
        return !app()->isProduction()
            || !in_array(config('mail.default'), ['log', 'array'], true);
    }

    private function invalidCode(): JsonResponse
    {
        return response()->json([
            'status' => false,
            'message' => 'รหัสไม่ถูกต้องหรือหมดอายุ กรุณาตรวจรหัสในอีเมล หรือขอรหัสใหม่',
            'errors' => ['code' => ['รหัสไม่ถูกต้องหรือหมดอายุ กรุณาตรวจรหัสในอีเมล หรือขอรหัสใหม่']],
        ], 422);
    }

    private function fail(string $message, int $status): JsonResponse
    {
        return response()->json(['status' => false, 'message' => $message], $status);
    }
}
