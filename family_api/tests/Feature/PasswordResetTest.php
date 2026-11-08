<?php

namespace Tests\Feature;

use App\Mail\PasswordResetCode;
use App\Models\SocialAccount;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Mail;
use Tests\TestCase;

// ลืมรหัสผ่าน: รหัส 6 หลักทางอีเมล หมดอายุ 15 นาที ใช้ครั้งเดียว ผิด 5 ครั้งต้องขอใหม่ ไม่บอกว่ามีบัญชีไหม
class PasswordResetTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Mail::fake();
    }

    private function requestCode(string $email): string
    {
        $this->postJson('/api/password/forgot', ['email' => $email])->assertOk();

        $code = null;

        Mail::assertSent(PasswordResetCode::class, function (PasswordResetCode $mail) use (&$code) {
            $code = $mail->code;

            return true;
        });

        return (string) $code;
    }

    private function reset(string $email, string $code, string $password = 'new-password-1')
    {
        return $this->postJson('/api/password/reset', [
            'email' => $email,
            'code' => $code,
            'password' => $password,
            'password_confirmation' => $password,
        ]);
    }

    public function test_reply_is_the_same_whether_or_not_the_email_has_an_account(): void
    {
        User::factory()->create(['email' => 'mom@example.com']);

        $known = $this->postJson('/api/password/forgot', ['email' => 'Mom@Example.com'])->assertOk()->json();
        $unknown = $this->postJson('/api/password/forgot', ['email' => 'nobody@example.com'])->assertOk()->json();

        $this->assertSame($known, $unknown);
        $this->assertStringContainsString('ถ้าอีเมลนี้มีบัญชี', $known['message']);

        Mail::assertSent(PasswordResetCode::class, 1);
        Mail::assertSent(PasswordResetCode::class, fn (PasswordResetCode $mail) => $mail->hasTo('mom@example.com'));

        // เก็บเฉพาะ hash ของรหัส
        $row = DB::table('password_reset_tokens')->where('email', 'mom@example.com')->first();
        $this->assertNotNull($row);
        $this->assertSame(0, (int) $row->attempts);
        $this->assertDoesNotMatchRegularExpression('/^\d{6}$/', $row->token);
    }

    public function test_code_resets_the_password_once_and_signs_out_everywhere(): void
    {
        $user = User::factory()->create(['email' => 'mom@example.com', 'password' => Hash::make('old-password')]);
        $user->createToken('phone');

        $code = $this->requestCode('mom@example.com');

        $this->reset('mom@example.com', $code)
            ->assertOk()
            ->assertJsonPath('message', 'ตั้งรหัสผ่านใหม่แล้ว เข้าสู่ระบบด้วยรหัสผ่านใหม่ได้เลย');

        $this->assertTrue(Hash::check('new-password-1', $user->refresh()->password));
        $this->assertSame(0, $user->tokens()->count());

        // ใช้ซ้ำไม่ได้
        $this->reset('mom@example.com', $code, 'another-pass-2')->assertUnprocessable();
        $this->assertTrue(Hash::check('new-password-1', $user->refresh()->password));

        $this->postJson('/api/login', ['email' => 'mom@example.com', 'password' => 'new-password-1'])->assertOk();
    }

    public function test_wrong_codes_are_limited_and_codes_expire(): void
    {
        $user = User::factory()->create(['email' => 'mom@example.com', 'password' => Hash::make('old-password')]);

        $code = $this->requestCode('mom@example.com');
        $wrong = $code === '111111' ? '222222' : '111111';

        // ผิด 5 ครั้ง (throttle 5 ครั้ง/นาที → ข้ามเวลาไปทีละนาที)
        for ($i = 0; $i < 5; $i++) {
            $this->reset('mom@example.com', $wrong)
                ->assertUnprocessable()
                ->assertJsonPath('errors.code.0', 'รหัสไม่ถูกต้องหรือหมดอายุ กรุณาตรวจรหัสในอีเมล หรือขอรหัสใหม่');

            $this->travel(1)->minutes();
        }

        // ครบ 5 ครั้งแล้ว รหัสที่ถูกก็ใช้ไม่ได้ ต้องขอใหม่
        $this->reset('mom@example.com', $code)->assertUnprocessable();
        $this->assertTrue(Hash::check('old-password', $user->refresh()->password));

        // รหัสใหม่ หมดอายุหลัง 15 นาที
        $this->travel(2)->minutes();
        Mail::fake();
        $fresh = $this->requestCode('mom@example.com');

        $this->travel(16)->minutes();

        $this->reset('mom@example.com', $fresh)->assertUnprocessable();
        $this->assertTrue(Hash::check('old-password', $user->refresh()->password));
    }

    public function test_asking_again_within_a_minute_does_not_send_another_email(): void
    {
        User::factory()->create(['email' => 'mom@example.com']);

        $this->postJson('/api/password/forgot', ['email' => 'mom@example.com'])->assertOk();
        $this->postJson('/api/password/forgot', ['email' => 'mom@example.com'])->assertOk();

        Mail::assertSent(PasswordResetCode::class, 1);

        $this->travel(61)->seconds();

        $this->postJson('/api/password/forgot', ['email' => 'mom@example.com'])->assertOk();

        Mail::assertSent(PasswordResetCode::class, 2);
    }

    public function test_social_only_account_is_told_its_provider_and_can_add_a_password(): void
    {
        $user = User::factory()->create(['email' => 'line-user@example.com', 'password' => null]);

        SocialAccount::create([
            'user_id' => $user->id,
            'provider' => 'line',
            'provider_user_id' => 'U123',
        ]);

        $this->assertFalse($user->hasPassword());

        $code = $this->requestCode('line-user@example.com');

        Mail::assertSent(PasswordResetCode::class, function (PasswordResetCode $mail) {
            $text = $mail->render();

            return !$mail->hasPassword
                && $mail->providers === ['LINE']
                && str_contains($text, 'บัญชีนี้เข้าสู่ระบบด้วย LINE ได้อยู่แล้ว');
        });

        $this->reset('line-user@example.com', $code)->assertOk();

        $this->assertTrue($user->refresh()->hasPassword());
    }

    public function test_requests_are_rate_limited_in_thai(): void
    {
        for ($i = 0; $i < 5; $i++) {
            $this->postJson('/api/password/forgot', ['email' => 'someone@example.com'])->assertOk();
        }

        $this->postJson('/api/password/forgot', ['email' => 'someone@example.com'])
            ->assertTooManyRequests()
            ->assertJsonPath('message', fn (string $message) => str_contains($message, 'วินาที'));
    }

    public function test_production_without_a_mail_service_does_not_pretend_to_send(): void
    {
        User::factory()->create(['email' => 'mom@example.com']);

        $this->app['env'] = 'production';
        config(['mail.default' => 'log']);

        $this->postJson('/api/password/forgot', ['email' => 'mom@example.com'])
            ->assertStatus(503)
            ->assertJsonPath('message', 'ระบบส่งอีเมลยังไม่เปิดใช้งาน กรุณาติดต่อผู้ดูแลระบบ');

        Mail::assertNothingSent();
    }
}
