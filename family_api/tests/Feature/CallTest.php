<?php

namespace Tests\Feature;

use App\Models\DeviceToken;
use App\Models\FamilyMember;
use App\Models\User;
use App\Support\AppSessions;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request as HttpRequest;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// โทร 1 ต่อ 1: สถานะสาย / token LiveKit อายุสั้น / หลายเครื่อง / สิทธิ์ บล็อก เซสชัน
// ฐานข้อมูลทดสอบแยก + Push ปลอม + LiveKit ปลอม (Http::fake) — ไม่โทร/ไม่ส่งหาใครจริง
class CallTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    private const FCM_URL = 'https://fcm.googleapis.com/v1/projects/test-project/messages:send';

    private const SECRET = 'secret-for-tests';

    protected function setUp(): void
    {
        parent::setUp();

        Http::preventStrayRequests();
        $this->withoutDefer();

        config([
            'services.livekit.url' => 'https://test.livekit.cloud',
            'services.livekit.api_key' => 'APItest',
            'services.livekit.api_secret' => self::SECRET,
            'services.fcm.credentials' => base64_encode(json_encode([
                'type' => 'service_account',
                'project_id' => 'test-project',
                'client_email' => 'push@test-project.iam.gserviceaccount.com',
                'private_key' => 'unused-in-this-test',
            ])),
        ]);

        Cache::put('fcm.access_token.test-project', 'cached-access-token', 600);

        Http::fake([
            self::FCM_URL => Http::response(['name' => 'projects/test-project/messages/1']),
            'https://test.livekit.cloud/*' => Http::response([]),
        ]);
    }

    private function privateRoom(User $a, User $b): int
    {
        Sanctum::actingAs($a);

        return $this->postJson('/api/chats', ['user_id' => $b->id])->assertSuccessful()->json('conversation.id');
    }

    private function ring(User $caller, int $room, string $type = 'audio'): int
    {
        Sanctum::actingAs($caller);

        return $this->postJson('/api/calls', ['conversation_id' => $room, 'type' => $type])
            ->assertCreated()
            ->assertJsonPath('call.status', 'ringing')
            ->json('call.id');
    }

    private function device(User $user, string $fid): void
    {
        DeviceToken::create([
            'user_id' => $user->id,
            'access_token_id' => $user->createToken(AppSessions::TOKEN_NAME)->accessToken->id,
            'token' => $fid,
        ]);
    }

    private function pushes(): Collection
    {
        return collect(Http::recorded())
            ->filter(fn ($pair) => $pair[0]->url() === self::FCM_URL)
            ->map(fn ($pair) => $pair[0]['message'])
            ->values();
    }

    // ตรวจลายเซ็น HS256 ของ token แล้วคืน claims
    private function claims(string $jwt): array
    {
        [$header, $payload, $signature] = explode('.', $jwt);

        $expected = rtrim(strtr(base64_encode(hash_hmac('sha256', $header . '.' . $payload, self::SECRET, true)), '+/', '-_'), '=');
        $this->assertSame($expected, $signature);

        return json_decode(base64_decode(strtr($payload, '-_', '+/')), true);
    }

    public function test_ring_answer_on_one_device_and_hang_up(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);
        $this->device($son, 'son-phone');
        $this->device($son, 'son-tablet');

        Sanctum::actingAs($mom);
        $start = $this->postJson('/api/calls', ['conversation_id' => $room, 'type' => 'video'])
            ->assertCreated()
            ->assertJsonPath('call.status', 'ringing')
            ->assertJsonPath('call.role', 'caller')
            ->assertJsonPath('livekit.url', 'wss://test.livekit.cloud');

        // token อายุสั้น ผูกห้องเดียว ชื่อห้องไม่ส่งออกมาตรง ๆ
        $caller = $this->claims($start->json('livekit.token'));
        $this->assertSame('u' . $mom->id, $caller['sub']);
        $this->assertTrue($caller['video']['roomJoin']);
        $this->assertSame(['microphone', 'camera'], $caller['video']['canPublishSources']);
        $this->assertLessThanOrEqual(310, $caller['exp'] - $caller['nbf']);
        $this->assertArrayNotHasKey('room', $start->json('call'));
        $callId = $start->json('call.id');

        // แจ้งเตือนสายเข้าทุกเครื่องของลูก ไม่มีเนื้อหาแชท
        $ring = $this->pushes()->where('data.status', 'ringing');
        $this->assertEqualsCanonicalizing(['son-phone', 'son-tablet'], $ring->pluck('fid')->all());
        $this->assertSame('วิดีโอคอลเข้า', $ring->first()['notification']['title']);
        $this->assertSame('call-' . $callId, $ring->first()['android']['notification']['tag']);

        // ลูกเปิดแอป → เห็นสายที่กำลังเรียก / รับสายที่เครื่องหนึ่ง
        Sanctum::actingAs($son);
        $this->getJson('/api/calls/active')->assertJsonPath('call.id', $callId);
        $accept = $this->postJson("/api/calls/{$callId}/accept")->assertOk()->assertJsonPath('call.status', 'accepted');
        $callee = $this->claims($accept->json('livekit.token'));
        $this->assertSame('u' . $son->id, $callee['sub']);
        $this->assertSame($caller['video']['room'], $callee['video']['room']);

        // อีกเครื่องกดรับพร้อมกัน → ไม่สำเร็จ / แจ้งเตือนสายเข้าบนเครื่องอื่นถูกแทนที่
        $this->postJson("/api/calls/{$callId}/accept")
            ->assertStatus(409)
            ->assertJsonPath('code', 'call_accepted')
            ->assertJsonPath('message', 'รับสายที่อุปกรณ์อื่นแล้ว');
        $answered = $this->pushes()->where('data.status', 'accepted')->first();
        $this->assertSame('รับสายที่อุปกรณ์อื่นแล้ว', $answered['notification']['body']);
        $this->assertSame('call-' . $callId, $answered['android']['notification']['tag']);
        $this->getJson('/api/calls/active')->assertJsonPath('call', null);

        // ระหว่างสาย: heartbeat ได้ token ใหม่
        $this->postJson("/api/calls/{$callId}/heartbeat")->assertOk()->assertJsonStructure(['livekit' => ['url', 'token']]);

        // แม่วางสาย → จบ + ลบห้อง LiveKit (ทุกคนหลุด) / กดรับหลังจบไม่ได้
        Sanctum::actingAs($mom);
        $this->postJson("/api/calls/{$callId}/hangup")->assertOk()->assertJsonPath('call.status', 'ended');
        Http::assertSent(fn (HttpRequest $request) => $request->url() === 'https://test.livekit.cloud/twirp/livekit.RoomService/DeleteRoom'
            && $request['room'] === $caller['video']['room']);

        Sanctum::actingAs($son);
        $this->postJson("/api/calls/{$callId}/accept")->assertStatus(409)->assertJsonPath('code', 'call_ended');
        $this->postJson("/api/calls/{$callId}/heartbeat")->assertOk()->assertJsonMissingPath('livekit');
    }

    public function test_decline_cancel_missed_busy_and_one_call_at_a_time(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $dad = User::factory()->create();
        $this->createFamily($mom, [$son, $dad]);
        $room = $this->privateRoom($mom, $son);
        $dadRoom = $this->privateRoom($dad, $son);
        $momDad = $this->privateRoom($mom, $dad);
        $this->device($son, 'son-phone');

        // ปฏิเสธ
        $id = $this->ring($mom, $room);
        Sanctum::actingAs($son);
        $this->postJson("/api/calls/{$id}/decline")->assertOk()->assertJsonPath('call.status', 'declined');
        Sanctum::actingAs($mom);
        $this->getJson("/api/calls/{$id}")->assertJsonPath('call.status', 'declined');

        // ผู้โทรยกเลิก → แจ้งเตือน "สายที่ไม่ได้รับ" แทนที่แจ้งเตือนสายเข้าเดิม
        $id = $this->ring($mom, $room);
        $this->postJson("/api/calls/{$id}/hangup")->assertOk()->assertJsonPath('call.status', 'cancelled');
        $missed = $this->pushes()->where('data.call_id', (string) $id)->where('data.status', 'cancelled')->first();
        $this->assertSame('สายที่ไม่ได้รับ', $missed['notification']['title']);
        $this->assertSame('call-' . $id, $missed['android']['notification']['tag']);

        // ไม่รับใน 45 วินาที → missed (กดรับทีหลังไม่ได้)
        $id = $this->ring($mom, $room);
        $this->travel(46)->seconds();
        Sanctum::actingAs($son);
        $this->postJson("/api/calls/{$id}/accept")->assertStatus(409)->assertJsonPath('code', 'call_missed');
        $this->travelBack();

        // ลูกคุยกับแม่อยู่ → พ่อโทรหาลูก = สายไม่ว่าง (ไม่เรียกเข้า ไม่มี token)
        $id = $this->ring($mom, $room);
        Sanctum::actingAs($son);
        $this->postJson("/api/calls/{$id}/accept")->assertOk();
        $ringsBefore = $this->pushes()->where('data.status', 'ringing')->count();

        Sanctum::actingAs($dad);
        $this->postJson('/api/calls', ['conversation_id' => $dadRoom, 'type' => 'audio'])
            ->assertCreated()
            ->assertJsonPath('call.status', 'busy')
            ->assertJsonMissingPath('livekit');
        $this->assertSame($ringsBefore, $this->pushes()->where('data.status', 'ringing')->count());

        // แม่มีสายอยู่ → เริ่มสายใหม่ไม่ได้
        Sanctum::actingAs($mom);
        $this->postJson('/api/calls', ['conversation_id' => $momDad, 'type' => 'audio'])
            ->assertStatus(409)
            ->assertJsonPath('code', 'already_in_call');
    }

    public function test_room_permission_blocks_sessions_and_leaving_the_group_end_calls(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $outsider = User::factory()->create();
        $family = $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);

        // คนนอกห้องโทรผ่านห้องนี้ไม่ได้
        Sanctum::actingAs($outsider);
        $this->postJson('/api/calls', ['conversation_id' => $room, 'type' => 'audio'])->assertNotFound();

        // บล็อกระหว่างคุย → สายจบทันที + ลบห้อง / โทรหาคนที่บล็อกไม่ได้
        $id = $this->ring($mom, $room);
        Sanctum::actingAs($son);
        $this->postJson("/api/calls/{$id}/accept")->assertOk();
        Sanctum::actingAs($mom);
        $this->postJson("/api/users/{$son->id}/block")->assertOk();
        $this->getJson("/api/calls/{$id}")
            ->assertJsonPath('call.status', 'failed')
            ->assertJsonPath('call.end_reason', 'blocked');
        Http::assertSent(fn (HttpRequest $request) => str_contains($request->url(), 'DeleteRoom'));
        $this->postJson('/api/calls', ['conversation_id' => $room, 'type' => 'audio'])
            ->assertForbidden()
            ->assertJsonPath('code', 'not_allowed');
        $this->deleteJson("/api/users/{$son->id}/block")->assertOk();

        // เพิกถอนเซสชันที่ใช้รับสาย → สายจบ
        app('auth')->forgetGuards();
        $momToken = $mom->createToken(AppSessions::TOKEN_NAME)->plainTextToken;
        $sonPhone = $son->createToken(AppSessions::TOKEN_NAME);
        $sonTablet = $son->createToken(AppSessions::TOKEN_NAME)->plainTextToken;

        $id = $this->withToken($momToken)->postJson('/api/calls', ['conversation_id' => $room, 'type' => 'audio'])
            ->assertCreated()->json('call.id');
        app('auth')->forgetGuards();
        $this->withToken($sonPhone->plainTextToken)->postJson("/api/calls/{$id}/accept")->assertOk();
        app('auth')->forgetGuards();
        $this->withToken($sonTablet)->deleteJson('/api/sessions/' . $sonPhone->accessToken->id)->assertOk();
        app('auth')->forgetGuards();
        $this->withToken($momToken)->getJson("/api/calls/{$id}")
            ->assertJsonPath('call.status', 'failed')
            ->assertJsonPath('call.end_reason', 'session_revoked');

        // ลูกออกจากกลุ่มระหว่างคุย → heartbeat ของแม่พบว่าหมดสิทธิ์ → สายจบ
        app('auth')->forgetGuards();
        $id = $this->ring($mom, $room);
        Sanctum::actingAs($son);
        $this->postJson("/api/calls/{$id}/accept")->assertOk();
        FamilyMember::where('family_id', $family->id)->where('user_id', $son->id)->delete();

        Sanctum::actingAs($mom);
        $this->postJson("/api/calls/{$id}/heartbeat")
            ->assertForbidden()
            ->assertJsonPath('code', 'not_allowed')
            ->assertJsonPath('call.status', 'failed');
    }

    public function test_calls_stay_off_until_livekit_is_configured(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);

        config(['services.livekit.url' => null]);

        Sanctum::actingAs($mom);
        $this->postJson('/api/calls', ['conversation_id' => $room, 'type' => 'audio'])
            ->assertStatus(503)
            ->assertJsonPath('code', 'calls_unavailable');
        $this->getJson("/api/chats/{$room}/messages")->assertJsonPath('conversation.calls_enabled', false);

        config(['services.livekit.url' => 'wss://test.livekit.cloud/']);
        $this->getJson("/api/chats/{$room}/messages")->assertJsonPath('conversation.calls_enabled', true);

        // ใส่ wss:// มา → แอปได้ wss:// / ที่อยู่ API เป็น https://
        $this->postJson('/api/calls', ['conversation_id' => $room, 'type' => 'audio'])
            ->assertJsonPath('livekit.url', 'wss://test.livekit.cloud');
        $this->assertSame('https://test.livekit.cloud', \App\Support\LiveKit::apiUrl());
    }
}
