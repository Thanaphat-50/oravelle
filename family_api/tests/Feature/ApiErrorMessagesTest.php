<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Route;
use Laravel\Sanctum\Sanctum;
use RuntimeException;
use Tests\TestCase;

// ข้อผิดพลาดที่แอปแสดงให้ผู้ใช้เห็นต้องเป็นภาษาไทย ไม่มีข้อความภายในของ Laravel
class ApiErrorMessagesTest extends TestCase
{
    use RefreshDatabase;

    public function test_wrong_password_is_a_thai_validation_error_not_a_session_401(): void
    {
        User::factory()->create(['email' => 'mom@example.com', 'password' => Hash::make('password123')]);

        // 422 (ไม่ใช่ 401) → แอปไม่เข้าใจผิดว่าเซสชันของผู้ใช้หมดอายุ
        $this->postJson('/api/login', ['email' => 'mom@example.com', 'password' => 'wrong-pass'])
            ->assertUnprocessable()
            ->assertJsonPath('errors.email.0', 'อีเมลหรือรหัสผ่านไม่ถูกต้อง');

        $this->postJson('/api/login', ['email' => 'not-an-email', 'password' => ''])
            ->assertUnprocessable()
            ->assertJsonPath('errors.email.0', 'รูปแบบอีเมลไม่ถูกต้อง')
            ->assertJsonPath('errors.password.0', 'กรุณาใส่รหัสผ่าน');

        $this->postJson('/api/login', ['email' => 'mom@example.com', 'password' => 'password123'])
            ->assertOk()
            ->assertJsonPath('message', 'เข้าสู่ระบบสำเร็จ');
    }

    public function test_register_errors_are_thai(): void
    {
        User::factory()->create(['email' => 'mom@example.com']);

        $this->postJson('/api/register', [
            'name' => 'แม่',
            'email' => 'mom@example.com',
            'password' => 'short',
            'password_confirmation' => 'other',
        ])
            ->assertUnprocessable()
            ->assertJsonPath('errors.email.0', 'อีเมลนี้มีบัญชีอยู่แล้ว กรุณาเข้าสู่ระบบ หรือใช้อีเมลอื่น')
            ->assertJsonPath('errors.password.0', 'รหัสผ่านต้องมีอย่างน้อย 8 ตัวอักษร');
    }

    public function test_missing_or_expired_token_is_a_thai_401(): void
    {
        $this->getJson('/api/user')
            ->assertUnauthorized()
            ->assertExactJson([
                'status' => false,
                'message' => 'เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่',
                'code' => 'unauthenticated',
            ]);
    }

    public function test_not_found_and_wrong_method_hide_laravel_details(): void
    {
        Sanctum::actingAs(User::factory()->create());

        $missing = $this->getJson('/api/orders/999999')->assertNotFound();

        $missing->assertJsonPath('message', 'ไม่พบข้อมูลที่ต้องการ อาจถูกลบไปแล้ว');
        $this->assertStringNotContainsString('App\\Models', $missing->getContent());

        $this->getJson('/api/login')
            ->assertStatus(405)
            ->assertJsonPath('message', 'ทำรายการนี้ไม่ได้');
    }

    public function test_default_rate_limit_message_is_thai(): void
    {
        Sanctum::actingAs(User::factory()->create());

        for ($i = 0; $i < 5; $i++) {
            $this->deleteJson('/api/account', ['password' => 'wrong']);
        }

        $this->deleteJson('/api/account', ['password' => 'wrong'])
            ->assertTooManyRequests()
            ->assertJsonPath('status', false)
            ->assertJsonPath('retry_after', fn ($seconds) => $seconds > 0)
            ->assertJsonPath('message', fn (string $message) => str_starts_with($message, 'ทำรายการบ่อยเกินไป'));
    }

    public function test_server_errors_are_thai_without_details_in_production(): void
    {
        Route::middleware('api')->get('/api/test-crash', fn () => throw new RuntimeException('SQLSTATE secret details'));

        config(['app.debug' => false]);

        $response = $this->getJson('/api/test-crash')
            ->assertStatus(500)
            ->assertExactJson([
                'status' => false,
                'message' => 'ระบบขัดข้องชั่วคราว กรุณาลองใหม่อีกสักครู่',
            ]);

        $this->assertStringNotContainsString('SQLSTATE', $response->getContent());
    }
}
