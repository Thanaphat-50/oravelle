<?php

namespace Tests\Feature;

use App\Models\AppNotification;
use App\Models\DeviceToken;
use App\Models\User;
use App\Support\AppSessions;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request as HttpRequest;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Laravel\Sanctum\PersonalAccessToken;
use Tests\TestCase;

// อุปกรณ์ที่เข้าสู่ระบบ: รายการเฉพาะของตัวเอง / เครื่องนี้จาก token จริง / เพิกถอนจริง / ซ้ำได้ปลอดภัย
// / Push ของเซสชันที่ถูกยกเลิก / ข้อมูลเก่า / Social Login — ฐานข้อมูลทดสอบแยก, Push ปลอม
class SessionManagementTest extends TestCase
{
    use RefreshDatabase;

    private const FCM_URL = 'https://fcm.googleapis.com/v1/projects/test-project/messages:send';

    private const PIXEL = ['device_name' => 'Google Pixel 7', 'device_platform' => 'android', 'os_version' => 'Android 14', 'app_version' => '1.4.0 (12)'];

    // เซสชันของแอป (เหมือนเข้าสู่ระบบจากเครื่องหนึ่ง) คืน [token ข้อความ, id]
    private function appSession(User $user, array $device = []): array
    {
        $plain = AppSessions::issue($user, Request::create('/api/login', 'POST', $device));

        return [$plain, (int) explode('|', $plain)[0]];
    }

    // ใช้ token นี้ในคำขอถัดไป (ล้างผู้ใช้ที่จำไว้จากคำขอก่อน)
    private function using(string $token): self
    {
        app('auth')->forgetGuards();

        return $this->withToken($token);
    }

    public function test_lists_only_my_sessions_with_current_marked_by_token(): void
    {
        $me = User::factory()->create();
        $other = User::factory()->create();

        // สองเครื่องรุ่นเดียวกัน → ต้องแยกด้วย token ไม่ใช่ชื่อรุ่น
        [$phoneA] = $this->appSession($me, self::PIXEL);
        [, $phoneBId] = $this->appSession($me, self::PIXEL);
        $this->appSession($other, self::PIXEL);
        $me->createToken('service-account');

        $response = $this->using($phoneA)->getJson('/api/sessions')->assertOk()
            ->assertJsonCount(2, 'sessions')
            ->assertJsonPath('others_count', 1)
            ->assertJsonPath('sessions.0.is_current', true)
            ->assertJsonPath('sessions.0.device_name', 'Google Pixel 7')
            ->assertJsonPath('sessions.0.os_version', 'Android 14')
            ->assertJsonPath('sessions.0.app_version', '1.4.0 (12)')
            ->assertJsonPath('sessions.1.id', $phoneBId)
            ->assertJsonPath('sessions.1.is_current', false);

        // ไม่มีข้อมูลลับ / ไม่บอกว่าออนไลน์
        $body = $response->getContent();
        $this->assertSame(['id', 'device_name', 'device_platform', 'os_version', 'app_version', 'signed_in_at', 'last_used_at', 'is_current'], array_keys($response->json('sessions.0')));
        foreach (PersonalAccessToken::pluck('token') as $hash) {
            $this->assertStringNotContainsString($hash, $body);
        }
        $this->assertStringNotContainsString(explode('|', $phoneA)[1], $body);
        $this->assertStringNotContainsString('online', $body);
        $this->assertNotNull($response->json('sessions.0.last_used_at'));
    }

    public function test_cannot_revoke_someone_elses_session_and_repeats_are_safe(): void
    {
        $me = User::factory()->create();
        $victim = User::factory()->create();

        [$mine] = $this->appSession($me);
        [$victimToken, $victimId] = $this->appSession($victim);

        // เปลี่ยน id เป็นของคนอื่น → ตอบเหมือน "ยกเลิกไปแล้ว" และไม่มีผล
        $this->using($mine)->deleteJson("/api/sessions/{$victimId}")->assertOk()
            ->assertJsonPath('revoked', 0);
        $this->using($victimToken)->getJson('/api/user')->assertOk();

        [, $otherDeviceId] = $this->appSession($me);

        $this->using($mine)->deleteJson("/api/sessions/{$otherDeviceId}")->assertOk()->assertJsonPath('revoked', 1);
        $this->using($mine)->deleteJson("/api/sessions/{$otherDeviceId}")->assertOk()->assertJsonPath('revoked', 0)
            ->assertJsonPath('message', 'อุปกรณ์นี้ถูกยกเลิกสิทธิ์ไปแล้ว');
        $this->using($mine)->deleteJson('/api/sessions/999999')->assertOk()->assertJsonPath('revoked', 0);

        $this->using($mine)->getJson('/api/user')->assertOk();
        $this->using($victimToken)->getJson('/api/user')->assertOk();
    }

    public function test_revoked_session_cannot_call_the_api_but_others_keep_working(): void
    {
        $me = User::factory()->create();

        [$phone] = $this->appSession($me);
        [$tablet, $tabletId] = $this->appSession($me);
        [$laptop] = $this->appSession($me);

        $this->using($phone)->deleteJson("/api/sessions/{$tabletId}")->assertOk()
            ->assertJsonPath('message', 'ยกเลิกสิทธิ์ของอุปกรณ์นี้แล้ว อุปกรณ์นั้นต้องเข้าสู่ระบบใหม่');

        $this->using($tablet)->getJson('/api/user')->assertUnauthorized();
        $this->using($tablet)->getJson('/api/sessions')->assertUnauthorized();
        $this->using($phone)->getJson('/api/user')->assertOk();
        $this->using($laptop)->getJson('/api/user')->assertOk();

        // ล็อกอินใหม่บนเครื่องที่ถูกยกเลิก → ใช้งานได้ปกติ
        app('auth')->forgetGuards();
        $fresh = $this->postJson('/api/login', ['email' => $me->email, 'password' => 'password'])->assertOk()->json('token');
        $this->using($fresh)->getJson('/api/user')->assertOk();
    }

    public function test_current_session_is_not_revoked_through_the_device_list(): void
    {
        $me = User::factory()->create();
        [$phone, $phoneId] = $this->appSession($me);

        $this->using($phone)->deleteJson("/api/sessions/{$phoneId}")->assertStatus(422)
            ->assertJsonPath('code', 'current_session');
        $this->using($phone)->getJson('/api/user')->assertOk();
    }

    public function test_revoke_all_others_keeps_this_device(): void
    {
        $me = User::factory()->create();
        $other = User::factory()->create();

        [$phone] = $this->appSession($me);
        [$tablet] = $this->appSession($me);
        [$laptop] = $this->appSession($me);
        [$otherToken] = $this->appSession($other);
        $service = $me->createToken('service-account')->plainTextToken;

        $this->using($phone)->postJson('/api/sessions/revoke-others')->assertOk()
            ->assertJsonPath('revoked', 2)
            ->assertJsonPath('message', 'ยกเลิกสิทธิ์อุปกรณ์อื่นแล้ว 2 เครื่อง คุณยังใช้งานบนเครื่องนี้ต่อได้');

        $this->using($phone)->getJson('/api/user')->assertOk();
        $this->using($tablet)->getJson('/api/user')->assertUnauthorized();
        $this->using($laptop)->getJson('/api/user')->assertUnauthorized();
        $this->using($otherToken)->getJson('/api/user')->assertOk();
        // token ประเภทอื่น (ไม่ใช่เซสชันแอป) ไม่ถูกแตะ
        $this->using($service)->getJson('/api/user')->assertOk();

        $this->using($phone)->postJson('/api/sessions/revoke-others')->assertOk()
            ->assertJsonPath('revoked', 0)
            ->assertJsonPath('message', 'ไม่มีอุปกรณ์อื่นที่เข้าสู่ระบบอยู่');
        $this->using($phone)->getJson('/api/sessions')->assertJsonPath('others_count', 0);
    }

    public function test_push_bindings_of_revoked_sessions_stop_without_touching_others(): void
    {
        config(['services.fcm.credentials' => base64_encode(json_encode([
            'type' => 'service_account',
            'project_id' => 'test-project',
            'client_email' => 'push@test-project.iam.gserviceaccount.com',
            'private_key' => 'unused-in-this-test',
        ]))]);
        Cache::put('fcm.access_token.test-project', 'cached-access-token', 600);
        $this->withoutDefer();
        Http::fake([self::FCM_URL => Http::response(['name' => 'projects/test-project/messages/1'])]);

        $me = User::factory()->create();
        $friend = User::factory()->create();

        [$phone] = $this->appSession($me);
        [$tablet, $tabletId] = $this->appSession($me);
        [$friendToken] = $this->appSession($friend);

        foreach ([[$phone, 'fid-phone'], [$tablet, 'fid-tablet'], [$friendToken, 'fid-friend']] as [$token, $fid]) {
            $this->using($token)->postJson('/api/device-tokens', ['token' => $fid])->assertOk();
        }

        // แถวเก่าที่ไม่ได้ผูกเซสชัน: ไม่ส่ง Push และไม่ถูกเดาลบ
        DeviceToken::create(['user_id' => $me->id, 'access_token_id' => null, 'token' => 'fid-legacy']);

        $this->using($phone)->deleteJson("/api/sessions/{$tabletId}")->assertOk();

        $this->assertEqualsCanonicalizing(['fid-phone', 'fid-friend', 'fid-legacy'], DeviceToken::pluck('token')->all());

        AppNotification::create(['user_id' => $me->id, 'type' => 'shop_status', 'title' => 'ทดสอบ', 'message' => 'ทดสอบ', 'is_read' => false]);

        Http::assertSentCount(1);
        Http::assertSent(fn (HttpRequest $request) => $request['message']['fid'] === 'fid-phone');
    }

    public function test_push_token_change_and_switching_account_on_the_same_device(): void
    {
        $mom = User::factory()->create();
        $dad = User::factory()->create();

        [$momToken] = $this->appSession($mom);

        // รหัส Push ของเครื่องเปลี่ยน → รหัสเก่าของเซสชันนี้ถูกแทนที่
        $this->using($momToken)->postJson('/api/device-tokens', ['token' => 'fid-old'])->assertOk();
        $this->using($momToken)->postJson('/api/device-tokens', ['token' => 'fid-new'])->assertOk();
        $this->assertSame(['fid-new'], DeviceToken::where('user_id', $mom->id)->pluck('token')->all());

        // พ่อเข้าสู่ระบบบนเครื่องเดียวกัน → รหัสเครื่องย้ายไปบัญชีพ่อ
        [$dadToken] = $this->appSession($dad);
        $this->using($dadToken)->postJson('/api/device-tokens', ['token' => 'fid-new'])->assertOk();

        $row = DeviceToken::where('token', 'fid-new')->first();
        $this->assertSame($dad->id, $row->user_id);

        // แม่ยกเลิกเครื่องอื่นทั้งหมด → ไม่กระทบการผูก Push ของพ่อ
        [$momTablet] = $this->appSession($mom);
        $this->using($momTablet)->postJson('/api/sessions/revoke-others')->assertOk();
        $this->assertSame($dad->id, DeviceToken::where('token', 'fid-new')->value('user_id'));
    }

    public function test_device_info_from_login_register_and_social_is_sanitized(): void
    {
        $user = User::factory()->create();

        $token = $this->postJson('/api/login', [
            'email' => $user->email,
            'password' => 'password',
            'device_name' => "  Galaxy\u{0000}\u{200B} S24\n" . str_repeat('x', 200),
            'device_platform' => 'windows',
            'os_version' => '<script>alert(1)</script>',
            'app_version' => '2.0.1 (40)',
        ])->assertOk()->json('token');

        $row = PersonalAccessToken::findToken($token);
        $this->assertStringStartsWith('Galaxy S24 xxx', $row->device_name);
        $this->assertSame(80, mb_strlen($row->device_name));
        $this->assertNull($row->device_platform);
        $this->assertNull($row->os_version);
        $this->assertSame('2.0.1 (40)', $row->app_version);

        $registered = $this->postJson('/api/register', [
            'name' => 'ใหม่',
            'email' => 'new-device@example.com',
            'password' => 'password123',
            'password_confirmation' => 'password123',
            ...self::PIXEL,
        ])->assertCreated()->json('token');
        $this->assertSame('Google Pixel 7', PersonalAccessToken::findToken($registered)->device_name);

        // Social Login (Google ปลอม)
        Http::preventStrayRequests();
        config(['services.google.client_ids' => 'web-client.apps.googleusercontent.com']);
        Http::fake(['https://oauth2.googleapis.com/tokeninfo*' => Http::response([
            'iss' => 'https://accounts.google.com',
            'aud' => 'web-client.apps.googleusercontent.com',
            'sub' => 'google-555',
            'email' => 'social-device@gmail.com',
            'email_verified' => 'true',
            'name' => 'Social',
            'exp' => (string) (time() + 600),
        ])]);

        $social = $this->postJson('/api/auth/social/google', ['id_token' => 'google-token', ...self::PIXEL])
            ->assertSuccessful()->json('token');
        $socialRow = PersonalAccessToken::findToken($social);
        $this->assertSame('Google Pixel 7', $socialRow->device_name);
        $this->assertSame('android', $socialRow->device_platform);
    }

    public function test_old_sessions_without_device_info_are_listed_and_manageable(): void
    {
        $me = User::factory()->create();

        // แอปเวอร์ชันเก่า: เข้าสู่ระบบโดยไม่ส่งข้อมูลอุปกรณ์
        $old = $this->postJson('/api/login', ['email' => $me->email, 'password' => 'password'])->assertOk()->json('token');
        [$current] = $this->appSession($me, self::PIXEL);

        $this->using($current)->getJson('/api/sessions')->assertOk()
            ->assertJsonPath('sessions.1.device_name', null)
            ->assertJsonPath('sessions.1.os_version', null);

        // แอปใหม่บอกข้อมูลของเซสชันตัวเองได้ (เฉพาะของตัวเอง)
        $this->using($old)->putJson('/api/sessions/current', ['device_name' => 'Samsung A54', 'device_platform' => 'android'])->assertOk();
        $this->assertSame('Samsung A54', PersonalAccessToken::findToken($old)->device_name);
        $this->assertSame('Google Pixel 7', PersonalAccessToken::findToken($current)->device_name);

        $this->using($current)->deleteJson('/api/sessions/' . PersonalAccessToken::findToken($old)->id)->assertOk()->assertJsonPath('revoked', 1);
        $this->using($old)->getJson('/api/user')->assertUnauthorized();
    }

    public function test_expired_sessions_are_not_listed(): void
    {
        $me = User::factory()->create();
        [$current] = $this->appSession($me);
        [, $oldId] = $this->appSession($me);

        PersonalAccessToken::whereKey($oldId)->update(['created_at' => now()->subMinutes(config('sanctum.expiration') + 5)]);

        $this->using($current)->getJson('/api/sessions')->assertOk()->assertJsonCount(1, 'sessions');
    }

    public function test_sessions_api_requires_login_and_is_rate_limited(): void
    {
        $this->getJson('/api/sessions')->assertUnauthorized();

        $me = User::factory()->create();
        [$current] = $this->appSession($me);

        foreach (range(1, 30) as $i) {
            $this->using($current)->getJson('/api/sessions')->assertOk();
        }

        $this->using($current)->getJson('/api/sessions')->assertStatus(429);
    }
}
