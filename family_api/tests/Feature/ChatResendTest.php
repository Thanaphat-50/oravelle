<?php

namespace Tests\Feature;

use App\Models\ChatMessage;
use App\Models\DeviceToken;
use App\Models\User;
use App\Support\MediaStorage;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\Concerns\FakesImages;
use Tests\TestCase;

// แอปส่งข้อความซ้ำด้วย client_id เดิม (หมดเวลารอ / กดส่งใหม่) → ข้อความเดียว แจ้งเตือนครั้งเดียว
class ChatResendTest extends TestCase
{
    use CreatesFamilies, FakesImages, RefreshDatabase;

    private const FCM_URL = 'https://fcm.googleapis.com/v1/projects/test-project/messages:send';

    private function room(): array
    {
        $mom = User::factory()->create(['name' => 'Mom']);
        $son = User::factory()->create(['name' => 'Son']);

        $this->createFamily($mom, [$son]);

        Sanctum::actingAs($mom);

        $roomId = $this->postJson('/api/chats', ['user_id' => $son->id])->assertOk()->json('conversation.id');

        return [$mom, $son, $roomId];
    }

    public function test_resending_with_the_same_client_id_returns_the_first_message(): void
    {
        $this->withoutDefer();
        Http::preventStrayRequests();
        config(['services.fcm.credentials' => base64_encode(json_encode([
            'project_id' => 'test-project',
            'client_email' => 'push@test-project.iam.gserviceaccount.com',
            'private_key' => 'unused',
        ]))]);
        Cache::put('fcm.access_token.test-project', 'cached-access-token', 600);
        Http::fake([self::FCM_URL => Http::response(['name' => 'ok'])]);

        [$mom, $son, $roomId] = $this->room();

        DeviceToken::create([
            'user_id' => $son->id,
            'access_token_id' => $son->createToken('app')->accessToken->id,
            'token' => 'son-phone',
        ]);

        Sanctum::actingAs($mom);

        $first = $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'กินข้าวยัง', 'client_id' => 'c-1'])
            ->assertCreated()
            ->assertJsonPath('message.client_id', 'c-1')
            ->json('message.id');

        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'กินข้าวยัง', 'client_id' => 'c-1'])
            ->assertOk()
            ->assertJsonPath('message.id', $first);

        $this->assertSame(1, ChatMessage::count());
        Http::assertSentCount(1);

        // รหัสใหม่ = ข้อความใหม่ (พิมพ์ข้อความเดิมซ้ำตั้งใจได้)
        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'กินข้าวยัง', 'client_id' => 'c-2'])->assertCreated();

        // แอปเวอร์ชันเก่า (ไม่มี client_id) ยังส่งได้เหมือนเดิม
        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'ok'])->assertCreated();
        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'ok'])->assertCreated();

        $this->assertSame(4, ChatMessage::count());

        // อีกฝ่ายไม่เห็น client_id ของเรา
        Sanctum::actingAs($son);

        $this->getJson("/api/chats/{$roomId}/messages")
            ->assertOk()
            ->assertJsonPath('messages.0.client_id', null);
    }

    public function test_resent_image_is_not_stored_twice(): void
    {
        Storage::fake(MediaStorage::disk());

        [$mom, , $roomId] = $this->room();

        Sanctum::actingAs($mom);

        $this->post("/api/chats/{$roomId}/messages", ['image' => $this->fakePng('a.png'), 'client_id' => 'img-1'], ['Accept' => 'application/json'])
            ->assertCreated();

        $this->post("/api/chats/{$roomId}/messages", ['image' => $this->fakePng('a.png'), 'client_id' => 'img-1'], ['Accept' => 'application/json'])
            ->assertOk();

        $this->assertSame(1, ChatMessage::count());
        $this->assertCount(1, Storage::disk(MediaStorage::disk())->allFiles('chat_images'));
    }

    public function test_client_id_is_per_sender(): void
    {
        [$mom, $son, $roomId] = $this->room();

        Sanctum::actingAs($mom);
        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'แม่', 'client_id' => 'same'])->assertCreated();

        // อีกคนใช้รหัสเดียวกันโดยบังเอิญ → ไม่ได้ข้อความของคนอื่น
        Sanctum::actingAs($son);
        $this->postJson("/api/chats/{$roomId}/messages", ['body' => 'ลูก', 'client_id' => 'same'])
            ->assertCreated()
            ->assertJsonPath('message.body', 'ลูก');
    }
}
