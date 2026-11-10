<?php

namespace App\Providers;

use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;
use Illuminate\Support\Str;

class AppServiceProvider extends ServiceProvider
{
    /**
     * Register any application services.
     */
    public function register(): void
    {
        //
    }

    /**
     * Bootstrap any application services.
     */
    public function boot(): void
    {
        // =====================================================
        // Rate Limit: Login
        //
        // - Email เดียวกันจาก IP เดียวกัน ลองได้ 5 ครั้ง/นาที
        //   (กันการเดารหัสผ่านของบัญชีใดบัญชีหนึ่ง)
        // - IP เดียวกัน ลองได้รวม 20 ครั้ง/นาที
        //   (กันการไล่เดาหลายบัญชีจากเครื่องเดียว)
        // =====================================================

        RateLimiter::for('login', function (Request $request) {
            $email = Str::lower(
                trim((string) $request->input('email'))
            );

            return [
                Limit::perMinute(5)
                    ->by('login-email:' . $email . '|' . $request->ip())
                    ->response($this->tooManyAttempts(...)),

                Limit::perMinute(20)
                    ->by('login-ip:' . $request->ip())
                    ->response($this->tooManyAttempts(...)),
            ];
        });

        // =====================================================
        // Rate Limit: ลืมรหัสผ่าน (ขอรหัส / ตั้งรหัสใหม่)
        //
        // - Email เดียวกันจาก IP เดียวกัน 5 ครั้ง/นาที (กันเดารหัส 6 หลัก + ส่งอีเมลรัว)
        // - IP เดียวกัน 20 ครั้ง/ชั่วโมง (กันไล่ขอรหัสหลายบัญชี)
        // =====================================================

        // =====================================================
        // Rate Limit: ศูนย์ช่วยเหลือ (ต่อผู้ใช้)
        // - สร้างคำร้อง 10 เรื่อง/ชั่วโมง
        // - ส่งข้อความเพิ่ม 10 ครั้ง/นาที และ 60 ครั้ง/ชั่วโมง
        // =====================================================

        RateLimiter::for('support-ticket', fn (Request $request) => Limit::perHour(10)
            ->by('support-ticket:' . ($request->user()?->id ?? $request->ip()))
            ->response($this->tooManyAttempts(...)));

        RateLimiter::for('support-message', fn (Request $request) => [
            Limit::perMinute(10)
                ->by('support-message-min:' . ($request->user()?->id ?? $request->ip()))
                ->response($this->tooManyAttempts(...)),
            Limit::perHour(60)
                ->by('support-message-hour:' . ($request->user()?->id ?? $request->ip()))
                ->response($this->tooManyAttempts(...)),
        ]);

        RateLimiter::for('password-reset', function (Request $request) {
            $email = Str::lower(trim((string) $request->input('email')));

            return [
                Limit::perMinute(5)
                    ->by('password-reset-email:' . $email . '|' . $request->ip())
                    ->response($this->tooManyAttempts(...)),

                Limit::perHour(20)
                    ->by('password-reset-ip:' . $request->ip())
                    ->response($this->tooManyAttempts(...)),
            ];
        });

        // =====================================================
        // Rate Limit: Register
        //
        // - IP เดียวกัน สมัครได้ 5 ครั้ง/นาที
        //   (กันการสร้างบัญชีปลอมจำนวนมาก)
        // =====================================================

        RateLimiter::for('register', function (Request $request) {
            return Limit::perMinute(5)
                ->by('register-ip:' . $request->ip())
                ->response($this->tooManyAttempts(...));
        });

        // =====================================================
        // Rate Limit: โพสต์ / ความคิดเห็น / รายงาน
        //
        // - ผู้ใช้คนเดียว รวมกันได้ 20 ครั้ง/นาที
        //   (กันสแปมในฟีดชุมชน)
        // =====================================================

        RateLimiter::for('ugc', function (Request $request) {
            return Limit::perMinute(20)
                ->by('ugc:' . ($request->user()?->id ?? $request->ip()))
                ->response($this->tooManyAttempts(...));
        });

        // อุปกรณ์ที่เข้าสู่ระบบ: ดูรายการ / ยกเลิกสิทธิ์เครื่องอื่น
        RateLimiter::for('sessions', function (Request $request) {
            return Limit::perMinute(30)
                ->by('sessions:' . ($request->user()?->id ?? $request->ip()))
                ->response($this->tooManyAttempts(...));
        });

        // ค้นหาโพสต์/ผู้ใช้: แอปรอหยุดพิมพ์ 400 มิลลิวินาทีก่อนค้น (พิมพ์ต่อเนื่องได้สบาย)
        RateLimiter::for('search', function (Request $request) {
            return Limit::perMinute(60)
                ->by('search:' . ($request->user()?->id ?? $request->ip()))
                ->response($this->tooManyAttempts(...));
        });

        // แชทกลุ่ม: ส่งข้อความ 30 ครั้ง/นาที / รูป 10 รูป/นาที และ 60 รูป/ชั่วโมง ต่อคน
        RateLimiter::for('group-chat-send', function (Request $request) {
            $id = $request->user()?->id ?? $request->ip();

            return [
                Limit::perMinute(30)->by('group-chat-send:' . $id)->response($this->tooManyAttempts(...)),
                ...($request->hasFile('image') ? [
                    Limit::perMinute(10)->by('group-chat-image:' . $id)->response($this->tooManyAttempts(...)),
                    Limit::perHour(60)->by('group-chat-image-hour:' . $id)->response($this->tooManyAttempts(...)),
                ] : []),
            ];
        });

        // แชทกลุ่ม: เปิดห้อง / ดึงข้อความใหม่ (ทุก 4 วินาทีขณะเปิดห้อง) / อ่านแล้ว / ปิดเสียง
        RateLimiter::for('group-chat', function (Request $request) {
            return Limit::perMinute(120)
                ->by('group-chat:' . ($request->user()?->id ?? $request->ip()))
                ->response($this->tooManyAttempts(...));
        });

        // แชท: คุยกันถี่กว่าโพสต์ได้
        RateLimiter::for('chat', function (Request $request) {
            return Limit::perMinute(60)
                ->by('chat:' . ($request->user()?->id ?? $request->ip()))
                ->response($this->tooManyAttempts(...));
        });

        // เส้นทางบนแผนที่: เรียก Google Routes API (มีค่าใช้จ่ายเมื่อเกินโควตาฟรี)
        RateLimiter::for('route', function (Request $request) {
            return [
                Limit::perMinute(10)->by('route-min:' . ($request->user()?->id ?? $request->ip())),
                Limit::perDay(200)->by('route-day:' . ($request->user()?->id ?? $request->ip())),
            ];
        });

        // รายละเอียดตำแหน่ง: OpenStreetMap + Google Places (มีค่าใช้จ่ายเมื่อเกินโควตาฟรี)
        RateLimiter::for('place', function (Request $request) {
            return [
                Limit::perMinute(10)->by('place-min:' . ($request->user()?->id ?? $request->ip())),
                Limit::perDay(150)->by('place-day:' . ($request->user()?->id ?? $request->ip())),
            ];
        });
    }

    // =====================================================
    // Response เมื่อลองเกินกำหนด (HTTP 429)
    // รูปแบบเดียวกับ API อื่น ๆ: status + message
    // =====================================================

    private function tooManyAttempts(
        Request $request,
        array $headers
    ): JsonResponse {
        $seconds = (int) ($headers['Retry-After'] ?? 60);

        return response()->json([
            'status' => false,
            'message' =>
                'ลองหลายครั้งเกินไป กรุณารอ '
                . $seconds
                . ' วินาทีแล้วลองใหม่',
            'retry_after' => $seconds,
        ], 429, $headers);
    }
}
